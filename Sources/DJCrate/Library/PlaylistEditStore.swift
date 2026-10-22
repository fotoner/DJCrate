import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 재생 목록 초안(#39·#40, 기능 조각 #251): 곡 넣기·빼기·순서, 목록·폴더 만들기·이름·지우기·옮기기.
/// rekordbox에는 바로 쓰지 않고 초안(`PlaylistDraft`)으로 쌓아, 반영(⇧⌘E) 때 큐·그리드 초안과 같은 확인 창·백업·되돌리기로 쓴다.
/// 사이드바·곡 목록은 rekordbox 상태에 초안을 얹은 모양을 보여 준다. 사이드바 트리·재생 목록 명령·고르기 시트·반영·복구 시트·USB 시트가 쓴다.
/// 최근 목록·넣기 전 나누기·기록 원본 고르기의 규칙은 유스케이스 `EditPlaylists`가 맡는다. 사이드바 펼침·이름 바꾸기는 `PlaylistSidebarModel`이 든다.
/// 핵심 `LibraryStore`의 `playlists` 속성이다. 곡·사이드바·설정·쓰기 잠금·되돌리기는 핵심 것을 읽는다(`library`).
@MainActor
@Observable
final class PlaylistEditStore {
    static let recentPlaylistsKey = "library.recentPlaylists"
    static var playlistSaveFailureText: String { ReflectionSession.playlistSaveFailureText }

    /// 이 조각을 든 핵심(곡·사이드바·설정·되돌리기). 핵심이 조각을 들고 있어 약하게 잡지 않는다.
    /// 연결 기록·복구·인텔리전트 목록 확장(다른 파일)도 읽으므로 `private`으로 두지 않는다
    @ObservationIgnored unowned let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    /// 사이드바 재생 목록 트리(rekordbox 상태에 재생 목록 초안을 얹은 모양)
    var playlistTree: [PlaylistOutlineNode] = []
    var playlistIndex: [String: PlaylistOutlineNode] = [:] { didSet { playlistCount = playlistIndex.values.filter { !$0.isFolder }.count } }
    /// 폴더를 뺀 rekordbox 플레이리스트 수(사이드바 제목)
    private(set) var playlistCount = 0
    /// 사이드바 재생 목록 곡 수(`recountPlaylists`)
    var playlistCounts: [String: Int] = [:]
    /// 스냅샷에서 읽은 rekordbox 재생 목록(초안을 얹기 전)
    var rekordboxPlaylists = PlaylistLayout()
    /// 재생 목록 초안(반영 때 쓴다). 바꿀 때는 `setPlaylistDraft`로(저장·화면·되돌리기).
    var playlistDraft = PlaylistDraft() { didSet { playlistDraftRevision &+= 1 } }
    /// 초안이 바뀔 때마다 오른다. 바깥 변경 확인은 읽는 사이 앱이 초안을 바꿨으면 결과를 버린다
    @ObservationIgnored private(set) var playlistDraftRevision: UInt64 = 0
    /// 초안을 얹은 모양과 편집마다 막힌 이유
    var playlistProjection = PlaylistDraft().project(onto: PlaylistLayout())
    /// 초안을 얹은 모양을 다시 만든 뒤(LINK가 켜 둔 서버의 재생 목록을 바꾼다)
    @ObservationIgnored var onProjectionChanged: (() -> Void)?
    /// 목록마다 초안으로 넣은 곡(ContentID). 목록을 볼 때 초안 표식을 붙인다.
    var playlistAddedTracks: [String: Set<String>] = [:]
    /// 최근에 곡을 넣은 목록(최근 것부터). 오른쪽 클릭 메뉴 맨 위·'마지막에 쓴 목록에 넣기'.
    var recentPlaylistIDs: [String] = []
    /// 재생 목록 편집 결과 안내(넣은 곡 수·이미 든 곡·막힌 이유)
    var playlistMessage: AppMessage? {
        didSet { if let playlistMessage { library.feedback.announce(playlistMessage) } }
    }
    /// 재생 목록 초안 저장에 실패해 메모리 초안이 디스크보다 최신이다(쓰기 전에 다시 저장한다, #174).
    var playlistDraftUnsaved = false
    /// 재생 목록 연결 기록(컬렉션에 들어간 뒤 만들 목록 연결, `PlaylistEditStore+Imports`)
    var playlistImports = PlaylistImports()
    var playlistImportsLoadFailed = false
    /// 목록 ID → 읽은 조건 칸(스냅샷을 읽을 때 채운다, `PlaylistEditStore+Smart`)
    var smartPlaylistSources: [String: SmartPlaylistSource] = [:]
    /// 켜 있을 때 목록 ID → 계산 결과(계산하지 못한 조건이 있으면 곡 없이 이유만)
    var smartPlaylistResults: [String: SmartPlaylistResult] = [:]
    /// '재생 목록에 넣기…' 시트의 화면 모델. 열 때마다 새로 만든다(찾는 말·고른 줄을 처음부터). 닫으면 nil이다
    var playlistPicker: PlaylistPickerModel?
    /// 복원한 뒤 다시 읽지 못해 아직 쌓지 못한 재생 목록 편집(옛 목록 상태에 쌓지 않게 다음 읽기 뒤에 쌓는다)
    @ObservationIgnored var playlistEditsAwaitingReload: [PlaylistEdit] = []
    /// 목록을 만든 뒤 알린다(만든 목록 ID와 조상 폴더 ID). 사이드바 화면 모델(`PlaylistSidebarModel`)이 붙여 조상만 펼치고 이름을 고치게 한다
    @ObservationIgnored var onCreate: ((_ id: String, _ ancestors: [String]) -> Void)?

    var hasPlaylistDrafts: Bool { !playlistDraft.isEmpty }

    /// 쓸 수 없는 초안 편집 수(rekordbox에서 바뀐 목록 등)
    var blockedPlaylistEditCount: Int { playlistProjection.blocked.compactMap { $0 }.count }

    /// 초안을 얹은 목록(없으면 nil). 사이드바·메뉴는 이 모양을 본다.
    func playlistItem(_ id: String) -> PlaylistLayout.Item? { playlistProjection.layout.item(id) }

    /// 곡을 넣고 뺄 수 있는 목록(폴더·인텔리전트 목록이 아님)
    func canEditTracks(of id: String) -> Bool { playlistItem(id)?.holdsTracks == true }

    /// 지금 보고 있는 목록(곡을 빼거나 순서를 바꿀 수 있을 때만)
    var editablePlaylistID: String? {
        guard case let .playlist(id) = library.sidebar, canEditTracks(of: id) else { return nil }
        return id
    }

    /// 끌어서 순서를 바꿀 수 있는지: 목록 순서(# 순)로 보고, 검색으로 거르지 않을 때
    /// '스트리밍 곡 숨기기'로 줄을 뺀 목록도 막는다: 숨은 줄이 끼어 있으면 놓을 자리가 모호해(검색으로 거른 목록과 같다) 숨기기를 끄고 옮긴다.
    var canReorderDisplayedTracks: Bool {
        editablePlaylistID != nil && library.sortOrder.isEmpty && library.search.trimmingCharacters(in: .whitespaces).isEmpty
            && library.streamingHiddenInView == 0
    }

    /// 곡을 넣을 수 있는 목록을 트리 순서로(경로: 위 폴더 이름들)
    var trackPlaylists: [(item: PlaylistLayout.Item, path: [String])] {
        let layout = playlistProjection.layout
        return layout.outline.filter(\.holdsTracks).map { ($0, layout.ancestors(of: $0.id).map(\.name)) }
    }

    /// 최근에 곡을 넣은 목록(지금 넣을 수 있는 것만)
    var recentPlaylists: [PlaylistLayout.Item] {
        recentPlaylistIDs.compactMap { playlistItem($0) }.filter(\.holdsTracks)
    }

    /// '마지막에 쓴 목록에 넣기'의 대상
    var lastUsedPlaylist: PlaylistLayout.Item? { recentPlaylists.first }

    /// 새 목록·폴더를 만들 부모: 사이드바에서 고른 것이 폴더면 그 안, 목록이면 그 부모, 아니면 맨 위(rekordbox처럼 부모 맨 위에 생긴다).
    var newPlaylistParent: String {
        guard case let .playlist(id) = library.sidebar, let item = playlistItem(id) else { return PlaylistLayout.root }
        return item.isFolder && !item.isSmart ? item.id : item.parentID
    }

    // MARK: - 화면 갱신

    /// 초안을 얹은 모양으로 사이드바 트리·곡 수·목록을 다시 만든다.
    func refreshPlaylists(refreshList: Bool = true) {
        let projection = playlistDraft.project(onto: rekordboxPlaylists, contentIDs: Set(library.rowsByID.keys))
        playlistProjection = projection
        defer { onProjectionChanged?() }
        playlistTree = PlaylistOutlineNode.tree(projection)
        fillSmartPlaylists()
        var index: [String: PlaylistOutlineNode] = [:]
        func walk(_ nodes: [PlaylistOutlineNode]) { for node in nodes { index[node.id] = node; walk(node.children ?? []) } }
        walk(playlistTree)
        playlistIndex = index
        recountPlaylists()
        // 초안으로 넣은 곡: 얹은 모양에 rekordbox보다 많이 든 곡
        var added: [String: Set<String>] = [:]
        for id in projection.changed {
            guard let item = projection.layout.item(id), item.holdsTracks else { continue }
            var before: [String: Int] = [:]
            for contentID in rekordboxPlaylists.item(id)?.trackIDs ?? [] { before[contentID, default: 0] += 1 }
            var now: [String: Int] = [:]
            for contentID in item.trackIDs { now[contentID, default: 0] += 1 }
            let extra = Set(now.filter { $0.value > before[$0.key, default: 0] }.keys)
            if !extra.isEmpty { added[id] = extra }
        }
        playlistAddedTracks = added
        if case let .playlist(id) = library.sidebar, index[id] == nil {
            // 보던 목록을 초안으로 지웠거나 되돌리기로 없어졌다
            library.sidebar = .filter(.all)
        } else if refreshList, case .playlist = library.sidebar {
            library.refreshBase()
        }
        // 함께 고른 목록 중 없어진 것은 고르기에서 뺀다(보던 목록은 남은 경우, #261)
        let gone = library.sidebarSelection.filter { if case let .playlist(id) = $0 { index[id] == nil } else { false } }
        if !gone.isEmpty { library.selectSidebar(library.sidebarSelection.subtracting(gone), showing: library.sidebar) }
    }

    /// 사이드바 재생 목록 곡 수. 컬렉션에 없는 곡과 숨기는 스트리밍 곡은 세지 않는다.
    func recountPlaylists() {
        let known = library.rowsByID, hiding = library.hideStreaming
        playlistCounts = playlistIndex.mapValues { node in
            StreamingVisibility.visibleCount(of: node.trackIDs, hidingStreaming: hiding) { known[$0]?.track }
        }
    }

    func loadRecentPlaylists() {
        let settings = library.settings
        recentPlaylistIDs = settings.persist ? settings.defaults.stringArray(forKey: Self.recentPlaylistsKey) ?? [] : []
    }

    /// 최근 목록을 바꾸고 설정에 남긴다(줄 세우는 규칙은 `EditPlaylists`)
    private func setRecent(_ ids: [String]) {
        recentPlaylistIDs = ids
        let settings = library.settings
        if settings.persist { settings.defaults.set(recentPlaylistIDs, forKey: Self.recentPlaylistsKey) }
    }

    private func touchRecent(_ id: String) {
        setRecent(EditPlaylists.touchingRecent(id, in: recentPlaylistIDs))
    }

    // MARK: - 초안 바꾸기

    /// 편집 요청을 차례로 초안에 더한다(유스케이스 `EditPlaylists.planning`, CLI `djc draft playlist`와 같은 규칙).
    /// 하나라도 쓸 수 없으면 아무것도 더하지 않고 이유를 알린다. 더했으면 계획(만든 목록 ID·쌓은 뒤 모양)을 돌려준다.
    /// `allOrNothing`이 false면(사이드바 여러 개 편집, #261) 막힌 요청만 건너뛰고 나머지를 쌓는다. 쌓은 것이 없어도 계획을 돌려준다
    /// (건너뛴 이유는 부른 쪽이 보인다). 묶음 하나는 ⌘Z 한 번에 되돌린다.
    @discardableResult
    func applyPlaylistRequests(_ requests: [PlaylistEditRequest], actionName: String, allOrNothing: Bool = true) -> EditPlaylists.Batch? {
        guard !library.editsFrozen, !requests.isEmpty else { return nil }
        // 바깥(CLI)에서 바뀐 초안이 있으면 먼저 받고 그 위에 쌓는다(덮지 않게)
        syncExternalPlaylistDraft()
        let batch = planPlaylistRequests(requests, allOrNothing: allOrNothing)
        if !allOrNothing {
            if batch.hasChanges { commitPlaylistDraft(batch.draft, actionName: actionName) }
            return batch
        }
        if batch.refused {
            playlistMessage = AppMessage(kind: .warning, text: EditPlaylists.refusedMessage(batch.firstSkipReason ?? ""))
            return nil
        }
        guard batch.hasChanges else { return nil }
        commitPlaylistDraft(batch.draft, actionName: actionName)
        return batch
    }

    /// 요청을 지금 초안에 얹어 계획만 한다(쌓지 않는다). 확인 창이 쌓을 것과 건너뛸 것을 미리 보인다
    func planPlaylistRequests(_ requests: [PlaylistEditRequest], allOrNothing: Bool = false) -> EditPlaylists.Batch {
        EditPlaylists.planning(requests, onto: playlistDraft, rekordbox: rekordboxPlaylists, allOrNothing: allOrNothing) {
            UUID().uuidString.lowercased()
        }
    }

    /// 초안을 바꾸고 저장·화면 갱신·되돌리기(⌘Z)를 건다. 되돌리기 대상은 핵심이다(쓰기 잠금이 핵심 대상으로 지운다).
    /// 디스크 초안이 바깥(CLI)에서 바뀌었으면 그 초안을 받고 이 변경은 하지 않는다(옛 초안으로 만든 변경이 CLI 초안을 덮지 않게).
    func setPlaylistDraft(_ draft: PlaylistDraft, actionName: String) {
        guard draft != playlistDraft else { return }
        if syncExternalPlaylistDraft() {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "바깥에서 바뀐 재생 목록 초안을 다시 읽어 방금 변경은 하지 않았습니다. 다시 해 주세요."))
            return
        }
        commitPlaylistDraft(draft, actionName: actionName)
    }

    private func commitPlaylistDraft(_ draft: PlaylistDraft, actionName: String) {
        let before = playlistDraft
        guard draft != before else { return }
        playlistDraft = draft
        savePlaylistDraft()
        refreshPlaylists()
        guard let undoManager = library.undoManager else { return }
        undoManager.registerUndo(withTarget: library) { target in
            guard !target.editsFrozen else { return }
            target.playlists.setPlaylistDraft(before, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - 곡

    /// 곡을 목록 끝에 넣는다. 이미 든 곡과 rekordbox에 아직 없는 곡(추가한 곡)은 넣지 않고 알린다.
    func addTracks(_ rows: [TrackRow], toPlaylist id: String) {
        guard let item = playlistItem(id), item.holdsTracks else { return }
        let plan = EditPlaylists.addPlan(library.uniqueTracks(rows), to: item)
        if !plan.new.isEmpty {
            guard applyPlaylistRequests([.addTracks(.ref(PlaylistRef(id)), contentIDs: plan.new)], actionName: String(ui: "재생 목록에 넣기")) != nil else { return }
            touchRecent(id)
        }
        if let summary = EditPlaylists.addSummary(name: item.name, added: plan.new.count, duplicates: plan.duplicates.count,
                                                  saveFailed: playlistDraftUnsaved, staged: plan.staged, saveFailureText: Self.playlistSaveFailureText) {
            playlistMessage = AppMessage(kind: summary.warning ? .warning : .success, text: summary.text)
        }
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 보고 있는 목록에서 곡을 뺀다(같은 곡이 여러 번 들었으면 모두). 컬렉션에서는 빼지 않는다.
    func removeTracks(_ rows: [TrackRow], fromPlaylist id: String) {
        guard let item = playlistItem(id), item.holdsTracks else { return }
        let entries = item.entries(of: Set(rows.map(\.track.id)))
        guard !entries.isEmpty else { return }
        if applyPlaylistRequests([.removeTracks(.ref(PlaylistRef(id)), contentIDs: Self.unique(entries.map(\.contentID)))],
                                 actionName: String(ui: "재생 목록에서 빼기")) != nil {
            let count = Set(entries.map(\.contentID)).count
            let removed = String(ui: "‘\(item.name)’에서 \(count)곡을 뺐습니다(쓰기 대기).")
            playlistMessage = playlistDraftUnsaved ? AppMessage(kind: .warning, text: removed + " " + Self.playlistSaveFailureText)
                : AppMessage(text: removed)
        }
    }

    /// 곡들을 `before` 곡 앞으로(nil이면 맨 끝) 옮긴다. 목록에 보이는 줄(같은 곡의 처음 자리)을 옮긴다.
    func moveTracks(_ contentIDs: [String], inPlaylist id: String, before: String?) {
        guard let item = playlistItem(id), item.holdsTracks else { return }
        let moving = item.firstEntries(of: Set(contentIDs))
        guard !moving.isEmpty else { return }
        // 목록 순서대로 넘겨 편집 하나로 옮긴다. 목록에 없는 곡 앞이면 맨 끝이다.
        let before = before.flatMap { item.trackIDs.contains($0) ? $0 : nil }
        applyPlaylistRequests([.moveTracks(.ref(PlaylistRef(id)), contentIDs: moving.map(\.contentID), before: before)],
                              actionName: String(ui: "곡 순서 바꾸기"))
    }

    /// 고른 곡을 보고 있는 목록에서 뺀다(⌫)
    func removeSelectedFromPlaylist() {
        guard let id = editablePlaylistID else { return }
        removeTracks(library.selectedRows, fromPlaylist: id)
    }

    /// '재생 목록에 넣기…'(이름으로 찾기) 시트를 연다. 시트 모델은 여기서 한 번 만든다(본문이 다시 그려져도 같은 모델).
    func openPlaylistPicker(tracks: [TrackRow]? = nil) {
        let tracks = library.uniqueTracks(tracks ?? library.selectedRows).filter { !$0.isStaged }
        guard !tracks.isEmpty, !library.editsFrozen else { return }
        playlistPicker = PlaylistPickerModel(playlists: self, tracks: tracks)
    }

    /// '마지막에 쓴 목록에 넣기'
    func addSelectionToLastPlaylist() {
        guard let target = lastUsedPlaylist else { return }
        addTracks(library.selectedRows, toPlaylist: target.id)
    }

    // MARK: - 목록·폴더

    /// 새 목록·폴더를 부모 맨 위에 만들고(곡을 주면 넣고) 고른다. 사이드바는 조상 폴더만 펼치고 이름을 고치게 한다(`onCreate`).
    /// 만든 목록 ID(`new:키`)를 돌려준다.
    @discardableResult
    func createPlaylist(isFolder: Bool, in parent: String? = nil, name: String? = nil, tracks: [TrackRow] = []) -> String? {
        let name = name ?? (isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록"))
        let ids = isFolder ? [] : EditPlaylists.creatableTrackIDs(library.uniqueTracks(tracks))
        let action = isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록")
        let request = PlaylistEditRequest.create(name: name, isFolder: isFolder, parent: .ref(PlaylistRef(parent ?? newPlaylistParent)),
                                                 position: nil, alias: nil, tracks: ids)
        guard let id = applyPlaylistRequests([request], actionName: action)?.outcomes.first?.playlistID else { return nil }
        if !ids.isEmpty { touchRecent(id) }
        let ancestors = playlistProjection.layout.ancestors(of: id).map(\.id)
        library.sidebar = .playlist(id)
        onCreate?(id, ancestors)
        return id
    }

    /// 재생 기록으로 재생 목록을 만든다(#70). 맨 위에, 튼 순서대로(같은 곡은 처음 한 번), 이름은 기록 제목.
    /// USB에서 보존한 기록(#43)은 컬렉션 짝이 있는 곡만 넣고, 이름은 기록 이름이다.
    func createPlaylist(fromHistory id: String) {
        guard let source = historyPlaylistSource(id), !source.rows.isEmpty else { return }
        createPlaylist(isFolder: false, in: PlaylistLayout.root, name: source.name, tracks: source.rows)
    }

    /// 재생 기록으로 만들 재생 목록의 이름과 컬렉션 곡(고르는 규칙은 `EditPlaylists.historySource`). 없는 기록이면 nil
    func historyPlaylistSource(_ id: String) -> (name: String, rows: [TrackRow])? {
        EditPlaylists.historySource(id, histories: library.history.historyIndex, archived: library.history.archivedHistoryIndex,
                                    rows: library.rowsByID)
    }

    func renamePlaylist(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = playlistItem(id), !name.isEmpty, name != item.name else { return }
        applyPlaylistRequests([.rename(.ref(PlaylistRef(id)), name: name)], actionName: String(ui: "재생 목록 이름 바꾸기"))
    }

    func deletePlaylist(_ id: String) {
        guard playlistItem(id) != nil else { return }
        applyPlaylistRequests([.delete(.ref(PlaylistRef(id)))], actionName: String(ui: "재생 목록 지우기"))
    }

    /// 다른 폴더(또는 맨 위)로 옮기고, `before`를 주면 그 항목 앞 자리로(없으면 맨 끝).
    func movePlaylist(_ id: String, into parent: String, before: String? = nil) {
        guard playlistItem(id) != nil, before != id else { return }
        // 그 폴더 안에 없는 항목 앞이면 맨 끝이다.
        let others = playlistProjection.layout.childIDs(of: parent).filter { $0 != id }
        let position = before.flatMap { others.contains($0) ? PlaylistPosition.before(.ref(PlaylistRef($0))) : nil }
        applyPlaylistRequests([.move(.ref(PlaylistRef(id)), into: .ref(PlaylistRef(parent)), position: position)],
                              actionName: String(ui: "재생 목록 옮기기"))
    }

    /// 목록(폴더면 그 아래까지)의 초안을 버린다. nil이면 재생 목록 초안 모두.
    func discardPlaylistDraft(_ id: String? = nil) {
        var draft = playlistDraft
        if let id { draft.discard(playlist: id, rekordbox: rekordboxPlaylists) } else { draft = PlaylistDraft() }
        setPlaylistDraft(draft, actionName: String(ui: "재생 목록 초안 버리기"))
    }

    /// rekordbox에서 바뀌어 쓸 수 없는 편집만 버린다.
    func discardBlockedPlaylistEdits() {
        var draft = playlistDraft
        draft.discardBlocked(rekordbox: rekordboxPlaylists, contentIDs: Set(library.rowsByID.keys))
        setPlaylistDraft(draft, actionName: String(ui: "재생 목록 초안 버리기"))
    }

    // MARK: - 바깥 변경(#260)

    /// 바깥(CLI `djc draft playlist`)에서 바꾼 디스크 초안을 받는다. 받으면 그 앞의 라이브러리 ⌘Z 기록(태그·재생 목록)을 비운다
    /// (옛 초안으로 되돌리면 CLI 초안을 덮는다). 저장하지 못한 메모리 초안(디스크보다 최신), 복원 뒤 다시 쌓을 편집, 쓰는 중이면 받지 않는다.
    /// - Returns: 받았으면 true
    @discardableResult
    func adoptExternalDraft(_ disk: PlaylistDraft?) -> Bool {
        guard let disk, disk != playlistDraft, !playlistDraftUnsaved, playlistEditsAwaitingReload.isEmpty,
              !library.libraryBusy else { return false }
        playlistDraft = disk
        refreshPlaylists()
        library.undoManager?.removeAllActions(withTarget: library)
        return true
    }

    /// 편집하기 전에: 디스크 초안이 메모리와 다르면(바깥에서 바뀜) 받는다. 1초마다 하는 바깥 변경 확인보다 먼저 편집해도 CLI 초안을 덮지 않게 한다
    @discardableResult
    func syncExternalPlaylistDraft() -> Bool {
        guard !playlistDraftUnsaved, playlistEditsAwaitingReload.isEmpty else { return false }
        return adoptExternalDraft(try? library.useCases.playlists.loadDraft())
    }

    // MARK: - 초안 저장

    /// 메모리 초안을 저장한다. 실패하면 메모리 초안을 그대로 두고 기록해, 쓰기 전에 다시 저장한다.
    @discardableResult
    func savePlaylistDraft() -> Bool {
        do {
            try library.useCases.playlists.saveDraft(playlistDraft)
            applyPlaylistSave(nil)
            return true
        } catch {
            applyPlaylistSave(error)
            return false
        }
    }

    /// 메모리 초안을 저장한 결과(`error`가 nil이면 저장했다)를 표시에 맞춘다. 실패면 쓰기 전에 다시 저장하도록 기록한다(#174)
    func applyPlaylistSave(_ error: (any Error)?) {
        if let error {
            playlistDraftUnsaved = true
            AppErrorMessage.log(error)
            playlistMessage = AppMessage(kind: .warning, text: Self.playlistSaveFailureText)
        } else {
            playlistDraftUnsaved = false
            if playlistMessage?.text == Self.playlistSaveFailureText { playlistMessage = nil }
        }
    }

    /// 쓰기 전에: 저장하지 못한 재생 목록 초안은 다시 저장해 본다. 저장했거나 저장할 것이 없으면 true(아니면 쓰기가 막는다).
    func ensurePlaylistDraftSaved() -> Bool {
        guard playlistDraftUnsaved else { return true }
        return savePlaylistDraft()
    }

    // MARK: - 반영 뒤

    /// 쓴 뒤: 반영 세션이 쓴 편집을 뺀 초안(막힌 편집은 남겨 다음 반영에서 다시 본다)과 새 목록 ID를 이은 연결 기록을 저장했다.
    /// 메모리 초안·연결 기록을 맞추고, 새로 만든 목록의 `new:키`를 새 rekordbox ID로 바꿔 둔다(최근 목록·보고 있는 목록).
    func applyPlaylistWrite(_ cleanup: EditPlaylists.WriteCleanup) {
        let ids = cleanup.ids
        if let draft = cleanup.draft {
            playlistDraft = draft
            applyPlaylistSave(cleanup.draftError)
        }
        if !ids.isEmpty {
            if let imports = cleanup.imports { applyImportsChange(imports) }
            setRecent(EditPlaylists.remappingRecent(recentPlaylistIDs, ids: ids))
            if case let .playlist(id) = library.sidebar, let real = ids[id] { library.sidebar = .playlist(real) }
        }
    }

    /// 되돌린 뒤: 그때 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓고, 그 뒤 쌓은 초안을 이어 붙인다(저장은 유스케이스 `EditPlaylists.restore`).
    /// - Returns: 다시 쌓지 못한 편집 수
    @discardableResult
    func restorePlaylistEdits(_ edits: [PlaylistEdit]) -> Int {
        guard !edits.isEmpty else { return 0 }
        let restored = library.useCases.playlists.restore(edits, onto: playlistDraft, rekordbox: rekordboxPlaylists, imports: playlistImports,
                                                          importsLoadFailed: playlistImportsLoadFailed)
        playlistDraft = restored.draft
        applyPlaylistSave(restored.draftError)
        refreshPlaylists()
        applyImportsChange(restored.imports)
        return restored.failed
    }

    /// 새 스냅샷을 읽은 뒤: 복원한 재생 목록 편집을 되돌린 rekordbox 상태에 다시 쌓는다(쌓지 못한 편집은 알린다).
    func restoreAwaitingPlaylistEdits() {
        guard !playlistEditsAwaitingReload.isEmpty else { return }
        let edits = playlistEditsAwaitingReload
        playlistEditsAwaitingReload = []
        let unrestored = restorePlaylistEdits(edits)
        if unrestored > 0 {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 편집 \(unrestored)건은 초안으로 되살리지 못했습니다."))
        }
    }
}
