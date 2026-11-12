@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import SwiftUI
import Testing

/// 머리 줄(#339)의 폭 맞춤: 폭이 모자라면 켜진 필터 칩이 「필터 N」 하나로 줄고, 어느 폭에서도 검색칸·필터 단추·칩·ⓘ·보기 전환이
/// 겹치거나 밖으로 나가지 않는다. 실제 창에 머리 줄만 올려 `SelfTestFrames`(디버그 전용 자리 기록)로 잰다.
/// 자리 기록은 프로세스 하나에 하나뿐이고 다른 시험도 머리 줄을 띄우므로, 장면마다 이름 앞에 붙일 글자(`selfTestFrameScope`)를 따로 줘 서로 섞이지 않게 한다.
/// 주 창은 최소 폭(1155)에서도 본문이 약 700pt 밑으로 좁아지지 않아 줄어든 모양이 거의 안 나오기 때문에 머리 줄만 따로 좁힌다.
@MainActor
@Suite("머리 줄 — 폭에 따른 칩 줄어듦")
struct ListHeaderLayoutTests {
    typealias Actions = ListHeaderActions

    struct Scene {
        var width: CGFloat
        var rating = 0
        var color: String?
        var sheet = false
        var scale = 1.0
        var sidebar: SidebarItem = .filter(.all)
        /// 저장소 상태 대신 머리 줄 오른쪽 구성(#340)을 값으로 넣는다
        var actions: ListHeaderActions?
        /// 폭이 아주 모자라면 칩이 숨는다(`ListHeaderLayout`의 마지막 수단). 이 장면은 칩이 있거나 없거나 둘 다 맞다
        var chipsMayHide = false
    }

    /// 머리 줄 안 자리들(왼쪽에서 오른쪽 순서). 칩은 이름에 글을 단다
    struct Measured {
        var search: CGRect?
        var filter: CGRect?
        var chips: [(title: String, frame: CGRect)] = []
        var status: CGRect?
        var primary: CGRect?
        var menu: CGRect?
        var info: CGRect?
        var viewMode: CGRect?

        var parts: [CGRect] { [search, filter].compactMap { $0 } + chips.map(\.frame) + [status, primary, menu, info, viewMode].compactMap { $0 } }
        /// 겹치지 않고 왼쪽에서 오른쪽으로 놓였는지
        var isOrdered: Bool { zip(parts, parts.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 } }
        func isInside(width: CGFloat) -> Bool { parts.allSatisfy { $0.minX >= -0.5 && $0.maxX <= width + 0.5 && $0.width > 0 } }
    }

    /// 실제 창에 올린 머리 줄 하나. 장면마다 새로 만든다
    final class Hosted {
        let store: LibraryStore
        let scene: Scene
        let scope = "headerLayout.\(UUID().uuidString)."
        let host: NSHostingView<AnyView>
        let window: NSWindow

        @MainActor init(_ scene: Scene) {
            _ = NSApplication.shared
            self.scene = scene
            store = LibraryStore.test(activityLog: ActivityLog(url: nil))
            store.phase = .loaded
            store.sidebar = scene.sidebar
            store.minimumRating = scene.rating
            store.colorFilter = scene.color
            let defaults = TestDefaults.make("header-layout")
            defaults.set(scene.sheet, forKey: SettingKeys.sheetMode.name)
            let root = ListHeaderBar(store: store, window: LibraryWindowModel(store: store), actions: ListActionBarModel(store: store))
                .environment(\.textScale, scene.scale)
                .environment(\.selfTestFrameScope, scope)
                .environment(\.listHeaderActionsOverride, scene.actions)
                .defaultAppStorage(defaults)
                .frame(width: scene.width, height: ListHeaderBar.height)
            host = NSHostingView(rootView: AnyView(root))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: scene.width, height: ListHeaderBar.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
        }

        /// 이 창이 기록한 자리(이름 접두사를 뗀 것)
        @MainActor func frames() -> [String: CGRect] {
            var found: [String: CGRect] = [:]
            for (key, frame) in SelfTestFrames.frames where key.hasPrefix(scope) { found[String(key.dropFirst(scope.count))] = frame }
            return found
        }

        /// 이 장면에 있어야 할 자리가 모두 올라오고 두 번 잇따라 같을 때까지 상태로 기다린 뒤 잰다
        @MainActor func measure() async throws -> Measured {
            var previous: [String: CGRect] = [:]
            let ready = await waitForState(safetyNet: .seconds(120)) {
                host.layoutSubtreeIfNeeded()
                let current = frames()
                defer { previous = current }
                let hasChips = current.keys.contains { $0.hasPrefix("listHeader.chip.") }
                let expectsChips = store.listIsFilterable && (scene.rating > 0 || scene.color != nil)
                return (current["listHeader.search"] != nil) == store.listIsSearchable
                    && (current["listHeader.filter"] != nil) == store.listIsFilterable
                    && current["listHeader.viewMode"] != nil
                    && (current["listHeader.info"] != nil) == store.showsTagSheet(sheetMode: scene.sheet)
                    && (current["listHeader.primary"] != nil) == (scene.actions?.primary != nil)
                    && (current["listHeader.status"] != nil) == (scene.actions?.status != nil)
                    && (current["listHeader.menu"] != nil) == (scene.actions?.menu.isEmpty == false)
                    && (scene.chipsMayHide || hasChips == expectsChips)
                    && current == previous
            }
            try #require(ready)
            let found = frames()
            let chips = found.filter { $0.key.hasPrefix("listHeader.chip.") }
                .map { (title: String($0.key.dropFirst("listHeader.chip.".count)), frame: $0.value) }
                .sorted { $0.frame.minX < $1.frame.minX }
            return Measured(search: found["listHeader.search"], filter: found["listHeader.filter"], chips: chips,
                            status: found["listHeader.status"], primary: found["listHeader.primary"], menu: found["listHeader.menu"],
                            info: found["listHeader.info"], viewMode: found["listHeader.viewMode"])
        }

        @MainActor func close() {
            window.contentView = nil
            window.close()
            SelfTestFrames.frames = SelfTestFrames.frames.filter { !$0.key.hasPrefix(scope) }
        }
    }

    private func measure(_ scene: Scene) async throws -> Measured {
        let hosted = Hosted(scene)
        defer { hosted.close() }
        return try await hosted.measure()
    }

    @Test func 폭이_넉넉하면_켠_조건마다_칩이_붙고_폭이_모자라면_필터_N_하나로_줄어든다() async throws {
        let wide = try await measure(Scene(width: 900, rating: 3, color: "2"))
        #expect(wide.chips.map(\.title) == ["★★★ 이상", "곡 색 Red"])
        #expect(wide.isOrdered && wide.isInside(width: 900))

        let narrow = try await measure(Scene(width: 560, rating: 3, color: "2"))
        #expect(narrow.chips.map(\.title) == ["필터 2"])
        #expect(narrow.isOrdered && narrow.isInside(width: 560))
        // 검색칸은 줄이기 전과 같은 폭을 지킨다(칩이 먼저 줄어든다)
        #expect(narrow.search?.width == wide.search?.width)
    }

    @Test func 칩이_하나여도_폭이_모자라면_필터_1로_줄어든다() async throws {
        let wide = try await measure(Scene(width: 700, rating: 4))
        #expect(wide.chips.map(\.title) == ["★★★★ 이상"])
        let narrow = try await measure(Scene(width: 440, rating: 4))
        #expect(narrow.chips.map(\.title) == ["필터 1"])
        #expect(narrow.isOrdered && narrow.isInside(width: 440))
    }

    @Test func 켠_조건이_없으면_칩이_없다() async throws {
        let none = try await measure(Scene(width: 700))
        #expect(none.chips.isEmpty)
        #expect(none.search != nil && none.filter != nil && none.viewMode != nil && none.info == nil)
        #expect(none.isOrdered && none.isInside(width: 700))
        // 보기 전환은 칩 자리가 비어도 오른쪽 끝(여백 14pt)에 붙는다
        let edge = try #require(none.viewMode?.maxX)
        #expect(abs(edge - (700 - Spacing.edge)) <= 0.5)
    }

    @Test(arguments: [620.0, 700.0, 860.0, 1000.0])
    func 본문_폭이_바뀌어도_글자를_키워도_머리_줄이_겹치거나_잘리지_않는다(width: CGFloat) async throws {
        for scale in [1.0, 1.5] {
            let measured = try await measure(Scene(width: width, rating: 3, color: "2", sheet: true, scale: scale))
            #expect(measured.isOrdered, "겹침: 폭 \(width) 배율 \(scale) \(measured.parts)")
            #expect(measured.isInside(width: width), "밖으로 나감: 폭 \(width) 배율 \(scale)")
            #expect(measured.info != nil, "태그 시트에는 ⓘ가 보인다")
            // 칩은 전부 보이거나 하나로 줄어든다(일부만 보이지 않는다)
            #expect(measured.chips.map(\.title) == ["★★★ 이상", "곡 색 Red"] || measured.chips.map(\.title) == ["필터 2"],
                    "칩 모양: 폭 \(width) 배율 \(scale) \(measured.chips.map(\.title))")
        }
    }

    @Test func 태그_시트일_때만_ⓘ가_보인다() async throws {
        let list = try await measure(Scene(width: 700, rating: 3))
        #expect(list.info == nil)
        let sheet = try await measure(Scene(width: 700, rating: 3, sheet: true))
        #expect(sheet.info != nil)
        #expect(sheet.isOrdered)
    }

    // MARK: 머리 줄이 판정을 실제로 쓰는지(배선). 칩을 마우스로 눌러 끄는 동작은 이 창에서 이벤트가 닿지 않아 사람이 확인한다(보고 5절)

    @Test(arguments: [SidebarItem.duplicates, .usb(.pending(volumeKey: "V"))])
    func 필터가_걸리지_않는_목록에서는_켜진_조건이_있어도_필터_단추와_칩이_없다(_ sidebar: SidebarItem) async throws {
        let hosted = Hosted(Scene(width: 800, rating: 3, color: "2", sidebar: sidebar))
        defer { hosted.close() }
        let measured = try await hosted.measure()
        #expect(measured.filter == nil)
        #expect(measured.chips.isEmpty)
        #expect(measured.viewMode != nil)
        // 검색칸은 중복 후보에는 있고 USB 쓰기 대기에는 없다(#338)
        #expect((measured.search != nil) == (sidebar == .duplicates))
        // 조건은 꺼지지 않고 남는다: 곡 목록으로 돌아오면 칩이 다시 보인다
        #expect(hosted.store.minimumRating == 3 && hosted.store.colorFilter == "2")
        hosted.store.sidebar = .filter(.all)
        #expect(try await hosted.measure().chips.map(\.title) == ["★★★ 이상", "곡 색 Red"])
    }

    // MARK: 오른쪽 구성(#340): 모드마다 가장 긴 이름으로 폭을 잰다

    /// 모드 아홉 가지를 저장소 상태 대신 값으로 넣는다. 이름은 가장 길게(세 자리 곡 수, 재생 목록·재생 기록 건수가 함께 붙는 쓰기 이름 등)
    @MainActor static var modeActions: [(name: String, sidebar: SidebarItem, actions: ListHeaderActions)] {
        typealias A = ListHeaderActions
        let locks = A.Locks()
        let restore = A.Restore(isEnabled: true, help: "라이브러리 전체를 마지막 저장 전 백업으로 복원합니다.")
        let histories = [A.HistoryMenu.Entry(id: "h1", name: "HISTORY 2026-10-05"), .init(id: "h2", name: "HISTORY 2026-10-06")]
        return [
            ("추가한 곡", .staged, A.staged(selected: true, count: 123, canRemove: true, canExportXML: true, importedCount: 12, locks: locks)),
            ("쓰기 대기", .pending, A.pending(selected: true, tracks: 123, playlistEdits: 12, histories: histories, unlinkedDrafts: 0,
                                           restore: restore, locks: locks)),
            ("쓰기 대기+연결 안 된 초안", .pending, A.pending(selected: false, tracks: 123, playlistEdits: 12, histories: histories,
                                                      unlinkedDrafts: 14, restore: restore, locks: locks)),
            ("Music 목록", .itunesPlaylist("itunes:A"), A.music(unavailable: 12)),
            ("계산 목록", .playlist("S"), A.smartPlaylist(unsupported: false)),
            ("재생 목록 편집", .playlist("P"), A.playlist(id: "P", isDraft: true, blockedReason: "곡이 rekordbox에서 사라졌습니다", hiddenStreaming: nil,
                                                    canCompare: true, locks: locks)),
            ("숨긴 스트리밍", .playlist("P"), A.playlist(id: "P", isDraft: false, blockedReason: nil, hiddenStreaming: 123, canCompare: true, locks: locks)),
            ("USB", .usb(.collection(volumeKey: "V")), A.usb(volumeKey: "V", editing: (updatable: 123, blockReason: nil, draftCount: 45), playlistMismatch: true)),
            ("파일 없음", .filter(.missingFile), A.missingFiles(volumes: [.init(name: "공연용 SSD", trackCount: 12)], checking: false, hasMissing: true,
                                                           canFindInFolder: true)),
            ("파일 없음+단서", .filter(.missingFile), A.missingFiles(volumes: [], checking: false, hasMissing: true, canFindInFolder: true)),
            ("BPM 없음", .filter(.noBPM), A.gridEstimate(count: 123, blocked: false)),
        ]
    }

    @Test(arguments: [620.0, 700.0, 860.0, 1000.0])
    func 모드마다_가장_긴_오른쪽_구성도_겹치거나_잘리지_않고_주_단추와_메뉴는_남는다(width: CGFloat) async throws {
        for mode in Self.modeActions {
            for scale in [1.0, 1.5] {
                let scene = Scene(width: width, rating: 3, color: "2", scale: scale, sidebar: mode.sidebar, actions: mode.actions, chipsMayHide: true)
                let measured = try await measure(scene)
                let note = "\(mode.name) · 폭 \(width) · 배율 \(scale) · \(measured.parts.map { "\(Int($0.minX))–\(Int($0.maxX))" })"
                #expect(measured.isOrdered, Comment(rawValue: "겹침: \(note)"))
                #expect(measured.isInside(width: width), Comment(rawValue: "밖으로 나감: \(note)"))
                // 줄이는 것은 상태 글과 칩, 검색칸뿐이다. 주 단추와 메뉴, 보기 전환은 늘 남는다
                if mode.actions.primary != nil { #expect(measured.primary != nil, Comment(rawValue: "주 단추: \(note)")) }
                if !mode.actions.menu.isEmpty { #expect(measured.menu != nil, Comment(rawValue: "메뉴: \(note)")) }
                #expect(measured.viewMode != nil)
            }
        }
    }

    /// 줄이는 차례: 칩 → 상태 글 → 검색칸 160 → 주 단추 이름의 덧붙은 말 → 검색칸 120 → 칩 숨김. 앞 단계가 안 들어갈 때만 다음 단계로 간다
    @Test(arguments: [1.0, 1.5])
    func 폭이_모자라면_정해_둔_차례로만_줄어든다(scale: Double) async throws {
        let mode = try #require(Self.modeActions.first { $0.name == "쓰기 대기+연결 안 된 초안" })
        var lastStage = 0
        var stages: [Int] = []
        for width: CGFloat in [1600, 1400, 1200, 1100, 1000, 900, 820, 780, 740, 700, 680, 660, 640, 620] {
            let m = try await measure(Scene(width: width, rating: 3, color: "2", scale: scale, sidebar: mode.sidebar, actions: mode.actions,
                                            chipsMayHide: true))
            let chipsHidden = m.chips.isEmpty
            let chipsOne = m.chips.map(\.title) == ["필터 2"]
            let chipsAll = m.chips.count == 2
            let statusIcon = (m.status?.width ?? 0) < 130 * scale
            let searchNarrow = (m.search?.width ?? 0) <= ListSearchField.narrowWidth + 0.5
            let searchLeast = (m.search?.width ?? 0) <= ListSearchField.minimumWidth + 0.5
            // 단추 글자는 컨트롤 크기를 따라 글자 배율과 상관없이 같다
            let primaryShort = (m.primary?.width ?? 0) < 200
            let note = Comment(rawValue: "폭 \(width) 배율 \(scale): 칩 \(m.chips.map(\.title)) 상태 \(m.status?.width ?? 0) 검색 \(m.search?.width ?? 0) 주 단추 \(m.primary?.width ?? 0)")
            #expect(chipsHidden || chipsOne || chipsAll, note)
            // 뒤 단계는 앞 단계를 모두 거친 뒤에만 나타난다
            if statusIcon { #expect(chipsHidden || chipsOne, note) }
            if searchNarrow { #expect(statusIcon, note) }
            if primaryShort { #expect(searchNarrow, note) }
            if searchLeast { #expect(primaryShort, note) }
            if chipsHidden { #expect(searchLeast, note) }
            let stage = (chipsOne || chipsHidden ? 1 : 0) + (statusIcon ? 1 : 0) + (searchNarrow ? 1 : 0) + (primaryShort ? 1 : 0)
                + (searchLeast ? 1 : 0) + (chipsHidden ? 1 : 0)
            // 좁아질수록 단계가 되돌아가지 않는다
            #expect(stage >= lastStage, note)
            lastStage = stage
            stages.append(stage)
        }
        #expect(stages.first == 0, "넉넉한 폭에서는 아무것도 줄지 않는다: \(stages)")
        #expect(stages.last ?? 0 > 0, "가장 좁은 폭에서는 줄어든다: \(stages)")
    }

    @Test func 쓰기_대기는_폭이_모자라면_곡_수만_남기고_함께_쓰는_건수를_툴팁으로_알린다() {
        let pending = Actions.pending(selected: true, tracks: 123, playlistEdits: 12,
                                      histories: [.init(id: "h", name: "기록")], unlinkedDrafts: 0,
                                      restore: .init(isEnabled: true, help: ""), locks: .init())
        #expect(pending.primary?.title == "고른 123곡 저장 (재생 목록 12건 · 재생 기록 1건)")
        #expect(pending.primary?.compactTitle == "고른 123곡 저장")
        #expect(pending.primary?.compactHelp == "재생 목록 12건 · 재생 기록 1건도 함께 저장합니다.")
        // 함께 쓰는 것이 없으면 줄일 말도 없다
        let plain = Actions.pending(selected: false, tracks: 5, playlistEdits: 0, histories: [], unlinkedDrafts: 0,
                                    restore: .init(isEnabled: true, help: ""), locks: .init())
        #expect(plain.primary?.compactTitle == nil)
        // 비교 창이 열려 있으면 줄인 이름에서도 막힌 이유가 먼저다
        let blocked = Actions.pending(selected: false, tracks: 5, playlistEdits: 2, histories: [], unlinkedDrafts: 0,
                                      restore: .init(isEnabled: true, help: ""), locks: .init(sheetBlocked: true))
        #expect(blocked.primary?.compactHelp == LibraryStore.writesBlockedBySheetReason)
        let usb = Actions.usb(volumeKey: "V", editing: (updatable: 8, blockReason: nil, draftCount: 1), playlistMismatch: false)
        #expect(usb.primary?.compactTitle == "USB에 쓰기 (8곡)")
    }
}
