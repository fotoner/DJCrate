import DJCDomain
import Foundation

/// 곡 넣기 뒤 정리(R22): 넣기에 쓴 판만 지우고, 넣는 동안 생긴 새 판(앱·CLI)은 새 곡의 제안으로 옮긴다.
/// 넣은 뒤 처리(`finishAdd`)와 재시작 정리(`resumeCleanups`)가 관문이 남긴 미정리 목록의 곡 넣기 몫(옛·새 UUID, 쓴 초안의 판, 쓴 값, 막힌 칸)으로
/// 같은 일을 한다. 그래서 보고서 저장이 실패했거나 정리 전에 멈춰도 결과가 같다.
extension ReflectionSession {
    /// 곡 넣기 하나를 정리한 결과
    public enum TrackAddCleanup: Equatable, Sendable {
        case done
        /// 새 곡 행을 아직 읽지 못해 큐·태그를 옮기지 못했다(다음 정리 때 다시 한다)
        case deferred
        /// 초안 저장소가 던졌다(목록을 남기고 다음 쓰기를 보류한다)
        case failed
    }

    /// 곡 넣기 하나를 정리한다. 종류(큐·그리드·태그)마다:
    /// - 넣기에 쓴 판 그대로면 지운다(판과 해시가 같을 때만. 판이 같은데 바깥에서 고쳤으면 제안으로 남아 아래처럼 옮긴다).
    /// - 그 밖에 옛 UUID에 남은 초안(넣는 동안 저장한 새 판, 넣기에서 막힌 칸의 초안)은 새 곡의 제안으로 옮기고 옛 UUID에서 지운다.
    ///   옮긴 초안은 넣기로 쓴 값을 기준으로 삼고 쓴 값에서 새 판으로 바뀐 것만 얹는다. 막힌 칸은 새 판의 값을 그대로 옮긴다. 출처가 남는다.
    /// 다시 해도 결과가 같다(옮긴 뒤 옛 초안이 없으면 할 일이 없다).
    /// - Parameter unchanged: 넣은 뒤 처리가 넘긴 판정(넣기 묶음의 판 그대로인 초안은 그 처리가 이미 옮기거나 백업에 남기고 지웠다).
    ///   nil이면 재시작 정리라 남은 초안을 모두 본다
    func cleanUpTrackAdd(_ add: DraftCleanupList.TrackAdd, unchanged: ((DraftKey) -> Bool)?) async -> TrackAddCleanup {
        let files = ports.drafts
        await BlockingWork.run { files.flush() }
        var result = TrackAddCleanup.done
        for kind in [DraftKey.Kind.cue, .grid, .tag] {
            let key = DraftKey(kind, add.stagedUUID)
            if let unchanged, unchanged(key) { continue }
            if let written = add.written.first(where: { $0.key == key }), files.stamp(key)?.revision == written.revision {
                guard let removal = try? await BlockingWork.run({ try files.removeWritten([written]) }) else {
                    result = .failed
                    continue
                }
                if !removal.removed.isEmpty {
                    clearRemovedDrafts([key])
                    continue
                }
            }
            switch await moveToNewTrack(key, add: add) {
            case .done: break
            case .deferred: if result == .done { result = .deferred }
            case .failed: result = .failed
            }
        }
        await BlockingWork.run { files.flush() }
        return result
    }

    /// 옛 UUID에 남은 초안 하나를 새 곡의 제안으로 옮기고 옛 초안을 지운다
    private func moveToNewTrack(_ key: DraftKey, add: DraftCleanupList.TrackAdd) async -> TrackAddCleanup {
        let files = ports.drafts, new = add.trackUUID, state = ports.library.state()
        guard let stamp = files.stamp(key), let hash = files.currentHash(key) else { return .done }
        // 출처가 남는다: 사람 편집이 아닌 출처가 있으면 그 출처로, 사람 편집만이면 모름으로 저장해 제안이 되게 한다
        let port = files.with(origin: stamp.origins.filter { $0 != .human }.min() ?? .unknown)
        switch key.kind {
        case .cue:
            guard let current = files.cueDraft(key.id) else { return .done }
            if let written = add.values.cues, !add.blockedFields.contains("cues") {
                // 넣기로 쓴 큐가 rekordbox에 있다: 다시 읽은 새 곡의 큐(원본 ID)를 기준으로 삼아야 쓸 때 기준 어긋남으로 막히지 않는다
                guard let row = state.rows[new] else { return .deferred }
                port.saveCue(AddedTrackDrafts.movedCueDraft(current, written: written, onto: row.cues, to: new, newID: files.newCueID))
            } else {
                port.saveCue(AddedTrackDrafts.movedCueDraft(from: current, to: new))
            }
        case .grid:
            guard let current = files.gridDraft(key.id) else { return .done }
            var moved = current
            moved.trackUUID = new
            moved.base = add.values.grid ?? []
            port.saveGrid(moved)
        case .tag:
            guard let current = files.tagDraft(key.id) else { return .done }
            guard let base = add.values.tags ?? state.rows[new]?.tagFields else { return .deferred }
            let moved = AddedTrackDrafts.movedTagDraft(current, written: base, blocked: Set(add.blockedFields), to: new)
            port.saveTags([moved])
            apply(.tagDrafts([moved]))
        case .gain, .artwork, .merge:
            return .done
        }
        // 옮긴 뒤 옛 초안을 지운다(그 사이 또 새 판이 저장됐으면 남긴다). 초안 잠금을 기다릴 수 있어 메인 액터 밖에서 한다
        let old = WrittenDraft(key: key, revision: stamp.revision, contentHash: hash)
        guard let removal = try? await BlockingWork.run({ try files.removeWritten([old]) }) else { return .failed }
        if !removal.removed.isEmpty { clearRemovedDrafts([key]) }
        apply(.unlinkedDraftsChanged)
        return .done
    }
}

extension AddedTrackDrafts {
    /// 넣는 동안 생긴 큐 초안 새 판을 새 곡으로 옮긴 모양(R22): 기준은 다시 읽은 새 곡의 rekordbox 큐(넣기로 쓴 큐)다.
    /// 그 위에 넣기로 쓴 큐에서 새 판으로 바뀐 것만 얹는다(더한 큐는 더하고, 지운 큐는 지우고, 고친 큐는 같은 자리의 rekordbox 큐를 고친다).
    /// 쓴 큐와 rekordbox 큐는 종류와 시각(1ms 안)으로 잇는다
    public static func movedCueDraft(_ current: CueDraft, written: [EditableCue], onto rekordboxCues: [Cue], to uuid: String,
                                     newID: () -> UUID) -> CueDraft {
        var moved = CueDraft(trackUUID: uuid, rekordboxCues: rekordboxCues, newID: newID)
        func placed(_ cue: EditableCue) -> EditableCue? { moved.base.first { $0.kind == cue.kind && abs($0.time - cue.time) < 0.001 } }
        let now = Dictionary(current.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = Dictionary(written.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for cue in written where now[cue.id] == nil {
            if let target = placed(cue) { moved.remove(target.id) }
        }
        for cue in current.cues {
            if let old = before[cue.id] {
                guard old != cue, let target = placed(old) else { continue }
                var edited = cue
                edited.id = target.id
                edited.sourceID = target.sourceID
                moved.place(edited)
            } else {
                var added = cue
                added.sourceID = nil
                moved.place(added)
            }
        }
        return moved
    }

    /// 넣는 동안 생긴 태그 초안 새 판을 새 곡으로 옮긴 모양(R22): 기준은 넣기로 쓴 값이다. 새 판이 고친 칸(추가 목록 곡 초안이 기준과 다르게 둔 칸)과
    /// 넣기에서 막힌 칸은 새 판의 값을 얹는다. 고치지 않은 칸(파일 태그를 따른 칸)은 쓴 값 그대로다
    public static func movedTagDraft(_ current: TagDraft, written: TagFields, blocked: Set<String>, to uuid: String) -> TagDraft {
        var moved = TagDraft(trackUUID: uuid, base: written)
        let changed = Set(current.changedKeys)
        for key in TagFields.Key.allCases where changed.contains(key) || blocked.contains(key.rawValue) {
            moved.fields[key] = current.fields[key]
        }
        return moved
    }
}

extension ReflectionSession {
    /// 넣은 뒤 처리의 끝(R22): 관문이 남긴 이 넣기의 미정리 목록으로 넣는 동안 생긴 새 판을 새 곡의 제안으로 옮기고, 정리를 마치면 목록을 지운다.
    /// 새 곡 행을 읽지 못했거나 저장소가 던지면 목록을 남겨 재시작 정리·다음 쓰기 전 정리가 다시 한다
    func finishTrackAddCleanup(operation: DraftWriteOperation, target: RekordboxWriteTarget, unchanged: @escaping (DraftKey) -> Bool) async {
        let gate = ports.gate, home = location.draftHome
        guard let lists = try? await BlockingWork.run({ try gate.cleanupLists(target, home) }),
              let list = lists.first(where: { $0.operationID == operation.id }) else { return }
        var finished = true
        for add in list.trackAdds {
            if await cleanUpTrackAdd(add, unchanged: unchanged) != .done { finished = false }
        }
        guard finished, list.written.isEmpty, list.playlistSteps.isEmpty else { return }
        await BlockingWork.run { try? gate.removeCleanupList(list, target) }
    }
}
