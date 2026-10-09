@testable import DJCrate
import DJCDomain
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("메뉴 — 구성·단축키·덱 동작")
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

    @Test func 덱_메뉴는_단축키_표의_모든_동작을_한번씩_포함한다() {
        let actions = DeckAction.Group.allCases.flatMap { DeckMenuCommand.actions(in: $0) }
        #expect(actions == DeckAction.allCases)
        #expect(Set(actions).count == actions.count)
    }

    @Test func 메뉴의_키_안내는_바꾼_키와_삭제한_키를_따른다() throws {
        var shortcuts = DeckShortcuts.standard
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts) == "Space")
        try shortcuts.replace(49, with: 35, in: .playPause)
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts) == "P")
        shortcuts.remove(35, from: .playPause)
        #expect(DeckMenuCommand.action(.playPause).keyLabel(shortcuts: shortcuts).isEmpty)
        try shortcuts.replace(18, with: 7, in: .hotCueA)
        #expect(DeckMenuCommand.deleteHotCue(0).keyLabel(shortcuts: shortcuts) == "⇧X · ⇧숫자패드 1")
        #expect(DeckMenuCommand.moveHotCue(0).keyLabel(shortcuts: shortcuts).isEmpty)
    }

    @Test func 키가_없거나_겹쳐도_메뉴는_고른_동작을_한번만_실행한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.shortcuts.remove(49, from: .playPause)
        let play = DeckMenuCommand.action(.playPause)
        play.perform(on: h.deck)
        #expect(h.deck.isPlaying)
        play.perform(on: h.deck)
        #expect(!h.deck.isPlaying)
        try h.deck.shortcuts.add(46, to: .tapTempo)
        DeckMenuCommand.action(.tapTempo).perform(on: h.deck)
        #expect(h.deck.taps.count == 1)
        #expect(h.deck.draft?.cues.isEmpty == true)
    }

    @Test func 메뉴_CUE는_누르기와_떼기를_마쳐_미리듣기가_남지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        let cue = DeckMenuCommand.action(.cue)
        cue.perform(on: h.deck)
        #expect(h.deck.cuePoint == 10.5)
        cue.perform(on: h.deck)
        #expect(!h.deck.isCuePreviewing)
        #expect(!h.deck.isPlaying)
        h.deck.togglePlay()
        cue.perform(on: h.deck)
        #expect(!h.deck.isPlaying)
    }

    @Test func 핫큐_메뉴는_찍기_옮기기_지우기를_제공한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let move = DeckMenuCommand.moveHotCue(0), delete = DeckMenuCommand.deleteHotCue(0)
        #expect(!move.isEnabled(on: h.deck))
        #expect(!delete.isEnabled(on: h.deck))
        h.deck.seek(10.5)
        DeckMenuCommand.action(.hotCueA).perform(on: h.deck)
        #expect(move.isEnabled(on: h.deck))
        h.deck.seek(20.5)
        move.perform(on: h.deck)
        #expect(h.deck.hotCue(slot: 0)?.time == 20.5)
        delete.perform(on: h.deck)
        #expect(h.deck.hotCue(slot: 0) == nil)
    }

    @Test func 쓰기_중에는_메뉴로_재생하거나_편집할_수_없다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.isWriteLocked = true
        for action in DeckAction.allCases {
            let command = DeckMenuCommand.action(action)
            #expect(!command.isEnabled(on: h.deck))
            command.perform(on: h.deck)
        }
        #expect(!h.deck.isPlaying)
        #expect(h.deck.draft?.cues.isEmpty == true)
        #expect(h.deck.taps.isEmpty)
    }

    @Test func 박_이동과_제안_메뉴는_단축키와_같은_함수를_부른다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10)
        #expect(DeckMenuCommand.action(.nudgeForward).isEnabled(on: h.deck), "선택한 큐가 없으면 재생 위치를 옮긴다")
        DeckMenuCommand.action(.nudgeForward).perform(on: h.deck)
        #expect(h.deck.currentTime == 10.5)
        DeckMenuCommand.stepBar(forward: true).perform(on: h.deck)
        #expect(h.deck.currentTime == 12.5)
        DeckMenuCommand.stepBar(forward: false).perform(on: h.deck)
        DeckMenuCommand.action(.nudgeBack).perform(on: h.deck)
        #expect(h.deck.currentTime == 10)

        for command in [DeckMenuCommand.action(.nextSuggestion), .previousSuggestion, .action(.acceptSuggestion)] {
            #expect(!command.isEnabled(on: h.deck), "제안이 없으면 끈다")
        }
        h.deck.suggestions = [20, 30]
        DeckMenuCommand.action(.nextSuggestion).perform(on: h.deck)
        DeckMenuCommand.action(.nextSuggestion).perform(on: h.deck)
        #expect(h.deck.currentTime == 30)
        DeckMenuCommand.previousSuggestion.perform(on: h.deck)
        #expect(h.deck.currentTime == 20)
        h.deck.seek(21)
        DeckMenuCommand.action(.acceptSuggestion).perform(on: h.deck)
        #expect(h.deck.draft?.cues.map(\.time) == [20])
        h.deck.isWriteLocked = true
        for command in [DeckMenuCommand.stepBar(forward: true), .stepBar(forward: false), .previousSuggestion] {
            #expect(!command.isEnabled(on: h.deck))
        }
    }

    @Test func Shift_동작은_메뉴에서_원래_동작_바로_아래에_Shift_키와_함께_있다() {
        #expect(DeckMenuCommand.variants(after: .memoryCue) == [.deleteMemoryCue])
        #expect(DeckMenuCommand.variants(after: .nudgeBack) == [.stepBar(forward: false)])
        #expect(DeckMenuCommand.variants(after: .nudgeForward) == [.stepBar(forward: true)])
        #expect(DeckMenuCommand.variants(after: .nextSuggestion) == [.previousSuggestion])
        #expect(DeckMenuCommand.variants(after: .acceptSuggestion).isEmpty)
        #expect(DeckMenuCommand.stepBar(forward: false).keyLabel(shortcuts: .standard) == "⇧←")
        #expect(DeckMenuCommand.previousSuggestion.keyLabel(shortcuts: .standard) == "⇧S")
        #expect(DeckMenuCommand.action(.acceptSuggestion).keyLabel(shortcuts: .standard) == "A")
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
        #expect(LibraryMenuAction.rekordboxActions == [.reflect, .pending, .writeResult, .restore, .pointSnapshots, .removeTracks])
        #expect(LibraryMenuAction.fileActions + LibraryMenuAction.rekordboxActions == LibraryMenuAction.allCases)
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
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(LibraryMenuAction.snapshot.isEnabled(in: store))
        #expect(!LibraryMenuAction.addFiles.isEnabled(in: store))
        #expect(!LibraryMenuAction.reflect.isEnabled(in: store))
        #expect(!LibraryMenuAction.restore.isEnabled(in: store))
        #expect(!LibraryMenuAction.removeTracks.isEnabled(in: store))
        #expect(!LibraryMenuAction.exportXML.isEnabled(in: store))
        #expect(!LibraryMenuAction.exportLibraryXML.isEnabled(in: store))
        #expect(LibraryMenuAction.pointSnapshots.isEnabled(in: store), "라이브러리를 읽기 전에도 스냅샷 목록은 본다")
        store.phase = .loading("시험")
        #expect(!LibraryMenuAction.snapshot.isEnabled(in: store))
        store.phase = .loaded
        store.isWritingRekordbox = true
        for action in LibraryMenuAction.allCases { #expect(!action.isEnabled(in: store)) }
    }
}
