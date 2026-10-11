@testable import DJCDomain
import Foundation
import Testing

@Suite("곡 편집 화면 규칙: 출력 마디 수")
struct EditPlanTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초, 100.5초 = 0마디 + 50마디
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    // MARK: - 출력 마디 수

    @Test func 출력_마디_수는_곡_머리를_빼고_잘린_마지막_마디는_센다() throws {
        #expect(try TrackEdit(grid: grid, sourceDuration: 100.5, bars: [BarRange(0, 16), BarRange(1, 16)]).barCount == 32)
        #expect(try TrackEdit(grid: grid, sourceDuration: 100.5, bars: [BarRange(1, 16), BarRange(17, 50)]).barCount == 50)
        #expect(try TrackEdit(grid: grid, sourceDuration: 101.5, bars: [BarRange(48, 51)]).barCount == 4)
    }
}
