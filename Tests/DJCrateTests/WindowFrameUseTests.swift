@testable import DJCrate
import Testing

/// 주 창 위치를 사용자 환경설정에 남기는지(R18: 창 위치 저장도 진단 실행 규칙을 따른다). 진단 실행(자가 테스트·측정·캡처)은 남기지 않는다.
/// 기존 `--quit-wait-selftest`가 창 위치를 남긴 일이 있었다(#406 1라운드 자가 테스트, 2026-11-24)
@MainActor
@Suite("주 창 위치 저장")
struct WindowFrameUseTests {
    @Test func 보통_실행과_명시한_사본은_창_위치를_읽고_남긴다() {
        #expect(DJCrateApp.windowFrameUse(arguments: ["DJCrate"]) == .restoreAndSave)
        #expect(DJCrateApp.windowFrameUse(arguments: ["DJCrate", "--db", "/tmp/x/master.db"]) == .restoreAndSave)
    }

    @Test(arguments: [["--quit-wait-selftest"], ["--quit-wait-selftest", "--quit-wait-poweroff"], ["--write-selftest"],
                      ["--xml-export-capture=/tmp/x"], ["--ui-perf=all"], ["--autoplay"]])
    func 진단_실행은_창_위치를_남기지_않는다(_ extra: [String]) {
        let use = DJCrateApp.windowFrameUse(arguments: ["DJCrate"] + extra)
        #expect(use != .restoreAndSave, "\(extra)")
    }

    @Test(arguments: [["--resize-perf=all"], ["--playlist-recovery-selftest"], ["--auto-reflect-selftest=save"]])
    func 기본_크기로_도는_진단_실행은_창_위치를_읽지도_않는다(_ extra: [String]) {
        #expect(DJCrateApp.windowFrameUse(arguments: ["DJCrate"] + extra) == .none)
    }
}
