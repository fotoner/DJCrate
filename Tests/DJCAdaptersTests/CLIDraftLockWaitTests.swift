import DJCAdapters
import DJCApplication
import Foundation
import Testing

/// CLI가 재생 목록 초안 파일 잠금을 기다리는 시간(R24). 앱의 자동 저장은 재생 목록 단계를 쓰는 동안 이 잠금을 쥔다.
/// 출시 관문 측정(E1, 2026-11-24, 전체 사본에 K행(큐·그리드·재생 목록) 묶음 5회)에서 자동 저장 한 번 전체가 최대 22.7초였다(첫 측정 13.3초):
/// 그보다 길게 기다려 자동 저장 중에 실행한 `djc draft`가 `draft_busy`로 끝나지 않고 그 저장 뒤에 쌓게 한다
@Suite("CLI 초안 잠금 대기")
struct CLIDraftLockWaitTests {
    @Test func 자동_저장_한_번보다_길게_기다린다() {
        #expect(DraftFiles.cliPlaylistLockWait == 30)
        #expect(DraftFiles.cliPlaylistLockWait > 22.7, "E1에서 잰 자동 저장 한 번 전체의 최댓값보다 길어야 한다")
    }
}
