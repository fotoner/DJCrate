import DJCDomain
import Foundation

public enum TagDraftStore {
    /// CLI는 삭제 실패를 성공으로 보고하지 않는다.
    public static func remove(trackUUID: String, directory: URL) throws {
        let url = directory.appending(path: "\(trackUUID).json")
        // 손상된 파일은 지우지 않고 옮겨 보관한다(#174).
        try DamagedDrafts.preserveIfDamaged(TagDraft.self, at: url, home: directory.deletingLastPathComponent(), trackUUID: trackUUID)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    public static var directory: URL {
        DJCPaths.userData.appending(path: "tag-drafts")
    }

    public static func load(trackUUID: String) -> TagDraft? {
        load(trackUUID: trackUUID, directory: directory)
    }

    public static func load(trackUUID: String, directory: URL) -> TagDraft? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(trackUUID).json")) else { return nil }
        return try? JSONDecoder().decode(TagDraft.self, from: data)
    }

    public static func save(_ draft: TagDraft, directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        if draft.hasChanges {
            try DamagedDrafts.preserveIfDamaged(TagDraft.self, at: url, home: directory.deletingLastPathComponent(), trackUUID: draft.trackUUID)
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            try remove(trackUUID: draft.trackUUID, directory: directory)
        }
    }

    public static func uuids(directory: URL = directory) -> Set<String> { DraftFiles.uuids(in: directory) }
}
