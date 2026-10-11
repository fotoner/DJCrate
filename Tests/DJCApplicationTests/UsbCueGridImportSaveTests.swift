import DJCApplication
import DJCDomain
import Foundation
import Testing

/// USB 큐·그리드 → 로컬 초안 쓰기(유스케이스). 초안 파일은 가짜 포트로 본다.
@Suite("USB 큐·그리드 초안 쓰기")
struct UsbCueGridImportSaveTests {
    /// 가짜 초안 파일: 있는 초안·쓴 초안을 기록한다
    final class Files {
        var existingCues: Set<String> = []
        var existingGrids: Set<String> = []
        var failSaves = false
        var savedCues: [String] = []
        var savedGrids: [String] = []

        var port: UsbCueGridDraftFiles {
            UsbCueGridDraftFiles(
                cueExists: { [unowned self] in existingCues.contains($0) },
                saveCue: { [unowned self] draft in
                    if failSaves { throw CocoaError(.fileWriteNoPermission) }
                    savedCues.append(draft.trackUUID)
                },
                gridExists: { [unowned self] in existingGrids.contains($0) },
                saveGrid: { [unowned self] draft in
                    if failSaves { throw CocoaError(.fileWriteNoPermission) }
                    savedGrids.append(draft.trackUUID)
                })
        }
    }

    static func row(_ uuid: String, title: String) -> UsbCueGridImportPlan.Row {
        let track = Track(id: uuid, uuid: uuid, title: title, artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                          releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/music/\(uuid).mp3",
                          comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        var cue = CueDraft(trackUUID: uuid)
        cue.cues = [EditableCue(kind: .hot(0), time: 2)]
        let grid = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)])
        return UsbCueGridImportPlan.Row(row: UsbCueGridImportTrack(track: track, cues: []), cues: cue, grid: grid)
    }

    @Test("초안이 없는 곡은 큐·그리드를 쓰고 쓴 초안을 돌려준다")
    func savesWhenNoDraft() {
        let files = Files()
        let plan = UsbCueGridImportPlan(rows: [Self.row("a", title: "A"), Self.row("b", title: "B")])
        let saved = UsbCueGridImport.saveDrafts(plan, files: files.port) { _, _ in false }
        #expect(files.savedCues == ["a", "b"] && files.savedGrids == ["a", "b"])
        #expect(saved.cues.map(\.trackUUID) == ["a", "b"] && saved.gridUUIDs == ["a", "b"])
        #expect(saved.summary.cueCount == 2 && saved.summary.gridCount == 2 && saved.summary.skippedCount == 0)
        #expect(saved.summary.details.isEmpty)
    }

    @Test("앱이 든 초안·파일·쓰기 대기가 있는 칸은 덮지 않고 곡마다 이유를 한 번 센다")
    func keepsExistingDrafts() {
        let files = Files()
        files.existingGrids = ["b"]
        let plan = UsbCueGridImportPlan(rows: [Self.row("a", title: "A"), Self.row("b", title: "B")])
        let saved = UsbCueGridImport.saveDrafts(plan, files: files.port) { uuid, part in uuid == "a" && part == .cue }
        #expect(files.savedCues == ["b"] && files.savedGrids == ["a"])
        #expect(saved.summary.cueCount == 1 && saved.summary.gridCount == 1 && saved.summary.skippedCount == 2)
        #expect(saved.summary.details.count == 2)
        #expect(saved.summary.details[0].hasPrefix("A: ") && saved.summary.details[1].hasPrefix("B: "))
    }

    @Test("저장에 실패하면 쓴 것으로 세지 않고, 짝이 맞지 않는 곡 수를 더한다")
    func failureAndUnmatched() {
        let files = Files()
        files.failSaves = true
        let plan = UsbCueGridImportPlan(rows: [Self.row("a", title: "A")], unmatchedCount: 3)
        let saved = UsbCueGridImport.saveDrafts(plan, files: files.port) { _, _ in false }
        #expect(saved.cues.isEmpty && saved.gridUUIDs.isEmpty)
        #expect(saved.summary.cueCount == 0 && saved.summary.gridCount == 0)
        #expect(saved.summary.skippedCount == 1 + 3)
        // 곡 하나의 이유 둘(큐·그리드) + 짝 없는 곡 안내 하나
        #expect(saved.summary.details.count == 3)
    }
}
