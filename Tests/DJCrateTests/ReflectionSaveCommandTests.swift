@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// ⌘S(메뉴 「rekordbox에 저장」)가 R3 표의 줄마다 하는 일(#404, R3·R19). 줄을 고르는 규칙은 `ReflectionStatusRowTests`가 본다.
/// 엔진이 없는 조립은 지금 동작(저장 대기가 있으면 저장)이라 `MenuCommandTests`가 그대로 본다.
@MainActor
@Suite("⌘S R3 줄 동작")
struct ReflectionSaveCommandTests {
    @MainActor
    struct World {
        let h: ReflectionStatusModelTests.Harness
        let feed = AutoReflectionFeed()
        let coordinator: ReflectionCoordinator
        let input = FieldEditingState()
    }

    @MainActor
    final class Counter { var commits = 0 }

    func world(_ status: AutoReflectionStatus = .pending, holds: Set<ReflectionHold> = [], leftovers: Set<ReflectionLeftover> = [],
               writing: Bool = false, pending: Bool = true, autoSaves: Bool = true, editingField: Bool = false) -> (World, Counter) {
        let h = ReflectionStatusModelTests.Harness()
        let world = World(h: h, coordinator: h.store.reflection)
        let counter = Counter()
        world.input.commit = { [input = world.input] in
            counter.commits += 1
            input.isEditing = false
        }
        world.input.isEditing = editingField
        h.window.autoFeed = world.feed
        h.window.fieldEditing = world.input
        if pending {
            h.addRows("a")
            h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        }
        world.feed.update(status, ReflectionConditions(holds: holds, leftovers: leftovers, writing: writing, hasPending: pending || writing,
                                                       editingField: false, autoSaves: autoSaves))
        return (world, counter)
    }

    func press(_ world: World) {
        LibraryMenuAction.reflect.perform(in: world.h.window, windows: nil, reflection: world.coordinator)
    }

    /// 쓰기를 시작했는지(쓰기 작업이 생겼다). 시작한 작업은 끝까지 기다려 정리한다
    func startedWrite(_ world: World) async -> Bool {
        let task = world.h.store.writeTask
        await task?.value
        return task != nil
    }

    // MARK: - 줄마다

    @Test func 중단_뒤에는_쓰지_않고_복원_안내를_보인다() async {
        let (w, _) = world(.interrupted(recoveryFailed: false), holds: [.interrupted(recoveryFailed: false)])
        #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window), "눌러도 아무 일이 없으면 안 되니 켜 두고 이유를 보인다")
        press(w)
        #expect(await !startedWrite(w))
        #expect(w.h.store.toast?.title == String(ui: "이 라이브러리에 끝나지 않은 저장 기록이 남아 있어 저장하지 않았습니다. DJCrate 상태 줄에서 기록으로 복원하거나 이대로 두세요"))
    }

    @Test func 쓸_수_없으면_이유를_보이고_쓰지_않는다() async {
        let (w, _) = world(.held(.unwritable(.counters)), holds: [.unwritable(.counters)])
        #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window))
        press(w)
        #expect(await !startedWrite(w))
        #expect(w.h.store.toast?.title == LibraryWriteBlock.counters.reason)
    }

    @Test func 켜짐_시트_USB_쓰기는_이유를_보이고_쓰지_않는다() async {
        let cases: [(ReflectionHold, String)] = [
            (.rekordboxRunning, "rekordbox가 켜져 있어 저장하지 않았습니다"),
            (.agentRunning, "rekordboxAgent가 켜져 있습니다"),
            (.importSheetOpen, "가져오기 창에서 적용하거나 닫은 뒤 다시 시도하세요"),
            (.usbBusy, "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요"),
            (.walRemains, "rekordbox가 정상적으로 종료되지 않은 것 같습니다(WAL 파일이 남아 있음). rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요"),
            (.cleanupPending, ReflectionSession.playlistSaveFailureText),
        ]
        for (hold, title) in cases {
            let (w, _) = world(.held(hold), holds: [hold])
            #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window), "\(hold)")
            press(w)
            #expect(await !startedWrite(w), "\(hold)")
            #expect(w.h.store.toast?.title == title, "\(hold): \(String(describing: w.h.store.toast?.title))")
            #expect(w.h.store.toast?.kind == .warning)
        }
    }

    @Test func 저장_대기가_없으면_꺼지고_입력_중인_칸이_있으면_켜져_확정한_뒤_저장한다() async {
        let (idle, _) = world(.saved, pending: false)
        #expect(!LibraryMenuAction.reflect.isEnabled(in: idle.h.window))
        // 입력 중인 칸이 있으면 저장 대기가 0이어도 켜진다(R19, #375)
        let (typing, counter) = world(.saved, pending: false, editingField: true)
        #expect(LibraryMenuAction.reflect.isEnabled(in: typing.h.window))
        press(typing)
        #expect(counter.commits == 1, "입력 중인 칸을 확정한다")
        // 확정이 만든 편집이 없으면 쓰지 않고 지금의 안내를 보인다(저장할 편집이 보이기를 잠깐 기다린 뒤)
        #expect(await waitForState { typing.h.store.toast != nil })
        #expect(typing.h.store.writeTask == nil)
        #expect(typing.h.store.toast?.title == LibraryMenuAction.reflect.disabledReason(in: typing.h.window))
    }

    @Test func 입력_중인_칸의_확정이_만든_편집은_저장한다() async {
        let (w, counter) = world(.saved, pending: false, editingField: true)
        // 칸을 확정하면 편집(저장 대기)이 생긴다
        w.input.commit = { [h = w.h, input = w.input] in
            counter.commits += 1
            h.addRows("a")
            h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
            input.isEditing = false
        }
        press(w)
        #expect(counter.commits == 1 && w.h.store.pendingWriteCount == 1)
        #expect(await waitForState { w.h.store.writeTask != nil || w.h.store.rekordboxWriteCount > 0 }, "확정한 뒤 5~9번 줄을 따라 저장한다")
        await w.h.store.writeTask?.value
    }

    @Test func 저장_대기가_있으면_입력_중인_칸도_확정하고_저장한다() async {
        let (w, counter) = world(.pending, editingField: true)
        press(w)
        #expect(counter.commits == 1)
        #expect(await waitForState { w.h.store.writeTask != nil || w.h.store.rekordboxWriteCount > 0 })
        await w.h.store.writeTask?.value
    }

    @Test func 쓰는_중에도_눌러_다음_차례로_넣는다() async {
        let (w, _) = world(.writing, writing: true)
        w.h.store.isWritingRekordbox = true
        #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window), "자동 저장이 쓰는 동안에도 켜 둔다(대기열 맨 앞)")
        // 수동 저장이 도는 중에도 켜 둔다: 요청 하나를 보관해 앞 쓰기가 끝난 뒤 한다(sol S4, `ReflectionSaveEntryTests`)
        w.h.store.writeTask = Task {}
        #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window))
        w.h.store.writeTask = nil
    }

    @Test func 자동_저장하지_않는_실행_멈춤_남은_편집_대기는_지금_저장한다() async {
        let cases: [(AutoReflectionStatus, Set<ReflectionHold>, Set<ReflectionLeftover>, Bool)] = [
            (.held(.notAutoRun(.debugBuild)), [.notAutoRun(.debugBuild)], [], false),
            (.stopped(.stoppedAfterFailure), [.stoppedAfterFailure], [], true),
            (.leftover(count: 1), [], [.suggestion], true),
            (.pending, [], [], true),
            (.held(.lockBusy), [.lockBusy], [], true),
        ]
        for (status, holds, leftovers, autoSaves) in cases {
            let (w, _) = world(status, holds: holds, leftovers: leftovers, autoSaves: autoSaves)
            #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window), "\(status)")
            press(w)
            #expect(await startedWrite(w), "\(status)")
        }
    }

    @Test func 저장_대기가_없는데_줄이_저장_줄이면_꺼진다() {
        let (w, _) = world(.pending, pending: false)
        // 엔진이 아직 대기를 모르는 사이(방금 비움)에도 저장할 것이 없으면 켜지 않는다
        w.feed.update(.pending, ReflectionConditions(hasPending: true, autoSaves: true))
        #expect(!LibraryMenuAction.reflect.isEnabled(in: w.h.window))
    }

    // MARK: - 엔진이 없는 조립(지금 동작)

    @Test func 엔진이_없으면_저장_대기가_있을_때만_켜진다() async {
        let h = ReflectionStatusModelTests.Harness()
        #expect(!LibraryMenuAction.reflect.isEnabled(in: h.window))
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        #expect(LibraryMenuAction.reflect.isEnabled(in: h.window))
    }

    // MARK: - 입력 중인 칸 확정(R19, 실제 AppKit 입력 칸)

    /// 곡 목록 칸에서 글자를 치다(Return 전) ⌘S를 누르면 그 값을 확정해 저장 대기로 만든 뒤 저장한다
    @Test func 곡_목록_칸에서_입력_중에_저장하면_확정한_값을_저장한다() async throws {
        let a = TrackListTagEditTests.row("1", title: "원래")
        let h = ListHarness(rows: [a], selection: [a.id])
        defer { h.close() }
        let input = FieldEditingState.live(window: { h.window })
        defer { input.stop() }
        h.store.rowsByUUID[a.track.uuid] = a
        let window = LibraryWindowModel(store: h.store)
        window.fieldEditing = input
        window.autoFeed = AutoReflectionFeed()
        window.autoFeed?.update(.saved, ReflectionConditions(hasPending: false, autoSaves: true))
        h.pressReturn()
        h.type("고친 제목")
        #expect(input.isEditing, "글자를 치기 시작하면 입력 중이다")
        #expect(h.store.pendingWriteCount == 0 && LibraryMenuAction.reflect.isEnabled(in: window), "저장 대기가 0이어도 입력 중이면 켜진다")
        let coordinator = ReflectionCoordinator.test(store: h.store, gate: .restoringOnly)
        LibraryMenuAction.reflect.perform(in: window, windows: nil, reflection: coordinator)
        #expect(!h.coordinator.isEditing && !input.isEditing, "칸을 확정했다")
        #expect(h.store.tags.tagCell(a, .title) == "고친 제목", "확정한 값이 초안이다")
        #expect(await waitForState { h.store.writeTask != nil || h.store.rekordboxWriteCount > 0 }, "확정한 편집을 저장하는 쓰기가 시작됐다")
        await h.store.writeTask?.value
    }

    @Test func 입력을_끝내면_입력_중이_아니다() throws {
        let a = TrackListTagEditTests.row("1")
        let h = ListHarness(rows: [a], selection: [a.id])
        defer { h.close() }
        let input = FieldEditingState.live(window: { h.window })
        defer { input.stop() }
        h.pressReturn()
        #expect(!input.isEditing, "칸을 열기만 해서는 값이 바뀌지 않았다")
        h.type("글자")
        #expect(input.isEditing)
        h.command(#selector(NSResponder.cancelOperation(_:)))
        #expect(!input.isEditing)
    }

    /// 태그 시트 칸에서 글자를 치다(Return 전) ⌘S를 누르면 그 값을 확정해 저장 대기로 만든다(R19)
    @Test func 태그_시트_칸에서_입력_중에_저장하면_확정한_값을_저장한다() async throws {
        _ = NSApplication.shared
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let rows = (1...2).map { TrackListTagEditTests.row(String($0), title: "합성 곡 \($0)") }
        for row in rows { store.rowsByUUID[row.track.uuid] = row }
        let coordinator = SheetCoordinator(store: store)
        let table = SheetTableView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        table.coordinator = coordinator
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        table.rowHeight = 22
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.width = spec.width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        window.contentView = scroll
        coordinator.update(rows: rows, revision: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        let input = FieldEditingState.live(window: { window })
        defer { input.stop() }
        coordinator.select(.init(row: 1, column: SheetColumn.titleIndex), extend: false)
        coordinator.beginEditing()
        window.contentView?.layoutSubtreeIfNeeded()
        let position = coordinator.cursor
        let cell = try #require(table.view(atColumn: position.column, row: position.row, makeIfNecessary: false) as? SheetCell)
        let editor = try #require(cell.editingField?.currentEditor() as? NSTextView)
        editor.insertText("시트에서 고친 제목", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(input.isEditing && coordinator.isEditing)

        let model = LibraryWindowModel(store: store)
        model.fieldEditing = input
        model.autoFeed = AutoReflectionFeed()
        model.autoFeed?.update(.saved, ReflectionConditions(hasPending: false, autoSaves: true))
        #expect(LibraryMenuAction.reflect.isEnabled(in: model), "저장 대기가 0이어도 입력 중이면 켜진다")
        LibraryMenuAction.reflect.perform(in: model, windows: nil, reflection: ReflectionCoordinator.test(store: store, gate: .restoringOnly))
        #expect(!coordinator.isEditing && !input.isEditing, "시트 칸을 확정했다")
        #expect(store.tags.tagCell(rows[1], .title) == "시트에서 고친 제목")
        #expect(await waitForState { store.writeTask != nil || store.rekordboxWriteCount > 0 }, "확정한 편집을 저장하는 쓰기가 시작됐다")
        await store.writeTask?.value
    }
}
