@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 머리 줄 오른쪽 구성(#340): 목록마다 다른 작업 줄을 주 단추 하나 · `…` 메뉴 · 상태 표시 하나로 합친다.
/// 구성은 값(`ListHeaderActions`)이라 단추 이름(고른·전체·개수)·메뉴 항목·상태 표시·막힘 이유를 값 단계에서 본다.
/// 같은 이유는 한 곳에서만 말한다: 곡이 없으면 가운데 안내(`EmptyListNotice`)가, 곡이 있으면 머리 줄이 말한다.
@MainActor
@Suite("머리 줄 오른쪽 구성", .serialized)
struct ListHeaderActionsTests {
    typealias Actions = ListHeaderActions

    private func store() -> LibraryStore {
        LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, stagingSaver: { _ in })
    }

    private func staged(_ name: String, imported: StagedTrack.ImportCheck.Result? = nil) -> StagedTrack {
        var track = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/synthetic/\(name).wav", title: "합성 \(name)", duration: 60,
                                addedOn: "2026-10-10")
        track.importCheck = imported.map { StagedTrack.ImportCheck(result: $0, checkedOn: "2026-10-10") }
        return track
    }

    private func stagedBar(_ tracks: [StagedTrack]) -> (LibraryStore, ListActionBarModel) {
        let store = store()
        store.sidebar = .staged
        store.staging.staged = tracks
        store.staging.rebuildStagedRows()
        return (store, ListActionBarModel(store: store))
    }

    private func commands(_ actions: Actions) -> [Actions.Command] {
        actions.menu.compactMap { if case let .command(command) = $0 { command } else { nil } }
    }

    private func titles(_ actions: Actions) -> [String] {
        actions.menu.compactMap {
            switch $0 {
            case let .command(command): command.title
            case let .histories(menu): menu.title
            case .divider: nil
            }
        }
    }

    private func menuCommand(_ actions: Actions, _ title: String) -> Actions.Command? { commands(actions).first { $0.title == title } }

    // MARK: - 단추 이름: 대상과 개수

    @Test func 바로_넣기_이름은_고른_추가한_곡이_있으면_고른_N곡_없으면_전체_N곡이다() {
        let a = staged("a"), b = staged("b"), c = staged("c")
        let (store, model) = stagedBar([a, b, c])
        #expect(model.actions.primary?.title == "전체 3곡 바로 넣기")
        store.selection = [b.id]
        #expect(model.actions.primary?.title == "고른 1곡 바로 넣기")
        store.selection = [a.id, c.id]
        #expect(model.actions.primary?.title == "고른 2곡 바로 넣기")
        // 목록에 없는 곡만 고른 상태는 고른 추가한 곡이 아니다
        store.selection = ["rekordbox-없는-곡"]
        #expect(model.actions.primary?.title == "전체 3곡 바로 넣기")
        #expect(model.actions.primary?.action == .addStaged)
        #expect(model.actions.primary?.isProminent == true)
    }

    @Test func 쓰기_이름은_고른_곡이면_고른_N곡_아니면_전체_N곡이고_함께_쓰는_건수가_붙는다() {
        #expect(Actions.writeTitle(selected: false, tracks: 12, playlistEdits: 0, histories: 0) == "전체 12곡 저장")
        #expect(Actions.writeTitle(selected: true, tracks: 3, playlistEdits: 0, histories: 0) == "고른 3곡 저장")
        #expect(Actions.writeTitle(selected: false, tracks: 0, playlistEdits: 2, histories: 0) == "전체 0곡 저장 (재생 목록 2건)")
        #expect(Actions.writeTitle(selected: false, tracks: 5, playlistEdits: 0, histories: 4) == "전체 5곡 저장 (재생 기록 4건)")
        #expect(Actions.writeTitle(selected: true, tracks: 3, playlistEdits: 2, histories: 1) == "고른 3곡 저장 (재생 목록 2건 · 재생 기록 1건)")
    }

    @Test func 쓰기_단추는_쓸_것이_하나도_없거나_쓰는_중이거나_비교_창이_열려_있으면_막는다() {
        func pending(tracks: Int = 0, playlistEdits: Int = 0, histories: Int = 0, locks: Actions.Locks = .init()) -> Actions {
            Actions.pending(selected: false, tracks: tracks, playlistEdits: playlistEdits,
                            histories: (0..<histories).map { .init(id: "h\($0)", name: "기록 \($0)") }, unlinkedDrafts: 0,
                            restore: .init(isEnabled: true, help: "복원"), locks: locks)
        }
        #expect(pending().primary?.isEnabled == false)
        // 곡이 없어도 재생 목록 초안·재생 기록만으로 쓸 수 있다
        #expect(pending(playlistEdits: 1).primary?.isEnabled == true)
        #expect(pending(histories: 1).primary?.isEnabled == true)
        #expect(pending(tracks: 1, locks: .init(busy: true)).primary?.isEnabled == false)
        let sheet = pending(tracks: 1, locks: .init(sheetBlocked: true))
        #expect(sheet.primary?.isEnabled == false)
        #expect(sheet.primary?.help == LibraryStore.writesBlockedBySheetReason)
        // 대상을 설명하던 툴팁은 없다: 막히지 않았으면 툴팁이 없다
        #expect(pending(tracks: 1).primary?.help == nil)
        #expect(pending(tracks: 1).primary?.action == .writePending)
        #expect(pending(tracks: 1).primary?.isProminent == true)
    }

    @Test func 쓰기_대기_저장소의_이름은_고른_곡_수를_따른다() async throws {
        let fixture = try HideStreamingTests.fixture()
        let store = await HideStreamingTests.makeStore(fixture)
        let model = ListActionBarModel(store: store)
        let drafted = try #require(store.rows.first(where: { $0.track.id == "1" }))
        let other = try #require(store.rows.first(where: { $0.track.id == "3" }))
        for row in [drafted, other] {
            var draft = TagDraft(track: row.track)
            draft.fields.comment = "시험 편집"
            store.tagDrafts[row.track.uuid] = draft
        }
        store.sidebar = .pending
        #expect(store.displayRows.count == 2)
        #expect(model.actions.primary?.title == "전체 2곡 저장")
        store.selection = [drafted.id]
        #expect(model.actions.primary?.title == "고른 1곡 저장")
        // 이름이 말하는 곡이 실제로 부르는 곡이다
        #expect(model.pendingTargets.map(\.id) == [drafted.id])
        withExtendedLifetime(fixture) {}
    }

    @Test func 쓰기_대기에_보이지_않는_곡의_선택만_남았으면_고른_곡이_없는_것으로_본다() async throws {
        // 다른 목록에서 고른 곡이나 방금 쓴 곡의 선택이 남아도 「고른 0곡 쓰기」로 막히지 않는다(#340 QA F340-1)
        let fixture = try HideStreamingTests.fixture()
        let store = await HideStreamingTests.makeStore(fixture)
        let model = ListActionBarModel(store: store)
        let drafted = try #require(store.rows.first(where: { $0.track.id == "1" }))
        let other = try #require(store.rows.first(where: { $0.track.id == "3" }))
        let elsewhere = try #require(store.rows.first(where: { $0.id != drafted.id && $0.id != other.id }))
        for row in [drafted, other] {
            var draft = TagDraft(track: row.track)
            draft.fields.comment = "시험 편집"
            store.tagDrafts[row.track.uuid] = draft
        }
        store.selection = [elsewhere.id]
        store.sidebar = .pending
        #expect(!store.displayRows.contains { $0.id == elsewhere.id })
        #expect(model.actions.primary?.title == "전체 2곡 저장")
        #expect(model.actions.primary?.isEnabled == true)
        #expect(Set(model.pendingTargets.map(\.id)) == [drafted.id, other.id])
        withExtendedLifetime(fixture) {}
    }

    @Test func 검색이나_필터로_좁힌_쓰기_대기는_고른_곡이_없으면_보이는_N곡이다() {
        // 고른 곡이 없으면 단추는 보이는 곡만 쓴다(메뉴·상태 줄의 쓰기는 쓰기 대기 전체). 좁혔을 때 「전체」라고 하지 않는다
        #expect(Actions.writeTitle(selected: false, narrowed: true, tracks: 4, playlistEdits: 0, histories: 0) == "보이는 4곡 저장")
        #expect(Actions.writeTitle(selected: false, narrowed: true, tracks: 4, playlistEdits: 1, histories: 0) == "보이는 4곡 저장 (재생 목록 1건)")
        // 고른 곡이 있으면 좁혔어도 고른 곡이다
        #expect(Actions.writeTitle(selected: true, narrowed: true, tracks: 2, playlistEdits: 0, histories: 0) == "고른 2곡 저장")
        let narrowed = Actions.pending(selected: false, narrowed: true, tracks: 4, playlistEdits: 1, histories: [], unlinkedDrafts: 0,
                                       restore: .init(isEnabled: true, help: "복원"), locks: .init())
        #expect(narrowed.primary?.compactTitle == "보이는 4곡 저장")
    }

    @Test func 쓰기_대기에서_검색으로_좁히면_이름이_보이는_곡_수를_말하고_그_곡을_쓴다() async throws {
        let fixture = try HideStreamingTests.fixture()
        let store = await HideStreamingTests.makeStore(fixture)
        let model = ListActionBarModel(store: store)
        let drafted = try #require(store.rows.first(where: { $0.track.id == "1" }))
        let other = try #require(store.rows.first(where: { $0.track.id == "3" }))
        for row in [drafted, other] {
            var draft = TagDraft(track: row.track)
            draft.fields.comment = "시험 편집"
            store.tagDrafts[row.track.uuid] = draft
        }
        store.sidebar = .pending
        store.search = drafted.track.title
        #expect(store.displayRows.map(\.id) == [drafted.id])
        #expect(model.actions.primary?.title == "보이는 1곡 저장")
        #expect(model.pendingTargets.map(\.id) == [drafted.id])
        store.search = ""
        #expect(model.actions.primary?.title == "전체 2곡 저장")
        withExtendedLifetime(fixture) {}
    }

    // MARK: - `…` 메뉴

    @Test func 추가한_곡_메뉴는_곡_추가_제거_XML_만들기를_담고_정리는_확인된_곡이_있을_때만_개수와_함께_붙는다() {
        let a = staged("a")
        let plain = Actions.staged(selected: false, count: 1, canRemove: false, canExportXML: true, importedCount: 0, locks: .init())
        #expect(titles(plain) == ["곡 추가…", "추가 목록에서 제거", "XML 만들기"])
        #expect(menuCommand(plain, "추가 목록에서 제거")?.isEnabled == false)
        let imported = Actions.staged(selected: true, count: 1, canRemove: true, canExportXML: true, importedCount: 2, locks: .init())
        #expect(titles(imported) == ["곡 추가…", "추가 목록에서 제거", "XML 만들기", "가져온 곡 정리 (2곡)"])
        #expect(menuCommand(imported, "추가 목록에서 제거")?.isEnabled == true)
        // 라벨을 되풀이하던 툴팁은 없다. 남는 것은 결과 범위 하나(파일은 지우지 않는다)
        #expect(menuCommand(imported, "XML 만들기")?.help == nil)
        #expect(menuCommand(imported, "가져온 곡 정리 (2곡)")?.help == nil)
        #expect(menuCommand(imported, "추가 목록에서 제거")?.help == "파일은 지우지 않습니다.")
        let (_, model) = stagedBar([a])
        #expect(titles(model.actions) == ["곡 추가…", "추가 목록에서 제거", "XML 만들기"])
        #expect(menuCommand(model.actions, "XML 만들기")?.isEnabled == true)
    }

    @Test func 가져온_곡_정리의_개수는_rekordbox에_들어간_것이_확인된_곡_수다() {
        let (_, model) = stagedBar([staged("m", imported: .matched), staged("r", imported: .reanalyzed), staged("p", imported: .pending), staged("n")])
        #expect(model.importedStagedCount == 2)
        #expect(titles(model.actions).last == "가져온 곡 정리 (2곡)")
    }

    @Test func 쓰기_대기_메뉴는_재생_기록_재생_목록_초안_XML_복원을_상황에_맞게_담는다() {
        let histories = [Actions.HistoryMenu.Entry(id: "h1", name: "기록 가"), .init(id: "h2", name: "기록 나")]
        let full = Actions.pending(selected: false, tracks: 2, playlistEdits: 3, histories: histories, unlinkedDrafts: 0,
                                   restore: .init(isEnabled: true, help: "라이브러리 전체를 마지막 저장 전 백업으로 복원합니다."), locks: .init())
        #expect(titles(full) == ["재생 기록 2건", "재생 목록 편집 버리기", "XML 만들기", "저장 전으로 복원…"])
        guard case let .histories(menu) = full.menu.first else { Issue.record("재생 기록 하위 메뉴가 먼저 와야 한다"); return }
        #expect(menu.entries.map(\.name) == ["기록 가", "기록 나"])
        #expect(menu.excludeAll.title == "모두 rekordbox 저장 대기에서 빼기")
        #expect(menu.excludeAll.action == .excludePendingHistories)
        // 재생 기록 메뉴의 툴팁(라벨을 되풀이하며 틀린 말을 하던 "USB 재생 기록")은 없다
        #expect(menu.excludeAll.help == nil)
        #expect(menuCommand(full, "재생 목록 편집 버리기")?.help == "⌘Z로 되돌릴 수 있습니다.")
        #expect(menuCommand(full, "XML 만들기")?.help == nil)
        // 복원은 결과 범위를 툴팁으로 남기고, 늘 확인 창이 뜨는 항목이라 …가 붙는다
        #expect(menuCommand(full, "저장 전으로 복원…")?.help == "라이브러리 전체를 마지막 저장 전 백업으로 복원합니다.")
        #expect(menuCommand(full, "저장 전으로 복원…")?.action == .restoreLatest)

        let bare = Actions.pending(selected: false, tracks: 2, playlistEdits: 0, histories: [], unlinkedDrafts: 0,
                                   restore: .init(isEnabled: false, help: "복원할 백업이 없습니다."), locks: .init())
        #expect(titles(bare) == ["XML 만들기", "저장 전으로 복원…"])
        #expect(menuCommand(bare, "저장 전으로 복원…")?.isEnabled == false)
        #expect(menuCommand(bare, "저장 전으로 복원…")?.help == "복원할 백업이 없습니다.")

        let frozen = Actions.pending(selected: false, tracks: 2, playlistEdits: 3, histories: histories, unlinkedDrafts: 0,
                                     restore: .init(isEnabled: true, help: ""), locks: .init(busy: true, editsFrozen: true))
        #expect(menuCommand(frozen, "재생 목록 편집 버리기")?.isEnabled == false)
        guard case let .histories(frozenMenu) = frozen.menu.first else { Issue.record("재생 기록 하위 메뉴"); return }
        #expect(frozenMenu.excludeAll.isEnabled == false)
        #expect(menuCommand(frozen, "저장 전으로 복원…")?.isEnabled == false)
        // XML 만들기는 곡이 없을 때만 막는다
        let noTracks = Actions.pending(selected: false, tracks: 0, playlistEdits: 1, histories: [], unlinkedDrafts: 0,
                                       restore: .init(isEnabled: true, help: ""), locks: .init())
        #expect(menuCommand(noTracks, "XML 만들기")?.isEnabled == false)
    }

    // MARK: - 상태 표시 하나

    @Test func 쓰기_대기는_연결되지_않은_초안이_있으면_그_수와_보기_단추를_상태로_보인다() {
        let none = Actions.pending(selected: false, tracks: 1, playlistEdits: 0, histories: [], unlinkedDrafts: 0,
                                   restore: .init(isEnabled: true, help: ""), locks: .init())
        #expect(none.status == nil)
        let some = Actions.pending(selected: false, tracks: 1, playlistEdits: 0, histories: [], unlinkedDrafts: 4,
                                   restore: .init(isEnabled: true, help: ""), locks: .init())
        #expect(some.status?.kind == .hint)
        #expect(some.status?.symbol == "questionmark.folder")
        #expect(some.status?.title == "연결되지 않은 편집 4곡")
        #expect(some.status?.command?.title == "보기…")
        #expect(some.status?.command?.action == .openUnlinkedDrafts)
        let busy = Actions.pending(selected: false, tracks: 1, playlistEdits: 0, histories: [], unlinkedDrafts: 4,
                                   restore: .init(isEnabled: true, help: ""), locks: .init(busy: true))
        #expect(busy.status?.kind == .progress)
        #expect(busy.status?.command == nil)
        #expect(some.status?.command?.isEnabled == true && busy.status?.command?.isEnabled != true)
    }

    @Test func 추가한_곡은_쓰는_중이면_진행_표시를_상태로_보이고_단추_이름은_그대로다() {
        let idle = Actions.staged(selected: false, count: 2, canRemove: false, canExportXML: true, importedCount: 0, locks: .init())
        let busy = Actions.staged(selected: false, count: 2, canRemove: false, canExportXML: true, importedCount: 0, locks: .init(busy: true))
        #expect(idle.status == nil)
        #expect(busy.status?.kind == .progress)
        #expect(busy.primary?.title == idle.primary?.title)
        #expect(busy.primary?.isEnabled == false)
    }

    @Test func Music_목록은_구성을_Music에서_바꾼다는_잠금을_보이고_연결하지_못한_곡이_있으면_경고가_대신한다() {
        let locked = Actions.music(unavailable: 0)
        #expect(locked.status?.kind == .readOnly)
        #expect(locked.status?.title == "목록 구성은 Music에서 바꿉니다")
        #expect(locked.primary == nil && locked.menu.isEmpty)
        let warned = Actions.music(unavailable: 3)
        #expect(warned.status?.kind == .warning)
        #expect(warned.status?.title == "연결하지 못한 3곡은 rekordbox 컬렉션 등록과 파일 위치를 확인하세요")
    }

    @Test func 계산한_목록은_잠금_표시와_ⓘ_하나이고_계산하지_못한_목록은_머리_줄이_아니라_가운데_안내가_말한다() {
        let computed = Actions.smartPlaylist(unsupported: false)
        #expect(computed.status?.kind == .readOnly)
        #expect(computed.status?.title == "읽기 전용")
        #expect(computed.status?.info == ["DJCrate가 조건으로 계산한 목록입니다. rekordbox 화면과 곡이 다를 수 있습니다."])
        #expect(computed.primary == nil && computed.menu.isEmpty)
        #expect(Actions.smartPlaylist(unsupported: true) == .none)
    }

    @Test func 재생_목록은_막힌_초안이면_경고와_비교_단추_초안이면_표시와_버리기_단추를_보인다() {
        let blocked = Actions.playlist(id: "P", isDraft: true, blockedReason: "곡이 사라졌습니다", hiddenStreaming: nil, canCompare: true, locks: .init())
        #expect(blocked.status?.kind == .warning)
        #expect(blocked.status?.title == "이 목록의 편집 일부를 저장할 수 없습니다: 곡이 사라졌습니다")
        #expect(blocked.primary?.title == "현재 목록 비교…")
        #expect(blocked.primary?.action == .comparePlaylist("P"))
        #expect(blocked.primary?.isEnabled == true)
        #expect(Actions.playlist(id: "P", isDraft: true, blockedReason: "x", hiddenStreaming: nil, canCompare: false, locks: .init()).primary?.isEnabled == false)

        let draft = Actions.playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: nil, canCompare: true, locks: .init())
        #expect(draft.status?.kind == .draft)
        #expect(draft.status?.title == "저장 전 목록 편집")
        #expect(draft.primary?.title == "이 목록의 편집 버리기")
        #expect(draft.primary?.action == .discardPlaylistDraft("P"))
        #expect(draft.primary?.help == "⌘Z로 되돌릴 수 있습니다.")
        let frozen = Actions.playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: nil, canCompare: true, locks: .init(busy: true, editsFrozen: true))
        #expect(frozen.primary?.isEnabled == false)

        #expect(Actions.playlist(id: "P", isDraft: false, blockedReason: nil, hiddenStreaming: nil, canCompare: true, locks: .init()) == .none)
    }

    @Test func 숨긴_스트리밍_곡은_N곡_숨김과_보이기_단추를_상태로_보이고_초안_표시보다_앞선다() {
        let hidden = Actions.playlist(id: "P", isDraft: false, blockedReason: nil, hiddenStreaming: 2, canCompare: true, locks: .init())
        #expect(hidden.status?.kind == .hidden)
        #expect(hidden.status?.title == "스트리밍 2곡 숨김")
        #expect(hidden.status?.command?.title == "보이기")
        #expect(hidden.status?.command?.action == .showStreaming)
        #expect(hidden.primary == nil)
        // 초안이 있어도 한 화면에 상태는 하나다: 순서를 못 바꾸는 이유(숨김)가 초안 표시보다 앞선다. 초안 버리기 단추는 그대로 있다
        let both = Actions.playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: 2, canCompare: true, locks: .init())
        #expect(both.status?.kind == .hidden)
        #expect(both.primary?.title == "이 목록의 편집 버리기")
        // 막힌 초안은 할 일이 있는 막힘이라 숨김보다 앞선다
        let blocked = Actions.playlist(id: "P", isDraft: true, blockedReason: "x", hiddenStreaming: 2, canCompare: true, locks: .init())
        #expect(blocked.status?.kind == .warning)
    }

    @Test func USB는_편집을_받으면_반영_단추와_쓰기_대기_메뉴_읽기만_하면_잠금_표시다() {
        let editing = Actions.usb(volumeKey: "합성", editing: (updatable: 3, blockReason: nil, draftCount: 5), playlistMismatch: false)
        #expect(editing.primary?.title == "로컬 변경을 USB에 쓰기 (3곡)")
        #expect(editing.primary?.action == .refreshUsbLocalChanges("합성"))
        #expect(editing.primary?.isEnabled == true)
        #expect(titles(editing) == ["USB 쓰기 대기 (5건)"])
        #expect(menuCommand(editing, "USB 쓰기 대기 (5건)")?.action == .showUsbPending("합성"))
        #expect(editing.status == nil, "USB에 쓰는 때를 되풀이하던 캡션은 없다(쓰기 대기 건수가 말한다)")

        let zero = Actions.usb(volumeKey: "합성", editing: (updatable: 0, blockReason: nil, draftCount: 0), playlistMismatch: false)
        #expect(zero.primary?.isEnabled == false)
        let blocked = Actions.usb(volumeKey: "합성", editing: (updatable: 2, blockReason: "실물 USB는 동의가 필요합니다", draftCount: 0), playlistMismatch: false)
        #expect(blocked.primary?.isEnabled == false)
        #expect(blocked.primary?.help == "실물 USB는 동의가 필요합니다")

        let readOnly = Actions.usb(volumeKey: "합성", editing: nil, playlistMismatch: false)
        #expect(readOnly.status?.kind == .readOnly)
        #expect(readOnly.status?.title == "USB의 곡·재생 목록은 읽기만 합니다")
        #expect(readOnly.primary == nil && readOnly.menu.isEmpty)
        // 두 형식의 재생 목록이 다르면 경고가 읽기 전용 표시보다 앞선다
        let mismatch = Actions.usb(volumeKey: "합성", editing: nil, playlistMismatch: true)
        #expect(mismatch.status?.kind == .warning)
        #expect(mismatch.status?.title == "두 형식의 재생 목록 내용이 다릅니다")
    }

    @Test func 파일_없음은_폴더에서_찾기가_주_단추이고_다시_확인은_메뉴이며_상태는_하나만_보인다() {
        let volume = Actions.MissingVolume(name: "공연용 SSD", trackCount: 12)
        let plain = Actions.missingFiles(volumes: [], checking: false, hasMissing: true, canFindInFolder: true)
        #expect(plain.primary?.title == "폴더에서 찾기…")
        #expect(plain.primary?.action == .findInFolder)
        #expect(plain.primary?.isEnabled == true)
        #expect(titles(plain) == ["다시 확인"])
        #expect(menuCommand(plain, "다시 확인")?.help == nil, "라벨을 되풀이하던 툴팁은 없다")
        #expect(plain.status?.kind == .hint)
        #expect(plain.status?.title == "옮긴 음원은 rekordbox의 Relocate로 다시 연결하세요")

        let volumes = Actions.missingFiles(volumes: [volume, .init(name: "백업 디스크", trackCount: 3)], checking: false, hasMissing: true, canFindInFolder: true)
        #expect(volumes.status?.kind == .warning)
        #expect(volumes.status?.title == "연결되지 않은 외장 디스크 2개")
        #expect(volumes.status?.detail == "공연용 SSD(12곡), 백업 디스크(3곡)")

        let checking = Actions.missingFiles(volumes: [volume], checking: true, hasMissing: true, canFindInFolder: true)
        #expect(checking.status?.kind == .progress)
        #expect(checking.status?.title == "파일을 확인하는 중…")
        #expect(menuCommand(checking, "다시 확인")?.isEnabled == false)
        #expect(checking.primary?.isEnabled == false)

        // 파일 없는 곡이 없으면 찾을 것도 없고, 다시 연결하라는 단서도 붙이지 않는다
        let clean = Actions.missingFiles(volumes: [], checking: false, hasMissing: false, canFindInFolder: true)
        #expect(clean.primary?.isEnabled == false)
        #expect(clean.status == nil)
        #expect(Actions.missingFiles(volumes: [], checking: false, hasMissing: true, canFindInFolder: false).primary?.isEnabled == false)
    }

    @Test func 상태_표시는_아이콘만_남는_폭에서도_이름을_알릴_아이콘이_있다() {
        // 아이콘이 없으면 글을 접을 때 상태가 통째로 사라진다. 진행 표시만 아이콘 대신 돌아가는 표시다
        let histories = [Actions.HistoryMenu.Entry(id: "h", name: "기록")]
        let restore = Actions.Restore(isEnabled: true, help: "")
        let statuses: [Actions.Status?] = [
            Actions.pending(selected: false, tracks: 1, playlistEdits: 0, histories: histories, unlinkedDrafts: 3, restore: restore, locks: .init()).status,
            Actions.pending(selected: false, tracks: 1, playlistEdits: 0, histories: histories, unlinkedDrafts: 0, restore: restore, locks: .init(busy: true)).status,
            Actions.music(unavailable: 0).status, Actions.music(unavailable: 2).status,
            Actions.smartPlaylist(unsupported: false).status,
            Actions.playlist(id: "P", isDraft: true, blockedReason: "x", hiddenStreaming: nil, canCompare: true, locks: .init()).status,
            Actions.playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: 2, canCompare: true, locks: .init()).status,
            Actions.playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: nil, canCompare: true, locks: .init()).status,
            Actions.usb(volumeKey: "V", editing: nil, playlistMismatch: false).status,
            Actions.usb(volumeKey: "V", editing: nil, playlistMismatch: true).status,
            Actions.missingFiles(volumes: [], checking: true, hasMissing: true, canFindInFolder: true).status,
            Actions.missingFiles(volumes: [.init(name: "SSD", trackCount: 1)], checking: false, hasMissing: true, canFindInFolder: true).status,
            // 단서(.hint)에도 아이콘이 있다: 파일 없는 곡이 있을 때 「옮긴 음원은 …Relocate로」
            Actions.missingFiles(volumes: [], checking: false, hasMissing: true, canFindInFolder: true).status,
        ]
        for status in statuses.compactMap({ $0 }) {
            #expect(status.kind == .progress || status.iconName != nil, Comment(rawValue: "아이콘 없음: \(status.title)"))
        }
        #expect(statuses.compactMap { $0 }.count == statuses.count, "모두 상태가 있는 경우만 골랐다")
    }

    @Test func 연결되지_않은_외장_디스크가_하나면_이름을_보이고_여럿이면_개수를_보인다() {
        let one = Actions.missingFiles(volumes: [.init(name: "공연용 SSD", trackCount: 12)], checking: false, hasMissing: true, canFindInFolder: true)
        #expect(one.status?.title == "연결되지 않은 외장 디스크: 공연용 SSD")
        #expect(one.status?.detail == "공연용 SSD(12곡)")
    }

    @Test func 쓰기_대기_저장소의_연결되지_않은_초안_수는_상태_표시가_읽는다() {
        let store = store()
        store.sidebar = .pending
        let model = ListActionBarModel(store: store)
        #expect(model.actions.status == nil)
        store.unlinkedDraftUUIDs = ["a", "b", "c"]
        #expect(model.actions.status?.title == "연결되지 않은 편집 3곡")
        #expect(model.actions.status?.command?.action == .openUnlinkedDrafts)
    }

    @Test func BPM_없는_곡은_그리드_추정_단추_하나뿐이고_되풀이하던_캡션이_없다() {
        let grid = Actions.gridEstimate(count: 7, blocked: false)
        #expect(grid.primary?.title == "이 목록 그리드 추정 (7곡)")
        #expect(grid.primary?.action == .estimateGrids)
        #expect(grid.primary?.isEnabled == true)
        #expect(grid.primary?.help == "rekordbox가 분석하지 않은 곡의 BPM·박 위치를 추정해 그리드 편집으로 보관합니다.")
        #expect(grid.menu.isEmpty && grid.status == nil)
        #expect(Actions.gridEstimate(count: 0, blocked: true).primary?.isEnabled == false)
    }

    // MARK: - 사이드바 항목에 따른 구성

    @Test func 일반_목록과_USB_쓰기_대기에는_구성이_없다() {
        let store = store()
        let model = ListActionBarModel(store: store)
        #expect(model.actions == .none)
        store.sidebar = .usb(.pending(volumeKey: "합성"))
        #expect(model.actions == .none)
        store.sidebar = .duplicates
        #expect(model.actions == .none)
    }

    @Test func 모든_단추의_툴팁은_75자_안이고_대상을_설명하지_않는다() {
        let histories = [Actions.HistoryMenu.Entry(id: "h", name: "기록")]
        let all: [Actions] = [
            .staged(selected: true, count: 2, canRemove: true, canExportXML: true, importedCount: 1, locks: .init(sheetBlocked: true)),
            .staged(selected: false, count: 2, canRemove: true, canExportXML: true, importedCount: 1, locks: .init()),
            .pending(selected: true, tracks: 2, playlistEdits: 1, histories: histories, unlinkedDrafts: 1,
                     restore: .init(isEnabled: true, help: "라이브러리 전체를 마지막 저장 전 백업으로 복원합니다."), locks: .init()),
            .playlist(id: "P", isDraft: true, blockedReason: nil, hiddenStreaming: 1, canCompare: true, locks: .init()),
            .usb(volumeKey: "합성", editing: (updatable: 1, blockReason: nil, draftCount: 1), playlistMismatch: false),
            .missingFiles(volumes: [], checking: false, hasMissing: true, canFindInFolder: true),
            .gridEstimate(count: 1, blocked: false),
        ]
        for actions in all {
            var helps = [actions.primary?.help, actions.status?.command?.help]
            helps += commands(actions).map(\.help)
            for help in helps.compactMap({ $0 }) {
                #expect(help.count <= 75, Comment(rawValue: help))
                #expect(!help.contains("없으면"), "고른 곡(없으면 목록 전체)처럼 대상을 풀어 쓰던 툴팁은 없다: \(help)")
            }
        }
    }

    // MARK: - [보이기]: 숨긴 스트리밍 곡을 그 자리에서 푼다

    @Test func 보이기를_누르면_숨기기_설정이_꺼지고_곡이_돌아온다() async throws {
        let fixture = try HideStreamingTests.fixture()
        let store = await HideStreamingTests.makeStore(fixture, hideStreaming: true)
        let model = ListActionBarModel(store: store)
        store.sidebar = .playlist("P")
        // 숨긴 줄이 있고 보이는 줄도 있으면 머리 줄이 말한다
        #expect(HideStreamingTests.ids(store) == ["1", "3", "5"])
        #expect(store.streamingHiddenInView == 2)
        #expect(model.actions.status?.kind == .hidden)
        #expect(model.actions.status?.title == "스트리밍 2곡 숨김")
        let show = try #require(model.actions.status?.command)
        #expect(show.title == "보이기" && show.isEnabled)

        model.perform(show.action, reflection: nil, window: nil)
        #expect(!store.hideStreaming)
        #expect(HideStreamingTests.ids(store) == ["1", "2", "3", "4", "5"])
        #expect(store.streamingHiddenInView == 0)
        #expect(model.actions.status == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test func 스트리밍_곡뿐인_목록은_머리_줄이_아니라_가운데_안내가_보이기를_맡고_같은_입구로_푼다() async throws {
        let fixture = try HideStreamingTests.fixture()
        let store = await HideStreamingTests.makeStore(fixture, hideStreaming: true)
        let model = ListActionBarModel(store: store)
        store.sidebar = .playlist("Q")
        #expect(store.displayRows.isEmpty && store.streamingHiddenInView == 2)
        #expect(model.actions.status == nil, "곡이 없으면 가운데 안내가 말한다")
        let notice = EmptyListNotice.resolve(store: store)
        guard case let .message(message) = notice else { Issue.record("가운데 안내가 와야 한다: \(notice)"); return }
        #expect(message.title == "이 목록은 스트리밍 곡뿐입니다")
        #expect(message.description == nil, "설정에서 끄세요라고 글로 안내하지 않는다")
        #expect(message.action == .init(title: "스트리밍 곡 보이기", kind: .showStreaming))
        message.action?.perform(store: store)
        #expect(!store.hideStreaming)
        #expect(HideStreamingTests.ids(store) == ["2", "4"])
        withExtendedLifetime(fixture) {}
    }

    // MARK: - 같은 이유는 한 곳에서: 가운데 안내

    private func notice(search: String = "", smartSummary: String? = nil, hasSmartResult: Bool = false, streamingHidden: Int = 0,
                        sidebar: SidebarItem = .filter(.all), pendingHistories: Int = 0, isUsb: Bool = false) -> EmptyListNotice.Message {
        let resolved = EmptyListNotice.resolve(guide: nil, smartSummary: smartSummary, hasSmartResult: hasSmartResult,
                                               streamingHidden: streamingHidden, sidebar: sidebar, pendingHistories: pendingHistories,
                                               isUsbSelection: isUsb)
        guard case let .message(message) = resolved else { fatalError("가운데 안내가 와야 한다") }
        return message
    }

    @Test func 계산한_목록의_빈_안내는_제목뿐이고_계산_주의는_머리_줄_ⓘ가_말한다() {
        let message = notice(hasSmartResult: true)
        #expect(message.title == "조건에 맞는 곡이 없습니다")
        #expect(message.description == nil)
    }

    @Test func 계산하지_못한_목록은_가운데_안내가_조건을_말하고_머리_줄은_말하지_않는다() {
        let message = notice(smartSummary: "별 3개 이상 조건", hasSmartResult: true)
        #expect(message.title == "조건을 계산하지 못했습니다")
        #expect(message.description == "별 3개 이상 조건. rekordbox에서 이 목록을 확인하세요.")
        #expect(Actions.smartPlaylist(unsupported: true).status == nil)
    }

    @Test func 계산하지_못한_목록은_검색어가_남아_있어도_가운데_안내가_조건을_말한다() {
        // 계산하지 못한 목록은 검색어와 상관없이 곡이 없고 머리 줄도 말하지 않으니, 이 안내가 그 사실을 말하는 유일한 자리다
        let guide = NoResultsGuide(search: "x", isFiltered: false, hasUnwrittenEdits: false)
        let resolved = EmptyListNotice.resolve(guide: guide, smartSummary: "별 3개 이상 조건", hasSmartResult: true, streamingHidden: 0,
                                               sidebar: .playlist("1"), pendingHistories: 0, isUsbSelection: false)
        guard case let .message(message) = resolved else {
            Issue.record("검색 안내가 아니라 계산하지 못한 안내가 와야 한다")
            return
        }
        #expect(message.title == "조건을 계산하지 못했습니다")
    }

    @Test func 쓰기_대기에_재생_기록만_있으면_건수는_위_쓰기_단추_이름에_맡기고_한_줄만_안내한다() {
        let message = notice(sidebar: .pending, pendingHistories: 3)
        #expect(message.title == "저장할 곡 편집이 없습니다")
        #expect(message.description == "위 저장 단추로 재생 기록을 rekordbox에 넣습니다.")
        #expect(!(message.description ?? "").contains("3"))
    }

    @Test func 추가한_곡이_없으면_끌어다_놓으라는_한_줄과_곡_추가_단추다() {
        let message = notice(sidebar: .staged)
        #expect(message.title == "추가한 곡이 없습니다")
        #expect(message.description == "음원 파일을 끌어다 놓으세요.")
        #expect(message.action == .init(title: "곡 추가…", kind: .addFiles))
    }

    @Test func 그_밖의_빈_목록은_다른_목록을_고르라는_한_줄이다() {
        let message = notice()
        #expect(message.title == "표시할 곡이 없습니다")
        #expect(message.description == "다른 목록을 고르거나 rekordbox와 동기화하세요.")
        #expect(message.action == nil)
    }
}
