import DJCDomain
import Foundation
@testable import RekordboxKit
import RekordboxFixtures
import Testing

/// 여러 편집을 한 초안으로 쌓았을 때도 미리 보기와 저장 결과가 같은지 확인한다.
struct MultiTempoCombinedEditTests {
    @Test func 반복된_구간을_모두_옮겨도_원본_인덱스를_유지한다() {
        let base = [
            GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
            GridSegment(start: 1.7, bpm: 120, firstBeatNumber: 1),
            GridSegment(start: 2.9, bpm: 120, firstBeatNumber: 1),
            GridSegment(start: 4.1, bpm: 120, firstBeatNumber: 1),
        ]
        var draft = GridDraft(trackUUID: "t", base: base, segments: base)
        draft.shift(by: 0.010)
        #expect(draft.matchingBaseIndices() == [0, 1, 2, 3])
        #expect(draft.preservesBoundary(after: 1))
    }

    @Test func 박_번호를_바꾸고_뒤에_구간을_추가해도_앞_박을_보존한다() throws {
        let (fixture, track, original) = try MultiTempoBoundaryTests().fixture()
        var draft = original
        draft.setDownbeat(nearest: 1, duration: 49)
        draft.addTempoChange(nearest: 20, duration: 49)
        let preview = draft.grid(duration: 49)
        #expect(preview.beats.contains { $0.time == 1.5 && $0.number == 2 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { $0.time == 1.5 && $0.number == 2 })
    }

    @Test func 인접한_두_구간만_같이_옮겨도_유지된_경계_박을_보존한다() throws {
        let (fixture, track, original) = try MultiTempoBoundaryTests().fixture()
        var draft = original
        draft.segments[0].start += 0.01
        draft.segments[1].start += 0.01
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.51 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { $0.time == 1.51 })
    }

    @Test func 전체를_옮긴_뒤_뒤쪽에_구간을_추가해도_앞_경계_박을_보존한다() throws {
        let (fixture, track, original) = try MultiTempoBoundaryTests().fixture()
        var draft = original
        draft.shift(by: 0.010)
        draft.addTempoChange(nearest: 20, duration: 49)
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.51 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { $0.time == 1.51 })
    }

    @Test func 전체를_옮긴_뒤_뒤쪽_구간을_삭제해도_앞_경계_박을_보존한다() throws {
        let (fixture, track, original) = try MultiTempoBoundaryTests().fixture()
        var draft = original
        draft.shift(by: 0.010)
        draft.removeTempoChange(at: 2)
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.51 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { $0.time == 1.51 })
    }

    @Test func 새로_넣은_경계는_가까운_이전_박을_대체한다() throws {
        let (fixture, track, original) = try MultiTempoBoundaryTests().fixture()
        var draft = original
        draft.shift(by: 0.010)
        draft.segments.insert(.init(start: 2.0, bpm: 300, firstBeatNumber: 1), at: 2)
        #expect(draft.preservesBoundary(after: 0))
        #expect(!draft.preservesBoundary(after: 1))
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.51 })
        #expect(!draft.grid(duration: 49).beats.contains { $0.time == 1.91 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { $0.time == 1.51 })
        #expect(!written.beats.contains { $0.time == 1.91 })
    }
}
