import DJCDomain
import Foundation

/// 곡별 rekordbox 오토게인 초안(dB). rekordbox에 반영하면 지운다.
/// 모든 곡을 파일 하나에 두므로 손상된 파일을 새 값만으로 덮지 않는다(옮겨 보관한 뒤 쓴다, #174).
public enum GainDraftStore {
    public static var url: URL { DJCPaths.userData.appending(path: "gain-drafts.json") }

    /// 없으면 빈 값. 내용을 해석하지 못하면 `DraftFileDamaged`, 읽지 못하면 그 오류를 던진다.
    public static func read(url: URL = url) throws -> [String: Double] {
        try DamagedDrafts.read([String: Double].self, at: url) ?? [:]
    }

    /// 읽지 못하면 빈 값(목록 표시용). 쓰기 전 확인은 `read`를 쓴다.
    public static func all(url: URL = url) -> [String: Double] {
        (try? read(url: url)) ?? [:]
    }

    public static func load(trackUUID: String, url: URL = url) -> Double? { all(url: url)[trackUUID] }

    public static func uuids(url: URL = url) -> Set<String> { Set(all(url: url).keys) }

    public static func save(_ gainDB: Double?, trackUUID: String, url: URL = url) throws {
        try DamagedDrafts.preserveIfDamaged([String: Double].self, at: url, home: url.deletingLastPathComponent(), trackUUID: nil)
        var drafts = try read(url: url)
        drafts[trackUUID] = gainDB
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
    }

    public static func remove(trackUUID: String, url: URL = url) throws { try save(nil, trackUUID: trackUUID, url: url) }
}
