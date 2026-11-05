@testable import DJCrate
import DJCDomain
import Foundation
import SwiftUI
import Testing

/// 목록 머리 줄의 검색칸과 편집 › 찾기(⌘F, #338).
/// 켜짐 조건은 순수 값으로 보고, 실제 키 전달·포커스는 자가 테스트(`--key-routing-selftest`)가 본다.
@MainActor
@Suite("목록 검색 — 찾기(⌘F)·머리 줄 검색칸")
struct ListSearchTests {
    private func loadedStore() -> LibraryStore {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.phase = .loaded
        return store
    }

    @Test func 찾기는_편집_메뉴의_Cmd_F_항목이다() {
        #expect(LibraryMenuAction.editActions == [.find])
        #expect(LibraryMenuAction.find.title == "찾기")
        #expect(LibraryMenuAction.find.shortcut == KeyboardShortcut("f", modifiers: .command))
        // ⌘F를 쓰는 항목은 이것 하나다(메뉴 막대에 ⌘F가 둘이 되지 않는다)
        let sharing = LibraryMenuAction.allCases.filter { $0.shortcut == KeyboardShortcut("f", modifiers: .command) }
        #expect(sharing == [.find])
    }

    @Test(arguments: [
        SidebarItem.filter(.all), .playlist("1"), .history("1"), .duplicates, .staged, .pending,
        .usb(.collection(volumeKey: "V")), .usb(.playlist(volumeKey: "V", id: 3)),
    ])
    func 찾기는_목록을_읽은_뒤_검색이_걸리는_화면에서_켜진다(_ sidebar: SidebarItem) {
        let store = loadedStore()
        store.sidebar = sidebar
        let window = LibraryWindowModel(store: store)
        #expect(store.listIsSearchable)
        #expect(LibraryMenuAction.find.isEnabled(in: window))
        #expect(LibraryMenuAction.find.disabledReason(in: window) == nil)
    }

    @Test func 찾기는_USB_쓰기_대기에서_꺼진다() {
        let store = loadedStore()
        store.sidebar = .usb(.pending(volumeKey: "V"))
        let window = LibraryWindowModel(store: store)
        // 이 화면에는 검색이 거를 곡 줄이 없다
        #expect(!store.listIsSearchable)
        #expect(!LibraryMenuAction.find.isEnabled(in: window))
        #expect(LibraryMenuAction.find.disabledReason(in: window) != nil)
    }

    @Test func 찾기는_목록을_읽기_전과_읽기_실패에서_꺼진다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let window = LibraryWindowModel(store: store)
        for phase: LibraryStore.Phase in [.idle, .loading("읽는 중"), .failed("읽지 못했습니다")] {
            store.phase = phase
            #expect(!LibraryMenuAction.find.isEnabled(in: window))
        }
    }

    @Test func 찾기는_rekordbox에_쓰는_동안_꺼진다() {
        let store = loadedStore()
        let window = LibraryWindowModel(store: store)
        #expect(LibraryMenuAction.find.isEnabled(in: window))
        store.isWritingRekordbox = true
        // 상세 열이 통째로 잠기므로 검색칸에도 갈 수 없다
        #expect(!LibraryMenuAction.find.isEnabled(in: window))
        #expect(LibraryMenuAction.find.disabledReason(in: window) == "rekordbox 쓰기가 끝난 뒤 다시 시도하세요")
    }

    @Test func 찾기를_누르면_검색칸_포커스_요청이_올라가고_꺼진_뒤에는_올라가지_않는다() {
        let store = loadedStore()
        let window = LibraryWindowModel(store: store)
        let first = window.searchFocusRequest
        LibraryMenuAction.find.perform(in: window)
        #expect(window.searchFocusRequest == first + 1)
        // 이미 검색칸에 있어도 다시 누르면 다시 요청한다(칸 전체를 고르게)
        LibraryMenuAction.find.perform(in: window)
        #expect(window.searchFocusRequest == first + 2)
        store.sidebar = .usb(.pending(volumeKey: "V"))
        LibraryMenuAction.find.perform(in: window)
        #expect(window.searchFocusRequest == first + 2)
    }

    /// 메뉴 막대의 ⌘F는 이것 하나다. 시스템 찾기 항목을 만들던 `.searchable`은 앱 어디에도 없고,
    /// ⌘F 키 등가물은 `LibraryMenuAction` 한 곳에만 있다. 실제 메뉴 막대는 `--search-layout-selftest`가 센다.
    @Test func 편집_메뉴_그룹이_찾기를_등록하고_앱_소스에_다른_Cmd_F와_searchable이_없다() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let commands = try String(contentsOf: root.appending(path: "Sources/DJCrate/App/AppCommands.swift"), encoding: .utf8)
        // 등록 줄이 편집 메뉴 그룹(`CommandGroup(after: .textEditing)`) 안에 있어야 한다. 다른 메뉴로 옮기면 실패한다
        let start = try #require(commands.range(of: "CommandGroup(after: .textEditing) {"))
        var depth = 0
        var end = commands.endIndex
        for index in commands[start.lowerBound...].indices {
            if commands[index] == "{" { depth += 1 }
            if commands[index] == "}" { depth -= 1; if depth == 0 { end = index; break } }
        }
        #expect(commands[start.lowerBound..<end].contains("ForEach(LibraryMenuAction.editActions, id: \\.self) { libraryButton($0) }"))
        let sources = root.appending(path: "Sources/DJCrate")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var searchable: [String] = [], commandF: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".searchable(") { searchable.append(url.lastPathComponent) }
            if text.contains("KeyboardShortcut(\"f\"") || text.contains(".keyboardShortcut(\"f\"") { commandF.append(url.lastPathComponent) }
        }
        #expect(searchable.isEmpty)
        #expect(commandF == ["LibraryMenuAction.swift"])
    }
}
