@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// Apple Music 가져오기 창 열기(#378): 최소화한 창을 같은 메뉴로 다시 열면 새 창이 생기지 않고 그 창이 복원된다.
/// 최소화 상태에서 창이 보이지 않는 경우와 실제 데스크톱의 Dock 복원을 같은 열기 동작으로 확인한다.
@MainActor
@Suite("Apple Music 가져오기 창 — 최소화·닫은 뒤 다시 열기", .serialized)
struct AppleMusicImportWindowTests {
    let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })

    /// 같은 제목으로 열린 다른 시험의 창은 이 가져오기 창에 속하지 않는다.
    func openWindows(of importer: AppleMusicImportWindow) -> [NSWindow] {
        NSApp.windows.filter { $0.delegate === importer && ($0.isVisible || $0.isMiniaturized) }
    }

    @Test func 최소화한_창은_같은_입구로_다시_열면_새_창_없이_그_창이_복원되고_선택을_유지한다() async throws {
        try await checkReopen { TestWindow(contentViewController: $0) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_APPKIT_MINIMIZE_TEST"] == "1"))
    func 데스크톱_Dock에서_최소화한_창을_다시_연다() async throws {
        try await checkReopen { NSWindow(contentViewController: $0) }
    }

    private func checkReopen(makeWindow: (NSViewController) -> NSWindow) async throws {
        _ = NSApplication.shared
        let importer = AppleMusicImportWindow()
        importer.open(store: store, makeWindow: makeWindow)
        let first = try #require(importer.window)
        defer { for window in openWindows(of: importer) { window.close() } }
        let model = try #require(importer.model)
        model.selected = [1, 2]
        model.createPlaylists = true

        first.miniaturize(nil)
        let minimized = await waitForState(safetyNet: .seconds(20)) { first.isMiniaturized }
        try #require(minimized, "창 서버가 최소화를 받지 못했다")

        importer.open(store: store)
        try #require(importer.window === first, "새 창을 만들지 않고 같은 창을 쓴다")
        let restored = await waitForState(safetyNet: .seconds(20)) { !first.isMiniaturized && first.isVisible }
        #expect(restored, "최소화한 창이 복원돼야 한다")
        #expect(importer.model === model && model.selected == [1, 2] && model.createPlaylists, "고른 곡과 설정이 그대로여야 한다")
        #expect(openWindows(of: importer).count == 1, "열려 있는 창은 하나뿐이어야 한다")
    }

    @Test func 열려_있는_창을_다시_열면_같은_창이다() throws {
        _ = NSApplication.shared
        let importer = AppleMusicImportWindow()
        importer.open(store: store)
        let first = try #require(importer.window)
        defer { for window in openWindows(of: importer) { window.close() } }
        importer.model?.selected = [3]
        importer.open(store: store)
        #expect(importer.window === first && importer.model?.selected == [3])
        #expect(openWindows(of: importer).count == 1)
    }

    /// 닫은 창은 다시 열면 새 창·새 모델로 열린다(옛 동작을 그대로 둔다. 연동 안내 창과 달리 닫으면 고른 곡을 버린다)
    @Test func 닫은_창은_다시_열면_새_창과_새_모델로_열린다() throws {
        _ = NSApplication.shared
        let importer = AppleMusicImportWindow()
        importer.open(store: store)
        let first = try #require(importer.window)
        defer { for window in openWindows(of: importer) { window.close() } }
        let firstModel = try #require(importer.model)
        firstModel.selected = [1, 2]
        first.close()
        #expect(openWindows(of: importer).isEmpty)

        importer.open(store: store)
        let second = try #require(importer.window)
        #expect(second !== first && importer.model !== firstModel && importer.model?.selected.isEmpty == true)
        #expect(second.isVisible && openWindows(of: importer).count == 1)
    }
}

/// Dock 없는 러너에서도 최소화한 창은 보이지 않고, 복원을 요청해야 최소화가 풀린다.
@MainActor
private final class TestWindow: NSWindow {
    private var minimized = false
    override var isMiniaturized: Bool { minimized }

    override func miniaturize(_ sender: Any?) {
        orderOut(sender)
        minimized = true
    }

    override func deminiaturize(_ sender: Any?) {
        minimized = false
        orderFront(sender)
    }
}
