import DJCDomain
import Foundation
import RekordboxKit

extension ITunesLibrarySnapshot {
    /// 선택 창을 처음 열 때의 선택(동기화 원문에서 맨 위를 골랐는지 읽는다)
    public var initialSelection: ITunesSyncSelection {
        initialSelection(rootSelected: syncData.map(Self.rootSelected) ?? false)
    }

    /// 동기화 원문에서 맨 위(Music 보관함 전체)를 골랐는지
    public static func rootSelected(_ syncData: Data) -> Bool {
        (try? RekordboxITunesSelection.parse(syncData))?.nodes.contains(where: { $0.id == "0" && $0.isSelected }) ?? false
    }

    /// 사본을 쓸 때의 파일 보호 등급. `.completeFileProtectionUnlessOpen`은 화면이 잠기면 닫힌 파일을 다시 열 수 없어(EPERM),
    /// 잠금 중 백그라운드 갱신이 사본을 읽지 못하고 잃었다(#187). 첫 잠금 해제 뒤에는 잠겨도 읽고 덮어쓸 수 있는 등급을 쓴다.
    /// 이 파일은 rekordbox 목록 구성 사본이라 인증값이 없어, 잠금 중 열람을 막을 이유가 없다.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    public func save(for database: URL) throws {
        let destination = Self.url(for: database)
        let pending = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).itunes.part")
        defer { try? FileManager.default.removeItem(at: pending) }
        try JSONEncoder().encode(self).write(to: pending, options: Self.writeOptions)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: pending)
        } else {
            try FileManager.default.moveItem(at: pending, to: destination)
        }
    }

    public static func load(for database: URL) -> Self {
        let file = url(for: database)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self(status: .notCaptured) }
        do {
            let snapshot = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            // 읽는 중은 메모리 상태라 파일에 적혀 있으면 읽지 못한 사본으로 본다(안 그러면 진행 안내가 영영 남는다).
            guard snapshot.version == 1, snapshot.status != .loading else { return Self(status: .unavailable) }
            try validate(snapshot.playlists)
            if let source = snapshot.sourcePlaylists { try validate(source) }
            return snapshot
        } catch { return Self(status: .unavailable) }
    }

    /// 동기화 ID로만 고르고, 그 목록을 찾아갈 수 있도록 현재 조상 폴더를 함께 남긴다.
    public static func select(_ selection: RekordboxITunesSelection, from source: [Playlist]) throws -> Self {
        try select(ids: selection.selectedIDs, from: source)
    }

    public func applyingRekordboxSelection(_ data: Data) throws -> Self {
        var result = try Self.select(RekordboxITunesSelection.parse(data), from: availablePlaylists)
        result.status = status
        result.syncData = data
        return result
    }

    /// rekordbox가 XML 읽기로 설정된 경우 같은 보관함 XML에서 폴더·순서를 읽는다.
    public static func parseLibraryXML(_ data: Data) throws -> [Playlist] {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any], format == .xml,
              let tracks = root["Tracks"] as? [String: [String: Any]], let lists = root["Playlists"] as? [[String: Any]] else {
            throw RekordboxITunesSelection.ParseError.invalidFile
        }
        return try lists.filter { $0["Master"] as? Bool != true }.map { raw in
            guard let id = raw["Playlist Persistent ID"] as? String, let name = raw["Name"] as? String,
                  raw["Playlist Items"] == nil || raw["Playlist Items"] is [[String: Any]] else {
                throw RekordboxITunesSelection.ParseError.invalidFile
            }
            let paths = try (raw["Playlist Items"] as? [[String: Any]] ?? []).map { item -> String? in
                guard let trackID = item["Track ID"] as? Int else { throw RekordboxITunesSelection.ParseError.invalidFile }
                guard let location = tracks[String(trackID)]?["Location"] as? String,
                      let url = URL(string: location), url.isFileURL,
                      url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
                return url.path
            }
            return Playlist(id: id, name: name, parentID: raw["Parent Persistent ID"] as? String,
                            isFolder: raw["Folder"] as? Bool == true, paths: paths)
        }
    }
}
