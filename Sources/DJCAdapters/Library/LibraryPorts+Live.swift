import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCStorage
import Foundation
import ImageIO
import RekordboxKit

extension LibraryPorts {
    /// 이 Mac의 실제 구현: 위치 값(`location`)의 rekordbox 폴더·초안 폴더와 초안 저장소 `drafts`(조립 지점이 덱·반영과 같은 저장 큐로 만든다),
    /// 반영 XML 묶음 저장 `batches`(조립 지점이 데이터 폴더의 파일로 붙인다)
    public static func live(location: LibraryLocation, drafts: DraftStore, batches: ReflectionBatchStore) -> LibraryPorts {
        LibraryPorts(source: .live, music: .live(rekordboxDirectory: location.rekordboxDirectory), drafts: drafts,
                     musicOrder: .shared, previews: .live, xml: .live, draftFiles: .live(home: location.draftHome), batches: batches,
                     staging: .live(home: location.draftHome), files: .live, analysis: .live, recovery: .live,
                     playlistImports: .live(url: DraftLocations(home: location.draftHome).playlistImports), backups: .live(), artwork: .live, relocate: .live,
                     query: .live(home: location.draftHome), appleMusic: .live, liveShare: location.liveShare,
                     linkedXML: DJCIdentity.linkedXMLFile, usbSnapshots: .live, snapshots: .live(location), localKeys: .live,
                     prepareMerge: { try RekordboxWriter.prepareMerge(keeping: $0, removing: $1, snapshot: $2) },
                     now: { Date() }, today: { String(ISO8601DateFormatter().string(from: .now).prefix(10)) }, newKey: { UUID().uuidString })
    }
}

extension PreviewWaveforms {
    /// 이 프로세스의 미리 보기 파형 캐시(`PreviewWaveformStore.shared`, 데이터 폴더의 파일)
    public static let live = live(store: .shared)

    /// 미리 보기 파형 캐시 `store`를 분석 파일에서 채우고 읽는다. 음원 파형은 DJCAnalysis 파형 캐시(`DJC_HOME`을 따른다)
    public static func live(store: PreviewWaveformStore) -> PreviewWaveforms {
        PreviewWaveforms(
            warm: { tracks, shareRoot in
                await store.warm(tracks.map {
                    PreviewWaveformStore.Source(uuid: $0.uuid, url: RekordboxShare.analysisURL($0.analysisPath, root: shareRoot))
                })
            },
            revision: { key, file in await store.revision(for: PreviewWaveformStore.Source(uuid: key, url: file)) },
            waveform: { key, file in await store.waveform(for: PreviewWaveformStore.Source(uuid: key, url: file)) },
            audioColumns: { audio, key in (try? WaveformCache.load(fileAt: audio, key: key))?.downsampled(to: 400).colorColumns },
            clear: { await store.clear() },
            // 미리 보기는 .DAT와 옆 .EXT를 연다. 둘 다 성분마다 lstat으로 링크를 거른다(UsbRoot)
            volumeFile: { root, path in
                let volume = UsbRoot(root)
                guard let dat = try? volume.url(for: path),
                      (try? volume.url(for: (path as NSString).deletingPathExtension + ".EXT")) != nil else { return nil }
                return dat
            })
    }
}

extension PlaylistImportsStore {
    /// 데이터 폴더의 연결 기록 파일
    public static func live(url: URL) -> PlaylistImportsStore {
        PlaylistImportsStore(load: { try PlaylistImportStore.load(url: url) }, save: { try PlaylistImportStore.save($0, url: url) })
    }
}

extension ArtworkFiles {
    /// rekordbox가 받는 그림 규칙(RekordboxKit)과 초안 사본 이름(SHA-256, DJCStorage), share의 rekordbox 그림(RekordboxKit)
    public static let live = ArtworkFiles(
        unsupportedReason: { TrackArtwork.unsupportedReason($0) },
        edit: { ArtworkDraftStore.edit(trackUUID: $0, base: $1, image: $2, imageName: $3) },
        thumbnail: { RekordboxShare.artworkThumbnail($0, root: $1, maxPixels: $2) },
        listThumbnail: { path, root in
            guard let url = RekordboxShare.artworkURL(path, size: .small, root: root),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
            ] as CFDictionary)
        },
        // 볼륨 안 경로는 성분마다 lstat으로 링크를 거른다(UsbRoot). 문자열 검사만으로는 링크를 따라 열지 않는 자리에 닿는다
        volumeThumbnail: { root, path, maxPixels in
            guard let url = try? UsbRoot(root).url(for: path), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        })
}
