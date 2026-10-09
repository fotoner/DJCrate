import DJCApplication
import DJCDomain
import Foundation
import Testing

@Suite("USB 큐·그리드 초안 보호")
struct UsbCueGridImportTests {
    @Test func 핫큐_이동은_기존_원본_ID를_잇는다() throws {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "도입", colorTableIndex: nil)]
        let draft = try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local,
                                                      imported: [.init(kind: .hot(0), time: 2, name: "도입")], legacy: false)
        #expect(draft.cues.first?.id == draft.base.first?.id)
        #expect(draft.cues.first?.sourceID == "a")
        #expect(draft.changes.count == 1)
    }

    @Test func 색_큐를_고쳐_메타데이터를_잃는_초안은_막는다() {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "", colorTableIndex: 4)]
        #expect(throws: UsbCueGridReadFailure.self) {
            try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local, imported: [.init(kind: .hot(0), time: 2)], legacy: false)
        }
    }

    @Test func DAT_큐는_기존_같은_큐의_이름을_보존한다() throws {
        let local = [Cue(id: "a", contentID: "1", kind: 1, inMsec: 1_000, name: "도입", colorTableIndex: nil)]
        let draft = try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local,
                                                      imported: [.init(kind: .hot(0), time: 2)], legacy: true)
        #expect(draft.cues.first?.name == "도입")
    }

    /// 2026-10-08 실험 G5b: 로컬에서 메모리 큐를 하나 더한(로컬이 더 새로운) 곡도 rekordbox의 ← CUE GRID INFO는
    /// USB의 큐 둘로 되돌렸다. 로컬 갱신 횟수로 건너뛰지 않고 두 USB 형식이 다를 때만 건너뛴다.
    @Test func 로컬이_더_새로워도_USB_큐로_바꾸는_초안을_만든다() throws {
        let local = [Cue(id: "a", contentID: "1", kind: 0, inMsec: 1_000, name: "", colorTableIndex: nil),
                     Cue(id: "b", contentID: "1", kind: 0, inMsec: 5_000, name: "", colorTableIndex: nil),
                     Cue(id: "c", contentID: "1", kind: 0, inMsec: 9_000, name: "", colorTableIndex: nil)]
        let draft = try UsbCueGridDraftImport.cueDraft(uuid: "uuid", local: local,
                                                      imported: [.init(kind: .memory, time: 1), .init(kind: .memory, time: 5)],
                                                      legacy: false)
        #expect(draft.cues.count == 2 && draft.hasChanges)
        #expect(draft.cues.map(\.sourceID) == ["a", "b"])
        for part in UsbCueGridDraftImport.Part.allCases {
            #expect(UsbCueGridDraftImport.formatConflictReason(part, conflicts: []) == nil)
        }
        #expect(UsbCueGridDraftImport.formatConflictReason(.cue, conflicts: ["cueUpdateCount"]) != nil)
        #expect(UsbCueGridDraftImport.formatConflictReason(.grid, conflicts: ["analysisDataUpdateCount"]) != nil)
        #expect(UsbCueGridDraftImport.formatConflictReason(.grid, conflicts: ["cueUpdateCount"]) == nil)
        // 곡 정보 칸이 두 형식에서 달라도 큐·그리드는 막지 않는다(정보 칸은 가져오지 않는다)
        for part in UsbCueGridDraftImport.Part.allCases {
            #expect(UsbCueGridDraftImport.formatConflictReason(part, conflicts: ["rating", "informationUpdateCount"]) == nil)
        }
    }

    /// rekordbox 7.2.19 실험 X1(2026-10-08, C1·C2): USB는 평점 3·Red·코멘트 'DJC233A', 로컬은 평점 5·Blue·'DJC233B'에
    /// 메모리 큐 하나를 더한 곡에 ← CUE GRID INFO를 하자 큐는 USB의 넷으로 돌아갔지만 평점·색·코멘트는 로컬 값 그대로였다.
    /// 확인 창은 "트랙 정보(색상, 레이팅 및 코멘트)"도 적었지만 실제로는 큐·루프·핫큐·그리드만 가져온다.
    @Test func 평점_색_코멘트는_가져오지_않고_큐와_그리드만_가져온다() {
        #expect(UsbCueGridDraftImport.Part.allCases == [.cue, .grid])
        let summary = UsbCueGridImportSummary(cueCount: 1, gridCount: 2, skippedCount: 3)
        #expect(summary.message == "큐 1곡·그리드 2곡을 초안으로 가져왔습니다. 3곡은 건너뛰었습니다.")
    }

    @Test func 일정_그리드는_로컬_기준으로_초안을_만든다() throws {
        let old = BeatGrid(beats: (0..<20).map { .init(number: $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5) })
        let new = old.shifted(by: 0.05)
        let draft = try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: old, imported: new, duration: 10)
        #expect(draft.base == GridDraft.segments(from: old))
        #expect(draft.hasChanges)
    }

    @Test func 원본_박번호를_구간으로_보존하지_못하면_그리드를_막는다() {
        let bad = BeatGrid(beats: (0..<20).map { .init(number: $0 == 10 ? 1 : $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5) })
        #expect(throws: UsbCueGridReadFailure.self) {
            try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: .init(beats: []), imported: bad, duration: 10)
        }
    }
    @Test("로컬 기준으로 새 변속 경계를 만들 때 USB 박이 사라지는 초안은 거부한다")
    func returnedDraftCannotDropTheBeatBeforeATempoChange() {
        let local = BeatGrid(beats: (0..<20).map {
            .init(number: $0 % 4 + 1, bpm: 120, time: 0.1 + Double($0) * 0.5)
        })
        let imported = BeatGrid(beats: [
            .init(number: 1, bpm: 120, time: 0.1),
            .init(number: 2, bpm: 120, time: 0.6),
        ] + (0..<36).map {
            .init(number: ($0 + 2) % 4 + 1, bpm: 240, time: 0.85 + Double($0) * 0.25)
        })
        #expect(throws: UsbCueGridReadFailure.self) {
            try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: local, imported: imported, duration: 10)
        }
    }

    @Test("기존 변속 경계를 옮긴 초안은 실제 반환 그리드의 모든 USB 박을 보존한다")
    func shiftedExistingTempoBoundaryPreservesEveryImportedBeat() throws {
        let local = BeatGrid(beats: [
            .init(number: 1, bpm: 120, time: 0.1),
            .init(number: 2, bpm: 120, time: 0.6),
        ] + (0..<36).map {
            .init(number: ($0 + 2) % 4 + 1, bpm: 240, time: 0.85 + Double($0) * 0.25)
        })
        let imported = local.shifted(by: 0.05)
        let draft = try UsbCueGridDraftImport.gridDraft(uuid: "uuid", local: local, imported: imported, duration: 10)
        #expect(draft.base == GridDraft.segments(from: local))
        let actual = draft.grid(duration: 11)
        for beat in imported.beats {
            #expect(actual.beats.contains {
                abs($0.time - beat.time) <= 0.002 && $0.number == beat.number && abs($0.bpm - beat.bpm) < 0.005
            })
        }
    }

    @Test func 최신_스냅샷의_짝은_사이드바_캐시_없이_계산한다() {
        let local = LocalLibraryKeys(localDBID: 100,
                                     tracks: [.init(contentID: "local", masterSongID: "10", fileNameL: "test.mp3")], counters: [:])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "test.mp3", masterDbId: 100, masterContentId: 10)]
        #expect(UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local) == [1: "local"])
    }

    @Test func 같은_로컬_곡으로_오는_USB_여러곡은_모두_건너뛴다() {
        let local = LocalLibraryKeys(localDBID: 100,
                                     tracks: [.init(contentID: "local", masterSongID: "10", fileNameL: "test.mp3"),
                                              .init(contentID: "other", masterSongID: "20", fileNameL: "other.mp3")], counters: [:])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "test.mp3", masterDbId: 100, masterContentId: 10),
                          .init(id: 2, fileName: "test.mp3", masterDbId: 100, masterContentId: 10),
                          .init(id: 3, fileName: "other.mp3", masterDbId: 100, masterContentId: 20)]
        #expect(UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local) == [3: "other"])
    }

}
