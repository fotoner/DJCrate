import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Observation
import Testing

/// 사이드바에서 재생 목록·폴더를 여러 개 골라 한꺼번에 지우고 옮긴다(#261).
/// 고르기 규칙(마지막에 고른 목록을 보임, 재생 목록끼리만 여럿)과 고른 항목 → 묶음 요청 변환(사이드바 순서, 폴더 안 항목 빼기,
/// 막힌 항목 건너뛰기)을 화면 모델(`PlaylistSidebarModel`)로 본다. 묶음은 `applyPlaylistRequests` 한 번이라 ⌘Z 한 번에 되돌린다.
@MainActor
@Suite("사이드바 여러 개 고르기")
struct SidebarMultiSelectTests {
    typealias Item = PlaylistLayout.Item
    let store: LibraryStore
    let model: PlaylistSidebarModel
    let prompter = ScriptedPrompter()
    let undo = UndoManager()

    static func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false, smart: Bool = false,
                     tracks: [String] = []) -> Item {
        Item(id: id, name: name, parentID: parent, isFolder: folder, isSmart: smart,
             entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    /// 사이드바 순서: F(폴더: A · G(폴더: H)) · B · S(인텔리전트) · D · T(폴더)
    init() {
        store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("sidebar-multi"), persist: false),
                                  activityLog: ActivityLog(), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        store.undoManager = undo
        store.phase = .loaded
        for id in ["1", "2", "3"] { store.rowsByID[id] = PlaylistEditingTests.row(id) }
        store.playlists.rekordboxPlaylists = PlaylistLayout([
            (Self.item("F", "폴더", folder: true), 1),
            (Self.item("A", "가", parent: "F", tracks: ["1", "2"]), 1),
            (Self.item("G", "안 폴더", parent: "F", folder: true), 2),
            (Self.item("H", "하", parent: "G", tracks: ["3"]), 1),
            (Self.item("B", "나", tracks: ["3"]), 2),
            (Self.item("S", "스마트", smart: true), 3),
            (Self.item("D", "다"), 4),
            (Self.item("T", "옮길 곳", folder: true), 5),
        ])
        store.playlists.refreshPlaylists()
        model = PlaylistSidebarModel(playlists: store.playlists)
        model.prompter = prompter
    }

    private func playlists(_ ids: String...) -> Set<SidebarItem> { Set(ids.map { SidebarItem.playlist($0) }) }
    private var layout: PlaylistLayout { store.playlists.playlistProjection.layout }

    // MARK: - 고르기

    @Test func 더해_고르면_모두_강조하고_마지막에_고른_목록을_보인다() {
        model.select(playlists("A"))
        model.select(playlists("A", "D"))
        #expect(model.selection == playlists("A", "D") && store.sidebar == .playlist("D"))
        model.select(playlists("A", "B", "D"))
        #expect(model.selection == playlists("A", "B", "D") && store.sidebar == .playlist("B"))
    }

    @Test func 범위로_고르면_누른_끝의_목록을_보인다() {
        model.select(playlists("B"))
        // 아래로 넓히면 맨 아래, 위로 넓히면 맨 위가 누른 줄이다
        model.select(playlists("B", "S", "D", "T"))
        #expect(store.sidebar == .playlist("T"))
        model.select(playlists("T"))
        model.select(playlists("S", "D", "T"))
        #expect(store.sidebar == .playlist("S") && model.selection == playlists("S", "D", "T"))
    }

    @Test func 범위를_줄이면_누른_끝의_목록을_보인다() {
        // D를 누른 뒤 B를 ⇧ 클릭(위로 넓힘), 이어 S를 ⇧ 클릭(줄임): 고정점 D가 아니라 누른 S를 보인다
        model.select(playlists("D"))
        model.select(playlists("B", "S", "D"))
        #expect(store.sidebar == .playlist("B"))
        model.select(playlists("S", "D"))
        #expect(store.sidebar == .playlist("S") && model.selection == playlists("S", "D"))
        // 아래로 넓힌 뒤 줄여도 누른 끝이다
        model.select(playlists("B"))
        model.select(playlists("B", "S", "D"))
        model.select(playlists("B", "S"))
        #expect(store.sidebar == .playlist("S"))
    }

    @Test func 보던_목록을_빼면_남은_것_중_그쪽_끝을_보인다() {
        model.select(playlists("A"))
        model.select(playlists("A", "B"))
        model.select(playlists("A", "B", "D"))
        model.select(playlists("A", "B"))
        #expect(store.sidebar == .playlist("B") && model.selection == playlists("A", "B"))
        model.select(playlists("A"))
        #expect(store.sidebar == .playlist("A") && model.selection == playlists("A"))
    }

    @Test func 재생_목록이_아닌_항목을_고르면_그_하나만_고른다() {
        model.select(playlists("A", "D"))
        model.select(playlists("A", "D").union([.filter(.all)]))
        #expect(store.sidebar == .filter(.all) && model.selection == [.filter(.all)])
        // 재생 목록을 더해도 재생 목록만 남는다
        model.select([.filter(.all), .playlist("B")])
        #expect(store.sidebar == .playlist("B") && model.selection == playlists("B"))
    }

    @Test func 범위가_재생_목록_칸을_넘으면_누른_끝을_보인다() {
        let top = LibraryFilter.visible(commentPreset: store.commentPreset, hidingStreaming: store.hideStreaming).map(SidebarItem.filter)
            + [.duplicates, .staged, .pending]
        // 맨 위 필터를 보다가 재생 목록 B를 ⇧ 클릭: 사이의 필터·쓰기 대기가 아니라 B를 보이고 재생 목록만 고른다
        store.sidebar = top[0]
        model.select(Set(top).union(playlists("F", "A", "G", "H", "B")))
        #expect(store.sidebar == .playlist("B") && model.selection == playlists("F", "A", "G", "H", "B"))
        // 쓰기 대기를 보다가 맨 위 필터를 ⇧ 클릭: 그 필터 하나다
        store.sidebar = .pending
        model.select(Set(top))
        #expect(store.sidebar == top[0] && model.selection == [top[0]])
    }

    private final class Flag: @unchecked Sendable { var fired = false }

    @Test func 빈_곳을_누르면_고른_것을_그대로_두고_목록에_다시_알린다() {
        model.select(playlists("A"))
        model.select(playlists("A", "D"))
        let flag = Flag()
        withObservationTracking { _ = model.selection } onChange: { flag.fired = true }
        model.select([])
        #expect(flag.fired, "목록이 고르기를 다시 읽어 강조를 되살린다(모델과 화면이 어긋나지 않게)")
        #expect(model.selection == playlists("A", "D") && store.sidebar == .playlist("D"))
    }

    @Test func 다른_곳이_사이드바를_바꾸면_하나로_돌아간다() {
        model.select(playlists("A"))
        model.select(playlists("A", "D"))
        store.sidebar = .pending
        #expect(model.selection == [.pending])
        // 같은 목록으로 돌아와도 예전 여러 개 고르기를 되살리지 않는다
        store.sidebar = .playlist("D")
        #expect(model.selection == playlists("D"))
    }

    // MARK: - 요청 만들기

    @Test func 폴더와_그_안_항목을_함께_고르면_폴더만_대상이다() {
        #expect(model.targets(["H", "D", "A", "F", "B"]) == ["F", "B", "D"])
        #expect(model.targets(["H", "G", "Z"]) == ["G"], "없는 목록은 뺀다")
    }

    @Test func 지우기_요청은_사이드바_순서로_하나씩_만든다() {
        #expect(model.deleteRequests(["D", "A", "B"]) == [.delete(.ref(.id("A"))), .delete(.ref(.id("B"))), .delete(.ref(.id("D")))])
    }

    @Test func 옮기기_요청은_사이드바_순서로_폴더_끝이나_놓은_목록_앞에_둔다() {
        #expect(model.moveRequests(["D", "B"], to: .into("T")) == [
            .move(.ref(.id("B")), into: .ref(.id("T")), position: nil), .move(.ref(.id("D")), into: .ref(.id("T")), position: nil),
        ])
        #expect(model.moveRequests(["D", "B"], to: .before("A")) == [
            .move(.ref(.id("B")), into: .ref(.id("F")), position: .before(.ref(.id("A")))),
            .move(.ref(.id("D")), into: .ref(.id("F")), position: .before(.ref(.id("A")))),
        ])
    }

    // MARK: - 지우기

    @Test func 여러_개를_지우면_개수와_이름을_묻고_한_번에_쌓아_한_번에_되돌린다() throws {
        model.select(playlists("B"))
        model.select(playlists("B", "D", "H", "G"))
        model.deleteSelection()

        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "재생 목록·폴더 3개를 지울까요?")
        #expect(prompt.text.contains("‘안 폴더’, ‘나’, ‘다’"))
        #expect(prompt.destructive)
        #expect(layout.item("B") == nil && layout.item("D") == nil && layout.item("G") == nil && layout.item("H") == nil)
        #expect(store.activityLog.latest?.kind == .success)
        // 보던 목록이 사라지면 전체 곡으로 돌아간다
        #expect(store.sidebar == .filter(.all))

        undo.undo()
        #expect(layout.item("B") != nil && layout.item("D") != nil && layout.item("H") != nil)
        #expect(store.playlists.playlistDraft.isEmpty)
    }

    @Test func 보던_항목이_남으면_지운_항목만_고르기에서_뺀다() {
        model.select(playlists("B"))
        model.select(playlists("B", "S"))
        model.deleteSelection()
        #expect(layout.item("B") == nil && store.sidebar == .playlist("S"))
        #expect(model.selection == playlists("S") && !model.isSelectingManyPlaylists)
    }

    @Test func 지우기를_취소하면_아무것도_쌓지_않는다() {
        prompter.answer = false
        model.deletePlaylists(["B", "D"])
        #expect(prompter.shown.count == 1)
        #expect(store.playlists.playlistDraft.isEmpty)
    }

    @Test func 인텔리전트_목록이_섞이면_그것만_건너뛰고_이유를_보인다() throws {
        model.deletePlaylists(["S", "B"])

        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "재생 목록 1개를 지울까요?")
        #expect(prompt.text.contains("‘스마트’"), "건너뛸 항목을 확인 창에 보인다")
        #expect(layout.item("B") == nil && layout.item("S") != nil)
        let message = try #require(store.activityLog.latest)
        #expect(message.kind == .warning)
        #expect(message.text.contains("‘스마트’") && message.text.contains("인텔리전트"))
    }

    @Test func 모두_막히면_묻지_않고_이유만_알린다() throws {
        model.deletePlaylists(["S"])
        #expect(prompter.shown.isEmpty)
        #expect(store.playlists.playlistDraft.isEmpty)
        #expect(try #require(store.activityLog.latest).text.contains("인텔리전트"))
    }

    @Test func 이름은_열_개까지_보이고_나머지는_줄인다() throws {
        var items: [(Item, Int)] = []
        for index in 1...12 { items.append((Self.item("P\(index)", "목록\(index)"), index)) }
        store.playlists.rekordboxPlaylists = PlaylistLayout(items)
        store.playlists.refreshPlaylists()
        model.deletePlaylists((1...12).map { "P\($0)" })
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "재생 목록 12개를 지울까요?")
        #expect(prompt.text.contains("‘목록10’") && !prompt.text.contains("‘목록11’") && prompt.text.contains("외 2개"))
    }

    // MARK: - 옮기기

    @Test func 여러_개를_폴더로_옮기면_사이드바_순서를_지키고_한_번에_되돌린다() {
        model.movePlaylists(["D", "A", "B"], to: .into("T"))
        #expect(layout.childIDs(of: "T") == ["A", "B", "D"])
        #expect(prompter.shown.isEmpty, "옮기기는 묻지 않는다(⌘Z로 되돌림)")
        undo.undo()
        #expect(layout.childIDs(of: "T").isEmpty && layout.childIDs(of: "F") == ["A", "G"])
    }

    @Test func 폴더를_제_아래로_옮기는_항목만_건너뛰고_나머지는_옮긴다() throws {
        model.movePlaylists(["F", "B"], to: .into("G"))
        #expect(layout.item("F")?.parentID == PlaylistLayout.root)
        #expect(layout.item("B")?.parentID == "G")
        let message = try #require(store.activityLog.latest)
        #expect(message.kind == .warning && message.text.contains("‘폴더’") && message.text.contains("제 안으로"))
    }

    @Test func 끄는_항목에는_놓을_수_없다() {
        model.select(playlists("B"))
        model.select(playlists("B", "D"))
        #expect(model.dragIDs(for: "D") == ["B", "D"])
        #expect(model.refusesPlaylistDrop(on: "B") && model.refusesPlaylistDrop(on: "D"))
        #expect(!model.refusesPlaylistDrop(on: "T"))
        // 고르지 않은 줄을 끌면 그 줄만 끈다
        #expect(model.dragIDs(for: "A") == ["A"])
        #expect(!model.refusesPlaylistDrop(on: "B"))
    }
}
