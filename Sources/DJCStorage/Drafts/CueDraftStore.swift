import DJCDomain
import Foundation

public enum CueDraftStore {
    /// rekordbox에 반영이 확인된 곡의 초안을 지운다(이제 rekordbox 값이 원본이다).
    public static func remove(trackUUID: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(trackUUID).json"))
    }

    /// CLI는 삭제 실패를 성공으로 보고하지 않는다.
    public static func remove(trackUUID: String, directory: URL) throws {
        let url = directory.appending(path: "\(trackUUID).json")
        // 손상된 파일은 지우지 않고 옮겨 보관한다(#174).
        try DamagedDrafts.preserveIfDamaged(CueDraft.self, at: url, home: directory.deletingLastPathComponent(), trackUUID: trackUUID)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    public static var directory: URL {
        DJCPaths.userData.appending(path: "cue-drafts")
    }

    public static func load(trackUUID: String) -> CueDraft? {
        load(trackUUID: trackUUID, directory: directory)
    }

    public static func load(trackUUID: String, directory: URL) -> CueDraft? {
        let url = directory.appending(path: "\(trackUUID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CueDraft.self, from: data)
    }

    public static func save(_ draft: CueDraft, directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(draft.trackUUID).json")
        if draft.hasChanges {
            try DamagedDrafts.preserveIfDamaged(CueDraft.self, at: url, home: directory.deletingLastPathComponent(), trackUUID: draft.trackUUID)
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } else {
            try remove(trackUUID: draft.trackUUID, directory: directory)
        }
    }
}

// MARK: - 시간축 이동

