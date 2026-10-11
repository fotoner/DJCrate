@testable import DJCDomain
import Foundation
import Testing

@Suite("시간축 이동")
struct TimelineShiftTests {
    @Test func 옮겼다_되돌리면_원래대로() {
        let draft = GridDraft(trackUUID: "t", base: [GridSegment(start: 0.2, bpm: 150, firstBeatNumber: 1)],
                              segments: [GridSegment(start: 0.25, bpm: 151, firstBeatNumber: 3)])
        let back = draft.shifted(by: -0.0512).shifted(by: 0.0512)
        #expect(abs(back.segments[0].start - 0.25) < 1e-9 && abs(back.base[0].start - 0.2) < 1e-9)
        #expect(!draft.shifted(by: 0.05).hasChanges == !draft.hasChanges)

        var cues = CueDraft(trackUUID: "t")
        cues.cues = [EditableCue(kind: .memory, time: 1.0)]
        #expect(abs(cues.shifted(by: -0.048).cues[0].time - 0.952) < 1e-9)
    }
}
