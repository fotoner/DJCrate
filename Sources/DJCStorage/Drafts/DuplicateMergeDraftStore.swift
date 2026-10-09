import DJCDomain
import Foundation

public enum DuplicateMergeDraftStore {
    public static let fileName = DraftFileNames.merge
    public static var url: URL { DJCPaths.userData.appending(path: fileName) }

    /// 없거나 읽지 못하면 빈 목록. 앱은 읽기 전에 손상된 파일을 옮겨 보관하고 알린다(`DamagedDrafts.preserveAll`).
    public static func load(url: URL = url) -> [DuplicateMergeDraft] {
        (try? DamagedDrafts.read([DuplicateMergeDraft].self, at: url)) ?? []
    }

    public static func save(_ drafts: [DuplicateMergeDraft], url: URL = url) throws {
        // 손상된 파일은 새 초안으로 덮거나 지우지 않고 옮겨 보관한다(#178).
        try DamagedDrafts.preserveIfDamaged([DuplicateMergeDraft].self, at: url, home: url.deletingLastPathComponent(), trackUUID: nil)
        if drafts.isEmpty {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
        }
    }
}
