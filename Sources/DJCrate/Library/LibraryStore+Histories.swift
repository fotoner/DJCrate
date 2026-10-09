import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 재생 기록(#43): rekordbox Histories처럼 연 › 월 › 기록 트리에 rekordbox 기록과 USB에서 보존한 기기 기록을 섞는다.
/// USB 기록은 USB를 읽을 때(`UsbStore.onLibraryEvaluated`) DJCrate 데이터 폴더(`usb-histories/`)에 보존하고(USB에는 쓰지 않는다),
/// 다른 초안처럼 "rekordbox 쓰기 대기"에 올려(`pendingHistories`) rekordbox에 쓰기(⇧⌘E) 때 rekordbox Histories에 넣는다.
/// rekordbox 쓰기 관문(`RekordboxWriter.writesHistories`)이 닫혀 있으면 미리 보기에서 막힘으로 보인다.
extension LibraryStore {
    /// 컬렉션에 없는 보존 기록 곡의 줄 ID 접두사. `usb:`로 시작해 `isUsb`가 참이라 편집·덱·쓰기·끌기가 막힌다
    static let archivedTrackIDPrefix = UsbLibraryRows.idPrefix + "history:"

    func archivedHistory(_ id: String) -> ArchivedHistory? { archivedHistoryIndex[id] }

    /// 쓴 ID는 라이브러리별 값이다. 옛 파일은 현재 원본 곡 키·이름·전체 순서까지 같아야 그 표시를 믿는다.
    var archivesWithValidatedWrittenMarkers: [ArchivedHistory] {
        return archivedHistories.map { history in
            guard history.rekordboxHistoryID != nil, !hasValidWrittenMarker(history) else { return history }
            var history = history
            history.rekordboxHistoryID = nil
            return history
        }
    }

    /// 검증하지 못한 쓴 ID는 이름으로 다른 ID를 추측하는 데도 쓰지 않고 보존본을 계속 보인다.
    var archivesForDuplicateMatching: [ArchivedHistory] {
        guard historyLocalKeys != nil else { return [] }
        return archivedHistories.filter { $0.rekordboxHistoryID == nil || hasValidWrittenMarker($0) }
    }

    private func hasValidWrittenMarker(_ history: ArchivedHistory) -> Bool {
        guard let local = historyLocalKeys, let writtenID = history.rekordboxHistoryID else { return false }
        if let recordedLibrary = history.rekordboxLibraryID { return recordedLibrary == String(local.localDBID) }
        guard let record = historyIndex[writtenID] else { return false }
        return !history.entries.isEmpty && history.entries.allSatisfy { entry in
            entry.contentID.flatMap { rowsByID[$0] } != nil
        } && rematched([history]).first?.entries == history.entries && history.name == record.name
            && history.matchedContentIDs == record.entries.sorted { $0.trackNumber < $1.trackNumber }.map(\.contentID)
    }

    private func rematched(_ histories: [ArchivedHistory]) -> [ArchivedHistory] {
        UsbHistoryMatches.rematch(histories, localDBID: historyLocalKeys?.localDBID, local: historyLocalKeys?.tracks ?? [],
                                  masterDBIDs: historyLocalKeys?.masterDBIDs ?? [:])
    }

    /// USB를 뺀 뒤에도 채택한 스냅샷의 원본 키로 보존본을 다시 검증한다.
    func rematchArchivedHistories() {
        let changed = zip(archivedHistories, rematched(archivedHistories)).compactMap { old, new in old == new ? nil : new }
        guard !changed.isEmpty else { return }
        let save = updateArchivedHistories(changed)
        Task { @MainActor [weak self] in
            guard await save.value > 0 else { return }
            self?.toast = .notice(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                                  String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 시도하세요"), isUsb: true)
        }
    }

    // MARK: - 트리

    /// 트리 줄 이름: 기록 이름, 없으면 날짜(앞 10자), 그것도 없으면 "날짜 없음"
    static func historyRowName(_ history: RekordboxHistory) -> String {
        if !history.name.isEmpty { return history.name }
        if let date = history.dateCreated, !date.isEmpty { return String(date.prefix(10)) }
        return String(ui: "날짜 없음")
    }

    /// 두 기록을 한 트리로. 보존 기록의 연·월·정렬 키는 가져온 시각(이 Mac의 달력)이다
    static func makeHistoryTree(histories: [RekordboxHistory], archived: [ArchivedHistory], calendar: Calendar = .current) -> HistoryTree {
        let rekordbox = histories.map { history -> HistoryTree.Item in
            let yearMonth = HistoryTree.yearMonth(folderNames: history.folderNames, dateCreated: history.dateCreated)
            return HistoryTree.Item(id: history.id, name: Self.historyRowName(history), year: yearMonth?.year, month: yearMonth?.month,
                                    sortKey: history.dateCreated ?? "", sequence: history.seq)
        }
        let usb = archived.map { history -> HistoryTree.Item in
            let parts = calendar.dateComponents([.year, .month], from: history.importedAt)
            return HistoryTree.Item(id: history.id, name: history.name, year: parts.year, month: parts.month,
                                    sortKey: HistoryTree.sortKey(history.importedAt, calendar: calendar), sequence: history.sequence)
        }
        return HistoryTree.build(rekordbox + usb)
    }

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

    /// 보존한 기록을 읽는다(앱 시작 때). 읽지 못한 파일은 `UsbHistoryStore`가 damaged-drafts로 옮기고 여기서 알린다
    func loadArchivedHistories(preservingCurrent: Bool = false) {
        guard let store = usbHistoryStore else { return }
        let loaded = store.load()
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

    /// USB의 새 기기 재생 기록을 보존하고 트리에 더한다(USB를 읽었거나 로컬 짝을 다시 계산한 뒤, `UsbStore.onLibraryEvaluated`).
    /// 같은 USB 기록은 다시 보존하지 않고, 로컬 짝은 원본 키로 다시 검증한다(`UsbHistoryMatches`).
    /// 한 줄로 세워 차례로 한다: 계획은 앞선 보존이 끝난 뒤의 상태로 세우고, 파일 쓰기(fsync)는 메인 액터 밖에서 한다
    func importUsbHistories(volume: UsbVolumeInfo, library: UsbLibrary, matches: [Int: String]) {
        guard usbHistoryStore != nil else { return }
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
        guard let store = usbHistoryStore else { return }
        if !unreadableHistoryFiles.isEmpty {
            loadArchivedHistories(preservingCurrent: true)
            guard unreadableHistoryFiles.isEmpty else { return }
        }
        let candidates = UsbHistoryCandidates.make(library: library, volumeKey: volume.usbKey, volumeName: volume.name, matches: matches)
        guard !candidates.isEmpty else { return }
        // 보존본끼리 이름을 매긴다. rekordbox 이름을 피하면 같은 이름으로 중복을 검증할 수 없다.
        // rekordbox에 쓸 때의 이름 충돌은 writer가 그 DB 안에서 해결한다.
        let plan = UsbHistoryImport.plan(existing: archivedHistories, candidates: candidates, reservedNames: [],
                                         now: historyClock(), calendar: .current, makeID: { UUID().uuidString })
        guard !plan.isEmpty else { return }
        // 기록마다 따로 저장해 저장된 것만 상태에 넣는다. 한꺼번에 저장하다 중간에 실패하면 디스크에는 남았는데 상태에 없는 기록이
        // 생기고, 다음 시도가 새 ID로 또 저장해 다시 켤 때 같은 기록이 둘이 된다
        let pending = rematched(plan.updated + plan.added)
        let (saved, failed) = await Task.detached(priority: .utility) { () -> ([ArchivedHistory], Bool) in
            var done: [ArchivedHistory] = []
            for history in pending {
                let result = Self.saveArchivedHistory(history, store: store)
                if result.accepted { done.append(history) }
                if result.failed { return (done, true) }
            }
            return (done, false)
        }.value
        if failed {
            toast = .notice(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                            String(ui: "DJCrate 데이터 폴더의 usb-histories를 확인한 뒤 USB를 다시 연결하세요"), isUsb: true)
        }
        guard !saved.isEmpty else { return }
        let savedIDs = Set(saved.map(\.id))
        var merged = archivedHistories
        var positions = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for history in saved {
            if let index = positions[history.id] {
                // 계획을 세운 뒤 바뀐 쓰기 상태(쓰기 대기에서 빼기·rekordbox에 쓴 표시)는 지금 값을 남긴다.
                // 그 변경의 파일 저장은 이 보존 뒤에 줄을 서 있어 지금 값으로 다시 쓴다(`updateArchivedHistories`)
                var updated = history
                updated.rekordboxHistoryID = merged[index].rekordboxHistoryID
                updated.rekordboxLibraryID = merged[index].rekordboxLibraryID
                updated.excludedFromRekordbox = merged[index].excludedFromRekordbox
                merged[index] = updated
            } else {
                positions[history.id] = merged.count
                merged.append(history)
            }
        }
        // 파일 쓰기를 기다리는 동안 채택한 새 스냅샷에도 맞춘다(그 저장은 이 보존 뒤에 줄을 선다).
        archivedHistories = merged
        rematchArchivedHistories()
        // rekordbox도 가져온 기록(숨김)은 새로 가져왔다고 알리지 않는다
        let shown = plan.added.filter { savedIDs.contains($0.id) && !shadowedArchiveIDs.contains($0.id) }
        if snapshotURL != nil { seedHistoryFolders() }
        for history in shown { revealHistory(history.id) }
        // 일부만 보존했으면 경고를 남긴다. 닫을 때까지 남는 경고·동작 단추가 있는 알림(USB 꺼내기 등)도 덮지 않는다
        if !shown.isEmpty, !failed, canReplaceToast {
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

    /// 쓰기 대기 기록을 rekordbox 쓰기 입력으로(가져온 차례). 컬렉션 짝이 있는 곡만 재생 순서대로 넘긴다
    /// (반복 재생 포함, 컬렉션에 없는 곡은 rekordbox처럼 뺀다). 만든 시각은 가져온 시각이다
    var pendingHistoryImports: [HistoryImport] {
        pendingHistories.map { history in
            let ids = history.entries.compactMap { entry in entry.contentID.flatMap { rowsByID[$0] == nil ? nil : $0 } }
            let identities = history.entries.compactMap { entry -> HistoryImport.TrackIdentity? in
                guard let id = entry.contentID, rowsByID[id] != nil else { return nil }
                return .init(contentID: id, masterDbId: entry.masterDbId, masterContentId: entry.masterContentId, fileName: entry.fileName)
            }
            return HistoryImport(id: history.id, name: history.name, dateCreated: history.importedAt, contentIDs: ids,
                                 skippedBeforeMatching: history.entries.count - ids.count,
                                 expectedLibraryID: historyLocalKeys.map { String($0.localDBID) }, existingHistoryID: history.rekordboxHistoryID,
                                 trackIdentities: identities)
        }
    }

    /// 보존 기록을 rekordbox 쓰기 대기에서 빼거나 다시 넣는다(보존본은 그대로). 편집 › 실행 취소로 되돌린다.
    /// 화면 상태는 바로 바꾸고 파일 저장은 보존 줄에 세운다. 저장하지 못하면 알린다(다시 켜면 옛 상태로 읽힌다)
    func setHistoriesExcluded(_ ids: [String], excluded: Bool) {
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        let changed = ids.compactMap { archivedHistoryIndex[$0] }.filter { $0.excludedFromRekordbox != excluded }.map { history -> ArchivedHistory in
            var history = history
            history.excludedFromRekordbox = excluded
            return history
        }
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
            self?.toast = .notice(String(ui: "재생 기록의 쓰기 대기 상태를 저장하지 못했습니다"),
                                  String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 바꾸세요"), isUsb: true)
        }
    }

    /// rekordbox에 쓴 보존 기록에 rekordbox 기록 ID를 남긴다(쓴 뒤 다시 읽기 전에 부른다).
    /// 다시 읽을 때까지는 쓴 ID를 rekordbox에 있는 것으로 봐(`historyIDsAwaitingReload`) 다시 읽지 못해도 같은 기록을 또 쓰지 않는다.
    /// 그 기록이 나중에 rekordbox에서 사라지면(쓰기 전으로 복원 등) `HistoryWriteQueue`가 다시 쓰기 대기로 돌린다.
    /// - Returns: 표시를 저장하지 못했을 때 알릴 문장(rekordbox 쓰기는 끝났다)
    func recordWrittenHistories(_ outcomes: [RekordboxWriter.HistoryOutcome]) async -> String? {
        var written: [String: String] = [:]
        for outcome in outcomes where outcome.status == .written || outcome.status == .unchanged {
            if let historyID = outcome.historyID { written[outcome.id] = historyID }
        }
        guard !written.isEmpty else { return nil }
        historyIDsAwaitingReload.formUnion(written.values)
        refreshPendingHistories()
        let changed = archivedHistories.compactMap { history -> ArchivedHistory? in
            guard let historyID = written[history.id] else { return nil }
            var history = history
            history.rekordboxHistoryID = historyID
            history.rekordboxLibraryID = historyLocalKeys.map { String($0.localDBID) }
            return history
        }
        let failed = await updateArchivedHistories(changed).value
        return failed == 0 ? nil : Self.historyMarkFailureText(failed)
    }

    static func historyMarkFailureText(_ count: Int) -> String {
        String(ui: "rekordbox에는 썼지만 보존한 재생 기록 \(count)건에 쓴 표시를 저장하지 못했으니, 다시 켠 뒤 그 기록이 쓰기 대기에 오르면 사이드바에서 쓰기 대기에서 빼세요.")
    }

    /// 고친 보존 기록을 화면 상태에 바로 넣고, 파일 저장은 보존 줄(`historyImports`)에 세운다.
    /// 저장은 줄 차례가 왔을 때의 보존본(그사이 가져오기가 짝을 채웠거나 다시 바꾼 것까지)을 메인 액터 밖에서 쓴다.
    /// - Returns: 저장하지 못한 기록 수를 돌려주는 작업
    @discardableResult
    func updateArchivedHistories(_ updated: [ArchivedHistory]) -> Task<Int, Never> {
        if !updated.isEmpty {
            var merged = archivedHistories
            let positions = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for history in updated {
                if let index = positions[history.id] { merged[index] = history }
            }
            archivedHistories = merged
        }
        let ids = updated.map(\.id)
        let previous = historyImports
        let save = Task { @MainActor [weak self] () -> Int in
            await previous?.value
            guard let self else { return 0 }
            return await self.saveArchivedHistories(ids)
        }
        historyImports = Task { @MainActor in _ = await save.value }
        return save
    }

    /// 지금 보존본을 기록마다 따로 내구 쓰기한다(메인 액터 밖). 저장하지 못한 기록 수
    private func saveArchivedHistories(_ ids: [String]) async -> Int {
        guard let store = usbHistoryStore else { return 0 }
        let histories = ids.compactMap { archivedHistoryIndex[$0] }
        guard !histories.isEmpty else { return 0 }
        return await Task.detached(priority: .utility) { () -> Int in
            var failed = 0
            for history in histories {
                // 화면에는 이미 이 상태가 있다. 파일 일치 확인을 해도 fsync 실패 경고는 남기고 상태를 되돌리지 않는다.
                if Self.saveArchivedHistory(history, store: store).failed { failed += 1 }
            }
            return failed
        }.value
    }

    nonisolated private static func saveArchivedHistory(_ history: ArchivedHistory, store: UsbHistoryStore) -> (accepted: Bool, failed: Bool) {
        do {
            try store.save([history])
            return (true, false)
        } catch {
            AppErrorMessage.log(error)
            // rename 뒤 폴더 fsync만 실패했다면 같은 ID의 파일을 채택해 다음 가져오기가 새 ID를 만들지 않게 한다.
            return (store.containsExact(history), true)
        }
    }
}
