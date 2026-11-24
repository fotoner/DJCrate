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

    /// 게인 초안을 저장한다(nil이면 지우기). 지우면 그 곡의 base(`saveBase`)도 지운다. 값만 바꾸면 base는 그대로다
    public static func save(_ gainDB: Double?, trackUUID: String, url: URL = url) throws {
        try DamagedDrafts.preserveIfDamaged([String: Double].self, at: url, home: url.deletingLastPathComponent(), trackUUID: nil)
        var drafts = try read(url: url)
        drafts[trackUUID] = gainDB
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if gainDB == nil, bases(url: url)[trackUUID] != nil { try saveBase(nil, trackUUID: trackUUID, url: url) }
        try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
    }

    /// 게인 초안의 base(초안을 만들 때 본 rekordbox 오토게인 dB, R23)를 옆 파일(`basesURL`)에 둔다(nil이면 지운다).
    /// 게인 파일 모양을 바꾸지 않아 옛 앱도 읽는다. 값보다 먼저 같은 저장 큐에서 적는다(값과 어긋나도 base만 남을 뿐이다)
    public static func saveBase(_ base: Double?, trackUUID: String, url: URL = url) throws {
        var bases = bases(url: url)
        guard bases[trackUUID] != base else { return }
        bases[trackUUID] = base
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bases).write(to: basesURL(for: url), options: .atomic)
    }

    /// 게인 초안의 base 파일(게인 파일 옆)
    public static func basesURL(for url: URL = url) -> URL { url.deletingLastPathComponent().appending(path: "gain-draft-bases.json") }

    /// 곡 UUID → 게인 초안의 base(dB). 없거나 읽지 못하면 빈 값: base를 모르는 초안은 자동으로 쓰지 않을 뿐 그대로 읽힌다(R23)
    public static func bases(url: URL = url) -> [String: Double] {
        guard let data = try? Data(contentsOf: basesURL(for: url)) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    public static func remove(trackUUID: String, url: URL = url) throws { try save(nil, trackUUID: trackUUID, url: url) }
}
