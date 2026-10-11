import DJCApplication
import DJCDomain
import Foundation

/// USB 곡 → 목록 줄(읽기 전용). 곡 ID는 로컬 곡과 겹치지 않게 `usb:<볼륨키>:<content_id>`로 짓는다.
/// 곡의 분석·아트워크 경로(`Track`)는 비운다: 로컬 share를 기준으로 찾는 곳(덱·반영·미리 데우기)이 로컬의 다른 파일을 읽는다.
/// 목록의 앨범아트·미리 보기 칸은 줄의 `usbFiles`(볼륨 뿌리와 볼륨 안 경로)로 USB에서 읽는다(#256).
/// - Parameters:
///   - revision: 그 볼륨을 읽은 판(`UsbStore`). 다시 읽으면 오른다
///   - commentRule: 분류 칸의 코멘트 규칙(로컬 줄과 같은 지금 프리셋)
enum UsbLibraryRows {
    static let idPrefix = TrackRow.usbIDPrefix

    static func trackID(volumeKey: String, contentID: Int) -> String { "\(idPrefix)\(volumeKey):\(contentID)" }

    /// 컬렉션: content_id 순
    static func collection(library: UsbLibrary, volumeKey: String, mountPoint: String, badges: [Int: UsbSyncStatus],
                           revision: Int = 0, commentRule: (any CommentRule)? = nil) -> [TrackRow] {
        let names = Names(library)
        return library.tracks.map {
            row($0, names: names, volumeKey: volumeKey, mountPoint: mountPoint, badge: badges[$0.id], revision: revision, commentRule: commentRule)
        }
    }

    /// 재생 목록: 항목 순서 그대로. 같은 곡이 여러 번 들어 있어도 줄마다 따로 고르게 줄 ID를 곡과 그 곡의 몇 번째 출현으로 짓는다
    /// (로컬 목록과 같다). 자리로 지으면 순서를 바꿔도 ID가 그대로라 선택이 옮긴 곡을 따라가지 않고 표가 줄을 다시 놓지 않는다(#240)
    static func playlist(_ id: Int, library: UsbLibrary, volumeKey: String, mountPoint: String,
                         badges: [Int: UsbSyncStatus], revision: Int = 0, commentRule: (any CommentRule)? = nil) -> [TrackRow] {
        guard let playlist = library.playlists.first(where: { $0.id == id }) else { return [] }
        let names = Names(library)
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var occurrences: [Int: Int] = [:]
        return entries(of: playlist).enumerated().compactMap { position, contentID in
            guard let track = tracks[contentID] else { return nil }
            let occurrence = occurrences[contentID, default: 0]
            occurrences[contentID] = occurrence + 1
            var row = row(track, names: names, volumeKey: volumeKey, mountPoint: mountPoint, badge: badges[contentID], revision: revision,
                          commentRule: commentRule)
            row.playlistOccurrence = .init(id: "\(idPrefix)\(volumeKey):pl\(id):\(contentID):\(occurrence)", number: position + 1)
            return row
        }
    }

    /// 보일 항목: OneLibrary에 있으면 그 순서(합친 모델이 앞세우는 쪽), 없으면 Device Library
    static func entries(of playlist: UsbPlaylist) -> [Int] { UsbSyncPlan.entries(of: playlist) }

    /// 이름 표(아티스트·앨범·장르·키)와 아트워크
    struct Names {
        var artists: [Int: String]
        var albums: [Int: UsbAlbum]
        var genres: [Int: String]
        var keys: [Int: String]
        var images: [Int: UsbImage]

        init(_ library: UsbLibrary) {
            func table(_ rows: [UsbNamedRow]) -> [Int: String] {
                Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            artists = table(library.artists)
            albums = Dictionary(library.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            genres = table(library.genres)
            keys = table(library.keys)
            images = Dictionary(library.images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    static func row(_ track: UsbTrack, names: Names, volumeKey: String, mountPoint: String, badge: UsbSyncStatus?, revision: Int,
                    commentRule: (any CommentRule)?) -> TrackRow {
        let id = trackID(volumeKey: volumeKey, contentID: track.id)
        let album = track.albumID.flatMap { names.albums[$0] }
        let model = Track(
            id: id, uuid: id, title: track.title, artist: track.artistID.flatMap { names.artists[$0] }, album: album?.name,
            albumArtist: album?.artistID.flatMap { names.artists[$0] }, genre: track.genreID.flatMap { names.genres[$0] },
            composer: track.composerID.flatMap { names.artists[$0] }, releaseYear: track.releaseYear > 0 ? track.releaseYear : nil,
            trackNumber: track.trackNo > 0 ? track.trackNo : nil, key: track.keyID.flatMap { names.keys[$0] },
            bpm: track.bpmx100 > 0 ? Double(track.bpmx100) / 100 : nil, lengthSeconds: track.lengthSeconds,
            folderPath: mountPoint + track.path, comment: track.comment, importedOn: track.dateAdded.isEmpty ? nil : track.dateAdded,
            analysisDataPath: nil, imagePath: nil, isDeleted: false, bitrateKbps: track.bitrate,
            // 거르기(평점·곡 색)도 로컬 곡과 같게 한다. USB 색 번호 1~8은 rekordbox 색과 같은 순서다(읽기 전용)
            rating: track.rating, colorID: track.colorID > 0 ? String(track.colorID) : nil)
        var row = TrackRow(track: model, cues: [], playCount: track.djPlayCount, commentRule: commentRule)
        row.usbSync = badge
        // 작은 그림은 두 형식이 같은 바이트(rekordbox의 `artwork_s.jpg`)다. OneLibrary 쪽(b)을 먼저, 없으면 Device Library 쪽(a)
        let image = track.imageID.flatMap { names.images[$0] }
        let artwork = [image?.oneLibraryPath, image?.pdbPath].lazy.compactMap { $0 }
            .compactMap { UsbLayout.readablePath($0, under: UsbLayout.artworkRoot) }.first
        row.usbFiles = TrackRow.UsbFiles(root: URL(filePath: mountPoint), artwork: artwork,
                                         analysis: UsbLayout.readablePath(track.analysisDataPath, under: UsbLayout.analysisRoot),
                                         revision: revision)
        return row
    }
}

/// 갱신 상태 칸 글자
enum UsbSyncText {
    static func text(_ status: UsbSyncStatus?) -> String {
        switch status {
        case nil: ""
        case .upToDate: String(ui: "최신")
        case .localNewer: String(ui: "갱신 가능")
        case .deviceModified: String(ui: "기기에서 고침")
        case .missingLocal: String(ui: "로컬에 없음")
        }
    }
}

extension TrackRow {
    var usbSyncText: String { UsbSyncText.text(usbSync) }
}
