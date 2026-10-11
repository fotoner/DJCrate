import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 재생 기록(#43, 기능 조각): rekordbox Histories처럼 연 › 월 › 기록 트리에 rekordbox 기록과 USB에서 보존한 기기 기록을 섞는다.
/// 사이드바 기록 칸·목록 아래 막대·사이드바 메뉴·반영(`pendingHistoryImports`·`recordWrittenHistories`)이 쓴다.
/// USB 기록은 USB를 읽을 때(`UsbStore.onLibraryEvaluated`) 유스케이스 `ArchiveUsbHistories`가 DJCrate 데이터 폴더(`usb-histories/`)에 보존하고
/// (USB에는 쓰지 않는다), 다른 초안처럼 "rekordbox 쓰기 대기"에 올려(`pendingHistories`) rekordbox에 쓰기(⇧⌘E) 때 반영 세션이
/// rekordbox Histories에 넣는다. 보존의 줄 세우기·채택·실패 알림은 그 유스케이스가 정하고, 이 조각은 결과를 화면 상태에 넣는다(#251).
/// 핵심 `LibraryStore`의 `history` 속성이다. 곡·사이드바·알림·쓰기 잠금·되돌리기는 핵심 것을 읽는다(`library`).
@MainActor
@Observable
final class HistoryStore {
    /// 컬렉션에 없는 보존 기록 곡의 줄 ID 접두사. `usb:`로 시작해 `isUsb`가 참이라 편집·쓰기·끌기가 막히고, 덱에는 짝이 없다고 알린다(#255)
    static let archivedTrackIDPrefix = UsbLibraryRows.idPrefix + "history:"

    /// 이 조각을 든 핵심(곡·사이드바·알림). 핵심이 조각을 들고 있어 약하게 잡지 않는다
    @ObservationIgnored private unowned let library: LibraryStore
    /// USB 기록 보존(유스케이스). 보존 파일을 붙이지 않았으면(시험 기본) USB 기록을 보존·가져오지 않는다
    @ObservationIgnored private let archive: ArchiveUsbHistories

    init(library: LibraryStore, archive: ArchiveUsbHistories) {
        self.library = library
        self.archive = archive
        archive.screen = UsbHistoryScreen(
            state: { [weak self] in self?.archiveState ?? UsbHistoryState() },
            apply: { [weak self] in self?.apply($0) })
    }

    var histories: [RekordboxHistory] = [] {
        didSet {
            guard histories != oldValue else { return }
            historyIndex = Dictionary(histories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            refreshHistoryTree()
        }
    }
    private(set) var historyIndex: [String: RekordboxHistory] = [:]
    /// USB에서 가져와 DJCrate에 보존한 기기 재생 기록(#43). rekordbox 라이브러리에는 없다
    var archivedHistories: [ArchivedHistory] = [] {
        didSet {
            guard archivedHistories != oldValue else { return }
            archivedHistoryIndex = Dictionary(archivedHistories.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            refreshHistoryTree()
        }
    }
    private(set) var archivedHistoryIndex: [String: ArchivedHistory] = [:]
    /// 현재 채택한 스냅샷의 키. USB 분리 뒤에도 보존본의 짝·쓴 표시를 검증한다.
    @ObservationIgnored var historyLocalKeys: LocalLibraryKeys?
    /// 사이드바 재생 기록 트리(연 › 월 › 기록). 두 기록 중 하나가 바뀔 때만 다시 만들어, 사이드바 구역 본문은 이 값만 읽는다(#141)
    private(set) var historyTree = HistoryTree()
    /// rekordbox도 가져온 같은 USB 기록이라 트리에서 숨긴 보존 기록(파일은 그대로)
    private(set) var shadowedArchiveIDs: Set<String> = []
    /// 펼친 재생 기록 연·월 폴더(`HistoryTree.yearID`·`monthID`). 읽은 뒤 처음 펼치기·가져온 기록 펼치기·기록 고르기가 흐름에서 바꾸므로
    /// 사이드바 화면 모델이 아니라 이 조각에 둔다
    var expandedHistoryFolders: Set<String> = []
    /// 가장 최근 연·월을 한 번 펼쳤는지(그 뒤 접고 펼친 것은 사용자 몫)
    @ObservationIgnored var historyFoldersSeeded = false
    /// rekordbox 쓰기 대기에 오른 보존 기록(#43, `HistoryWriteQueue.pending`, 가져온 차례). 라이브러리를 읽은 뒤에만 고르고
    /// (rekordbox에 이미 쓴 기록인지 모르는 동안 올리지 않게), 기록·보존본이 바뀔 때만 다시 계산한다(#141).
    /// 사이드바 배지·기록 줄 표시·쓰기 대기 바·rekordbox에 쓰기(⇧⌘E)가 이것을 쓴다
    private(set) var pendingHistories: [ArchivedHistory] = []
    /// 쓰기 대기 기록 ID(사이드바 기록 줄이 대기 표시를 고른다)
    private(set) var pendingHistoryIDs: Set<String> = []
    /// rekordbox에 썼지만 아직 새 스냅샷으로 읽지 못한 기록의 rekordbox ID. 다시 읽을 때까지 rekordbox에 있는 것으로 본다
    /// (쓴 뒤 다시 읽지 못해도 같은 기록을 또 쓰지 않게). 라이브러리를 새로 읽으면 비운다
    @ObservationIgnored var historyIDsAwaitingReload: Set<String> = []
    /// rekordbox 재생 기록 쓰기 관문. 조립 지점이 사본 재현으로 확인한 `RekordboxWriter.writesHistories`를 넣고 시험은 따로 바꾼다.
    /// 닫혀 있으면 보존·보기만 하고 쓰기 대기에 올리지 않는다(다른 초안을 쓸 때마다 막힘을 묻지 않게)
    @ObservationIgnored var writesHistories = false {
        didSet { if writesHistories != oldValue { refreshHistoryTree() } }
    }

    /// 트리·숨김·쓰기 대기를 다시 정한다(`UsbHistoryRules.view`). 같으면 건드리지 않는다(사이드바·배지가 다시 계산되지 않게)
    func refreshHistoryTree() {
        let rows = library.rowsByID
        let view = UsbHistoryRules.view(histories: histories, archived: archivedHistories, local: historyLocalKeys,
                                        inCollection: { rows[$0] != nil }, queueOpen: library.snapshotURL != nil && writesHistories,
                                        awaitingReload: historyIDsAwaitingReload, calendar: .current)
        if view.shadowed != shadowedArchiveIDs { shadowedArchiveIDs = view.shadowed }
        if view.tree != historyTree { historyTree = view.tree }
        guard view.pending != pendingHistories else { return }
        pendingHistories = view.pending
        pendingHistoryIDs = Set(view.pending.map(\.id))
    }

    /// 새 스냅샷의 rekordbox 기록과 짝짓기 키를 채택한다. 새 스냅샷이 rekordbox 기록의 원본이라 쓴 뒤 기다리던 기록 ID를 비우고
    /// 쓰기 대기를 다시 고른다(복원으로 사라진 기록은 다시 대기, #43)
    func setHistories(_ histories: [RekordboxHistory], localKeys: LocalLibraryKeys?) {
        historyLocalKeys = localKeys
        self.histories = histories
        historyIDsAwaitingReload = []
        rematchArchivedHistories()
        refreshHistoryTree()
    }

    func archivedHistory(_ id: String) -> ArchivedHistory? { archivedHistoryIndex[id] }

    /// USB를 뺀 뒤에도 채택한 스냅샷의 원본 키로 보존본을 다시 검증한다.
    func rematchArchivedHistories() { archive.rematch() }

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
        if let history = historyIndex[id] { return library.count(history: history) }
        return archivedHistoryIndex[id].map { count(archived: $0) } ?? 0
    }

    /// '스트리밍 곡 숨기기'는 rekordbox 기록과 같게 컬렉션 곡에만 건다
    func count(archived history: ArchivedHistory) -> Int {
        let rowsByID = library.rowsByID
        return history.entries.reduce(0) { count, entry in
            guard let row = entry.contentID.flatMap({ rowsByID[$0] }) else { return count + 1 }
            return StreamingVisibility.hides(row.track, hidingStreaming: library.hideStreaming) ? count : count + 1
        }
    }

    /// 보존 기록의 줄(재생 순서, 반복 재생 포함). 컬렉션 짝이 있으면 그 곡 줄, 없으면 보존한 제목·아티스트·경로로 만든 읽기 전용 줄
    func archivedHistoryRows(_ id: String) -> [TrackRow] {
        guard let history = archivedHistoryIndex[id] else { return [] }
        let rowsByID = library.rowsByID
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

    // MARK: - USB 기록 보존(유스케이스에 줄을 세운다)

    /// 읽지 못해 그 자리에 남은 보존 파일(유스케이스가 든다. 해소될 때까지 새 ID 보존을 막는다)
    var unreadableHistoryFiles: [String] { archive.unreadable }

    /// 보존한 기록을 읽는다(조립 지점이 보존 파일을 붙인 뒤). 읽지 못한 파일은 유스케이스가 damaged-drafts로 옮기고 알린다
    func loadArchivedHistories(preservingCurrent: Bool = false) async {
        await archive.reload(preservingCurrent: preservingCurrent)
    }

    /// 보존한 기록 읽기를 보존 줄 맨 앞에 세운다(USB를 읽으면 그와 견줘 새 기록만 보존한다)
    func startLoadingArchivedHistories() { archive.startLoading() }

    /// USB의 새 기기 재생 기록을 보존하고 트리에 더한다(USB를 읽었거나 로컬 짝을 다시 계산한 뒤, `UsbStore.onLibraryEvaluated`)
    func importUsbHistories(volume: UsbVolumeInfo, library: UsbLibrary, matches: [Int: String]) {
        archive.startImport(volumeKey: volume.usbKey, volumeName: volume.name, library: library, matches: matches, calendar: .current)
    }

    /// 줄 선 USB 기록 보존이 모두 끝날 때까지(시험·자가 테스트)
    func waitForHistoryImports() async { await archive.waitUntilIdle() }

    /// 고친 보존 기록을 화면 상태에 바로 넣고, 파일 저장은 보존 줄에 세운다(`ArchiveUsbHistories.update`).
    /// - Returns: 저장하지 못한 기록 수를 돌려주는 작업
    @discardableResult
    func updateArchivedHistories(_ updated: [ArchivedHistory]) -> Task<Int, Never> { archive.update(updated) }

    /// 유스케이스가 읽는 지금 값
    private var archiveState: UsbHistoryState {
        UsbHistoryState(archived: archivedHistories, local: historyLocalKeys, shadowed: shadowedArchiveIDs, pending: pendingHistoryIDs)
    }

    /// 유스케이스가 정한 것을 화면 상태에 넣는다(펼치기·보던 기록 목록 다시 만들기·알림)
    private func apply(_ change: UsbHistoryChange) {
        switch change {
        case let .archived(histories):
            archivedHistories = histories
        case let .awaitingReload(ids):
            historyIDsAwaitingReload.formUnion(ids)
            refreshHistoryTree()
        case let .loaded(notice):
            if library.snapshotURL != nil { seedHistoryFolders() }
            if case .history = library.sidebar { library.refreshBase() }
            if let notice { show(notice) }
        case let .imported(shown, saved, notice):
            if library.snapshotURL != nil { seedHistoryFolders() }
            for id in shown { revealHistory(id) }
            // 닫을 때까지 남는 경고·동작 단추가 있는 알림(USB 꺼내기 등)은 덮지 않는다
            if let notice, canReplaceToast { show(notice) }
            if case let .history(id) = library.sidebar, saved.contains(id) { library.refreshBase() }
        case let .notice(notice):
            show(notice)
        }
    }

    private func show(_ notice: UsbHistoryNotice) {
        library.toast = .notice(notice.title, notice.detail, kind: notice.kind == .success ? .success : .warning, isUsb: true)
    }

    /// 지금 알림을 기록 가져오기 알림으로 바꿔도 되는지: 없거나, 곧 사라지는 성공 알림(되돌리기·동작 단추 없음)일 때만
    private var canReplaceToast: Bool {
        guard let toast = library.toast else { return true }
        return toast.kind == .success && toast.undoBackup == nil && toast.action == nil
    }

    // MARK: - rekordbox 쓰기 대기

    /// 쓰기 대기 재생 기록이 있는지(곡 초안이 없어도 rekordbox에 쓸 것이 있다)
    var hasHistoryDrafts: Bool { !pendingHistories.isEmpty }

    /// 쓰기 대기 기록을 rekordbox 쓰기 입력으로(가져온 차례, `UsbHistoryRules.imports`). 반영 세션이 읽는다
    var pendingHistoryImports: [HistoryImport] {
        let rows = library.rowsByID
        return UsbHistoryRules.imports(pendingHistories, local: historyLocalKeys, inCollection: { rows[$0] != nil })
    }

    /// 보존 기록을 rekordbox 쓰기 대기에서 빼거나 다시 넣는다(보존본은 그대로). 편집 › 실행 취소로 되돌린다.
    /// 화면 상태는 바로 바꾸고 파일 저장은 보존 줄에 세운다. 저장하지 못하면 유스케이스가 알린다(다시 켜면 옛 상태로 읽힌다)
    func setHistoriesExcluded(_ ids: [String], excluded: Bool) {
        guard library.writeLockPolicy.allowsLibraryInteraction else { return }
        let changedIDs = archive.exclude(ids, excluded: excluded)
        guard !changedIDs.isEmpty, let undoManager = library.undoManager else { return }
        // 한 이벤트 안에서 여러 번 바꿔도 각각 한 단계로 남긴다(태그·덱 초안과 같다)
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        // 되돌리기 대상은 핵심이다(쓰기 잠금이 핵심 대상으로 되돌리기를 지운다)
        undoManager.registerUndo(withTarget: library) { target in
            guard !target.isWritingRekordbox else { return }
            target.history.setHistoriesExcluded(changedIDs, excluded: !excluded)
        }
        undoManager.setActionName(excluded ? String(ui: "rekordbox 쓰기 대기에서 빼기") : String(ui: "rekordbox 쓰기 대기에 넣기"))
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// rekordbox에 쓴(또는 최신 대상에 이미 있던) 보존 기록에 rekordbox 기록 ID를 남긴다(반영 세션이 쓴 뒤 다시 읽기 전에 부른다).
    /// 다시 읽을 때까지는 쓴 ID를 rekordbox에 있는 것으로 봐(`historyIDsAwaitingReload`) 다시 읽지 못해도 같은 기록을 또 쓰지 않는다.
    /// - Returns: 표시를 저장하지 못했을 때 알릴 문장(rekordbox 쓰기는 끝났다)
    func recordWrittenHistories(_ outcomes: [RekordboxHistoryOutcome]) async -> String? {
        await archive.markWritten(outcomes)
    }
}
