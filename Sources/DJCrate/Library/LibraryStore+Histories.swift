import DJCApplication
import DJCDomain
import Foundation

/// 재생 기록(#43): rekordbox Histories처럼 연 › 월 › 기록 트리에 rekordbox 기록과 USB에서 보존한 기기 기록을 섞는다.
/// USB 기록은 USB를 읽을 때(`UsbStore.onLibraryEvaluated`) 유스케이스 `ArchiveUsbHistories`가 DJCrate 데이터 폴더(`usb-histories/`)에 보존하고
/// (USB에는 쓰지 않는다), 다른 초안처럼 "rekordbox 쓰기 대기"에 올려(`pendingHistories`) rekordbox에 쓰기(⇧⌘E) 때 반영 세션이
/// rekordbox Histories에 넣는다. 판정은 `UsbHistoryRules`·`UsbHistoryImport`에 있고, 이 확장은 보존·저장을 한 줄로 세우고 결과를 화면 상태에 넣는다.
extension LibraryStore {
    /// 컬렉션에 없는 보존 기록 곡의 줄 ID 접두사. `usb:`로 시작해 `isUsb`가 참이라 편집·덱·쓰기·끌기가 막힌다
    static let archivedTrackIDPrefix = UsbLibraryRows.idPrefix + "history:"

    func archivedHistory(_ id: String) -> ArchivedHistory? { archivedHistoryIndex[id] }

    /// USB를 뺀 뒤에도 채택한 스냅샷의 원본 키로 보존본을 다시 검증한다.
    func rematchArchivedHistories() {
        let changed = zip(archivedHistories, UsbHistoryRules.rematch(archivedHistories, local: historyLocalKeys))
            .compactMap { old, new in old == new ? nil : new }
        guard !changed.isEmpty else { return }
        let save = updateArchivedHistories(changed)
        Task { @MainActor [weak self] in
            guard await save.value > 0 else { return }
            self?.toast = .notice(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                                  String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 시도하세요"), isUsb: true)
        }
    }

    // MARK: - 트리

    /// 처음 한 번 가장 최근 연·월을 펼친다. 라이브러리를 읽은 뒤에 부른다
    /// (보존 기록만 먼저 읽힌 트리로 펼치면 rekordbox의 더 최근 달이 접혀 있다)
    func seedHistoryFolders() {
        guard !historyFoldersSeeded, !historyTree.isEmpty else { return }
        historyFoldersSeeded = true
        expandHistoryFolders(historyTree.latestFolderIDs)
    }

    /// 기록이 든 연·월을 펼친다(기록을 골랐을 때·새로 가져왔을 때)
    func revealHistory(_ id: String) {
        expandHistoryFolders(historyTree.folderIDs(containing: id))
    }

    /// 연·월 폴더를 펼치거나 접는다(사이드바 폴더 줄)
    func setHistoryFolder(_ id: String, expanded: Bool) {
        if expanded { expandedHistoryFolders.insert(id) } else { expandedHistoryFolders.remove(id) }
    }

    private func expandHistoryFolders(_ ids: [String]) {
        let missing = Set(ids).subtracting(expandedHistoryFolders)
        if !missing.isEmpty { expandedHistoryFolders.formUnion(missing) }
    }

    // MARK: - 곡 수·줄

    /// 사이드바 곡 수(보일 줄 수). rekordbox 기록은 컬렉션에 있는 곡만, 보존 기록은 컬렉션에 없는 곡도 센다(읽기 전용 줄로 보인다)
    func historyCount(_ id: String) -> Int {
        if let history = historyIndex[id] { return count(history: history) }
        return archivedHistoryIndex[id].map { count(archived: $0) } ?? 0
    }

    /// '스트리밍 곡 숨기기'는 rekordbox 기록과 같게 컬렉션 곡에만 건다
    func count(archived history: ArchivedHistory) -> Int {
        history.entries.reduce(0) { count, entry in
            guard let row = entry.contentID.flatMap({ rowsByID[$0] }) else { return count + 1 }
            return StreamingVisibility.hides(row.track, hidingStreaming: hideStreaming) ? count : count + 1
        }
    }

    /// 보존 기록의 줄(재생 순서, 반복 재생 포함). 컬렉션 짝이 있으면 그 곡 줄, 없으면 보존한 제목·아티스트·경로로 만든 읽기 전용 줄
    func archivedHistoryRows(_ id: String) -> [TrackRow] {
        guard let history = archivedHistoryIndex[id] else { return [] }
        return history.entries.map { entry -> TrackRow in
            var row = entry.contentID.flatMap { rowsByID[$0] } ?? Self.archivedRow(entry, history: history)
            // 같은 곡을 다시 튼 줄도 따로 고르게 줄 ID를 기록·순번으로 짓는다(`TrackRow.id`)
            row.historyEntry = RekordboxHistory.Entry(id: "\(history.id):\(entry.trackNumber)", contentID: entry.contentID ?? "",
                                                      trackNumber: entry.trackNumber)
            return row
        }
    }

    /// 컬렉션에 없는 곡의 읽기 전용 줄(USB에서 읽은 제목·아티스트·경로·BPM·길이). 분석·아트워크 경로는 비운다(`UsbLibraryRows.row`와 같은 까닭: 로컬의 다른 파일을 읽는다)
    static func archivedRow(_ entry: ArchivedHistory.Entry, history: ArchivedHistory) -> TrackRow {
        let id = "\(archivedTrackIDPrefix)\(history.id):\(entry.trackNumber)"
        let track = Track(id: id, uuid: id, title: entry.title, artist: entry.artist, album: nil, albumArtist: nil, genre: nil,
                          composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: entry.bpm, lengthSeconds: entry.lengthSeconds ?? 0,
                          folderPath: entry.path, comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0)
    }

    // MARK: - USB 기록 보존

    /// 보존한 기록을 읽는다(조립 지점이 유스케이스를 붙인 뒤). 읽지 못한 파일은 유스케이스가 damaged-drafts로 옮기고 여기서 알린다
    func loadArchivedHistories(preservingCurrent: Bool = false) async {
        guard let usbHistories else { return }
        let loaded = await usbHistories.load()
        unreadableHistoryFiles = loaded.unreadable
        if preservingCurrent {
            // 기다리는 동안 고친 쓰기 상태는 지키고, 앞서 읽지 못했던 파일에서 알아낸 기록만 더한다.
            let known = Set(archivedHistories.map(\.id))
            archivedHistories += loaded.histories.filter { !known.contains($0.id) }
        } else {
            archivedHistories = loaded.histories
        }
        rematchArchivedHistories()
        if snapshotURL != nil { seedHistoryFolders() }
        if case .history = sidebar { refreshBase() }
        if !loaded.unreadable.isEmpty {
            toast = .notice(String(ui: "USB 재생 기록 파일을 읽지 못했습니다. usb-histories 읽기 권한을 확인한 뒤 USB를 다시 연결하세요"),
                            loaded.unreadable.joined(separator: ", "), isUsb: true)
        } else if !loaded.damaged.isEmpty {
            toast = .notice(String(ui: "읽지 못한 USB 재생 기록 파일 \(loaded.damaged.count)개를 damaged-drafts로 옮겼습니다. 기록이 남은 USB를 다시 연결하면 다시 가져옵니다"),
                            loaded.damaged.joined(separator: ", "), isUsb: true)
        }
    }

    /// 보존한 기록 읽기를 보존 줄 맨 앞에 세운다(USB를 읽으면 그와 견줘 새 기록만 보존한다)
    func startLoadingArchivedHistories() {
        guard usbHistories != nil else { return }
        let previous = historyImports
        historyImports = Task { @MainActor [weak self] in
            await previous?.value
            await self?.loadArchivedHistories()
        }
    }

    /// USB의 새 기기 재생 기록을 보존하고 트리에 더한다(USB를 읽었거나 로컬 짝을 다시 계산한 뒤, `UsbStore.onLibraryEvaluated`).
    /// 한 줄로 세워 차례로 한다: 계획은 앞선 보존이 끝난 뒤의 상태로 세우고, 파일 쓰기(fsync)는 메인 액터 밖에서 한다
    func importUsbHistories(volume: UsbVolumeInfo, library: UsbLibrary, matches: [Int: String]) {
        guard usbHistories != nil else { return }
        let previous = historyImports
        historyImports = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performUsbHistoryImport(volume: volume, library: library, matches: matches)
        }
    }

    /// 줄 선 USB 기록 보존이 모두 끝날 때까지(시험·자가 테스트)
    func waitForHistoryImports() async {
        while let task = historyImports {
            await task.value
            // 기다리는 동안 새로 줄을 서지 않았으면 끝
            if historyImports == task { return }
        }
    }

    /// 저장됐거나 현재 파일 내용이 일치하는 기록만 채택하고, 내구 쓰기 실패는 알린다.
    private func performUsbHistoryImport(volume: UsbVolumeInfo, library: UsbLibrary, matches: [Int: String]) async {
        guard let usbHistories else { return }
        if !unreadableHistoryFiles.isEmpty {
            await loadArchivedHistories(preservingCurrent: true)
            guard unreadableHistoryFiles.isEmpty else { return }
        }
        guard let imported = await usbHistories.importFrom(volumeKey: volume.usbKey, volumeName: volume.name, library: library, matches: matches,
                                                           existing: archivedHistories, local: historyLocalKeys, calendar: .current) else { return }
        if imported.failed {
            toast = .notice(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                            String(ui: "DJCrate 데이터 폴더의 usb-histories를 확인한 뒤 USB를 다시 연결하세요"), isUsb: true)
        }
        guard !imported.saved.isEmpty else { return }
        let savedIDs = Set(imported.saved.map(\.id))
        // 파일 쓰기를 기다리는 동안 채택한 새 스냅샷에도 맞춘다(그 저장은 이 보존 뒤에 줄을 선다).
        archivedHistories = UsbHistoryRules.merging(saved: imported.saved, into: archivedHistories)
        rematchArchivedHistories()
        // rekordbox도 가져온 기록(숨김)은 새로 가져왔다고 알리지 않는다
        let shown = imported.added.filter { savedIDs.contains($0.id) && !shadowedArchiveIDs.contains($0.id) }
        if snapshotURL != nil { seedHistoryFolders() }
        for history in shown { revealHistory(history.id) }
        // 일부만 보존했으면 경고를 남긴다. 닫을 때까지 남는 경고·동작 단추가 있는 알림(USB 꺼내기 등)도 덮지 않는다
        if !shown.isEmpty, !imported.failed, canReplaceToast {
            // 보존본을 넣으면서 쓰기 대기를 다시 골랐다(`refreshHistoryTree`). 대기에 오른 기록은 그 사실을 함께 알린다
            let queued = shown.filter { pendingHistoryIDs.contains($0.id) }.count
            let detail = queued == 0 ? volume.name
                : queued == shown.count ? String(ui: "\(volume.name) · rekordbox 쓰기 대기에 올렸습니다")
                : String(ui: "\(volume.name) · \(queued)개를 rekordbox 쓰기 대기에 올렸습니다")
            toast = .notice(String(ui: "USB에서 재생 기록 \(shown.count)개를 가져왔습니다"), detail, kind: .success, isUsb: true)
        }
        if case let .history(id) = sidebar, savedIDs.contains(id) { refreshBase() }
    }

    /// 지금 알림을 기록 가져오기 알림으로 바꿔도 되는지: 없거나, 곧 사라지는 성공 알림(되돌리기·동작 단추 없음)일 때만
    private var canReplaceToast: Bool {
        guard let toast else { return true }
        return toast.kind == .success && toast.undoBackup == nil && toast.action == nil
    }

    // MARK: - rekordbox 쓰기 대기

    /// 쓰기 대기 재생 기록이 있는지(곡 초안이 없어도 rekordbox에 쓸 것이 있다)
    var hasHistoryDrafts: Bool { !pendingHistories.isEmpty }

    /// 쓰기 대기 기록을 rekordbox 쓰기 입력으로(가져온 차례, `UsbHistoryRules.imports`). 반영 세션이 읽는다
    var pendingHistoryImports: [HistoryImport] {
        let rows = rowsByID
        return UsbHistoryRules.imports(pendingHistories, local: historyLocalKeys, inCollection: { rows[$0] != nil })
    }

    /// 보존 기록을 rekordbox 쓰기 대기에서 빼거나 다시 넣는다(보존본은 그대로). 편집 › 실행 취소로 되돌린다.
    /// 화면 상태는 바로 바꾸고 파일 저장은 보존 줄에 세운다. 저장하지 못하면 알린다(다시 켜면 옛 상태로 읽힌다)
    func setHistoriesExcluded(_ ids: [String], excluded: Bool) {
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        let changed = UsbHistoryRules.excluding(archivedHistories, ids: ids, excluded: excluded)
        guard !changed.isEmpty else { return }
        let save = updateArchivedHistories(changed)
        if let undoManager {
            // 한 이벤트 안에서 여러 번 바꿔도 각각 한 단계로 남긴다(태그·덱 초안과 같다)
            let grouping = !undoManager.isUndoing && !undoManager.isRedoing
            let groupsByEvent = undoManager.groupsByEvent
            if grouping {
                undoManager.groupsByEvent = false
                undoManager.beginUndoGrouping()
            }
            let changedIDs = changed.map(\.id)
            undoManager.registerUndo(withTarget: self) { target in
                guard !target.isWritingRekordbox else { return }
                target.setHistoriesExcluded(changedIDs, excluded: !excluded)
            }
            undoManager.setActionName(excluded ? String(ui: "rekordbox 쓰기 대기에서 빼기") : String(ui: "rekordbox 쓰기 대기에 넣기"))
            if grouping {
                undoManager.endUndoGrouping()
                undoManager.groupsByEvent = groupsByEvent
            }
        }
        Task { [weak self] in
            guard await save.value > 0 else { return }
            self?.toast = .notice(Self.historyQueueSaveFailureTitle,
                                  String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 바꾸세요"), isUsb: true)
        }
    }

    /// rekordbox에 쓴(또는 최신 대상에 이미 있던) 보존 기록에 rekordbox 기록 ID를 남긴다(반영 세션이 쓴 뒤 다시 읽기 전에 부른다).
    /// 다시 읽을 때까지는 쓴 ID를 rekordbox에 있는 것으로 봐(`historyIDsAwaitingReload`) 다시 읽지 못해도 같은 기록을 또 쓰지 않는다.
    /// 그 기록이 나중에 rekordbox에서 사라지면(쓰기 전으로 복원 등) `HistoryWriteQueue`가 다시 쓰기 대기로 돌린다.
    /// - Returns: 표시를 저장하지 못했을 때 알릴 문장(rekordbox 쓰기는 끝났다)
    func recordWrittenHistories(_ outcomes: [RekordboxHistoryOutcome]) async -> String? {
        let marked = UsbHistoryRules.markWritten(archivedHistories, outcomes: outcomes, local: historyLocalKeys)
        guard !marked.historyIDs.isEmpty else { return nil }
        historyIDsAwaitingReload.formUnion(marked.historyIDs)
        refreshHistoryTree()
        let failed = await updateArchivedHistories(marked.changed).value
        return failed == 0 ? nil : Self.historyMarkFailureText(failed)
    }

    static func historyMarkFailureText(_ count: Int) -> String {
        String(ui: "rekordbox에는 썼지만 보존한 재생 기록 \(count)건에 쓴 표시를 저장하지 못했으니, 다시 켠 뒤 그 기록이 쓰기 대기에 오르면 사이드바에서 쓰기 대기에서 빼세요.")
    }

    static var historyQueueSaveFailureTitle: String { String(ui: "재생 기록의 쓰기 대기 상태를 저장하지 못했습니다") }

    /// 고친 보존 기록을 화면 상태에 바로 넣고, 파일 저장은 보존 줄(`historyImports`)에 세운다.
    /// 저장은 줄 차례가 왔을 때의 보존본(그사이 가져오기가 짝을 채웠거나 다시 바꾼 것까지)을 메인 액터 밖에서 쓴다.
    /// - Returns: 저장하지 못한 기록 수를 돌려주는 작업
    @discardableResult
    func updateArchivedHistories(_ updated: [ArchivedHistory]) -> Task<Int, Never> {
        archivedHistories = UsbHistoryRules.replacing(archivedHistories, with: updated)
        let ids = updated.map(\.id)
        let previous = historyImports
        let save = Task { @MainActor [weak self] () -> Int in
            await previous?.value
            guard let self, let usbHistories = self.usbHistories else { return 0 }
            return await usbHistories.save(ids.compactMap { self.archivedHistoryIndex[$0] })
        }
        historyImports = Task { @MainActor in _ = await save.value }
        return save
    }
}
