import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 재생 목록 초안(#39·#40, 기능 조각 #251): 곡 넣기·빼기·순서, 목록·폴더 만들기·이름·지우기·옮기기.
/// rekordbox에는 바로 쓰지 않고 초안(`PlaylistDraft`)으로 쌓아, 저장(⌘S) 때 큐·그리드 초안과 같은 확인 창·백업·되돌리기로 쓴다.
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
    /// 재생 목록 초안 저장에 실패해 메모리 초안이 디스크보다 최신이다(쓰기 전에 다시 저장한다, #174).
    var playlistDraftUnsaved = false
    /// 디스크 초안을 읽지 못해 메모리 초안이 디스크와 같은지 모른다(도장 기록 실패로 읽기가 던졌다). 디스크 초안을 다시 받을 때까지
    /// 재생 목록 편집과 저장을 하지 않는다(옛 메모리로 저장해 바깥(CLI)에서 더한 단계를 덮지 않게, #402)
    private(set) var playlistDraftNeedsSync = false
    /// 지금 rekordbox에 쓰고 있는 재생 목록 단계의 식별자(R21 얼리기). nil이면 얼리지 않았다. 얼려 둔 동안은 재생 목록·재생 기록 편집을
    /// 받고(`isEditBlocked`), 쓰는 단계는 합치지도 지우지도 않으며 새 편집은 뒤에 쌓는다. `freezeWrite`로 얼리고 `thawWrite`로 푼다
    private(set) var writeFreeze: Set<UUID>?
    /// 쓰고 있는 재생 기록(보존 기록 ID). 얼려 둔 동안 이 기록은 저장 대기에서 빼지 못한다(이미 쓰고 있다)
    private(set) var writingHistories: Set<String> = []
    /// 저장 실패를 알린 창 알림(넣기·빼기 결과가 실패를 함께 적었으면 그 알림). 다시 저장하면 거둔다
    @ObservationIgnored var saveFailureToast: AppToast.ID?
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

    /// 재생 목록·재생 기록 편집을 지금 받지 않는지. 라이브러리를 쓰는 동안은 받지 않는다. 다만 초안 쓰기가 재생 목록 단계를 얼려 두었으면
    /// 받는다(R21): 쓰는 단계와 합치지 않고 뒤에 쌓는다. 복원·곡 넣기·빼기·iTunes 동기화·읽기는 얼리지 않아 늘 막는다. 합치기는 이 값을 읽지 않는다
    var isEditBlocked: Bool { library.libraryBusy && !(writeFreeze != nil && library.isDraftWrite) }

    /// 쓰고 있는 재생 목록 단계를 얼린다. 쓰기 묶음을 만든 자리(곡 단위 초안 쓰기)에서 묶음의 재생 목록 초안으로 부른다.
    /// 단계 식별자가 없는 단계가 있으면 얼릴 수 없다(false): 그 단계는 합치기에서 뺄 수 없어 편집을 막은 채 둔다. 초안 쓰기가 아니면 얼리지 않는다
    /// - Parameters:
    ///   - written: 쓰기 묶음의 재생 목록 초안(메모리 초안의 단계와 같은 식별자)
    ///   - histories: 쓰기 묶음의 재생 기록(보존 기록 ID)
    @discardableResult
    func freezeWrite(_ written: PlaylistDraft, histories: Set<String> = []) -> Bool {
        guard library.isDraftWrite, written.stepIDs.allSatisfy({ $0 != nil }) else { return false }
        writeFreeze = Set(written.stepIDs.compactMap { $0 })
        writingHistories = histories
        refreshPlaylists()
        return true
    }

    /// 얼림을 푼다(쓴 뒤 정리를 맞춘 때, 쓰기를 마칠 때·취소할 때). 풀면 쓰는 중에는 다시 재생 목록 편집을 받지 않는다
    func thawWrite(refresh: Bool = true) {
        guard writeFreeze != nil || !writingHistories.isEmpty else { return }
        writeFreeze = nil
        writingHistories = []
        if refresh { refreshPlaylists() }
    }

    /// 얼린 단계(없으면 빈 집합)
    private var frozen: Set<UUID> { writeFreeze ?? [] }
    /// 쓴 새 목록의 연결 ID(`new:키` → 실제 ID). 저장 뒤 ⌘Z가 새로 만든 목록을 찾는다(R12)
    @ObservationIgnored var writtenPlaylistIDs: [String: String] = [:]
    /// ⌘Z 단계를 건 뒤 쓰기들이 rekordbox에 쓴 단계의 식별자(정리·사본 실패로 초안에 남은 단계 포함, #295 E6).
    /// ⌘Z가 그 편집의 단계가 쓰였는지 본다. ⌘Z 기록을 비우는 자리에서만 비운다(`forgetWrittenSteps`)
    @ObservationIgnored private(set) var writtenStepIDs: Set<UUID> = []

    /// 저장하지 못해 식별자 없이 메모리에 남은 단계 가운데 이을 출처가 있는 단계(⌘Z·⇧⌘Z·복원이 되살린 단계, #295 리뷰 F5).
    /// 다음 저장에 넘기고 저장에 성공하면 비운다: 그 사이 다른 편집이 사람 편집 포트로 저장해도 그 단계는 기록한 출처로 남는다
    @ObservationIgnored private var unsavedStepOrigins: [(step: PlaylistDraft.Step, origins: Set<DraftOrigin>)] = []

    /// ⌘Z 기록을 비울 때 쓴 단계·연결 ID 기록도 비운다(#295 E6: ⌘Z 기록을 비우는 자리에서만)
    func forgetWrittenSteps() {
        writtenStepIDs = []
        writtenPlaylistIDs = [:]
    }


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
        let projection = playlistDraft.project(onto: rekordboxPlaylists, contentIDs: Set(library.rowsByID.keys), frozen: frozen)
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
        guard !isEditBlocked, !requests.isEmpty else { return nil }
        // 바깥(CLI)에서 바뀐 초안이 있으면 먼저 받고 그 위에 쌓는다(덮지 않게). 읽지 못하면 옛 메모리 위에 쌓지 않는다
        guard syncBeforeEdit() else { return nil }
        let batch = planPlaylistRequests(requests, allOrNothing: allOrNothing)
        if !allOrNothing {
            if batch.hasChanges { commitPlaylistDraft(batch.draft, actionName: actionName) }
            return batch
        }
        if batch.refused {
            library.showToast(.notice(text: EditPlaylists.refusedMessage(batch.firstSkipReason ?? ""), kind: .warning))
            return nil
        }
        guard batch.hasChanges else { return nil }
        commitPlaylistDraft(batch.draft, actionName: actionName)
        return batch
    }

    /// 요청을 지금 초안에 얹어 계획만 한다(쌓지 않는다). 확인 창이 쌓을 것과 건너뛸 것을 미리 보인다
    func planPlaylistRequests(_ requests: [PlaylistEditRequest], allOrNothing: Bool = false) -> EditPlaylists.Batch {
        EditPlaylists.planning(requests, onto: playlistDraft, rekordbox: rekordboxPlaylists, allOrNothing: allOrNothing, frozen: frozen) {
            UUID().uuidString.lowercased()
        }
    }

    /// 초안을 바꾸고 저장·화면 갱신·되돌리기(⌘Z)를 건다. 되돌리기 대상은 핵심이다(쓰기 잠금이 핵심 대상으로 지운다).
    /// 디스크 초안이 바깥(CLI)에서 바뀌었으면 그 초안을 받고 이 변경은 하지 않는다(옛 초안으로 만든 변경이 CLI 초안을 덮지 않게).
    /// - Parameters:
    ///   - registersUndo: 실행 취소(⌘Z) 단계를 남긴다. 잠긴 동안 눌러 미뤘다가 실행하는 ⌘Z 요청은 남기지 않는다(컨실 S6)
    ///   - freshOrigins: 식별자가 없는 단계 가운데 이을 출처가 있는 자리(⌘Z·⇧⌘Z가 되살린 단계, #295 E6)
    func setPlaylistDraft(_ draft: PlaylistDraft, actionName: String, registersUndo: Bool = true, freshOrigins: [Int: Set<DraftOrigin>] = [:]) {
        guard draft != playlistDraft, !isEditBlocked else { return }
        switch syncExternal() {
        case .adopted:
            library.showToast(.notice(text: String(ui: "바깥에서 바뀐 재생 목록 편집을 다시 읽어 방금 변경은 하지 않았습니다. 다시 해 주세요."), kind: .warning))
            return
        case .failed:
            library.showToast(.notice(text: Self.syncFailureText, kind: .warning))
            return
        case .current, .held:
            guard !playlistDraftNeedsSync else { return }
        }
        // 쓰고 있는 단계는 바꾸지 않는다(되돌리기·다시 하기가 쓰는 단계를 되살리거나 지우지 않게)
        guard preservesFrozen(draft) else { return }
        commitPlaylistDraft(draft, actionName: actionName, registersUndo: registersUndo, freshOrigins: freshOrigins)
    }

    /// 쓰고 있는 단계가 그대로 든 초안인지(얼리지 않았으면 늘 true)
    private func preservesFrozen(_ draft: PlaylistDraft) -> Bool {
        guard let frozen = writeFreeze else { return true }
        let next = Dictionary(draft.steps.compactMap { step in step.id.map { ($0, step) } }, uniquingKeysWith: { first, _ in first })
        return playlistDraft.steps.allSatisfy { step in
            guard let id = step.id, frozen.contains(id) else { return true }
            return next[id] == step
        }
    }

    /// 편집하기 전에 디스크 초안을 맞춘다. 읽지 못하면 알리고 false(옛 메모리 위에 쌓지 않는다)
    private func syncBeforeEdit() -> Bool {
        switch syncExternal() {
        case .current, .adopted, .held:
            // 쓰는 중이라 다시 읽지 못했는데 앞서 읽기가 실패했으면 디스크와 같은지 모른다: 쌓지 않는다
            if playlistDraftNeedsSync {
                library.showToast(.notice(text: Self.syncFailureText, kind: .warning))
                return false
            }
            return true
        case .failed:
            library.showToast(.notice(text: Self.syncFailureText, kind: .warning))
            return false
        }
    }

    static var syncFailureText: String { String(ui: "재생 목록 편집을 읽지 못해 고치지 않았습니다. 잠시 뒤 다시 해 주세요.") }

    private func commitPlaylistDraft(_ draft: PlaylistDraft, actionName: String, registersUndo: Bool = true,
                                     freshOrigins: [Int: Set<DraftOrigin>] = [:]) {
        let before = playlistDraft, beforeLayout = playlistProjection.layout
        guard draft != before else { return }
        let undoManager = registersUndo ? library.undoManager : nil
        // 편집 전 단계의 출처와 막힘(⌘Z가 지금 디스크에 없는 단계를 되살릴 때 출처를 잇고, 새로 막히는지 본다, #295 E6)
        let beforeOrigins = undoManager == nil ? [:] : library.useCases.playlists.stepOrigins()
        let beforeBlocked = Set(zip(before.steps, playlistProjection.blocked).compactMap { $1 == nil ? nil : $0.id })
        playlistDraft = draft
        savePlaylistDraft(freshOrigins: freshOrigins)
        refreshPlaylists()
        guard let undoManager else { return }
        // 쓰는 동안 한 편집도 편집 순간 단계를 건다(#295 E6). 편집 뒤 초안은 저장 뒤 초안(저장소가 준 단계 식별자 포함)이다.
        // 편집 전후 초안과 그때 보이던 목록을 든다: 쓴 뒤에도 지금 목록 위에서 이 편집을 거꾸로 하는 단계를 만든다(R12, `PlaylistUndo`).
        // 되돌릴 수 없게 되면(만들기·지우기·바깥에서 바뀜·일부만 쓰임) 그 단계가 맨 위가 됐을 때 ⌘Z 기록을 비운다(`UndoSteps`, 컨실 2라운드 A)
        let afterOrigins = library.useCases.playlists.stepOrigins()
        let step = PlaylistUndoStep(before: before, after: playlistDraft, beforeLayout: beforeLayout, afterLayout: playlistProjection.layout,
                                    origins: beforeOrigins.merging(afterOrigins) { _, after in after }, beforeBlocked: beforeBlocked)
        library.undoSteps.register(undoManager, kind: .library, canUndo: { [weak self] in self?.canUndo(step) ?? false }) { [weak self] in
            self?.undo(step, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - 저장 뒤 ⌘Z(R12)

    /// 재생 목록 ⌘Z 한 단계: 편집 전후 초안과 그때 보이던 목록(rekordbox + 초안), 두 초안의 단계 출처, 편집 전 투영에서 막혀 있던 단계
    struct PlaylistUndoStep {
        var before: PlaylistDraft
        /// 편집 뒤 초안(저장 뒤 초안: 단계 식별자 포함. 저장하지 못했으면 새 단계의 식별자가 없다)
        var after: PlaylistDraft
        var beforeLayout: PlaylistLayout
        var afterLayout: PlaylistLayout
        /// 편집 전·뒤 초안의 단계 출처(식별자 → 출처). 지금 디스크에 없는 단계를 되살릴 때 잇는다(#295 E6)
        var origins: [UUID: Set<DraftOrigin>] = [:]
        /// 편집 전 초안의 투영에서 막혀 있던 단계(식별자). 되돌린 초안에서 막힌 단계가 이것 밖이면 새로 막힌 것이다
        var beforeBlocked: Set<UUID> = []
    }

    /// 재생 목록 ⌘Z를 어떻게 할지(#295 E6)
    enum UndoPlan: Equatable {
        /// 저장 전 경로: 이 초안으로 바꾼다(편집 전 초안이나 쓴 단계를 뺀 편집 전 초안)
        case draft(PlaylistDraft)
        /// 저장 뒤 경로: 지금 초안에 그 편집을 거꾸로 하는 단계를 더한 초안
        case reverse(PlaylistDraft)
        /// 되돌리지 않는다(일부만 쓰임·지금 초안이 맞지 않음·되돌릴 수 없는 종류·새로 막힘): ⌘Z 기록을 비우고 알린다
        case refused
    }

    /// ⌘Z·⇧⌘Z 한 단계. 쓰는 중이면 누른 요청으로 줄에 두었다가 쓰기가 끝나면 누른 차례대로 실행한다(`LibraryStore.pendingUndo`, 컨실 S6).
    /// 실행 때 판정한다(`undoPlan`): 저장 전 경로면 목표 초안으로(지금 디스크에 없는 단계는 기록한 출처를 잇는다), 저장 뒤 경로면 역편집을 쌓고(자동 저장이
    /// 쓴다), 되돌릴 수 없으면 ⌘Z 기록을 비우고 이유를 알린다
    /// - Parameter registersRedo: 다시 실행(⇧⌘Z) 단계를 남긴다(미뤘다가 실행하는 요청은 남기지 않는다)
    private func undo(_ step: PlaylistUndoStep, actionName: String, registersRedo: Bool = true) {
        if defersUndo {
            if library.undoManager?.isRedoing != true {
                library.pendingUndo.append(ready: { [weak self] in self.map { !$0.defersUndo } ?? true }) { [weak self] in
                    self?.undo(step, actionName: actionName, registersRedo: false)
                }
            }
            return
        }
        switch undoPlan(step) {
        case let .draft(target):
            // 지금 디스크 초안에 없는 단계는 새 식별자·새 판으로 저장하되 출처는 그 단계에 기록한 출처를 잇는다(기록이 없으면 모름을 더한다)
            let present = Set(playlistDraft.stepIDs.compactMap { $0 })
            var restored = target
            var origins: [Int: Set<DraftOrigin>] = [:]
            var ids = restored.stepIDs
            for index in ids.indices {
                guard let id = ids[index], !present.contains(id) else { continue }
                ids[index] = nil
                origins[index] = step.origins[id] ?? [.human, .unknown]
            }
            restored.setStepIDs(ids)
            setPlaylistDraft(restored, actionName: actionName, registersUndo: registersRedo, freshOrigins: origins)
        case let .reverse(reversed):
            setPlaylistDraft(reversed, actionName: actionName, registersUndo: registersRedo)
        case .refused:
            library.refuseUndo()
        }
    }

    /// 그 단계를 지금 되돌릴 수 있는지(미루면 참)
    private func canUndo(_ step: PlaylistUndoStep) -> Bool {
        defersUndo || undoPlan(step) != .refused
    }

    /// ⌘Z 판정(#295 E6). 쓰인 단계 식별자·연결 ID는 단계를 건 뒤 쓰기들의 관문 결과로 모은 것이다(`writtenStepIDs`·`writtenPlaylistIDs`).
    /// 0. 이 편집이 더하거나 고친 단계를 구한다(편집 뒤 초안에 식별자가 없으면 지금 초안의 같은 자리 식별자). 그 가운데 쓰인 것이 있는지 먼저 본다.
    /// 1. 쓰인 것이 없고 지금 초안 == 편집 뒤 초안이면 편집 전 초안으로(합치기·지우기·버리기·이름 A→B→C 모두 바르다).
    /// 2. 아니면 정규화 N(편집 전·뒤 초안에서 쓰인 단계를 빼고 연결 ID를 옮김): 쓰인 것이 없고 N(편집 뒤) == 지금 초안이면 N(편집 전)으로.
    ///    더한 단계가 하나 이상이고 모두 쓰였으면 역편집. 그 밖(일부만 쓰임·불일치)은 되돌리지 않는다.
    /// 3. 적용 전에 결과 초안을 투영해, 편집 전 초안의 투영에서는 막히지 않던 단계가 새로 막히면 되돌리지 않는다
    func undoPlan(_ step: PlaylistUndoStep) -> UndoPlan {
        let current = playlistDraft, written = writtenStepIDs
        let previous = Dictionary(step.before.steps.compactMap { step in step.id.map { ($0, step) } }, uniquingKeysWith: { first, _ in first })
        var changed: Set<UUID> = []
        var unidentified = false
        for (index, after) in step.after.steps.enumerated() {
            guard let id = after.id ?? (current.steps.indices.contains(index) ? current.steps[index].id : nil) else {
                unidentified = true
                continue
            }
            if after.id == nil || previous[id] != after { changed.insert(id) }
        }
        let anyWritten = !changed.isDisjoint(with: written)
        func checked(_ plan: UndoPlan) -> UndoPlan {
            switch plan {
            case let .draft(target), let .reverse(target): newlyBlocked(target, step: step) ? .refused : plan
            case .refused: .refused
            }
        }
        if !anyWritten, current == step.after { return checked(.draft(step.before)) }
        func normalized(_ draft: PlaylistDraft) -> PlaylistDraft {
            var next = draft
            next.removeSteps(at: next.steps.indices.filter { next.steps[$0].id.map(written.contains) ?? false })
            return next.remapped(writtenPlaylistIDs)
        }
        if !anyWritten, normalized(step.after) == current { return checked(.draft(normalized(step.before))) }
        if anyWritten, !unidentified, !changed.isEmpty, changed.isSubset(of: written), let reversed = reversedDraft(step) {
            return checked(.reverse(reversed))
        }
        return .refused
    }

    /// 되돌린 초안을 지금 rekordbox에 얹으면 편집 전 초안의 투영에서는 막히지 않던 단계가 막히는지(지금 초안에서 이미 막힌 단계는 세지 않는다).
    /// 식별자가 없는 단계가 새로 막히면 확인할 수 없어 막힌 것으로 본다
    private func newlyBlocked(_ target: PlaylistDraft, step undoStep: PlaylistUndoStep) -> Bool {
        let contentIDs = Set(library.rowsByID.keys)
        let currentBlocked = Set(zip(playlistDraft.steps, playlistProjection.blocked).compactMap { $1 == nil ? nil : $0.id })
        let projection = target.project(onto: rekordboxPlaylists, contentIDs: contentIDs, frozen: frozen)
        for (step, reason) in zip(target.steps, projection.blocked) where reason != nil {
            guard let id = step.id else { return true }
            if !currentBlocked.contains(id), !undoStep.beforeBlocked.contains(id) { return true }
        }
        return false
    }

    /// 재생 목록 ⌘Z를 지금 실행하지 않고 누른 요청으로 미룰지: 쓰는 중이거나 쓰는 단계를 얼려 두었거나, 쓴 뒤·복원 뒤 새 목록을 아직 읽지 못했다
    /// (옛 목록 위에서 거꾸로 할 단계를 만들거나 얼린 단계에 막혀 요청을 잃지 않게, 컨실 2라운드 F·S14·G12)
    private var defersUndo: Bool {
        isEditBlocked || writeFreeze != nil || library.draftWriteReadPending || !playlistEditsAwaitingReload.isEmpty
    }

    /// 편집 한 번이 초안에 더한 편집: 편집 전 초안이 앞에 그대로 있으면 뒤에 붙은 것, 아니면(합침·정리) 편집 뒤에만 있는 것을 개수까지 센 차집합
    static func addedEdits(before: [PlaylistEdit], after: [PlaylistEdit]) -> [PlaylistEdit] {
        if after.starts(with: before) { return Array(after.dropFirst(before.count)) }
        var remaining = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        return after.filter { edit in
            guard let count = remaining[edit], count > 0 else { return true }
            remaining[edit] = count - 1
            return false
        }
    }

    /// 지금 초안에 그 편집을 거꾸로 하는 단계를 더한 초안. 되돌리지 않는 종류이거나 대상이 그 편집 뒤 모양이 아니면 nil
    private func reversedDraft(_ step: PlaylistUndoStep) -> PlaylistDraft? {
        // 그 편집이 순서를 옮긴 목록(이 단계가 더한 reorder·move의 대상): 순서 역편집은 이 목록을 원래 자리로 옮긴다(컨실 3라운드 G).
        // 같은 목록을 같은 자리로 다시 옮겨 같은 편집이 쌓여도 이 단계가 더한 편집을 구한다: 앞이 같으면 뒤에 붙은 것, 아니면 멀티셋 차집합(4라운드 G23)
        let added = Self.addedEdits(before: step.before.edits, after: step.after.edits)
        let moved = Set(added.compactMap { edit -> String? in
            switch edit {
            case let .reorder(ref, _), let .move(ref, _): ref.layoutID
            default: nil
            }
        })
        guard case let .edits(edits) = PlaylistUndo.reversing(before: step.beforeLayout, after: step.afterLayout,
                                                              current: playlistProjection.layout, ids: writtenPlaylistIDs,
                                                              moved: moved) else { return nil }
        var draft = playlistDraft
        for edit in edits {
            guard (try? draft.append(edit, rekordbox: rekordboxPlaylists, frozen: frozen)) != nil else { return nil }
        }
        return draft
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
            library.showToast(.notice(text: summary.text, kind: summary.warning ? .warning : .success))
            if playlistDraftUnsaved { saveFailureToast = library.toast?.id }
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
            let removed = String(ui: "‘\(item.name)’에서 \(count)곡을 뺐습니다(저장 대기).")
            library.showToast(playlistDraftUnsaved ? .notice(text: removed + " " + Self.playlistSaveFailureText, kind: .warning)
                : .notice(text: removed, kind: .success))
            if playlistDraftUnsaved { saveFailureToast = library.toast?.id }
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
        guard !tracks.isEmpty, !isEditBlocked else { return }
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
        // 쓰는 동안은 얼려 둔 때만 받고, 쓰고 있는 단계는 버리지 않는다
        guard !isEditBlocked else { return }
        var draft = playlistDraft
        if let id {
            draft.discard(playlist: id, rekordbox: rekordboxPlaylists, frozen: frozen)
        } else {
            draft.removeSteps(at: draft.steps.indices.filter { index in !(draft.steps[index].id.map(frozen.contains) ?? false) })
        }
        setPlaylistDraft(draft, actionName: String(ui: "재생 목록 편집 버리기"))
    }

    /// rekordbox에서 바뀌어 쓸 수 없는 편집만 버린다.
    func discardBlockedPlaylistEdits() {
        guard !isEditBlocked else { return }
        var draft = playlistDraft
        draft.discardBlocked(rekordbox: rekordboxPlaylists, contentIDs: Set(library.rowsByID.keys), frozen: frozen)
        setPlaylistDraft(draft, actionName: String(ui: "재생 목록 편집 버리기"))
    }

    // MARK: - 바깥 변경(#260)

    /// 바깥(CLI `djc draft playlist`)에서 바꾼 디스크 초안을 받는다. 받으면 그 앞의 라이브러리 ⌘Z 기록(태그·재생 목록)을 비운다
    /// (옛 초안으로 되돌리면 CLI 초안을 덮는다). 저장하지 못한 메모리 초안(디스크보다 최신), 복원 뒤 다시 쌓을 편집, 쓰는 중이면 받지 않는다.
    /// 내용은 같고 단계 식별자만 다른 디스크 초안은 조용히 받는다(되돌리기 기록은 그대로: 식별자 없는 메모리 단계는 저장마다 새 단계가 되어
    /// 출처가 바뀐다). 읽기에 성공했고 메모리가 디스크와 같아지면 동기화 실패 표시를 푼다.
    /// - Returns: 내용이 바뀐 디스크 초안을 받았으면 true
    @discardableResult
    func adoptExternalDraft(_ disk: PlaylistDraft?) -> Bool {
        defer {
            if let disk, disk == playlistDraft, disk.stepIDs == playlistDraft.stepIDs { playlistDraftNeedsSync = false }
        }
        guard let disk, !playlistDraftUnsaved, playlistEditsAwaitingReload.isEmpty, !library.libraryBusy else { return false }
        let changed = disk != playlistDraft
        guard changed || disk.stepIDs != playlistDraft.stepIDs else { return false }
        playlistDraft = disk
        unsavedStepOrigins = []
        refreshPlaylists()
        if changed { library.clearLibraryUndo() }
        return changed
    }

    /// 편집하기 전에: 디스크 초안이 메모리와 다르면(바깥에서 바뀜) 받는다. 1초마다 하는 바깥 변경 확인보다 먼저 편집해도 CLI 초안을 덮지 않게 한다
    @discardableResult
    func syncExternalPlaylistDraft() -> Bool { syncExternal() == .adopted }

    /// 디스크 초안을 맞춘 결과
    enum ExternalSync: Equatable {
        /// 맞출 것이 없다(디스크와 같거나, 저장하지 못한 편집·복원 뒤 편집이 있어 받지 않는다)
        case current
        /// 바뀐 디스크 초안을 받았다
        case adopted
        /// 쓰는 중이라 다시 읽지 않았다(초안 파일 잠금이 바깥 편집을 막고 있어 앞서 읽은 것과 같다고 본다). 앞서 읽기가 실패했으면 아직 모른다
        case held
        /// 디스크 초안을 읽지 못했다(도장 기록 실패·손상). 디스크 초안을 받을 때까지 재생 목록 저장을 막는다
        case failed
    }

    /// 디스크 초안을 읽어 맞춘다. 읽지 못하면 `failed`로 알리고 디스크 초안을 받을 때까지 저장을 막는다(#402).
    /// 쓰는 동안은 CLI가 초안 파일을 고치지 못하므로(초안 파일 잠금) 다시 읽지 않는다
    func syncExternal() -> ExternalSync {
        guard !playlistDraftUnsaved, playlistEditsAwaitingReload.isEmpty else { return .current }
        guard !library.libraryBusy else { return .held }
        do {
            let adopted = adoptExternalDraft(try library.useCases.playlists.loadDraft())
            return adopted ? .adopted : .current
        } catch {
            AppErrorMessage.log(error)
            playlistDraftNeedsSync = true
            return .failed
        }
    }

    // MARK: - 초안 저장

    /// 메모리 초안을 저장한다. 실패하면 메모리 초안을 그대로 두고 기록해, 쓰기 전에 다시 저장한다.
    /// - Parameter freshOrigins: 식별자가 없는 단계 가운데 이을 출처가 있는 자리(⌘Z·⇧⌘Z가 되살린 단계, #295 E6)
    @discardableResult
    func savePlaylistDraft(freshOrigins: [Int: Set<DraftOrigin>] = [:]) -> Bool {
        // 디스크 초안을 읽지 못해 메모리가 디스크와 같은지 모르면 저장하지 않는다(옛 메모리로 바깥 편집을 덮지 않게). 디스크 초안을 받으면 푼다
        guard !playlistDraftNeedsSync else { return false }
        // 앞서 저장하지 못한 되살린 단계는 그때 기록한 출처를 잇는다(같은 내용의 식별자 없는 단계에 하나씩)
        var origins = freshOrigins, remembered = unsavedStepOrigins
        for (index, step) in playlistDraft.steps.enumerated() where step.id == nil && origins[index] == nil {
            if let match = remembered.firstIndex(where: { $0.step == step }) { origins[index] = remembered.remove(at: match).origins }
        }
        do {
            try library.useCases.playlists.saveDraft(playlistDraft, freshOrigins: origins)
            unsavedStepOrigins = []
            adoptSavedIdentifiers()
            applyPlaylistSave(nil)
            return true
        } catch {
            let steps = playlistDraft.steps
            unsavedStepOrigins = origins.sorted { $0.key < $1.key }.compactMap { index, origins in
                steps.indices.contains(index) ? (steps[index], origins) : nil
            }
            applyPlaylistSave(error)
            return false
        }
    }

    /// 저장이 단계마다 식별자·판을 주었으니 디스크에서 다시 읽어 메모리 단계가 같은 식별자를 갖게 한다. 식별자 없는 메모리 단계는 저장마다
    /// 새 단계·새 판이 되어 낡은 메모리가 기존 단계를 다시 저장하면 출처가 새로 적힌다(출처 세탁). 다시 읽지 못하면 디스크 초안을 받을 때까지 저장을 막는다
    func adoptSavedIdentifiers() {
        do {
            let disk = try library.useCases.playlists.loadDraft()
            if disk == playlistDraft, disk.stepIDs != playlistDraft.stepIDs { playlistDraft = disk }
        } catch {
            AppErrorMessage.log(error)
            playlistDraftNeedsSync = true
        }
    }

    /// 메모리 초안을 저장한 결과(`error`가 nil이면 저장했다)를 표시에 맞춘다. 실패면 쓰기 전에 다시 저장하도록 기록한다(#174)
    func applyPlaylistSave(_ error: (any Error)?) {
        if let error {
            AppErrorMessage.log(error)
            // 메모리에만 남은 초안이라 다른 저장 실패처럼 닫을 때까지 남긴다. 저장하지 못한 동안 고칠 때마다 다시 띄우지 않는다
            // (곡 넣기·빼기 결과는 이 실패를 함께 적는다)
            if !playlistDraftUnsaved { saveFailureToast = library.notify(.notice(text: Self.playlistSaveFailureText, kind: .failure)) }
            playlistDraftUnsaved = true
        } else {
            playlistDraftUnsaved = false
            // 저장했으니 아직 떠 있는 "저장하지 못했다" 알림을 거둔다
            if let saveFailureToast { library.dismissToast(saveFailureToast) }
            saveFailureToast = nil
        }
    }

    /// 쓰기 전에: 저장하지 못한 재생 목록 초안은 다시 저장해 본다. 저장했거나 저장할 것이 없으면 true(아니면 쓰기가 막는다).
    func ensurePlaylistDraftSaved() -> Bool {
        // 디스크 초안을 읽지 못한 채 쓰면 바깥에서 더한 단계를 놓친다: 다시 읽어 보고, 읽지 못했으면 반영 세션이 재생 목록을 쓰기 묶음에서 뺀다
        // (`ReflectionLibraryState.playlistDraftNeedsSync`). 다른 종류 초안을 쓰는 것은 막지 않는다
        if playlistDraftNeedsSync {
            _ = syncExternal()
            if playlistDraftNeedsSync { return true }
        }
        guard playlistDraftUnsaved else { return true }
        return savePlaylistDraft()
    }

    // MARK: - 반영 뒤

    /// 쓴 뒤: 반영 세션이 쓴 편집을 뺀 초안(막힌 편집은 남겨 다음 반영에서 다시 본다)과 새 목록 ID를 이은 연결 기록을 저장했다.
    /// 메모리 초안·연결 기록을 맞추고, 새로 만든 목록의 `new:키`를 새 rekordbox ID로 바꿔 둔다(최근 목록·보고 있는 목록).
    func applyPlaylistWrite(_ cleanup: EditPlaylists.WriteCleanup) {
        let ids = cleanup.ids
        // 새 목록의 실제 ID와 쓴 단계를 기억한다: 저장 뒤 ⌘Z가 그 목록을 찾고, 그 편집의 단계가 쓰였는지 본다(R12, #295 E6)
        writtenPlaylistIDs.merge(ids) { _, new in new }
        writtenPlaylistIDs.merge(cleanup.writtenIDs) { _, new in new }
        writtenStepIDs.formUnion(cleanup.writtenSteps)
        // 쓴 단계를 뺐으니 얼림을 푼다. 쓰기가 끝나 새 사본을 읽을 때까지(`libraryBusy`) 재생 목록 편집은 받지 않는다
        // (옛 사본 위에 더한 단계가 쓴 목록의 기준과 어긋나지 않게)
        thawWrite(refresh: false)
        if let draft = cleanup.draft {
            playlistDraft = draft
            applyPlaylistSave(cleanup.draftError)
        } else if let error = cleanup.draftError {
            // 초안 파일을 읽지 못해 쓴 단계를 빼지 못했다: 메모리 초안은 그대로고 다음 정리 때 다시 한다
            applyPlaylistSave(error)
        }
        if !cleanup.copied.isEmpty {
            library.notify(.notice(text: String(ui: "바깥에서 고친 재생 목록 편집 \(cleanup.copied.count)건은 사본을 백업 폴더에 남기고 저장했습니다."), kind: .warning))
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
        // 복원이 되살린 단계의 출처는 "복원이 되살림"이다: 자동 저장하지 않는 제안이 된다(R8). 그대로 둔 단계는 제 출처를 지킨다
        let previous = playlistDraft.steps
        let restored = library.useCases.restoredPlaylists.restore(edits, onto: playlistDraft, rekordbox: rekordboxPlaylists, imports: playlistImports,
                                                                  importsLoadFailed: playlistImportsLoadFailed)
        if restored.draftError != nil {
            // 저장하지 못했으면 되살린 단계(앞 초안에 없던 식별자 없는 단계)의 출처를 기억해 다음 저장에 넘긴다(#295 리뷰 F5)
            unsavedStepOrigins += restored.draft.steps.filter { $0.id == nil && !previous.contains($0) }.map { ($0, [.restored]) }
        }
        playlistDraft = restored.draft
        applyPlaylistSave(restored.draftError)
        if restored.draftError == nil { adoptSavedIdentifiers() }
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
            library.notify(.notice(text: String(ui: "재생 목록 편집 \(unrestored)건은 편집으로 되살리지 못했습니다."), kind: .warning))
        }
    }
}
