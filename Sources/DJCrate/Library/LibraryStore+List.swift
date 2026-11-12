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

    func count(playlist node: PlaylistOutlineNode) -> Int { playlists.playlistCounts[node.id] ?? 0 }

    /// 표의 초안 칸: 곡 초안이 있는 곡 + 보고 있는 목록에 초안으로 넣은 곡(곡 목록 표가 읽는 값이라 핵심에 둔다)
    var listMarkedUUIDs: Set<String> {
        guard case let .playlist(id) = sidebar, let added = playlists.playlistAddedTracks[id], !added.isEmpty else { return editedUUIDs }
        return editedUUIDs.union(added.compactMap { rowsByID[$0]?.track.uuid })
    }

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
        case let .playlist(id): .playlist(trackIDs: playlists.playlistIndex[id]?.trackIDs ?? [])
        case let .itunesPlaylist(id):
            .iTunesPlaylist(id: id, trackIDs: music.library.index[id]?.trackIDs ?? [], numbers: music.library.index[id]?.trackNumbers ?? [])
        case let .history(id):
            // USB에서 보존한 기록(#43)은 컬렉션 짝이 없는 곡도 읽기 전용 줄로 보인다
            if let history = self.history.historyIndex[id] { .history(history.entries) } else { .rows(self.history.archivedHistoryRows(id)) }
        case .staged: .rows(staging.stagedRows)
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

    /// 숨긴 스트리밍 곡을 그 자리에서 푼다('스트리밍 곡 숨기기' 설정을 끈다). 머리 줄 [보이기]와 가운데 안내 [스트리밍 곡 보이기]가 함께 쓰는 입구다.
    /// 설정을 바꾸는 것이라 곡 목록·곡 수에 보이는 것만 달라지고, 읽은 곡·초안·쓰기 내용은 그대로다.
    func showHiddenStreaming() { hideStreaming = false }

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
        playlists.recountPlaylists()
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
        showRows(TrackListProjection.filtered(sortedBase, search: search, filter: filter))
    }

    /// 검색이 거를 곡 줄이 있는 화면인지(#338). 머리 줄 검색칸과 편집 › 찾기(⌘F)가 같은 판정을 쓴다.
    /// USB 쓰기 대기는 곡 줄이 아니라 그 볼륨의 쓰기 대기 표라 검색이 걸리지 않는다
    var listIsSearchable: Bool { if case .usb(.pending) = sidebar { false } else { true } }

    /// 필터가 거를 곡 줄이 있는 화면인지(#339). 머리 줄 필터 단추·칩과 같은 판정을 쓴다.
    /// 중복 후보는 묶음째 보여 주고(`refreshFiltered`), USB 쓰기 대기는 곡 줄이 아니라 볼륨의 쓰기 대기 표라 필터가 걸리지 않는다
    var listIsFilterable: Bool {
        switch sidebar {
        case .duplicates, .usb(.pending): false
        default: true
        }
    }

    /// 켜진 조건의 칩(머리 줄)
    var attributeFilterChips: AttributeFilterChips {
        AttributeFilterChips(filter: filter, colors: trackColors)
    }

    /// 칩 하나를 끈다: 그 조건만 꺼지고 다른 조건과 검색은 그대로다.
    /// 칩을 누른 사이 다른 곳에서 값이 바뀌었으면(지금 켜진 조건이 칩의 조건과 다르면) 건드리지 않는다
    func clearAttributeFilter(_ condition: AttributeFilterChip.Condition) {
        switch condition {
        case let .bpm(range): if filter.bpm == range { filter.bpm = nil }
        case let .key(key): if filter.key == key { filter.key = nil }
        case let .genre(genre): if filter.genre == genre { filter.genre = nil }
        case let .rating(count): if min(filter.minimumRating, 5) == count { filter.minimumRating = 0 }
        case let .color(id): filter.colorIDs.remove(id)
        }
    }

    /// 켜진 조건을 모두 끈다(검색은 그대로). 필터 창의 「모든 필터 끄기」·결과 없음 안내의 [필터 끄기]가 함께 쓴다
    func clearAttributeFilters() {
        filter = TrackFilter()
    }

    /// 필터 창의 장르 고르기에 보일 이름: 지금 목록(검색·필터 전)의 곡이 가진 장르
    var genreChoices: [String] { TrackFilter.genreChoices(in: sortedBase) }

    /// 태그 시트로 보이는 화면인지(#339). 태그 시트는 편집 화면이라 중복 후보·USB(읽기 전용) 목록에서는 곡 목록으로 보인다.
    /// 목록 본문(`LibraryDetail`)과 머리 줄의 ⓘ(초안 범례)가 같은 판정을 쓴다
    func showsTagSheet(sheetMode: Bool) -> Bool { sheetMode && sidebar != .duplicates && !isUsbSelection }

    /// 목록 | 태그 시트 전환을 막는 이유(막히지 않았으면 nil). 조건과 문구는 툴바에 있던 보기 전환 그대로다(#339).
    /// 메뉴 보기 › 목록·태그 시트(⌘1·⌘2)는 이 판정이 아니라 쓰는 동안 잠금(`editsFrozen`)만 본다
    var viewModeBlockReason: String? {
        if editsFrozen { return String(ui: "rekordbox 저장이 끝난 뒤 다시 시도하세요") }
        if isUsbSelection { return String(ui: "USB 곡은 읽기 전용이니 로컬 라이브러리에서 태그를 편집하세요") }
        if sidebar == .duplicates { return String(ui: "중복 후보에서는 태그 시트를 열 수 없으니 전체 목록에서 곡을 고르세요") }
        return nil
    }

    var sidebarTitle: String {
        switch sidebar {
        case let .filter(filter): filter.title
        case let .playlist(id): playlists.playlistIndex[id]?.name ?? String(ui: "플레이리스트")
        case let .itunesPlaylist(id): music.library.index[id]?.name ?? String(ui: "iTunes 동기화 목록")
        case let .history(id): history.historyIndex[id].map(historyTitle) ?? history.archivedHistoryIndex[id].map(history.displayName) ?? String(ui: "재생 기록")
        case .duplicates: String(ui: "중복 후보")
        case .staged: String(ui: "추가한 곡")
        case .pending: String(ui: "rekordbox 저장 대기")
        case let .usb(target): usb?.title(for: target) ?? "USB"
        }
    }
}
