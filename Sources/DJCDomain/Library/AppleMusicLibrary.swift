import Foundation

/// 사용자가 Music·iTunes에서 내보낸 XML만 읽는다(값과 해석, 파일 확인은 부르는 쪽이 준다). 보관함 DB와 음원은 고치지 않는다.
public struct AppleMusicLibrary: Sendable {
    public var id: String?
    public var tracks: [Track]
    public var playlists: [Playlist]

    public struct Track: Identifiable, Sendable {
        public var id: Int
        public var title: String
        public var artist: String
        public var fileURL: URL?
        public var exclusion: Exclusion?
    }

    public struct Playlist: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var trackIDs: [Int]
    }

    public enum Exclusion: Sendable {
        case protectedContent, streaming, cloudOnly, invalidLocation, unavailableFile, unsupportedFormat

        public var message: String {
            switch self {
            case .protectedContent: String(ui: "보호된 곡은 가져올 수 없습니다. DRM 없는 로컬 음원을 준비하세요.")
            case .streaming: String(ui: "스트리밍 곡은 가져올 수 없습니다. 로컬 음원을 준비하세요.")
            case .cloudOnly: String(ui: "로컬 파일 위치가 없습니다. 음원을 내려받고 XML을 다시 내보내세요.")
            case .invalidLocation: String(ui: "파일 위치를 읽을 수 없습니다. 이 Mac에서 XML을 다시 내보내세요.")
            case .unavailableFile: String(ui: "파일을 읽을 수 없습니다. 드라이브 연결과 파일 접근 권한을 확인하세요.")
            case .unsupportedFormat: String(ui: "지원하지 않는 형식입니다. MP3·M4A·WAV·AIFF·FLAC 등의 음원을 준비하세요.")
            }
        }
    }

    public enum ParseError: Error, LocalizedError {
        case invalidLibrary
        public var errorDescription: String? {
            String(ui: "보관함 XML을 읽을 수 없습니다. Music의 파일 › 보관함 › 보관함 내보내기에서 만든 XML을 고르세요.")
        }
    }

    /// - Parameter isReadableFile: 그 음원 파일을 읽을 수 있는지(이 Mac의 파일 시스템, DJCStorage `isReadableFile`)
    public static func parse(_ data: Data, isReadableFile: (URL) -> Bool) throws -> Self {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              format == .xml, let rawTracks = root["Tracks"] as? [String: [String: Any]] else {
            throw ParseError.invalidLibrary
        }
        var tracks: [Track] = []
        var seenTracks = Set<Int>()
        for (key, raw) in rawTracks {
            guard let id = Int(key), id > 0, seenTracks.insert(id).inserted,
                  raw["Track ID"] == nil || raw["Track ID"] as? Int == id else { throw ParseError.invalidLibrary }
            let location = raw["Location"] as? String ?? ""
            let url = location.isEmpty ? nil : URL(string: location)
            let reason = exclusion(raw, url: url, location: location, isReadableFile: isReadableFile)
            tracks.append(Track(id: id, title: raw["Name"] as? String ?? String(ui: "제목 없음"),
                                artist: raw["Artist"] as? String ?? "", fileURL: url?.isFileURL == true ? url : nil,
                                exclusion: reason))
        }
        var playlists: [Playlist] = []
        var seenPlaylists = Set<String>()
        if let value = root["Playlists"], !(value is [[String: Any]]) { throw ParseError.invalidLibrary }
        for raw in root["Playlists"] as? [[String: Any]] ?? [] {
            if raw["Master"] as? Bool == true || raw["Folder"] as? Bool == true { continue }
            guard let id = raw["Playlist Persistent ID"] as? String ?? (raw["Playlist ID"] as? Int).map(String.init),
                  !id.isEmpty, seenPlaylists.insert(id).inserted else { throw ParseError.invalidLibrary }
            if let value = raw["Playlist Items"], !(value is [[String: Any]]) { throw ParseError.invalidLibrary }
            let items = raw["Playlist Items"] as? [[String: Any]] ?? []
            // 알 수 없는 참조도 남겨 뒤쪽 곡의 순서가 앞당겨지지 않게 한다.
            let ids = try items.map { item in
                guard let id = item["Track ID"] as? Int, id > 0 else { throw ParseError.invalidLibrary }
                return id
            }
            playlists.append(Playlist(id: id, name: raw["Name"] as? String ?? String(ui: "이름 없는 재생 목록"),
                                      parentID: raw["Parent Persistent ID"] as? String, trackIDs: ids))
        }
        return Self(id: root["Library Persistent ID"] as? String, tracks: tracks.sorted { $0.id < $1.id }, playlists: playlists)
    }

    public func selectedTracks(trackIDs: Set<Int>, playlistIDs: Set<String> = []) -> [Track] {
        let selected = trackIDs.union(playlists.filter { playlistIDs.contains($0.id) }.flatMap(\.trackIDs))
        return tracks.filter { selected.contains($0.id) && $0.exclusion == nil }
    }

    public func origin(for trackID: Int) -> AppleMusicOrigin {
        AppleMusicOrigin(libraryID: id, trackID: trackID, playlists: playlists.flatMap { playlist in
            playlist.trackIDs.enumerated().compactMap { position, id in
                id == trackID ? AppleMusicOrigin.Playlist(id: playlist.id, name: playlist.name,
                                                         parentID: playlist.parentID, position: position) : nil
            }
        })
    }

    private static func exclusion(_ raw: [String: Any], url: URL?, location: String,
                                  isReadableFile: (URL) -> Bool) -> Exclusion? {
        let kind = (raw["Kind"] as? String ?? "").lowercased()
        if raw["Protected"] as? Bool == true || raw["Apple Music"] as? Bool == true
            || kind.contains("protected") || kind.contains("apple music") || url?.pathExtension.lowercased() == "m4p" {
            return .protectedContent
        }
        if raw["Track Type"] as? String == "URL" || ["http", "https", "itms", "itmss"].contains(url?.scheme?.lowercased() ?? "") {
            return .streaming
        }
        if location.isEmpty { return .cloudOnly }
        guard let url, url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return .invalidLocation }
        guard raw["Has Video"] as? Bool != true, StagedTrack.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return .unsupportedFormat
        }
        return isReadableFile(url) ? nil : .unavailableFile
    }
}
