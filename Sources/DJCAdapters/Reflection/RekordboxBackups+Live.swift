import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension RekordboxBackups {
    /// 백업 폴더 이름: 곡 넣기 백업에 남기는 추가 목록(되돌리면 추가 목록으로 돌아온다)
    public static let stagedFileName = "djc-staged.json"

    /// 쓰기 전 백업 폴더의 실제 모양(RekordboxKit이 쓰기·복원 때 남기고 읽는 모양).
    /// - Parameter writeFile: 곡 넣기 백업에 추가 목록·초안 사본을 쓴다(시험은 저장 실패를 만들려고 바꾼다)
    public static func live(writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) -> Self {
        Self(
            list: { RekordboxWriter.backups(in: $0) },
            laterCount: { backup, folder in (try? RekordboxWriter.laterBackups(than: backup, in: folder))?.count ?? 0 },
            pointRestoreRefusal: { RekordboxWriter.pointRestoreRefusal(after: $0, in: $1) },
            drafts: { backup in
                RekordboxBackupDrafts(cues: RekordboxWriter.contents(of: backup).drafts, grids: RekordboxWriter.gridDrafts(in: backup),
                                      gains: RekordboxWriter.gainDrafts(in: backup), tags: RekordboxWriter.tagDrafts(in: backup),
                                      artworks: RekordboxWriter.artworkDrafts(in: backup), merges: RekordboxWriter.mergeDrafts(in: backup),
                                      playlistEdits: RekordboxWriter.playlistEdits(in: backup))
            },
            updateCount: { try RekordboxWriter.updateCount(of: $0) },
            canWrite: { folder in
                let fm = FileManager.default
                var folder = folder
                while !fm.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder = folder.deletingLastPathComponent() }
                return fm.isWritableFile(atPath: folder.path)
            },
            stagedTracks: { backup in
                guard let data = try? Data(contentsOf: backup.appending(path: stagedFileName)) else { return nil }
                return try? JSONDecoder().decode([StagedTrack].self, from: data)
            },
            saveStagedTracks: { tracks, backup in
                try writeFile(JSONEncoder().encode(tracks), backup.appending(path: stagedFileName))
            },
            saveDraft: { draft, backup in
                // 백업 폴더의 초안 모양은 큐·그리드·태그 쓰기가 남기는 것과 같다(복원이 그대로 읽는다)
                let folder: String, data: Data
                switch draft {
                case let .cue(value): folder = "cue-drafts"; data = try JSONEncoder().encode(value)
                case let .grid(value): folder = "grid-drafts"; data = try JSONEncoder().encode(value)
                case let .tag(value): folder = "tag-drafts"; data = try JSONEncoder().encode(value)
                }
                let directory = backup.appending(path: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try writeFile(data, directory.appending(path: "\(draft.trackUUID).json"))
            },
            fileWarning: { RekordboxWriter.fileWarning(in: $0) })
    }
}
