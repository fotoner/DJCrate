import DJCApplication
import DJCDomain
import AppKit
import Foundation

/// 큐 편집(초안만 바뀐다, 규칙은 `CueDraft` 확장)
extension DeckModel {
    /// 사용자가 지금 실행한 명령만 알린다. 이전 곡의 뷰·드래그 완료는 초안과 안내 모두 건드리지 않는다.
    func commandDraft(expectedTrackUUID: String? = nil) -> CueDraft? {
        if let expectedTrackUUID, expectedTrackUUID != row?.track.uuid { return nil }
        guard !isWriteLocked else { return nil }
        guard let draft, draft.trackUUID == row?.track.uuid else {
            showToast(String(ui: "편집할 곡의 초안이 준비되지 않았으니 곡을 덱에 다시 불러온 뒤 편집하세요"), kind: .warning)
            return nil
        }
        return draft
    }

    func cueForCommand(_ id: EditableCue.ID, expectedTrackUUID: String? = nil) -> EditableCue? {
        guard let draft = commandDraft(expectedTrackUUID: expectedTrackUUID) else { return nil }
        guard let cue = draft.cue(id) else {
            showToast(String(ui: "편집할 큐가 없어졌으니 현재 곡에서 큐를 다시 선택하세요"), kind: .warning)
            return nil
        }
        return cue
    }
    // MARK: - 큐 편집 (초안만 바뀐다)

    func snapped(_ time: Double) -> Double {
        let clamped = min(max(time, 0), duration)
        return quantize ? (grid?.snap(clamped) ?? clamped) : clamped
    }

    func cue(_ id: EditableCue.ID?) -> EditableCue? { draft?.cue(id) }

    func hotCue(slot: Int) -> EditableCue? { draft?.hotCue(slot: slot) }

    /// 패드 동작과 루프 반복 상태를 VoiceOver에도 같은 뜻으로 전달한다.
    func hotCueAccessibility(slot: Int) -> (label: String, value: String) {
        let letter = String(UnicodeScalar(UInt8(65 + slot)))
        guard let cue = hotCue(slot: slot) else {
            return (String(ui: "핫큐 \(letter) 비어 있음, 설정"), "")
        }
        guard let loop = cue.loop else {
            return (String(ui: "핫큐 \(letter)로 이동"), cue.time.spokenClockText)
        }
        let beats = loop.beats.map(LoopRules.text) ?? loopBeats(cue).map(String.init) ?? "?"
        let value = engagedLoopID == cue.id ? String(ui: "\(beats)박, 반복 중") : String(ui: "\(beats)박, 반복 꺼짐")
        return (String(ui: "루프 핫큐 \(letter)"), value)
    }

    /// 이 곡의 메모리 큐 수. rekordbox 자동 큐도 목록에 메모리 큐로 있으므로 목록에 보이는 수 그대로다(#145).
    var memoryCueCount: Int { draft?.memoryCount ?? 0 }

    func addMemoryCue(at time: Double) {
        storeMemoryCue(at: snapped(time), loop: nil)
    }

    /// + 메모리 큐 · M: 즉석 루프 중이면 그 루프를 메모리 루프로 저장하고, 아니면 CUE 위치에 메모리 큐를 찍는다.
    func addMemoryCue() {
        guard let loop = instantLoop else {
            storeMemoryCue(at: cuePoint, loop: nil)
            return
        }
        guard let id = storeMemoryCue(at: loop.start, loop: EditableCue.Loop(end: loop.end, active: false, beats: loop.beats)) else { return }
        instantLoop = nil
        engagedLoopID = id
    }

    /// 메모리 큐(루프)를 더한다. 같은 자리(±30ms)에 있으면 그 큐를 고르고, rekordbox 한도(10개)면 알린다. 새로 만들면 그 ID.
    @discardableResult
    func storeMemoryCue(at time: Double, loop: EditableCue.Loop?) -> EditableCue.ID? {
        guard var edited = commandDraft() else { return nil }
        switch edited.addMemory(at: time, loop: loop, newID: storage.drafts.newCueID) {
        case let .existing(id):
            selectedCueID = id
            return nil
        case .limitReached:
            showToast(edited.memoryLimitMessage)
            return nil
        case let .added(id):
            mutate(name: String(ui: "메모리 큐 찍기")) { $0 = edited }
            selectedCueID = id
            return id
        }
    }

    /// 재생 위치(±30ms, 퀀타이즈 위치 포함)에 있는 메모리 큐를 지운다. CDJ에서 메모리 큐를 불러온 자리에서 DELETE를 누르는 것과 같다.
    @discardableResult
    func deleteMemoryCue(at time: Double) -> Bool {
        guard let cue = draft?.memoryCue(near: [time, snapped(time)], closestTo: time) else { return false }
        delete(cue.id)
        return true
    }

    func pressHotCue(slot: Int) {
        audio.recordEvent("조작 핫큐 \(String(UnicodeScalar(UInt8(65 + slot)))) · 재생 중=\(isPlaying) · 위치 \(String(format: "%.2f", playhead))")
        if let cue = hotCue(slot: slot), scrubAnchor != nil {
            // 확대 파형을 끄는 중(#133): 자리만 옮기고 끌기는 거기서 이어 간다. 재생·루프는 놓은 뒤 평소대로(끌기가 쥐고 있다).
            scrub(to: cue.time)
            scrubAnchor?.move(to: playhead)
            selectedCueID = cue.id
        } else if let cue = hotCue(slot: slot) {
            // 루프 핫큐: 재생 중에 같은 루프를 다시 누르면 빠져나오고, 정지 중이면 처음부터 재생한다.
            if isPlaying, cue.loop != nil, engagedLoopID == cue.id {
                exitLoop()
                return
            }
            // 재생 중 퀀타이즈가 켜져 있으면 다음 큰 박선에서 저장 큐로 넘어간다(정지 중이면 바로 재생).
            if !quantizedJump(to: cue) {
                let startsPlayback = !isPlaying && canPlay
                seek(cue.time)
                if cue.loop != nil { instantLoop = nil; engagedLoopID = cue.id; syncAudioLoop() }
                if startsPlayback { startPlayback(from: playhead) }
            }
            selectedCueID = cue.id
        } else if let loop = instantLoop {
            // 즉석 루프 중에 빈 칸을 누르면 그 루프를 루프 핫큐로 저장하고 계속 반복한다(CDJ와 같다).
            var cue = EditableCue(id: storage.drafts.newCueID(), kind: .hot(slot), time: loop.start)
            cue.loop = EditableCue.Loop(end: loop.end, active: false, beats: loop.beats)
            mutate(name: String(ui: "핫큐 찍기")) { $0.place(cue) }
            instantLoop = nil
            engagedLoopID = cue.id
            selectedCueID = cue.id
        } else {
            guard canPlay || grid != nil else {
                if let reason = hotCueCreationUnavailableReason { showToast(reason) }
                return
            }  // 소리·그리드 없이 0초에 박히지 않게
            let cue = EditableCue(id: storage.drafts.newCueID(), kind: .hot(slot), time: snapped(currentTime))
            mutate(name: String(ui: "핫큐 찍기")) { $0.place(cue) }
            selectedCueID = cue.id
        }
    }

    /// 그 칸의 핫큐를 지운다(초안만, 되돌리기 가능).
    func deleteHotCue(slot: Int) {
        guard let cue = hotCue(slot: slot) else { return }
        delete(cue.id)
    }

    func moveHotCueToPlayhead(slot: Int) {
        guard var cue = hotCue(slot: slot) else { return }
        cue.time = snapped(currentTime)
        mutate(name: String(ui: "큐 옮기기")) { $0.place(cue) }
    }

    /// 옮긴다(퀀타이즈면 박에 맞춤). 루프는 길이를 유지한다.
    func move(_ id: EditableCue.ID, to time: Double, save: Bool = true, expectedTrackUUID: String? = nil) {
        let target = snapped(time)
        guard let cue = cueForCommand(id, expectedTrackUUID: expectedTrackUUID), abs(target - cue.time) >= 0.0005 else { return }
        mutate(name: String(ui: "큐 옮기기"), save: save) { $0.move(id, to: target) }
    }

    /// 박 단위로 민다(그리드가 없으면 0.5초).
    func nudge(_ id: EditableCue.ID, beats: Int) {
        guard let cue = cueForCommand(id) else { return }
        let target = grid?.nudge(cue.time, beats: beats) ?? min(max(cue.time + Double(beats) * 0.5, 0), duration)
        mutate(name: String(ui: "큐 옮기기")) { $0.move(id, to: target) }
    }

    // MARK: 루프

    /// 큐를 박 수만큼의 루프로 만든다(nil이면 루프를 없앤다). 그리드가 있으면 박에 맞춘다.
    func setLoop(_ id: EditableCue.ID, beats: Int?, expectedTrackUUID: String? = nil) {
        guard let cue = cueForCommand(id, expectedTrackUUID: expectedTrackUUID) else { return }
        guard let beats else {
            mutate(name: String(ui: "루프 편집")) { $0.setLoop(id, end: nil, beats: nil) }
            return
        }
        guard let end = loopEnd(from: cue.time, beats: Double(beats)) else { return }
        mutate(name: String(ui: "루프 편집")) { $0.setLoop(id, end: end, beats: Double(beats)) }
    }

    /// 활성 루프 켜기·끄기(곡을 불러오면 그 루프를 자동으로 반복한다). 곡에 하나만 둔다.
    func toggleActiveLoop(_ id: EditableCue.ID) {
        guard cue(id)?.loop != nil else { return }
        mutate(name: String(ui: "활성 루프 변경")) { $0.toggleActiveLoop(id) }
    }

    /// 루프 박 수(그리드 기준, 대략)
    func loopBeats(_ cue: EditableCue) -> Int? { LoopRules.beats(of: cue, grid: grid, bpm: gridBPM) }

    func setKind(_ id: EditableCue.ID, _ kind: EditableCue.Kind, expectedTrackUUID: String? = nil) {
        guard var cue = cueForCommand(id, expectedTrackUUID: expectedTrackUUID) else { return }
        cue.kind = kind
        mutate(name: String(ui: "큐 종류 변경")) { $0.place(cue) }
    }

    func rename(_ id: EditableCue.ID, _ name: String, expectedTrackUUID: String? = nil) {
        guard var cue = cueForCommand(id, expectedTrackUUID: expectedTrackUUID) else { return }
        cue.name = name
        mutate(name: String(ui: "큐 이름 변경")) { $0.place(cue) }
    }

    func delete(_ id: EditableCue.ID, expectedTrackUUID: String? = nil) {
        guard let cue = cueForCommand(id, expectedTrackUUID: expectedTrackUUID) else { return }
        let name = cue.kind.slotLetter == nil ? String(ui: "메모리 큐 지우기") : String(ui: "핫큐 지우기")
        mutate(name: name) { $0.remove(id) }
        if selectedCueID == id { selectedCueID = nil }
    }

    /// 제안 자리에 메모리 큐를 찍는다(배지 클릭·A·VoiceOver 동작). 새로 찍었으면 VoiceOver로 알린다.
    func acceptSuggestion(_ time: Double) {
        let target = snapped(time)
        guard storeMemoryCue(at: target, loop: nil) != nil else { return }
        announce(String(ui: "제안을 받아 \(target.spokenClockText)에 메모리 큐를 찍었습니다"))
    }

    /// A: 재생 위치에서 가장 가까운 제안을 받는다. 제안이 없으면 아무것도 하지 않고 VoiceOver로만 알린다.
    func acceptNearestSuggestion() {
        guard !isWriteLocked else { return }
        guard let nearest = suggestions.min(by: { abs($0 - playhead) < abs($1 - playhead) }) else {
            announce(String(ui: "받을 제안이 없습니다"))
            return
        }
        acceptSuggestion(nearest)
    }

    /// S·⇧S: 다음·이전 제안 자리로 재생 위치만 옮긴다(큐·CUE 지점은 그대로). 그쪽에 제안이 없으면 VoiceOver로만 알린다.
    func jumpToSuggestion(forward: Bool) {
        guard !isWriteLocked else { return }
        // 재생 중 이전으로는 Q처럼 방금 지난 제안(0.25초 안)을 건너뛴다.
        let slack = !forward && isPlaying ? 0.25 : Self.cueTolerance
        let target = forward
            ? suggestions.filter { $0 > playhead + Self.cueTolerance }.min()
            : suggestions.filter { $0 < playhead - slack }.max()
        guard let target else {
            announce(forward ? String(ui: "뒤쪽에 제안이 없습니다") : String(ui: "앞쪽에 제안이 없습니다"))
            return
        }
        seek(target)
    }

    /// 화면 알림 없이 VoiceOver로만 알린다.
    func announce(_ text: String) {
        feedback.announce(AppMessage(kind: .success, text: text))
    }

    func revertDraft() {
        mutate(name: String(ui: "큐 초안 버리기")) { $0.revert() }
        selectedCueID = nil
    }

    func reloadExternalCueDraft(_ saved: CueDraft?) {
        guard !isWriteLocked, !hasUncommittedCueEdits, let row, saved == nil || saved?.trackUUID == row.track.uuid else { return }
        guard !currentDraftSaveFailures.contains(where: { $0.kind == .cue }) else { return }
        let saved = saved?.includingAutoCues(from: row.cues, newID: storage.drafts.newCueID)
        if let saved, saved.base == draft?.base, saved.cues == draft?.cues { return }
        if saved == nil, draft?.hasChanges != true { return }
        // 그리드·게인 실행 취소에도 옛 큐가 들어 있으므로 이 곡의 덱 이력을 비운다.
        clearDraftUndo()
        draft = saved ?? CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues, newID: storage.drafts.newCueID)
        if cue(selectedCueID) == nil { selectedCueID = nil }
        if cue(engagedLoopID)?.loop == nil { engagedLoopID = nil }
        refreshSuggestions()
        syncAudioLoop()
    }

    func commitDraft() {
        guard !isWriteLocked, let draft else { return }
        persist(draft)
        registerDraftUndo(from: pendingDraftUndo, name: String(ui: "큐 옮기기"))
        pendingDraftUndo = nil
    }

    func mutate(name: String = String(ui: "큐 편집"), save: Bool = true, recordingUndo: Bool = true, _ change: (inout CueDraft) -> Void) {
        guard var draft = commandDraft() else { return }
        let before = draftSnapshot
        change(&draft)
        guard self.draft != draft else { return }
        if recordingUndo, !save, pendingDraftUndo == nil { pendingDraftUndo = before }
        self.draft = draft
        hasUncommittedCueEdits = !save
        refreshSuggestions()
        if save {
            persist(draft)
            if recordingUndo {
                registerDraftUndo(from: pendingDraftUndo ?? before, name: name)
                pendingDraftUndo = nil
            }
        }
        syncAudioLoop()
    }

    func persist(_ draft: CueDraft) {
        hasUncommittedCueEdits = false
        storage.drafts.saveCue(draft, completion: draftSaveCompletion(.cue, uuid: draft.trackUUID))
        onCueDraftChange?(draft)
        onDraftChange?(draft.trackUUID, .cue, draft.hasChanges)
    }
}
