import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 반영 XML 시험(CLI `reflection-dry-run`). DB·XML 파일 없이 메모리 라이브러리·메모리 초안·가짜 XML 파일로 계획과 쓰는 것을 본다.
@Suite("반영 XML 시험")
struct ExportXMLDryRunTests {
    static let latest = URL(filePath: "/snapshots/master-latest.db")

    static func track(_ id: String) -> Track {
        Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 120, folderPath: "/m/\(id).mp3", comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    /// 가짜 XML 파일: 큐 초안이 고친 것이 있으면 반영할 수 있는 계획, 쓴 계획·재생 목록 이름·자리를 남긴다
    final class Written: Sendable {
        let calls = Mutex<[(uuids: [String], name: String, out: String)]>([])
    }

    static func files(_ written: Written) -> XMLFiles {
        var files = XMLFiles.unused
        files.reflectionPlan = { track, _, cue, grid in
            ReflectionXMLPlan(trackID: track.id, uuid: track.uuid, path: track.folderPath, title: track.title, marks: [], tempos: nil,
                              blockers: cue == nil && grid != nil ? ["그리드만"] : [], cueChanged: cue?.hasChanges ?? false,
                              gridChanged: false, before: ReflectionXMLMetadata(track), beforeMarks: [])
        }
        files.writeReflection = { plans, name, out in written.calls.withLock { $0.append((plans.map(\.uuid), name, out.path)) } }
        return files
    }

    @Test func 초안이_있는_곡만_라이브러리_순서로_계획하고_반영할_수_있는_것만_시험_목록으로_쓴다() throws {
        let library = RekordboxLibrary(allTracks: ["1", "2", "3", "4"].map(Self.track), cues: [], playCounts: [:])
        let drafts = MemoryDrafts()
        var cue = CueDraft(trackUUID: "u3")
        cue.place(EditableCue(id: UUID(), kind: .memory, time: 3))
        cue.place(EditableCue(id: UUID(), kind: .hot(0), time: 5))
        drafts.save(cue)
        drafts.save(GridDraft(trackUUID: "u1", base: [], segments: [GridSegment(start: 0, bpm: 128, firstBeatNumber: 1)]))
        let written = Written()
        let export = ExportXML(files: Self.files(written), source: .memory([Self.latest: library], latest: Self.latest), drafts: drafts.store,
                               batches: ReflectionBatchStore(load: { nil }, save: { _ in }), now: { Date(timeIntervalSince1970: 0) })

        let plans = try export.dryRunPlans(snapshotDirectory: URL(filePath: "/snapshots"))
        #expect(plans.map(\.plan.uuid) == ["u1", "u3"])
        #expect(plans.map(\.cueChanges) == [0, 2])
        #expect(plans.map(\.plan.isEligible) == [false, true])

        try export.writeDryRun(plans.map(\.plan), to: URL(filePath: "/out/dry.xml"))
        let calls = written.calls.withLock { $0 }
        #expect(calls.count == 1 && calls[0].uuids == ["u3"] && calls[0].name == "DJCrate 반영 시험" && calls[0].out == "/out/dry.xml")
    }

    @Test func 스냅샷이_없으면_던진다() {
        let export = ExportXML(files: Self.files(Written()), source: .memory([:]), drafts: MemoryDrafts().store, batches: ReflectionBatchStore(load: { nil }, save: { _ in }),
                               now: { Date(timeIntervalSince1970: 0) })
        #expect(throws: DJCError.self) { try export.dryRunPlans(snapshotDirectory: URL(filePath: "/snapshots")) }
    }
}
