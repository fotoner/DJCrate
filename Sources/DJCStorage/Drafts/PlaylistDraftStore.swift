import DJCDomain
import Foundation

/// 재생 목록 초안(#39·#40). 편집이 서로 기대므로(새로 만든 목록에 곡 넣기 등) 파일 하나에 순서대로 둔다.
/// 반영하면 쓴 편집을 빼고, 비면 파일을 지운다.
public enum PlaylistDraftStore {
    public static let fileName = DraftFileNames.playlist
    public static var url: URL { DJCPaths.userData.appending(path: fileName) }

    /// 없거나 읽지 못하면 빈 초안. 앱은 읽기 전에 손상된 파일을 옮겨 보관하고 알린다(`DamagedDrafts.preserveAll`).
    public static func load(url: URL = url) -> PlaylistDraft {
        (try? DamagedDrafts.read(PlaylistDraft.self, at: url)) ?? PlaylistDraft()
    }

    public static func save(_ draft: PlaylistDraft, url: URL = url) throws {
        // 손상된 파일은 덮거나 지우지 않고 옮겨 보관한다(#174).
        try DamagedDrafts.preserveIfDamaged(PlaylistDraft.self, at: url, home: url.deletingLastPathComponent(), trackUUID: nil)
        guard !draft.isEmpty else {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(draft).write(to: url, options: .atomic)
    }
}
