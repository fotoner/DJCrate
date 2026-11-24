import DJCApplication
import DJCDomain
import Foundation
import Testing

/// R3 표(#404): 엔진이 모은 조건(`ReflectionConditions`)에서 줄(1~9)을 고른다. 한 번에 여러 줄에 들면 위에 있는 줄이다.
/// 줄마다 단추 보임·⌘S 동작 칸은 `AutoReflectionContractTests.상태_줄_표`가 본다. 여기는 어느 줄에 드는지만 본다.
@Suite("상태 줄 R3 줄 고르기")
struct ReflectionStatusRowTests {
    /// 자동 저장하는 실행에서 저장 대기가 있는 조건(줄을 가르는 사유만 바꿔 쓴다)
    static func conditions(holds: Set<ReflectionHold> = [], leftovers: Set<ReflectionLeftover> = [], writing: Bool = false,
                           hasPending: Bool = true, editingField: Bool = false, autoSaves: Bool = true) -> ReflectionConditions {
        ReflectionConditions(holds: holds, leftovers: leftovers, writing: writing, waiting: false, hasPending: hasPending,
                             editingField: editingField, autoSaves: autoSaves)
    }

    // MARK: - 줄마다

    @Test func 중단은_1번_줄이고_복구까지_실패해도_같다() {
        for failed in [false, true] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [.interrupted(recoveryFailed: failed)])) == .interrupted)
        }
    }

    @Test func 쓸_수_없음은_2번_줄이다() {
        let blocks: [LibraryWriteBlock] = [.unsupportedVersion("7.3.0"), .schema, .counters, .backupFolder]
        for block in blocks {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [.unwritable(block)])) == .unwritable)
        }
        // 저장 대기가 없어도 늘 칩이 이유를 보인다
        #expect(ReflectionStatusRow.first(Self.conditions(holds: [.unwritable(.counters)], hasPending: false)) == .unwritable)
        // 하드링크·준비 폴더 불가도 관문이 거절하는 쓸 수 없음이다
        for hold: ReflectionHold in [.hardLinkedDatabase, .stagingUnavailable] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold])) == .unwritable)
        }
    }

    @Test func rekordbox_켜짐_시트_USB_쓰기는_3번_줄이다() {
        // rekordbox·Agent 켜짐, 막힌 초안 비교 창, 가져오기 시트, USB 쓰기 중, 정상 종료되지 않은 -wal(관문이 거절), 정리를 못 마친 목록, 종료 중
        let busy: [ReflectionHold] = [.rekordboxRunning, .agentRunning, .blockedDraftsOpen, .importSheetOpen, .usbBusy, .walRemains,
                                      .cleanupPending, .cleanupStoreMissing, .playlistCopyFailed, .shuttingDown]
        for hold in busy {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold])) == .busy, "\(hold)")
        }
    }

    @Test func 저장_대기가_없으면_4번_줄이고_입력_중인_칸이_있어도_같다() {
        #expect(ReflectionStatusRow.first(Self.conditions(hasPending: false)) == .nothingPending)
        #expect(ReflectionStatusRow.first(Self.conditions(hasPending: false, editingField: true)) == .nothingPending)
        // 보류 사유만 있고 대기가 없으면 사유는 줄을 바꾸지 않는다(멈춤·LINK·편집 중·읽기)
        for hold: ReflectionHold in [.stoppedAfterFailure, .stoppedAfterRestore, .linkServer, .libraryReading, .editing, .lockBusy] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold], hasPending: false)) == .nothingPending, "\(hold)")
        }
        // 쓰는 동안은 대기 수가 아직 0으로 보여도 쓰는 중이다(저장됨으로 보이지 않는다)
        #expect(ReflectionStatusRow.first(Self.conditions(writing: true, hasPending: false)) == .writing)
    }

    @Test func 쓰는_중은_5번_줄이다() {
        #expect(ReflectionStatusRow.first(Self.conditions(writing: true)) == .writing)
        // 자동 저장하지 않는 실행의 수동 저장도 쓰는 중이다
        #expect(ReflectionStatusRow.first(Self.conditions(writing: true, autoSaves: false)) == .writing)
    }

    @Test func 자동_저장하지_않는_실행은_6번_줄이다() {
        #expect(ReflectionStatusRow.first(Self.conditions(holds: [.notAutoRun(.debugBuild)], autoSaves: false)) == .manualRun)
        for off: AutoReflectionRun.Off in [.debugBuild, .explicitCopy, .diagnostic, .unsafeSelfTest] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [.notAutoRun(off)], autoSaves: false)) == .manualRun)
        }
        // 엔진이 없는 조립(화면 시험·진단)은 조건이 기본값이라 지금 동작(저장 대기가 있으면 단추)과 같다
        #expect(ReflectionStatusRow.first(ReflectionConditions(hasPending: true)) == .manualRun)
        #expect(ReflectionStatusRow.first(ReflectionConditions(hasPending: false)) == .nothingPending)
    }

    @Test func 멈춤은_7번_줄이다() {
        for hold: ReflectionHold in [.stoppedAfterFailure, .stoppedAfterRestore] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold])) == .stopped)
        }
    }

    @Test func 남은_편집은_8번_줄이다() {
        let leftovers: [ReflectionLeftover] = [.outsideScope, .suggestion, .needsConfirmation, .cancelled, .overRowLimit, .undoOverRowLimit, .noBase]
        for leftover in leftovers {
            #expect(ReflectionStatusRow.first(Self.conditions(leftovers: [leftover])) == .leftover, "\(leftover)")
        }
        // 백업 조건 미달·백업 전 실패 보류도 남은 편집처럼 단추가 보인다
        for hold: ReflectionHold in [.backupNoClone, .lowDiskSpace, .preBackupFailure] {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold])) == .leftover, "\(hold)")
        }
    }

    @Test func 자동_저장_대기는_9번_줄이다() {
        // 저장 대기·편집 중·조용함 대기·LINK·시점 스냅샷·라이브러리 읽기·다른 프로세스 쓰기 잠금·시작 중
        #expect(ReflectionStatusRow.first(Self.conditions()) == .waiting)
        let waiting: [ReflectionHold] = [.editing, .quietWaiting, .shmRemains, .baseRecheck, .linkServer, .pointSnapshot, .libraryReading,
                                         .lockBusy, .starting]
        for hold in waiting {
            #expect(ReflectionStatusRow.first(Self.conditions(holds: [hold])) == .waiting, "\(hold)")
        }
    }

    // MARK: - 줄이 겹칠 때(위 줄이 이긴다)

    @Test func USB_쓰기_중에_CLI_제안이_남으면_3번_줄이라_단추가_숨는다() {
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.usbBusy], leftovers: [.suggestion]))
        #expect(row == .busy && !row.showsSaveButton && row.saveCommand == .refuseWithReason)
    }

    @Test func 멈춤이어도_저장_대기가_0이면_4번_줄이라_단추가_숨는다() {
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.stoppedAfterFailure], hasPending: false))
        #expect(row == .nothingPending && !row.showsSaveButton)
    }

    @Test func 디버그_실행에_rekordbox가_켜져_있으면_3번_줄이다() {
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.notAutoRun(.debugBuild), .rekordboxRunning], autoSaves: false))
        #expect(row == .busy && !row.showsSaveButton)
    }

    @Test func 쓰는_중에_대상_밖_편집이_남으면_5번_줄이라_단추가_숨는다() {
        let row = ReflectionStatusRow.first(Self.conditions(leftovers: [.outsideScope], writing: true))
        #expect(row == .writing && !row.showsSaveButton && row.saveCommand == .queueFront)
    }

    @Test func 자동_저장하지_않는_실행에_LINK가_켜져_있으면_6번_줄이라_단추가_보인다() {
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.notAutoRun(.explicitCopy), .linkServer], autoSaves: false))
        #expect(row == .manualRun && row.showsSaveButton && row.saveCommand == .saveNow)
    }

    @Test func 멈춤_위에_남은_편집이_있으면_7번_줄이다() {
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.stoppedAfterRestore], leftovers: [.suggestion]))
        #expect(row == .stopped && row.saveCommand == .saveAndResume)
    }

    @Test func 남은_편집_위에_자동_저장_대기가_있어도_8번_줄이라_단추가_남는다() {
        // 남은 편집이 있어도 새 대상 편집은 자동 저장으로 가고 남은 편집은 그대로 단추로 남는다
        let row = ReflectionStatusRow.first(Self.conditions(holds: [.quietWaiting, .linkServer], leftovers: [.cancelled]))
        #expect(row == .leftover && row.showsSaveButton)
    }

    @Test func 중단은_다른_모든_줄_위다() {
        let everything = Self.conditions(holds: [.interrupted(recoveryFailed: false), .unwritable(.counters), .rekordboxRunning, .stoppedAfterFailure,
                                                 .backupNoClone, .lockBusy],
                                         leftovers: [.suggestion], writing: true, editingField: true)
        #expect(ReflectionStatusRow.first(everything) == .interrupted)
        // 쓸 수 없음은 3번 줄 이하 위다
        let unwritable = Self.conditions(holds: [.unwritable(.counters), .rekordboxRunning, .stoppedAfterFailure], writing: true)
        #expect(ReflectionStatusRow.first(unwritable) == .unwritable)
    }
}
