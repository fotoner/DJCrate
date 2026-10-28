@testable import DJCrate
import DJCDomain
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("메뉴 — 구성·단축키")
struct MenuCommandTests {
    @Test func 설정_메뉴와_단축키는_Settings_장면에서만_등록한다() throws {
        // Settings가 메뉴와 ⌘,를 함께 만든다. 다른 장면의 수동 링크가 겹치지 않게 고정한다.
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appending(path: "Sources/DJCrate/App/DJCrateApp.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Sources/DJCrate/App/AppCommands.swift"), encoding: .utf8)
        #expect(app.components(separatedBy: "Settings {").count - 1 == 1)
        #expect(!(app + commands).contains("SettingsLink"))
        #expect(!(app + commands).contains(".appSettings"))
    }

    @Test func 파형_높이_메뉴는_보이는_높이에서_한_칸씩_범위_안으로_바꾼다() {
        #expect(DeckLayout.steppedWaveformHeight(displayed: 150, direction: 1, maximum: 400) == 150 + DeckLayout.waveformHeightStep)
        #expect(DeckLayout.steppedWaveformHeight(displayed: 150, direction: -1, maximum: 400) == 150 - DeckLayout.waveformHeightStep)
        // 저장한 높이가 창보다 커도 지금 보이는 높이에서 줄인다
        #expect(DeckLayout.steppedWaveformHeight(displayed: 395, direction: 1, maximum: 400) == 400)
        #expect(DeckLayout.steppedWaveformHeight(displayed: 85, direction: -1, maximum: 400) == DeckLayout.minimumWaveformHeight)
        var requested = 480.0
        let control = WaveformHeightControl(displayed: 200, maximum: 260) { requested = $0 }
        #expect(control.canGrow && control.canShrink)
        control.shrink()
        #expect(requested == 200 - DeckLayout.waveformHeightStep)
        #expect(!WaveformHeightControl(displayed: 260, maximum: 260) { _ in }.canGrow)
        #expect(!WaveformHeightControl(displayed: DeckLayout.minimumWaveformHeight, maximum: 260) { _ in }.canShrink)
    }

    @Test func 앱_명령은_파일과_rekordbox_메뉴로_나뉜다() {
        #expect(LibraryMenuAction.fileActions == [.addFiles, .importAppleMusic, .snapshot, .exportXML, .exportLibraryXML, .importRekordboxXML])
        #expect(LibraryMenuAction.rekordboxActions == [.reflect, .pending, .activityLog, .restore, .pointSnapshots, .removeTracks])
        #expect(LibraryMenuAction.fileActions + LibraryMenuAction.rekordboxActions == LibraryMenuAction.allCases)
    }

    @Test func 도움말_메뉴의_쓰기_전으로_복원은_rekordbox_메뉴와_같은_명령이다() throws {
        // 도움말 메뉴는 rekordbox 메뉴의 항목을 그대로 다시 보인다(새 경로 없음). 이름·켜짐 조건·꺼진 이유가 같다.
        #expect(LibraryMenuAction.helpActions == [.restore])
        #expect(LibraryMenuAction.rekordboxActions.contains(.restore))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let commands = try String(contentsOf: root.appending(path: "Sources/DJCrate/App/AppCommands.swift"), encoding: .utf8)
        // 등록 줄이 도움말 그룹(`CommandGroup(replacing: .help)`) 안에 있어야 한다. 다른 메뉴로 옮기면 실패한다
        let helpStart = try #require(commands.range(of: "CommandGroup(replacing: .help) {"))
        var depth = 0
        var helpEnd = commands.endIndex
        for index in commands[helpStart.lowerBound...].indices {
            if commands[index] == "{" { depth += 1 }
            if commands[index] == "}" { depth -= 1; if depth == 0 { helpEnd = index; break } }
        }
        let helpGroup = commands[helpStart.lowerBound..<helpEnd]
        #expect(helpGroup.contains("ForEach(LibraryMenuAction.helpActions, id: \\.self) { libraryButton($0) }"), "도움말 메뉴도 rekordbox 메뉴와 같은 libraryButton으로 항목을 만든다")

        let backups = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: backups) }
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in }, backupDirectory: backups)
        let window = LibraryWindowModel(store: store)
        for action in LibraryMenuAction.helpActions {
            #expect(action.menuTitle(in: window) == "쓰기 전으로 복원…")
            // 백업이 없으면 막히고 이유는 활동 기록을 보라고 알린다
            #expect(!action.isEnabled(in: window))
            #expect(action.disabledReason(in: window) == "쓰기 전 백업이 없으니 활동 기록을 확인하세요")
        }
        let backup = backups.appending(path: "2026-01-02-write")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data().write(to: backup.appending(path: "master.db"))
        store.refreshWriteBackups()
        for action in LibraryMenuAction.helpActions {
            #expect(action.isEnabled(in: window))
            #expect(action.disabledReason(in: window) == nil)
        }
        // 쓰는 동안은 막힌다(rekordbox 메뉴와 같은 잠금)
        store.isWritingRekordbox = true
        for action in LibraryMenuAction.helpActions {
            #expect(!action.isEnabled(in: window))
            #expect(action.disabledReason(in: window) == "rekordbox 쓰기가 끝난 뒤 다시 시도하세요")
        }
    }

    @Test func 툴바에는_rekordbox_쓰기_단추가_없고_입구는_메뉴와_상태_줄이_맡는다() throws {
        // 툴바 분할 단추(`reflection`)와 ▾ 메뉴(`ReflectionMenu`)는 상태 줄 칩·[쓰기]·팝오버와 rekordbox 메뉴가 대신한다(#325).
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appending(path: "Sources/DJCrate/App/ContentView.swift"), encoding: .utf8)
        #expect(!content.contains("id: \"reflection\""))
        #expect(!content.contains("ReflectionMenu("))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Sources/DJCrate/Reflection/ReflectionMenu.swift").path))
        // 쓰기·복원 입구가 남아 있다: 메뉴 막대 rekordbox(⇧⌘E)와 상태 팝오버
        #expect(LibraryMenuAction.rekordboxActions.contains(.reflect))
        #expect(ReflectionStatusModel.popoverActions.contains(.reflect) && ReflectionStatusModel.popoverActions.contains(.restore))
    }

    @Test func 쓰기와_복원은_확인을_예고하고_XML은_바로_만든다() {
        #expect(LibraryMenuAction.reflect.title == "rekordbox에 쓰기")
        #expect(LibraryMenuAction.restore.title == "쓰기 전으로 복원…")
        #expect(LibraryMenuAction.exportXML.title == "XML 만들기")
        #expect(LibraryMenuAction.exportLibraryXML.title == "라이브러리 XML 내보내기…", "저장 위치를 고르므로 …, 연동 파일을 만드는 XML 만들기와 이름이 겹치지 않는다")
        #expect(LibraryMenuAction.pending.title == "쓰기 대기 목록 보기")
        #expect(LibraryMenuAction.pointSnapshots.title == "시점 스냅샷…", "창을 여므로 …, 라이브러리 읽기 사본(스냅샷)과 구별한다")
    }

    @Test func 앱_명령의_조합_단축키는_서로_겹치지_않는다() {
        #expect(LibraryMenuAction.addFiles.shortcut == KeyboardShortcut("o", modifiers: .command))
        #expect(LibraryMenuAction.snapshot.shortcut == KeyboardShortcut("r", modifiers: .command))
        #expect(LibraryMenuAction.reflect.shortcut == KeyboardShortcut("e", modifiers: [.command, .shift]))
        #expect(LibraryMenuAction.allCases.filter { $0.shortcut != nil } == [.addFiles, .snapshot, .reflect])
    }

    @Test func 빈_라이브러리와_쓰기_잠금에서_명령의_활성_조건을_지킨다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let window = LibraryWindowModel(store: store)
        #expect(LibraryMenuAction.snapshot.isEnabled(in: window))
        #expect(!LibraryMenuAction.addFiles.isEnabled(in: window))
        #expect(!LibraryMenuAction.reflect.isEnabled(in: window))
        #expect(!LibraryMenuAction.restore.isEnabled(in: window))
        #expect(!LibraryMenuAction.removeTracks.isEnabled(in: window))
        #expect(!LibraryMenuAction.exportXML.isEnabled(in: window))
        #expect(!LibraryMenuAction.exportLibraryXML.isEnabled(in: window))
        #expect(LibraryMenuAction.pointSnapshots.isEnabled(in: window), "라이브러리를 읽기 전에도 스냅샷 목록은 본다")
        store.phase = .loading("시험")
        #expect(!LibraryMenuAction.snapshot.isEnabled(in: window))
        store.phase = .loaded
        store.isWritingRekordbox = true
        for action in LibraryMenuAction.allCases { #expect(!action.isEnabled(in: window)) }
    }
}
