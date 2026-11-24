@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 상태 줄의 칩·저장 단추·⌘S를 엔진 상태(`AutoReflectionFeed`)에서 R3 표 순서대로 보인다(#404, R3).
/// 줄을 고르는 규칙은 `ReflectionStatusRowTests`(DJCApplicationTests)가 촘촘히 본다. 여기는 줄마다 화면이 어떻게 보이는지(글자·단추·⌘S)와
/// 줄이 겹치는 조합을 본다. 엔진이 없는 조립(화면 시험·진단)은 `ReflectionStatusModelTests`가 지금 동작 그대로 본다.
@MainActor
@Suite("상태 줄 R3 줄 화면")
struct ReflectionStatusRowsModelTests {
    typealias Harness = ReflectionStatusModelTests.Harness

    /// 엔진이 알린 상태를 넣은 하네스. `pending`이 참이면 곡 초안 하나가 저장 대기에 있다(저장 대기 1건)
    func harness(_ status: AutoReflectionStatus, holds: Set<ReflectionHold> = [], leftovers: Set<ReflectionLeftover> = [], writing: Bool = false,
                 pending: Bool = true, autoSaves: Bool = true, editingField: Bool = false) -> Harness {
        let h = Harness()
        let feed = AutoReflectionFeed()
        h.window.autoFeed = feed
        if pending {
            h.addRows("a")
            h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        }
        feed.update(status, ReflectionConditions(holds: holds, leftovers: leftovers, writing: writing, hasPending: pending || writing,
                                                 editingField: editingField, autoSaves: autoSaves))
        h.model.refresh()
        return h
    }

    // MARK: - 줄마다

    @Test func 중단은_복원_안내만_보이고_저장_단추는_숨는다() {
        let broken = harness(.interrupted(recoveryFailed: false), holds: [.interrupted(recoveryFailed: false)])
        #expect(broken.model.saveRow == .interrupted && !broken.model.showsWriteButton)
        #expect(broken.model.line.title == "쓰다가 중단된 기록이 있습니다" && broken.model.line.symbol == .interrupted)
        #expect(broken.model.journalActions == [.restore, .keep], "기본 차례는 복원이 먼저다")
        let failed = harness(.interrupted(recoveryFailed: true), holds: [.interrupted(recoveryFailed: true)])
        #expect(failed.model.line.title == "복구하지 못한 쓰기가 있습니다" && failed.model.line.symbol == .interrupted)
    }

    @Test func 중단_뒤_rekordbox가_라이브러리를_바꿨으면_이대로_두기를_먼저_보인다() {
        let h = harness(.interrupted(recoveryFailed: false), holds: [.interrupted(recoveryFailed: false)])
        let stamp = RekordboxFileStamp(size: 10, modifiedNanoseconds: 20)
        let journal = RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts, startCounter: 3)
        h.window.autoFeed?.setFinding(RekordboxJournalFinding(journal: journal, changedSince: true, database: stamp))
        #expect(h.model.journalActions == [.keep, .restore])
        h.window.autoFeed?.setFinding(RekordboxJournalFinding(journal: journal, changedSince: false, database: stamp))
        #expect(h.model.journalActions == [.restore, .keep])
        // 중단이 풀리면 찾은 값도 비운다(다음 중단이 옛 값을 보이지 않게)
        h.window.autoFeed?.update(.saved, ReflectionConditions(autoSaves: true))
        #expect(h.window.autoFeed?.finding == nil && h.model.journalActions.isEmpty)
    }

    @Test func 중단이_나타난_때_한_번만_기록을_찾는다() {
        let feed = AutoReflectionFeed()
        var asked = 0
        feed.onInterrupted = { asked += 1 }
        let interrupted = ReflectionConditions(holds: [.interrupted(recoveryFailed: false)], hasPending: true, autoSaves: true)
        feed.update(.interrupted(recoveryFailed: false), interrupted)
        feed.update(.interrupted(recoveryFailed: false), interrupted)
        #expect(asked == 1, "같은 중단 동안 다시 찾지 않는다")
        feed.update(.saved, ReflectionConditions(autoSaves: true))
        feed.update(.interrupted(recoveryFailed: true), ReflectionConditions(holds: [.interrupted(recoveryFailed: true)], autoSaves: true))
        #expect(asked == 2, "다음 중단은 새로 찾는다")
    }

    @Test func 쓸_수_없음은_이유를_툴팁으로_보이고_단추는_숨는다() {
        let h = harness(.held(.unwritable(.counters)), holds: [.unwritable(.counters)])
        #expect(h.model.saveRow == .unwritable && !h.model.showsWriteButton)
        #expect(h.model.line.title == "rekordbox에 저장할 수 없음 · 저장 대기 1건" && h.model.line.symbol == .warning)
        #expect(h.model.line.help == LibraryWriteBlock.counters.reason)
        // 저장 대기가 없어도 편집하기 전에 알린다
        let idle = harness(.held(.unwritable(.schema)), holds: [.unwritable(.schema)], pending: false)
        #expect(idle.model.saveRow == .unwritable && idle.model.line.title == "rekordbox에 저장할 수 없음")
    }

    @Test func 켜짐_시트_USB_쓰기는_이유를_보이고_단추가_숨는다() {
        let cases: [(ReflectionHold, String)] = [
            (.rekordboxRunning, "rekordbox가 켜져 있습니다 · 저장 대기 1건"),
            (.agentRunning, "rekordboxAgent가 켜져 있습니다 · 저장 대기 1건"),
            (.blockedDraftsOpen, "막힌 편집 비교 창이 열려 있습니다 · 저장 대기 1건"),
            (.importSheetOpen, "가져오기 창이 열려 있습니다 · 저장 대기 1건"),
            (.usbBusy, "USB에 쓰는 중… · 저장 대기 1건"),
            (.walRemains, "rekordbox가 정상 종료되지 않았습니다 · 저장 대기 1건"),
        ]
        for (hold, title) in cases {
            let h = harness(.held(hold), holds: [hold])
            #expect(h.model.saveRow == .busy && !h.model.showsWriteButton, "\(hold)")
            #expect(h.model.line.title == title, "\(hold)")
        }
    }

    @Test func 저장_대기가_없으면_저장됨이고_단추가_숨는다() {
        let h = harness(.saved, pending: false)
        #expect(h.model.saveRow == .nothingPending && !h.model.showsWriteButton)
        #expect(h.model.line.title == "저장 대기 없음" && h.model.line.symbol == .saved)
    }

    @Test func 쓰는_중은_1초_뒤에_보이고_단추가_숨는다() async {
        let h = harness(.writing, writing: true)
        #expect(h.model.saveRow == .writing && !h.model.showsWriteButton)
        #expect(h.model.line.title == "저장 대기 1건", "짧은 쓰기가 깜빡이지 않게 쓰기 단계가 1초 이어질 때만 쓰는 중으로 바꾼다")
        h.store.isWritingRekordbox = true
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.line.title == "rekordbox에 저장하는 중…" })
        #expect(h.model.line.symbol == .writing)
    }

    @Test func 자동_저장하지_않는_실행은_저장_단추가_보인다() {
        let h = harness(.held(.notAutoRun(.debugBuild)), holds: [.notAutoRun(.debugBuild)], autoSaves: false)
        #expect(h.model.saveRow == .manualRun && h.model.showsWriteButton && h.model.writeButtonTitle == "저장")
        #expect(h.model.line.title == "저장 대기 1건" && h.model.line.symbol == .pending)
    }

    @Test func 멈춤은_이유를_보이고_저장_단추가_보인다() {
        let failed = harness(.stopped(.stoppedAfterFailure), holds: [.stoppedAfterFailure])
        #expect(failed.model.saveRow == .stopped && failed.model.showsWriteButton)
        #expect(failed.model.line.title == "저장하지 못해 자동 저장이 멈췄습니다 · 저장 대기 1건" && failed.model.line.symbol == .stopped)
        let restored = harness(.stopped(.stoppedAfterRestore), holds: [.stoppedAfterRestore])
        #expect(restored.model.line.title == "복원해서 자동 저장이 멈췄습니다 · 저장 대기 1건")
    }

    @Test func 남은_편집은_건수와_첫_이유를_보이고_저장_단추가_보인다() {
        let cases: [(ReflectionLeftover, String)] = [
            (.outsideScope, "자동 저장 대상이 아님"), (.suggestion, "다른 곳에서 만든 편집"), (.needsConfirmation, "확인이 필요함"),
            (.cancelled, "자동 저장을 취소함"), (.overRowLimit, "양이 많아 자동 저장하지 않음"), (.undoOverRowLimit, "양이 많아 자동 저장하지 않음"),
            (.noBase, "기준 값이 없음"),
        ]
        for (leftover, reason) in cases {
            let h = harness(.leftover(count: 1), leftovers: [leftover])
            #expect(h.model.saveRow == .leftover && h.model.showsWriteButton, "\(leftover)")
            #expect(h.model.line.title == "저장 대기 1건 · \(reason)", "\(leftover)")
        }
        let holds: [(ReflectionHold, String)] = [(.backupNoClone, "백업 폴더가 다른 디스크임"), (.lowDiskSpace, "디스크 공간이 모자람"),
                                                 (.preBackupFailure, "백업을 만들지 못함")]
        for (hold, reason) in holds {
            let h = harness(.leftover(count: 1), holds: [hold])
            #expect(h.model.saveRow == .leftover && h.model.showsWriteButton && h.model.line.title == "저장 대기 1건 · \(reason)", "\(hold)")
        }
    }

    @Test func 자동_저장_대기는_이유를_보이고_저장_단추가_숨는다() {
        let pending = harness(.pending)
        #expect(pending.model.saveRow == .waiting && !pending.model.showsWriteButton && pending.model.line.title == "저장 대기 1건")
        let cases: [(ReflectionHold, String)] = [
            (.quietWaiting, "rekordbox가 꺼졌습니다 · 저장 대기 1건"), (.linkServer, "LINK가 켜져 있습니다 · 저장 대기 1건"),
            (.pointSnapshot, "복원 시점을 남기는 중… · 저장 대기 1건"), (.libraryReading, "rekordbox 라이브러리를 읽는 중… · 저장 대기 1건"),
            (.lockBusy, "다른 프로그램이 쓰는 중… · 저장 대기 1건"), (.editing, "저장 대기 1건"),
        ]
        for (hold, title) in cases {
            let h = harness(.held(hold), holds: [hold])
            #expect(h.model.saveRow == .waiting && !h.model.showsWriteButton, "\(hold)")
            #expect(h.model.line.title == title, "\(hold)")
        }
    }

    @Test func 재생_목록_초안을_저장하지_못했으면_팝오버가_그_이유를_한_번_말한다() {
        let h = harness(.leftover(count: 1), leftovers: [.needsConfirmation])
        #expect(!h.model.line.details.contains(ReflectionSession.playlistSaveFailureText))
        h.store.playlists.playlistDraftUnsaved = true
        #expect(h.model.line.details == [ReflectionSession.playlistSaveFailureText])
        #expect(h.model.popoverLines.filter { $0 == ReflectionSession.playlistSaveFailureText }.count == 1)
        // 남은 편집 줄이 아니면 이 이유를 말하지 않는다(다른 줄의 주 알림 자리가 이유를 말한다)
        let waiting = harness(.pending)
        waiting.store.playlists.playlistDraftUnsaved = true
        #expect(!waiting.model.line.details.contains(ReflectionSession.playlistSaveFailureText))
    }

    // MARK: - 대량 유예

    @Test func 대량_유예는_남은_초와_취소를_보인다() {
        let h = harness(.grace(secondsLeft: 12))
        #expect(h.model.saveRow == .waiting && !h.model.showsWriteButton)
        #expect(h.model.line.title == "12초 뒤 저장" && h.model.graceSecondsLeft == 12)
        h.window.autoFeed?.update(.pending, ReflectionConditions(hasPending: true, autoSaves: true))
        #expect(h.model.graceSecondsLeft == nil)
    }

    @Test func 엔진이_있으면_rekordbox가_꺼져도_저장_단추를_강조하지_않는다() async {
        let h = harness(.leftover(count: 1), leftovers: [.suggestion])
        h.run.state = .running
        h.model.refresh()
        h.run.state = .stopped
        h.model.refresh()
        h.settle.release()
        #expect(await waitForState { h.model.chip.reason == .rekordboxStopped }, "지금 칩의 꺼짐 판정은 그대로 돈다")
        #expect(h.model.showsWriteButton && !h.model.emphasizesWrite && h.model.writeButtonTitle == "저장")
    }

    // MARK: - 줄이 겹칠 때

    @Test func USB에_쓰는_중에_CLI_제안이_남으면_3번_줄이라_단추가_숨고_이유를_보인다() {
        let h = harness(.held(.usbBusy), holds: [.usbBusy], leftovers: [.suggestion])
        #expect(h.model.saveRow == .busy && !h.model.showsWriteButton && h.model.saveCommand == .refuseWithReason)
        #expect(h.model.line.title == "USB에 쓰는 중… · 저장 대기 1건")
    }

    @Test func 멈춤이어도_저장_대기가_없으면_4번_줄이라_단추가_숨는다() {
        let h = harness(.stopped(.stoppedAfterFailure), holds: [.stoppedAfterFailure], pending: false)
        #expect(h.model.saveRow == .nothingPending && !h.model.showsWriteButton && h.model.line.title == "저장 대기 없음")
    }

    @Test func 디버그_실행에_rekordbox가_켜져_있으면_3번_줄이라_단추가_숨는다() {
        let h = harness(.held(.notAutoRun(.debugBuild)), holds: [.notAutoRun(.debugBuild), .rekordboxRunning], autoSaves: false)
        #expect(h.model.saveRow == .busy && !h.model.showsWriteButton)
        #expect(h.model.line.title == "rekordbox가 켜져 있습니다 · 저장 대기 1건")
    }

    @Test func 쓰는_중에_대상_밖_편집이_남으면_5번_줄이라_단추가_숨는다() {
        let h = harness(.writing, leftovers: [.outsideScope], writing: true)
        #expect(h.model.saveRow == .writing && !h.model.showsWriteButton && h.model.saveCommand == .queueFront)
    }

    @Test func 자동_저장하지_않는_실행에_LINK가_켜져_있으면_6번_줄이라_단추가_보인다() {
        let h = harness(.held(.notAutoRun(.explicitCopy)), holds: [.notAutoRun(.explicitCopy), .linkServer], autoSaves: false)
        #expect(h.model.saveRow == .manualRun && h.model.showsWriteButton && h.model.saveCommand == .saveNow)
    }

    // MARK: - 엔진이 없는 조립(지금 동작)

    @Test func 엔진이_없으면_저장_대기가_있을_때_단추가_보이는_지금_동작_그대로다() {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        #expect(h.window.autoFeed == nil && h.model.saveRow == .manualRun && h.model.showsWriteButton)
        #expect(h.model.line.title == h.model.chip.title && h.model.graceSecondsLeft == nil && h.model.journalActions.isEmpty)
    }
}
