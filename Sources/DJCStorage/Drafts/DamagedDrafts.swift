import DJCDomain
import Foundation
import Synchronization

/// 내용을 해석하지 못한 초안 파일(#174). 없는 파일(nil)과 구분한다.
public struct DraftFileDamaged: Error, Equatable, Sendable {
    public var file: URL
}

/// 읽지 못한 초안 파일을 지우거나 빈 값으로 덮지 않고 `damaged-drafts` 폴더에 옮겨 보관한다(#174).
/// 옮긴 파일은 알릴 때까지 기록해 두고(`take`), 앱이 이유와 할 일을 보인다.
public enum DamagedDrafts {
    public static let folderName = "damaged-drafts"

    /// 옮겨 둔 초안 파일 하나(값은 DJCDomain, 곡 목록 유스케이스가 함께 본다)
    public typealias Entry = DamagedDraftFile

    private static let log = Mutex<[String: [Entry]]>([:])

    private static func key(_ home: URL) -> String { home.resolvingSymlinksInPath().standardizedFileURL.path }

    /// 초안 파일을 읽는다. 없으면 nil, 내용을 해석하지 못하면 `DraftFileDamaged`, 읽지 못하면(권한 등) 그 오류를 던진다.
    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOTDIR) {
            // 초안 폴더 자리에 일반 파일이 있으면 그 안에 초안도 없다(저장은 따로 실패로 알린다).
            return nil
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DraftFileDamaged(file: url) }
    }

    /// 덮어쓰거나 지우기 전에: 기존 파일이 손상됐으면 옮겨 보관한다. 읽지 못하면(권한 등) 오류를 던져 덮지 않게 한다.
    static func preserveIfDamaged<T: Decodable>(_ type: T.Type, at url: URL, home: URL, trackUUID: String?) throws {
        do { _ = try read(type, at: url) }
        catch is DraftFileDamaged { try preserve(url, home: home, trackUUID: trackUUID) }
    }

    /// 데이터 폴더의 초안(큐·그리드·태그·그림 폴더, 게인·재생 목록·합치기 초안 파일)과 추가 목록을 모두 읽어 보고 손상된 파일을 옮긴다.
    /// 다른 이유로 읽지 못한 파일(권한·폴더)은 그대로 둔다. 옮긴 파일은 `take`로 받는다.
    public static func preserveAll(home: URL) {
        func scan<T: Decodable>(_ type: T.Type, folder: String) {
            let directory = home.appending(path: folder)
            for uuid in DraftFiles.uuids(in: directory).sorted() {
                let url = directory.appending(path: "\(uuid).json")
                if case .failure(let error) = Result(catching: { try read(type, at: url) }), error is DraftFileDamaged {
                    try? preserve(url, home: home, trackUUID: uuid)
                }
            }
        }
        scan(CueDraft.self, folder: "cue-drafts")
        scan(GridDraft.self, folder: "grid-drafts")
        scan(TagDraft.self, folder: "tag-drafts")
        // 그림 초안은 가리키는 사본(.image)이 맞아야 읽은 것이다. 옮길 때 그 곡의 사본도 함께 옮긴다. 초안이 가리키지 않는 사본은
        // 끝나지 않은 저장일 수 있어 손상으로 보지 않는다(그 곡을 저장하거나 버릴 때 지운다).
        let artwork = home.appending(path: ArtworkDraftStore.folderName)
        for uuid in ArtworkDraftStore.uuids(directory: artwork).sorted() {
            try? ArtworkDraftStore.preserveIfDamaged(trackUUID: uuid, directory: artwork)
        }
        try? preserveIfDamaged([String: Double].self, at: home.appending(path: "gain-drafts.json"), home: home, trackUUID: nil)
        try? preserveIfDamaged(PlaylistDraft.self, at: home.appending(path: "playlist-drafts.json"), home: home, trackUUID: nil)
        try? preserveIfDamaged([DuplicateMergeDraft].self, at: home.appending(path: DuplicateMergeDraftStore.fileName), home: home, trackUUID: nil)
        try? preserveIfDamaged([StagedTrack].self, at: home.appending(path: StagedTrackFile.fileName), home: home, trackUUID: nil)
    }

    /// 옮긴 뒤 아직 알리지 않은 파일을 받아 간다(한 번만 돌려준다).
    public static func take(home: URL) -> [Entry] {
        log.withLock { $0.removeValue(forKey: key(home)) ?? [] }
    }

    /// `damaged-drafts/<원래 폴더>/<이름>-<시각>.<확장자>`로 옮긴다. 같은 이름이 있으면 번호를 붙인다(지우지 않는다).
    /// - Parameter logged: 알릴 목록에 더할지(그림 초안의 사본처럼 초안과 함께 옮기는 파일은 따로 알리지 않는다)
    static func preserve(_ url: URL, home: URL, trackUUID: String?, now: Date = .now, logged: Bool = true) throws {
        let parent = url.deletingLastPathComponent()
        let inHome = key(parent) == key(home)
        let name = inHome ? url.lastPathComponent : "\(parent.lastPathComponent)/\(url.lastPathComponent)"
        var directory = home.appending(path: folderName)
        if !inHome { directory = directory.appending(path: parent.lastPathComponent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(url.deletingPathExtension().lastPathComponent)-\(formatter.string(from: now))"
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        var destination = directory.appending(path: "\(stem).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appending(path: "\(stem)-\(index).\(ext)")
            index += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        guard logged else { return }
        log.withLock { $0[key(home), default: []].append(Entry(name: name, preserved: destination, trackUUID: trackUUID)) }
    }
}
