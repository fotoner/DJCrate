import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// 쓰기 전 백업 폴더의 메모리 구현(반영 세션 시험이 쓴다). 곡 넣기가 백업에 남긴 추가 목록·초안은 같은 백업에서 다시 읽힌다(복원이 되살린다).
/// 실제 구현(`RekordboxBackups.live`)과 같은 계약을 지키는지는 DJCAdaptersTests의 계약 시험이 같은 시험 함수로 본다.
public final class MemoryBackups: Sendable {
    private struct State {
        var folders: [URL: (staged: [StagedTrack]?, drafts: RekordboxBackupDrafts)] = [:]
        /// 백업마다 따로 정하지 않았을 때 되살릴 초안·추가 목록(복원 시험이 정한다)
        var drafts = RekordboxBackupDrafts()
        var staged: [StagedTrack]?
        var failing: Set<String> = []
        var later = 0
        var refusal: String?
        var updateCount = 1
        var canWrite = true
        var fileWarning: String?
    }
    private let state = Mutex(State())
    /// 백업에 남길 때마다 한 줄("backup staged …"·"backup cue <UUID>" …)
    private let onSave: @Sendable (String) -> Void

    public init(onSave: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onSave = onSave
    }

    /// 따로 남긴 것이 없는 백업에서 되살릴 초안
    public var drafts: RekordboxBackupDrafts {
        get { state.withLock { $0.drafts } }
        set { state.withLock { $0.drafts = newValue } }
    }
    public var staged: [StagedTrack]? {
        get { state.withLock { $0.staged } }
        set { state.withLock { $0.staged = newValue } }
    }
    /// 남기기가 실패할 것("staged"·"cue"·"grid"·"tag")
    public var failing: Set<String> {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    public var later: Int {
        get { state.withLock { $0.later } }
        set { state.withLock { $0.later = newValue } }
    }
    public var refusal: String? {
        get { state.withLock { $0.refusal } }
        set { state.withLock { $0.refusal = newValue } }
    }
    /// 스냅샷에서 읽은 변경 카운터(백업의 카운터와 다르면 그 뒤 rekordbox가 바뀐 것)
    public var updateCount: Int {
        get { state.withLock { $0.updateCount } }
        set { state.withLock { $0.updateCount = newValue } }
    }
    public var canWrite: Bool {
        get { state.withLock { $0.canWrite } }
        set { state.withLock { $0.canWrite = newValue } }
    }
    /// 복원 직전 백업에 남은 참고 경고
    public var fileWarning: String? {
        get { state.withLock { $0.fileWarning } }
        set { state.withLock { $0.fileWarning = newValue } }
    }

    public var port: RekordboxBackups {
        RekordboxBackups(
            list: { _ in [] },
            laterCount: { _, _ in self.later },
            pointRestoreRefusal: { _, _ in self.refusal },
            drafts: { backup in self.state.withLock { $0.folders[backup]?.drafts ?? $0.drafts } },
            updateCount: { _ in self.updateCount },
            canWrite: { _ in self.canWrite },
            stagedTracks: { backup in self.state.withLock { state in state.folders[backup].map { $0.staged } ?? state.staged } },
            saveStagedTracks: { tracks, backup in
                try self.save("staged", line: "backup staged \(tracks.map(\.uuid).sorted())", backup: backup) { $0.staged = tracks }
            },
            saveDraft: { draft, backup in
                let kind = switch draft { case .cue: "cue"; case .grid: "grid"; case .tag: "tag" }
                try self.save(kind, line: "backup \(kind) \(draft.trackUUID)", backup: backup) { folder in
                    switch draft {
                    case let .cue(value): folder.drafts.cues.removeAll { $0.trackUUID == value.trackUUID }; folder.drafts.cues.append(value)
                    case let .grid(value): folder.drafts.grids.removeAll { $0.trackUUID == value.trackUUID }; folder.drafts.grids.append(value)
                    case let .tag(value): folder.drafts.tags.removeAll { $0.trackUUID == value.trackUUID }; folder.drafts.tags.append(value)
                    }
                }
            },
            fileWarning: { _ in self.fileWarning })
    }

    private func save(_ kind: String, line: String, backup: URL,
                      _ change: (inout (staged: [StagedTrack]?, drafts: RekordboxBackupDrafts)) -> Void) throws {
        try state.withLock { state in
            if state.failing.contains(kind) { throw MemoryBackupsFailure() }
            var folder = state.folders[backup] ?? (nil, RekordboxBackupDrafts())
            change(&folder)
            state.folders[backup] = folder
        }
        onSave(line)
    }
}

struct MemoryBackupsFailure: Error, CustomStringConvertible { var description = "백업에 남기지 못함(시험)" }
