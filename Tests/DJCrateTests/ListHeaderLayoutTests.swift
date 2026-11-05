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
    struct Scene {
        var width: CGFloat
        var rating = 0
        var color: String?
        var sheet = false
        var scale = 1.0
        var sidebar: SidebarItem = .filter(.all)
    }

    /// 머리 줄 안 자리들(왼쪽에서 오른쪽 순서). 칩은 이름에 글을 단다
    struct Measured {
        var search: CGRect?
        var filter: CGRect?
        var chips: [(title: String, frame: CGRect)] = []
        var info: CGRect?
        var viewMode: CGRect?

        var parts: [CGRect] { [search, filter].compactMap { $0 } + chips.map(\.frame) + [info, viewMode].compactMap { $0 } }
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
            let root = ListHeaderBar(store: store, window: LibraryWindowModel(store: store))
                .environment(\.textScale, scene.scale)
                .environment(\.selfTestFrameScope, scope)
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
                    && hasChips == expectsChips
                    && current == previous
            }
            try #require(ready)
            let found = frames()
            let chips = found.filter { $0.key.hasPrefix("listHeader.chip.") }
                .map { (title: String($0.key.dropFirst("listHeader.chip.".count)), frame: $0.value) }
                .sorted { $0.frame.minX < $1.frame.minX }
            return Measured(search: found["listHeader.search"], filter: found["listHeader.filter"], chips: chips,
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
}
