import DJCDomain
import Foundation

/// 곡 목록(표에 보이는 줄): 사이드바 대상 → 숨기기 → 정렬 → 검색·평점·곡 색 거르기와 선택 규칙.
/// 규칙은 DJCDomain(`TrackListProjection`·`TrackSelection`)이고, 여기서는 그 결과를 관찰 값에 넣는다.
extension LibraryStore {
    /// 불러오기 명령(⌘→·메뉴)이 덱에 올릴 곡: 선택 중 표 순서로 첫 곡.
    var primaryRow: TrackRow? {
        TrackSelection.primary(selection: selection, displayRows: displayRows, rowsByID: rowsByID)
    }

    var selectedRows: [TrackRow] {
        uniqueTracks(displayRows.filter { selection.contains($0.id) })
    }

    /// 재생 기록의 반복 행을 함께 골라도 곡 편집·반영 대상은 한 번만 넘긴다(USB 곡은 뺀다).
    func uniqueTracks(_ candidates: [TrackRow]) -> [TrackRow] {
        TrackSelection.uniqueTracks(candidates, rowsByID: rowsByID)
    }

    func historyTitle(_ history: RekordboxHistory) -> String { history.title }

    func count(history: RekordboxHistory) -> Int {
        StreamingVisibility.visibleCount(of: history.entries.map(\.contentID), hidingStreaming: hideStreaming) { rowsByID[$0]?.track }
    }

    func count(_ filter: LibraryFilter) -> Int { filterCounts[filter] ?? 0 }

    func count(playlist node: PlaylistOutlineNode) -> Int { playlistCounts[node.id] ?? 0 }

    /// USB 목록·라이브러리가 바뀌었다: 보고 있던 USB 대상이 없어졌으면 라이브러리로 돌아가고, 아니면 줄을 다시 만든다.
    func usbChanged() {
        guard case let .usb(target) = sidebar else { return }
        if usb?.contains(target) == true { refreshBase() } else { sidebar = .filter(.all) }
    }

    /// '스트리밍 곡 숨기기'를 적용하는 보기. 쓰기 대기 목록은 보이는 것이 곧 쓸 곡이라 거르지 않는다.
    /// 추가한 곡·USB 곡·중복 후보·iTunes 목록은 스트리밍 곡이 들지 않는다.
    private static func hidesStreaming(in sidebar: SidebarItem) -> Bool {
        switch sidebar {
        case .filter, .playlist, .history: true
        case .itunesPlaylist, .duplicates, .staged, .pending, .usb: false
        }
    }

    /// 지금 사이드바 대상이 보여 줄 줄(투영 규칙에 넘길 값)
    private var listSource: TrackListProjection.Source {
        switch sidebar {
        case let .filter(filter): .filter(filter)
        case let .playlist(id): .playlist(trackIDs: playlistIndex[id]?.trackIDs ?? [])
        case let .itunesPlaylist(id):
            .iTunesPlaylist(id: id, trackIDs: music.library.index[id]?.trackIDs ?? [], numbers: music.library.index[id]?.trackNumbers ?? [])
        case let .history(id):
            // USB에서 보존한 기록(#43)은 컬렉션 짝이 없는 곡도 읽기 전용 줄로 보인다
            if let history = self.history.historyIndex[id] { .history(history.entries) } else { .rows(self.history.archivedHistoryRows(id)) }
        case .staged: .rows(stagedRows)
        case .pending: .pending(pendingUUIDs)
        // 분류 칸은 로컬 줄과 같은 코멘트 규칙(지금 프리셋)으로 가른다(#256)
        case let .usb(target): .rows(usb?.rows(for: target, commentPreset: commentPreset) ?? [])
        case .duplicates: .duplicates(duplicateGroups.flatMap { $0.tracks.map(\.id) })
        }
    }

    func refreshBase() {
        let base = TrackListProjection.base(listSource, rows: rows, rowsByID: rowsByID)
        applyListBase(TrackListProjection.hidingStreaming(base, hide: hideStreaming && Self.hidesStreaming(in: sidebar)))
        refreshFiltered()
        pruneHiddenSelection()
    }

    /// 숨긴 스트리밍 곡은 선택에서도 뺀다(숨은 곡에 쓰기·덱 동작이 가지 않게). 검색으로 가려진 곡의 선택은 건드리지 않는다.
    private func pruneHiddenSelection() {
        guard hideStreaming, Self.hidesStreaming(in: sidebar), !selection.isEmpty else { return }
        let kept = TrackSelection.withoutHidden(selection, hiddenIDs: hiddenStreamingRowIDs, rowsByID: rowsByID)
        if kept != selection { selection = kept }
    }

    /// 다시 읽은 뒤: 라이브러리에서 지운 곡은 선택에서도 뺀다
    func pruneMissingSelection() {
        let existing = TrackSelection.existing(selection, rowsByID: rowsByID, displayRows: displayRows)
        if existing != selection { selection = existing }
    }

    /// 설정을 바꾼 즉시: 필터·재생 목록 곡 수와 목록을 다시 만든다(다시 읽지 않는다).
    func applyStreamingVisibility() {
        recountFilters()
        recountPlaylists()
        if hideStreaming, sidebar == .filter(.streaming) {
            // 사이드바에서 사라지는 필터에 남지 않는다(목록은 sidebar 변경이 다시 만든다)
            sidebar = .filter(.all)
        } else {
            refreshBase()
        }
    }

    /// 프리셋 전환은 초안·선택·스냅샷을 보존하고 코멘트 캐시만 갱신한다.
    func refreshCommentRule() {
        applyCommentRuleToRows(commentPreset.rule)
        recountFilters()
        withoutListRefresh {
            if !commentRuleEnabled {
                sortOrder.removeAll { $0.keyPath == \TrackRow.commentClassName }
            }
        }
        if !commentRuleEnabled, case let .filter(filter) = sidebar, filter.requiresCommentRule {
            sidebar = .filter(.all)
        } else {
            refreshBase()
        }
    }

    func refreshFiltered() {
        if sidebar == .duplicates {
            // 검색한 곡의 비교 상대도 남겨 묶음이 한 곡으로 잘리지 않게 한다.
            let groups = TrackListProjection.duplicateGroups(duplicateGroups, members: { $0.tracks.map(\.id) },
                                                             search: search, rowsByID: rowsByID)
            let visible = Set(groups.flatMap { $0.tracks.map(\.id) })
            showRows(sortedBase.filter { visible.contains($0.id) }, duplicateGroups: groups)
            return
        }
        showRows(TrackListProjection.filtered(sortedBase, search: search, minimumRating: minimumRating, color: colorFilter))
    }

    /// 평점·곡 색 거르기(#65). USB 곡도 같은 칸(평점·색)으로 거른다.
    nonisolated static func matchesAttributes(_ row: TrackRow, minimumRating: Int, color: String?) -> Bool {
        TrackListProjection.matchesAttributes(row, minimumRating: minimumRating, color: color)
    }

    var sidebarTitle: String {
        switch sidebar {
        case let .filter(filter): filter.title
        case let .playlist(id): playlistIndex[id]?.name ?? String(ui: "플레이리스트")
        case let .itunesPlaylist(id): music.library.index[id]?.name ?? String(ui: "iTunes 동기화 목록")
        case let .history(id): history.historyIndex[id].map(historyTitle) ?? history.archivedHistoryIndex[id]?.name ?? String(ui: "재생 기록")
        case .duplicates: String(ui: "중복 후보")
        case .staged: String(ui: "추가한 곡")
        case .pending: String(ui: "rekordbox 쓰기 대기")
        case let .usb(target): usb?.title(for: target) ?? "USB"
        }
    }
}
