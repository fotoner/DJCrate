import DJCDomain
import AVFoundation
import Foundation

/// 파일에서 추가할 곡 만들기(태그 읽기)·폴더 훑기.
public extension StagedTrack {
    /// 파일 태그로 만든다. 태그가 없으면 파일 이름을 제목으로 쓴다.
    static func make(fileAt url: URL, addedOn: String) async throws -> StagedTrack {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let items = (try? await asset.load(.metadata)) ?? []
        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
        let title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        let artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        let album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        let genre = await string([.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre, .commonIdentifierType])
        let composer = await string([.id3MetadataComposer, .iTunesMetadataComposer, .quickTimeMetadataComposer])
        let comment = await string([.id3MetadataComments, .iTunesMetadataUserComment, .quickTimeMetadataComment])
        let yearText = await string([.id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate])
        var trackText = await string([.id3MetadataTrackNumber])
        // iTunes(M4A) 트랙 번호는 문자열이 아니라 8바이트 데이터다: 0,0,번호(2바이트),총수(2바이트),0,0
        if trackText == nil, let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataTrackNumber).first,
           let data = try? await item.load(.dataValue), data.count >= 4 {
            let bytes = [UInt8](data)
            let number = Int(bytes[2]) << 8 | Int(bytes[3])
            if number > 0 { trackText = String(number) }
        }
        var track = StagedTrack(uuid: UUID().uuidString.lowercased(), path: url.path, title: title ?? url.deletingPathExtension().lastPathComponent,
                                artist: artist, album: album, genre: genre, composer: composer,
                                year: yearText.flatMap { Int($0.prefix(4)) },
                                trackNumber: trackText.flatMap { Int($0.split(separator: "/").first ?? "") },
                                comment: comment ?? "", duration: duration.isFinite ? duration : 0, addedOn: addedOn)
        // 태그에 키가 없으면 비워 두고 백그라운드에서 추정한다.
        if let key = await tagKey(in: items) {
            track.key = key
            track.keySource = .tag
        }
        return track
    }

    /// 파일 태그의 키(Camelot). 없거나 읽을 수 없는 표기면 nil. 음원은 읽기만 한다.
    static func tagKey(fileAt url: URL) async -> String? {
        await tagKey(in: (try? await AVURLAsset(url: url).load(.metadata)) ?? [])
    }

    /// ID3 TKEY, iTunes 자유 형식 `initialkey`, Vorbis `KEY` 등 키 칸을 찾아 Camelot으로 바꾼다.
    private static func tagKey(in items: [AVMetadataItem]) async -> String? {
        for item in items {
            let id = item.identifier?.rawValue.lowercased() ?? ""
            guard id.hasSuffix("/tkey") || id.hasSuffix("initialkey") || id.hasSuffix("/key") else { continue }
            if let text = try? await item.load(.stringValue), let key = KeyNotation.camelot(from: text) { return key }
        }
        return nil
    }

    /// 폴더는 펼치고, rekordbox가 못 읽는 형식은 뺀다.
    static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if supportedExtensions.contains(file.pathExtension.lowercased()) { result.append(file) }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// 추가한 곡 목록 파일(Application Support/DJCrate/staged.json). 앱·유스케이스는 포트 `StagingStore`(DJCApplication)로 읽고 쓴다.
public enum StagedTrackFile {
    public static let fileName = DraftFileNames.staged
    public static var url: URL {
        DJCPaths.userData.appending(path: fileName)
    }

    /// 없거나 읽지 못하면 빈 목록. 앱은 읽기 전에 손상된 파일을 옮겨 보관하고 알린다(`DamagedDrafts.preserveAll`).
    public static func load(url: URL = url) -> [StagedTrack] {
        (try? DamagedDrafts.read([StagedTrack].self, at: url)) ?? []
    }

    public static func save(_ tracks: [StagedTrack], url: URL = url) throws {
        // 손상된 파일은 새 목록으로 덮지 않고 옮겨 보관한다. 곡 파일 경로가 들어 있어 사용자가 다시 추가할 수 있게 남긴다(#178).
        try DamagedDrafts.preserveIfDamaged([StagedTrack].self, at: url, home: url.deletingLastPathComponent(), trackUUID: nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tracks).write(to: url, options: .atomic)
    }
}
