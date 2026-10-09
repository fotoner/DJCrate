import DJCApplication
import DJCDomain
import AppKit
import Foundation

/// 그리드 편집·추정 제안(초안만 바뀐다)
extension DeckModel {
    // MARK: - 그리드 편집 (초안만 바뀐다)

    var canEditGrid: Bool { !isWriteLocked && gridDraft != nil && gridEditBlockedReason == nil }

    /// 그리드 초안 버리기: 편집 중이거나, 편집이 막힌 초안(막히면 편집 잠금을 풀 수 없어도 버릴 수는 있어야 한다)
    var canDiscardGridDraft: Bool {
        guard !isWriteLocked, gridDraft?.hasChanges == true else { return false }
        return gridEditBlockedReason != nil || (canEditGrid && gridEditing)
    }

    /// rekordbox 그리드도, 적용한 추정 그리드도 없는 로컬 곡.
    var needsGrid: Bool { row != nil && row?.track.isStreaming == false && !hasRekordboxGrid && gridDraft == nil }

    func shiftGrid(ms: Double) { mutateGrid(name: String(ui: "그리드 옮기기")) { $0.shift(by: ms / 1000) } }

    func setGridBPM(_ bpm: Double) {
        guard GridDraft.bpmRange.contains(bpm) else {
            showToast(String(ui: "BPM은 20…655.35 사이로 입력하세요"))
            return
        }
        mutateGrid(name: String(ui: "BPM 변경")) { $0.setBPM(bpm, at: playhead) }
    }

    func scaleGridBPM(_ factor: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm * factor)
    }

    func nudgeGridBPM(_ delta: Double) {
        guard let bpm = gridBPM else { return }
        setGridBPM(bpm + delta)
    }

    func setGridAnchorAtPlayhead() { mutateGrid { $0.setAnchor(at: playhead) } }

    /// 변속 지점도 큐·루프처럼 Q를 따른다: 켜면 가장 가까운 박, 끄면 재생 위치 그대로(#207).
    func addTempoChangeAtPlayhead() {
        if quantize {
            mutateGrid { $0.addTempoChange(nearest: playhead, duration: duration) }
            return
        }
        var rejected = false
        mutateGrid { rejected = !$0.addTempoChange(at: playhead, duration: duration) }
        if rejected {
            showToast(String(ui: "변속 지점은 첫 구간 시작 뒤, 이웃 변속 지점과 반 박 넘게 떨어진 자리에 두세요"), kind: .warning)
        }
    }

    func removeTempoChange(at index: Int) { mutateGrid { $0.removeTempoChange(at: index) } }

    func revertGrid() {
        guard canDiscardGridDraft || canEditGrid else { return }
        mutateGrid(name: String(ui: "그리드 초안 버리기"), allowingBlocked: true) { $0.revert() }
    }

    /// 그리드 편집 막대의 ‹ › 버튼을 누르고 있는 동안 그리드 전체를 옮긴다(한 번의 편집으로 저장).
    func beginGridDrag() {
        guard canEditGrid else { return }
        pendingDraftUndo = draftSnapshot
        gridDragBase = gridDraft
        cueDragBase = carryCues ? draft?.cues : nil
    }

    func dragGrid(by seconds: Double) {
        guard !isWriteLocked, var base = gridDragBase, base.trackUUID == row?.track.uuid else { return }
        let from = base.segments
        base.shift(by: seconds)
        gridDraft = base
        if let cues = cueDragBase { moveCuesWithGrid(cues, from: from, to: base.segments, save: false) }
        refreshGrid()
        // 끄는 동안에도 메트로놈이 새 그리드를 따라가게 한다(너무 잦지 않게).
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastClickReset > 0.25 {
            lastClickReset = now
            audio.resetClicks()
        }
    }

    func endGridDrag() {
        guard gridDragBase != nil else { return }
        guard !isWriteLocked else { return }
        gridDragBase = nil
        cueDragBase = nil
        if let draft { persist(draft) }
        saveGridEdit()
        registerDraftUndo(from: pendingDraftUndo, name: String(ui: "그리드 옮기기"))
        pendingDraftUndo = nil
    }

    /// 그리드가 `from` → `to`로 바뀐 만큼 큐(핫큐·메모리 큐·루프 끝)를 따라 옮긴다.
    func moveCuesWithGrid(_ cues: [EditableCue]? = nil, from: [GridSegment], to: [GridSegment], save: Bool = true) {
        guard carryCues, let current = draft else { return }
        let length = max(duration, Double(row?.track.lengthSeconds ?? 0))
        // 지금 초안 값과 같은 큐는 건드리지 않는다(끄는 동안은 출발 위치에서 옮긴다).
        let moved = GridDraft.carried(cues ?? current.cues, from: from, to: to, duration: length).filter { cue in
            guard let now = current.cues.first(where: { $0.id == cue.id }) else { return false }
            return abs(now.time - cue.time) >= 0.0005 || abs((now.loop?.end ?? 0) - (cue.loop?.end ?? 0)) >= 0.0005
        }
        guard !moved.isEmpty else { return }
        mutate(save: save, recordingUndo: false) { draft in for cue in moved { draft.place(cue) } }
    }

    /// 탭 템포: 2초 넘게 쉬면 새로 센다. 최근 8번 간격의 평균.
    func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = taps.last, now - last > 2 { taps = [] }
        taps.append(now)
        taps = Array(taps.suffix(9))
        guard taps.count >= 3 else { tapBPM = nil; return }
        let interval = (taps.last! - taps.first!) / Double(taps.count - 1)
        tapBPM = 60 / interval
    }

    func resetTapTempo() {
        taps = []
        tapBPM = nil
    }

    func mutateGrid(name: String = String(ui: "그리드 편집"), allowingBlocked: Bool = false, _ change: (inout GridDraft) -> Void) {
        guard !isWriteLocked else { return }
        guard var gridDraft, gridDraft.trackUUID == row?.track.uuid else {
            showToast(String(ui: "편집할 그리드 초안이 준비되지 않았으니 곡을 덱에 다시 불러온 뒤 편집하세요"), kind: .warning)
            return
        }
        guard canEditGrid || allowingBlocked else {
            if let reason = gridUnavailableReason { showToast(reason, kind: .warning) }
            return
        }
        let snapshot = draftSnapshot
        let before = gridDraft.segments
        change(&gridDraft)
        guard self.gridDraft != gridDraft else { return }
        // 복잡한 원본을 대체한 초안은 승인한 모양(템포 구간 하나)을 벗어나는 편집을 받지 않는다(받으면 편집 전체가 막힌다).
        if gridDraft.replacementSource != nil, let originalGrid, !gridDraft.isVerifiedReplacement(of: originalGrid, duration: duration) {
            showToast(String(ui: "복잡한 rekordbox 그리드를 대체한 초안은 템포 구간을 하나로만 둘 수 있으니 변속 지점은 rekordbox에서 편집하세요"), kind: .failure)
            return
        }
        self.gridDraft = gridDraft
        moveCuesWithGrid(from: before, to: gridDraft.segments)
        saveGridEdit()
        registerDraftUndo(from: snapshot, name: name)
    }

    func saveGridEdit() {
        guard let gridDraft else { return }
        refreshGridEditEligibility()
        refreshGrid()
        persistGrid(gridDraft)
        onDraftChange?(gridDraft.trackUUID, .grid, gridDraft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(gridDraft.trackUUID, gridDraft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
    }

    private func refreshGridEditEligibility() {
        guard let originalGrid else { return }
        gridEditBlockedReason = DeckGridGate.editBlockedReason(trackUUID: row?.track.uuid ?? "", original: originalGrid,
                                                               draft: gridDraft, duration: duration)
    }

    // MARK: - 그리드 추정·제안

    /// MU 분석 결과와 어택 곡선으로 그리드를 추정한다. 추가한 곡(아직 rekordbox에 없음)은 그리드가 없으면 바로 적용한다.
    func startGridSuggestion(_ sections: DeckSections, url: URL, key: String, generation: Int) {
        suggestionTask?.cancel()
        let analyzer = analyzer, offset = timelineOffset, duration = duration
        suggestionTask = Task {
            let suggestion = try? await Task.detached(priority: .utility) {
                try analyzer.gridSuggestion(sections, file: url, key: key, timelineOffset: offset, duration: duration)
            }.value
            guard self.isCurrentLoad(generation), let suggestion else { return }
            self.gridSuggestion = suggestion.estimate
            self.suggestedGrid = suggestion.grid
            if self.gridDraft == nil, self.row?.isStaged == true {
                self.applyGridSuggestion(recordingUndo: false)
            } else {
                self.refreshSuggestionNote()
            }
        }
    }

    /// 재분석: 이 곡의 섹션·그리드 추정·조성 캐시와 제안 무시 표시(그리드·키)를 지우고 다시 불러온다.
    func reanalyze() {
        guard let uuid = row?.track.uuid else { return }
        analyzer.forget(key: uuid)
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        dismissed.remove(uuid)
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        dismissedRevision += 1
        onReanalyze?(uuid)
        reload()
        showToast(String(ui: "다시 분석합니다"), kind: .success)
    }

    /// 무시한 제안을 다시 보인다.
    func restoreGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        guard dismissed.remove(uuid) != nil else { return }
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        dismissedRevision += 1
    }

    /// 이 곡의 그리드 제안을 더는 보이지 않게 한다(곡마다 기억).
    func dismissGridSuggestion() {
        guard let uuid = row?.track.uuid else { return }
        var dismissed = storage.settings.strings(SettingKeys.dismissedGridSuggestions)
        dismissed.insert(uuid)
        storage.settings.setStrings(SettingKeys.dismissedGridSuggestions, dismissed)
        dismissedRevision += 1
    }

    /// 무시 표시는 설정에만 있어 관찰되지 않는다. 바뀔 때 올리는 `dismissedRevision`을 함께 읽어 화면이 따라 바뀌게 한다.
    var isGridSuggestionDismissed: Bool {
        _ = dismissedRevision
        guard let uuid = row?.track.uuid else { return false }
        return storage.settings.strings(SettingKeys.dismissedGridSuggestions).contains(uuid)
    }


    // MARK: 알림(잠깐 떴다 사라진다)


    /// 떠 있는 시간(nil이면 닫을 때까지). 경고는 문장이 길어 읽을 시간을 더 준다(#146).
    static func toastDuration(_ kind: AppToast.Kind) -> Duration? {
        switch kind {
        case .success: .seconds(2.5)
        case .warning: .seconds(5)
        case .failure: nil
        }
    }

    func showToast(_ text: String, kind: AppToast.Kind = .warning) {
        toastTask?.cancel()
        toastTask = nil
        let message = AppMessage(kind: kind, text: text)
        toast = message
        feedback.announce(message)
        guard let duration = Self.toastDuration(kind), !feedback.isVoiceOverEnabled() else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, !self.feedback.isVoiceOverEnabled() else { return }
            self.toast = nil
        }
    }

    /// 추정 그리드를 초안으로 적용한다(원본이 있으면 원본은 그대로 두고 구간만 바꾼다).
    func applyGridSuggestion(recordingUndo: Bool = true) {
        guard !isWriteLocked, let suggestion = gridSuggestion, let uuid = row?.track.uuid else { return }
        let base = gridDraft?.base ?? []
        let before = gridDraft?.segments ?? originalGrid.map(GridDraft.segments(from:)) ?? []
        var draft = GridDraft(trackUUID: uuid, base: base, segments: suggestion.segments)
        if let originalGrid, !originalGrid.beats.isEmpty {
            // 초안을 만든 뒤 rekordbox 그리드가 바뀌었으면 어느 쪽도 덮지 않는다.
            guard base == GridDraft.segments(from: originalGrid) else {
                showToast(String(ui: "초안을 만든 뒤 rekordbox에서 그리드가 바뀌었으니 그리드 현재값 가져오기로 비교하세요"), kind: .failure)
                return
            }
            // 템포 구간으로 다시 만들 수 없는 원본만 명시 대체로 승인한다(단순한 원본은 보통 초안이다).
            if GridEditEligibility.reconstructionErrorMilliseconds(of: originalGrid, duration: duration) > 2 {
                guard let approved = draft.approvingReplacement(of: originalGrid, duration: duration) else {
                    showToast(String(ui: "rekordbox 그리드가 복잡한 곡은 템포 구간이 하나인 추정 그리드로만 바꿀 수 있습니다"), kind: .failure)
                    return
                }
                draft = approved
            }
        }
        // 자동 분석은 새 편집이 아니라 초안의 기준을 바꾸는 로드다.
        if !recordingUndo { clearDraftUndo() }
        let snapshot = draftSnapshot
        gridDraft = draft
        moveCuesWithGrid(from: before, to: draft.segments)
        // 복잡한 원본이라 막아 둔 곡도, 추정 그리드로 바꾸면 편집할 수 있다.
        gridEditBlockedReason = nil
        refreshGridEditEligibility()
        refreshGrid()
        persistGrid(draft)
        onDraftChange?(uuid, .grid, draft.hasChanges)
        if row?.isStaged == true { onStagedGridChange?(uuid, draft.segments.first?.bpm) }
        audio.resetClicks()
        refreshSuggestionNote()
        if recordingUndo { registerDraftUndo(from: snapshot, name: String(ui: "추정 그리드 적용")) }
    }

    /// 백그라운드 추정이 이 곡의 초안을 저장했으면 다시 읽는다.
    func gridDraftSavedExternally(_ uuid: String) {
        guard row?.track.uuid == uuid, gridDraft == nil, let saved = storage.drafts.currentGrid(uuid) else { return }
        clearDraftUndo()
        gridDraft = saved
        refreshGrid()
        refreshSuggestionNote()
    }

    /// rekordbox XML 가져오기(#72)가 만든 이 곡의 그리드 초안을 받아 덱 저장 경로로 쓴다.
    /// 덱 초안을 바꿨거나(끄는 중 포함) 다른 곡이면 받지 않는다(덱 편집을 덮지 않는다).
    func adoptImportedGridDraft(_ draft: GridDraft) -> Bool {
        guard !isWriteLocked, row?.track.uuid == draft.trackUUID, gridDragBase == nil, gridDraft?.hasChanges != true else { return false }
        // 실행 취소 이력의 옛 그리드가 가져온 초안을 덮지 않게 비운다.
        clearDraftUndo()
        gridDraft = draft
        saveGridEdit()
        return true
    }

    /// 덱 제안 줄의 그리드 제안: 추정과 현재 그리드의 차이(없거나 작으면 nil). 그리드가 없는 곡은 추정 BPM만 보인다.
    func refreshSuggestionNote() {
        guard let suggestion = gridSuggestion else { gridSuggestionItem = nil; return }
        let tempos = suggestion.segments.map(\.bpm)
        guard let grid, !grid.beats.isEmpty else {
            gridSuggestionItem = .grid(bpm: suggestion.bpm, phaseMilliseconds: nil, tempos: tempos, hasRekordboxGrid: !needsGrid,
                                       isConfident: suggestion.isConfident)
            return
        }
        let suggested = GridDraft(trackUUID: "", base: [], segments: suggestion.segments).grid(duration: duration)
        let bpmDelta = suggestion.bpm - (grid.beats.first?.bpm ?? suggestion.bpm)
        // 곡 가운데 80%에서 현재 박과 추정 박의 차이(반 박 안으로 접은 값)의 중앙값
        let period = 60 / max(suggestion.bpm, 1)
        var deltas: [Double] = []
        for beat in grid.beats where beat.time > duration * 0.1 && beat.time < duration * 0.9 {
            let i = suggested.firstIndex(atOrAfter: beat.time)
            let near = [i - 1, i].filter { suggested.beats.indices.contains($0) }.map { suggested.beats[$0].time }
            guard let nearest = near.min(by: { abs($0 - beat.time) < abs($1 - beat.time) }) else { continue }
            var d = (nearest - beat.time).truncatingRemainder(dividingBy: period)
            if d > period / 2 { d -= period } else if d < -period / 2 { d += period }
            deltas.append(d)
        }
        deltas.sort()
        let phase = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
        if abs(bpmDelta) < 0.05, abs(phase) < 0.010 {
            gridSuggestionItem = nil  // 사실상 같다
        } else {
            gridSuggestionItem = .grid(bpm: suggestion.bpm, phaseMilliseconds: phase * 1000, tempos: tempos,
                                       isConfident: suggestion.isConfident)
        }
    }
}
