import DJCApplication
import DJCDomain
import Foundation

/// 재생 목록 초안(#39·#40): 곡 넣기·빼기·순서, 목록·폴더 만들기·이름·지우기·옮기기.
/// rekordbox에는 바로 쓰지 않고 초안(`PlaylistDraft`)으로 쌓아, 반영(⇧⌘E) 때 큐·그리드 초안과 같은 확인 창·백업·되돌리기로 쓴다.
/// 사이드바·곡 목록은 rekordbox 상태에 초안을 얹은 모양을 보여 준다.
extension LibraryStore {
    static let recentPlaylistsKey = "library.recentPlaylists"
    static let recentPlaylistLimit = 5

    var hasPlaylistDrafts: Bool { !playlistDraft.isEmpty }

    /// 쓸 수 없는 초안 편집 수(rekordbox에서 바뀐 목록 등)
    var blockedPlaylistEditCount: Int { playlistProjection.blocked.compactMap { $0 }.count }

    /// 초안을 얹은 목록(없으면 nil). 사이드바·메뉴는 이 모양을 본다.
    func playlistItem(_ id: String) -> PlaylistLayout.Item? { playlistProjection.layout.item(id) }

    /// 곡을 넣고 뺄 수 있는 목록(폴더·인텔리전트 목록이 아님)
    func canEditTracks(of id: String) -> Bool { playlistItem(id)?.holdsTracks == true }

    /// 지금 보고 있는 목록(곡을 빼거나 순서를 바꿀 수 있을 때만)
    var editablePlaylistID: String? {
        guard case let .playlist(id) = sidebar, canEditTracks(of: id) else { return nil }
        return id
    }

    /// 끌어서 순서를 바꿀 수 있는지: 목록 순서(# 순)로 보고, 검색으로 거르지 않을 때
    /// '스트리밍 곡 숨기기'로 줄을 뺀 목록도 막는다: 숨은 줄이 끼어 있으면 놓을 자리가 모호해(검색으로 거른 목록과 같다) 숨기기를 끄고 옮긴다.
    var canReorderDisplayedTracks: Bool {
        editablePlaylistID != nil && sortOrder.isEmpty && search.trimmingCharacters(in: .whitespaces).isEmpty
            && streamingHiddenInView == 0
    }

    /// 표의 초안 칸: 곡 초안이 있는 곡 + 보고 있는 목록에 초안으로 넣은 곡
    var listMarkedUUIDs: Set<String> {
        guard case let .playlist(id) = sidebar, let added = playlistAddedTracks[id], !added.isEmpty else { return editedUUIDs }
        return editedUUIDs.union(added.compactMap { rowsByID[$0]?.track.uuid })
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
        guard case let .playlist(id) = sidebar, let item = playlistItem(id) else { return PlaylistLayout.root }
        return item.isFolder && !item.isSmart ? item.id : item.parentID
    }

    // MARK: - 화면 갱신

    /// 초안을 얹은 모양으로 사이드바 트리·곡 수·목록을 다시 만든다.
    func refreshPlaylists(refreshList: Bool = true) {
        let projection = playlistDraft.project(onto: rekordboxPlaylists, contentIDs: Set(rowsByID.keys))
        playlistProjection = projection
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
        if case let .playlist(id) = sidebar, index[id] == nil {
            // 보던 목록을 초안으로 지웠거나 되돌리기로 없어졌다
            sidebar = .filter(.all)
        } else if refreshList, case .playlist = sidebar {
            refreshBase()
        }
    }

    /// 사이드바 재생 목록 곡 수. 컬렉션에 없는 곡과 숨기는 스트리밍 곡은 세지 않는다.
    func recountPlaylists() {
        let known = rowsByID, hiding = hideStreaming
        playlistCounts = playlistIndex.mapValues { node in
            StreamingVisibility.visibleCount(of: node.trackIDs, hidingStreaming: hiding) { known[$0]?.track }
        }
    }

    func loadRecentPlaylists() {
        recentPlaylistIDs = settings.persist ? settings.defaults.stringArray(forKey: Self.recentPlaylistsKey) ?? [] : []
    }

    private func touchRecent(_ id: String) {
        var recent = recentPlaylistIDs.filter { $0 != id }
        recent.insert(id, at: 0)
        recentPlaylistIDs = Array(recent.prefix(Self.recentPlaylistLimit))
        if settings.persist { settings.defaults.set(recentPlaylistIDs, forKey: Self.recentPlaylistsKey) }
    }

    // MARK: - 초안 바꾸기

    /// 편집을 차례로 초안에 더한다. 하나라도 쓸 수 없으면 아무것도 더하지 않고 이유를 알린다.
    @discardableResult
    func applyPlaylistEdits(_ edits: [PlaylistEdit], actionName: String) -> Bool {
        guard !isWritingRekordbox, !edits.isEmpty else { return false }
        do {
            setPlaylistDraft(try EditPlaylists.appending(edits, to: playlistDraft, rekordbox: rekordboxPlaylists), actionName: actionName)
            return true
        } catch {
            playlistMessage = AppMessage(kind: .warning, text: (error as? EditPlaylists.Refused)?.message ?? DJCError.reason(of: error))
            return false
        }
    }

    /// 초안을 바꾸고 저장·화면 갱신·되돌리기(⌘Z)를 건다.
    func setPlaylistDraft(_ draft: PlaylistDraft, actionName: String) {
        let before = playlistDraft
        guard draft != before else { return }
        playlistDraft = draft
        savePlaylistDraft()
        refreshPlaylists()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWritingRekordbox else { return }
            target.setPlaylistDraft(before, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - 곡

    /// 곡을 목록 끝에 넣는다. 이미 든 곡과 rekordbox에 아직 없는 곡(추가한 곡)은 넣지 않고 알린다.
    func addTracks(_ rows: [TrackRow], toPlaylist id: String) {
        guard let item = playlistItem(id), item.holdsTracks else { return }
        let tracks = uniqueTracks(rows)
        let staged = tracks.filter(\.isStaged).count
        let split = item.split(adding: tracks.filter { !$0.isStaged }.map(\.track.id))
        if !split.new.isEmpty {
            guard applyPlaylistEdits([.addTracks(playlist: PlaylistRef(id), contentIDs: split.new)], actionName: String(ui: "재생 목록에 넣기")) else { return }
            touchRecent(id)
        }
        if let summary = EditPlaylists.addSummary(name: item.name, added: split.new.count, duplicates: split.duplicates.count,
                                                  saveFailed: playlistDraftUnsaved, staged: staged, saveFailureText: Self.playlistSaveFailureText) {
            playlistMessage = AppMessage(kind: summary.warning ? .warning : .success, text: summary.text)
        }
    }

    /// 보고 있는 목록에서 곡을 뺀다(같은 곡이 여러 번 들었으면 모두). 컬렉션에서는 빼지 않는다.
    func removeTracks(_ rows: [TrackRow], fromPlaylist id: String) {
        guard let item = playlistItem(id), item.holdsTracks else { return }
        let entries = item.entries(of: Set(rows.map(\.track.id)))
        guard !entries.isEmpty else { return }
        if applyPlaylistEdits([.removeTracks(playlist: PlaylistRef(id), entries: entries)], actionName: String(ui: "재생 목록에서 빼기")) {
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
        let to = item.insertionPoint(before: before, moving: moving)
        let order = item.entries.filter { !moving.contains($0) }
        var after = order
        after.insert(contentsOf: moving, at: min(max(to - 1, 0), after.count))
        guard after != item.entries else { return }
        applyPlaylistEdits([.moveTracks(playlist: PlaylistRef(id), entries: moving, to: to)], actionName: String(ui: "곡 순서 바꾸기"))
    }

    /// 고른 곡을 보고 있는 목록에서 뺀다(⌫)
    func removeSelectedFromPlaylist() {
        guard let id = editablePlaylistID else { return }
        removeTracks(selectedRows, fromPlaylist: id)
    }

    /// '재생 목록에 넣기…'(이름으로 찾기) 창을 연다.
    func openPlaylistPicker(tracks: [TrackRow]? = nil) {
        let tracks = uniqueTracks(tracks ?? selectedRows).filter { !$0.isStaged }
        guard !tracks.isEmpty, !isWritingRekordbox else { return }
        playlistPickerTracks = tracks
        showingPlaylistPicker = true
    }

    /// '마지막에 쓴 목록에 넣기'
    func addSelectionToLastPlaylist() {
        guard let target = lastUsedPlaylist else { return }
        addTracks(selectedRows, toPlaylist: target.id)
    }

    // MARK: - 목록·폴더

    /// 새 목록·폴더를 부모 맨 위에 만들고(곡을 주면 넣고) 이름을 고치게 한다. 만든 목록 ID(`new:키`)를 돌려준다.
    @discardableResult
    func createPlaylist(isFolder: Bool, in parent: String? = nil, name: String? = nil, tracks: [TrackRow] = []) -> String? {
        let key = UUID().uuidString.lowercased()
        let name = name ?? (isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록"))
        var edits: [PlaylistEdit] = [.create(key: key, name: name, isFolder: isFolder, parent: PlaylistRef(parent ?? newPlaylistParent))]
        let ids = uniqueTracks(tracks).filter { !$0.isStaged }.map(\.track.id)
        if !isFolder, !ids.isEmpty { edits.append(.addTracks(playlist: .new(key), contentIDs: ids)) }
        let action = isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록")
        guard applyPlaylistEdits(edits, actionName: action) else { return nil }
        let id = PlaylistRef.new(key).layoutID
        if !ids.isEmpty { touchRecent(id) }
        expandedPlaylistIDs.formUnion(playlistProjection.layout.ancestors(of: id).map(\.id))
        sidebar = .playlist(id)
        renamingPlaylistID = id
        return id
    }

    /// 재생 기록으로 재생 목록을 만든다(#70). 맨 위에, 튼 순서대로(같은 곡은 처음 한 번), 이름은 기록 제목.
    /// USB에서 보존한 기록(#43)은 컬렉션 짝이 있는 곡만 넣고, 이름은 기록 이름이다.
    func createPlaylist(fromHistory id: String) {
        guard let source = historyPlaylistSource(id), !source.rows.isEmpty else { return }
        createPlaylist(isFolder: false, in: PlaylistLayout.root, name: source.name, tracks: source.rows)
    }

    /// 재생 기록으로 만들 재생 목록의 이름과 컬렉션 곡(튼 순서, 반복 재생 포함 — 넣을 때 처음 한 번만 남는다). 없는 기록이면 nil
    func historyPlaylistSource(_ id: String) -> (name: String, rows: [TrackRow])? {
        if let history = historyIndex[id] {
            let rows = history.entries.sorted { $0.trackNumber < $1.trackNumber }.compactMap { rowsByID[$0.contentID] }
            return (historyTitle(history), rows)
        }
        guard let archived = archivedHistoryIndex[id] else { return nil }
        let rows = archived.entries.sorted { $0.trackNumber < $1.trackNumber }.compactMap { $0.contentID.flatMap { rowsByID[$0] } }
        return (archived.name, rows)
    }

    func renamePlaylist(_ id: String, to name: String) {
        renamingPlaylistID = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = playlistItem(id), !name.isEmpty, name != item.name else { return }
        applyPlaylistEdits([.rename(playlist: PlaylistRef(id), name: name)], actionName: String(ui: "재생 목록 이름 바꾸기"))
    }

    func deletePlaylist(_ id: String) {
        guard playlistItem(id) != nil else { return }
        applyPlaylistEdits([.delete(playlist: PlaylistRef(id))], actionName: String(ui: "재생 목록 지우기"))
    }

    /// 다른 폴더(또는 맨 위)로 옮기고, `before`를 주면 그 항목 앞 자리로(없으면 맨 끝).
    func movePlaylist(_ id: String, into parent: String, before: String? = nil) {
        guard let item = playlistItem(id), before != id else { return }
        let layout = playlistProjection.layout
        let others = layout.childIDs(of: parent).filter { $0 != id }
        let index = before.flatMap { others.firstIndex(of: $0) } ?? others.count
        var edits: [PlaylistEdit] = []
        if item.parentID != parent {
            // 옮기기는 새 부모 맨 끝에 놓는다. 다른 자리면 순서 바꾸기를 이어 붙인다.
            edits.append(.move(playlist: PlaylistRef(id), into: PlaylistRef(parent)))
            if index != others.count { edits.append(.reorder(playlist: PlaylistRef(id), index: index)) }
        } else if index != layout.childIDs(of: parent).firstIndex(of: id) {
            edits.append(.reorder(playlist: PlaylistRef(id), index: index))
        }
        guard !edits.isEmpty else { return }
        applyPlaylistEdits(edits, actionName: String(ui: "재생 목록 옮기기"))
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
        draft.discardBlocked(rekordbox: rekordboxPlaylists, contentIDs: Set(rowsByID.keys))
        setPlaylistDraft(draft, actionName: String(ui: "재생 목록 초안 버리기"))
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
            recentPlaylistIDs = recentPlaylistIDs.map { ids[$0] ?? $0 }
            if settings.persist { settings.defaults.set(recentPlaylistIDs, forKey: Self.recentPlaylistsKey) }
            if case let .playlist(id) = sidebar, let real = ids[id] { sidebar = .playlist(real) }
        }
    }

    /// 되돌린 뒤: 그때 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓고, 그 뒤 쌓은 초안을 이어 붙인다(저장은 유스케이스 `EditPlaylists.restore`).
    /// - Returns: 다시 쌓지 못한 편집 수
    @discardableResult
    func restorePlaylistEdits(_ edits: [PlaylistEdit]) -> Int {
        guard !edits.isEmpty else { return 0 }
        let restored = useCases.playlists.restore(edits, onto: playlistDraft, rekordbox: rekordboxPlaylists, imports: playlistImports,
                                                  importsLoadFailed: playlistImportsLoadFailed)
        playlistDraft = restored.draft
        applyPlaylistSave(restored.draftError)
        refreshPlaylists()
        applyImportsChange(restored.imports)
        return restored.failed
    }
}
