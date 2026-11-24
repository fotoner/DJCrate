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
    /// - 넣기에 쓴 판 그대로이고 그 종류에 막힌 칸이 없으면 지운다(판과 해시가 같을 때만. 판이 같은데 바깥에서 고쳤으면 제안으로 남아 아래처럼 옮긴다).
    /// - 그 밖에 옛 UUID에 남은 초안(넣는 동안 저장한 새 판, 넣기에서 막힌 칸이 있는 초안)은 새 곡의 제안으로 옮기고 옛 UUID에서 지운다.
    ///   옮긴 초안은 넣기로 쓴 값을 기준으로 삼고 쓴 값에서 새 판으로 바뀐 것만 얹는다. 막힌 칸은 새 판의 값을 그대로 옮긴다. 출처가 남는다.
    /// - 새 곡에 그 종류 초안이 이미 있거나(사용자가 새 곡을 고쳤다) 큐 대응이 모호하면 옮기지 않고 옛 초안을 연결되지 않은 초안으로 남긴다.
    /// 옛 판은 새 곡의 초안·도장이 저장된 것을 본 뒤에만 지운다. 옮기는 동안 옛 판이 바뀌었으면 끝난 것으로 보지 않는다(다음 정리가 다시 한다).
    /// 다시 해도 결과가 같다(옮긴 뒤 옛 초안이 없으면 할 일이 없다).
    /// - Parameter unchanged: 넣은 뒤 처리가 넘긴 판정(넣기 묶음의 판 그대로인 초안은 그 처리가 이미 옮기거나 백업에 남기고 지웠다).
    ///   nil이면 재시작 정리라 남은 초안을 모두 본다
    /// - Parameter libraryFresh: 앱이 라이브러리를 방금 다시 읽었다(새 곡 행이 없으면 미루지 않고 옛 초안을 연결 안 된 초안으로 남긴다)
    func cleanUpTrackAdd(_ add: DraftCleanupList.TrackAdd, unchanged: ((DraftKey) -> Bool)?, libraryFresh: Bool = false) async -> TrackAddCleanup {
        let files = ports.drafts
        await BlockingWork.run { files.flush() }
        var result = TrackAddCleanup.done
        func merge(_ next: TrackAddCleanup) {
            switch next {
            case .done: break
            case .deferred: if result == .done { result = .deferred }
            case .failed: result = .failed
            }
        }
        for kind in [DraftKey.Kind.cue, .grid, .tag] {
            let key = DraftKey(kind, add.stagedUUID)
            if let unchanged, unchanged(key) { continue }
            if !Self.hasBlockedFields(kind, add), let written = add.written.first(where: { $0.key == key }),
               files.stamp(key)?.revision == written.revision {
                guard let removal = try? await BlockingWork.run({ try files.removeWritten([written]) }) else {
                    merge(.failed)
                    continue
                }
                if !removal.removed.isEmpty {
                    clearRemovedDrafts([key])
                    continue
                }
            }
            merge(await moveToNewTrack(key, add: add, libraryFresh: libraryFresh))
        }
        await BlockingWork.run { files.flush() }
        return result
    }

    /// 넣기에서 그 종류의 칸이 막혔는지(막힌 칸은 지우지 않고 새 곡으로 옮긴다)
    static func hasBlockedFields(_ kind: DraftKey.Kind, _ add: DraftCleanupList.TrackAdd) -> Bool {
        switch kind {
        case .cue: add.blockedFields.contains("cues")
        case .tag: add.blockedFields.contains { TagFields.Key(rawValue: $0) != nil }
        case .grid, .gain, .artwork, .merge: false
        }
    }

    /// 옛 UUID에 남은 초안 하나를 새 곡의 제안으로 옮기고, 새 곡에 저장된 것을 본 뒤 옛 초안을 지운다
    private func moveToNewTrack(_ key: DraftKey, add: DraftCleanupList.TrackAdd, libraryFresh: Bool) async -> TrackAddCleanup {
        let files = ports.drafts, new = add.trackUUID, state = ports.library.state()
        // 새 곡 행을 기다려야 하는데 방금 다시 읽은 라이브러리에도 없으면(그 사이 뺐다) 옮기지 않고 끝낸다
        let missingRow: TrackAddCleanup = libraryFresh ? .done : .deferred
        let newKey = DraftKey(key.kind, new)
        guard let stamp = files.stamp(key), let hash = files.currentHash(key) else { return .done }
        // 새 곡에 그 종류 초안이 이미 있다(다시 읽은 뒤 사용자가 고쳤다): 덮지 않고 옛 초안은 연결되지 않은 초안으로 남긴다
        if files.stamp(newKey) != nil || files.currentHash(newKey) != nil { return .done }
        // 출처가 남는다: 사람 편집이 아닌 출처가 있으면 그 출처로, 사람 편집만이면 모름으로 저장해 제안이 되게 한다
        let port = files.with(origin: stamp.origins.filter { $0 != .human }.min() ?? .unknown)
        /// 새 곡에 저장할 초안의 해시(바뀐 것이 없으면 nil: 저장하지 않고 옛 초안만 지운다)
        var expected: DraftContentHash?
        switch key.kind {
        case .cue:
            guard let current = files.cueDraft(key.id) else { return .done }
            let moved: CueDraft
            if let written = add.values.cues, !add.blockedFields.contains("cues") {
                // 넣기로 쓴 큐가 rekordbox에 있다: 다시 읽은 새 곡의 큐(원본 ID)를 기준으로 삼아야 쓸 때 기준 어긋남으로 막히지 않는다
                guard let row = state.rows[new] else { return missingRow }
                // 같은 종류·시각의 큐가 여럿이면 어느 rekordbox 큐에 이어야 할지 모른다: 다른 큐를 고치지 않게 옮기지 않는다
                guard !AddedTrackDrafts.cueMatchIsAmbiguous(written, onto: row.cues) else { return .done }
                moved = AddedTrackDrafts.movedCueDraft(current, written: written, onto: row.cues, to: new, newID: files.newCueID)
            } else {
                moved = AddedTrackDrafts.movedCueDraft(from: current, to: new)
            }
            if moved.hasChanges {
                port.saveCue(moved)
                expected = try? DraftContentHash(of: moved)
            }
        case .grid:
            guard let current = files.gridDraft(key.id) else { return .done }
            var moved = current
            moved.trackUUID = new
            moved.base = add.values.grid ?? []
            if moved.hasChanges {
                port.saveGrid(moved)
                expected = try? DraftContentHash(of: moved)
            }
        case .tag:
            guard let current = files.tagDraft(key.id) else { return .done }
            guard let base = add.values.tags ?? state.rows[new]?.tagFields else { return missingRow }
            // 넣기 때 태그 초안이 있었는지(있었으면 그 판이 넣기 묶음에 실렸다): 넣기 계획에 실린 칸을 가린다
            let hadDraft = add.written.contains { $0.key == DraftKey(.tag, add.stagedUUID) }
            let moved = AddedTrackDrafts.movedTagDraft(current, written: base, blocked: Set(add.blockedFields), hadDraft: hadDraft, to: new)
            if moved.hasChanges {
                port.saveTags([moved])
                apply(.tagDrafts([moved]))
                expected = try? DraftContentHash(of: moved)
            }
        case .gain, .artwork, .merge:
            return .done
        }
        // 새 곡의 초안과 도장이 저장된 것을 본 뒤에만 옛 판을 지운다(저장하지 못했으면 목록을 남겨 다음에 다시 한다)
        if let expected {
            await BlockingWork.run { files.flush() }
            guard files.currentHash(newKey) == expected, files.stamp(newKey) != nil else { return .failed }
        }
        // 옮긴 뒤 옛 초안을 지운다(그 사이 또 새 판이 저장됐으면 남긴다). 초안 잠금을 기다릴 수 있어 메인 액터 밖에서 한다
        let old = WrittenDraft(key: key, revision: stamp.revision, contentHash: hash)
        guard let removal = try? await BlockingWork.run({ try files.removeWritten([old]) }) else { return .failed }
        if !removal.removed.isEmpty { clearRemovedDrafts([key]) }
        apply(.unlinkedDraftsChanged)
        // 옮기는 동안 옛 UUID에 더 새 판이 생겼다(지우지 못하고 남았다): 끝난 것으로 보지 않는다
        return removal.removed.isEmpty ? .deferred : .done
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

    /// 넣기 계획에 태그 초안에서 싣는 칸(`apply(_:to:)`가 음원 태그 위에 얹는 칸)
    static let plannedTagKeys: [TagFields.Key] = [.title, .artist, .album, .albumArtist, .genre, .composer, .year, .trackNumber, .comment]

    /// 넣는 동안 생긴 태그 초안 새 판을 새 곡으로 옮긴 모양(R22): 기준은 넣기로 쓴 값이다. 그 위에 새 판의 값을 얹는 칸은
    /// - 새 판에서 사용자가 바꾼 칸(`changedKeys`: 기준과 다른 칸)
    /// - 넣기 때 태그 초안이 있었으면 그 계획에 실린 칸 가운데 쓴 값과 새 판이 다른 칸(파일 값으로 되돌린 칸 포함)
    /// - 넣기에서 막힌 칸
    /// 이다. 넣기 때 태그 초안이 없었으면 계획은 음원 태그를 썼으니 바꾸지 않은 칸을 쓴 값과 견주지 않는다(추가 목록 곡 행에 없던 칸을 지우지 않게).
    /// 쓰지 않은 미확정 키(추정·파일 키: 쓴 키가 비었고 새 판이 키를 바꾸지 않았다)는 옮기지 않는다
    public static func movedTagDraft(_ current: TagDraft, written: TagFields, blocked: Set<String>, hadDraft: Bool = true, to uuid: String) -> TagDraft {
        var keys = Set(current.changedKeys).union(TagFields.Key.allCases.filter { blocked.contains($0.rawValue) })
        if hadDraft { keys.formUnion(plannedTagKeys.filter { current.fields[$0] != written[$0] }) }
        if written.musicalKey.isEmpty, current.base.musicalKey == current.fields.musicalKey { keys.remove(.musicalKey) }
        var moved = TagDraft(trackUUID: uuid, base: written)
        for key in keys { moved.fields[key] = current.fields[key] }
        return moved
    }

    /// 쓴 큐와 새 곡의 rekordbox 큐를 종류·시각(1ms 안)으로 잇는 대응이 모호한지: 같은 자리에 rekordbox 큐가 여럿이거나 쓴 큐가 여럿이다
    public static func cueMatchIsAmbiguous(_ written: [EditableCue], onto rekordboxCues: [Cue]) -> Bool {
        let base = CueDraft(trackUUID: "", rekordboxCues: rekordboxCues, newID: { UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }).base
        func same(_ a: EditableCue, _ b: EditableCue) -> Bool { a.kind == b.kind && abs(a.time - b.time) < 0.001 }
        return written.contains { cue in base.filter { same($0, cue) }.count > 1 || written.filter { same($0, cue) }.count > 1 }
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
