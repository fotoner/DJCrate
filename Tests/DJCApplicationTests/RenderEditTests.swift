import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 편집본 쓰기 유스케이스(이름 고르기 → 렌더 → 추가한 곡에 넣기). 음원·초안 파일 없이 가짜 파일 접근으로 시험한다.
/// 넣기 자체의 규칙(중복·초안·되돌리기)은 `StageEditTests`.
@Suite("편집본 쓰기")
@MainActor
struct RenderEditTests {
    struct Failure: Error, Equatable {}

    /// 가짜 파일 접근: 부른 일과 그때 메인 스레드였는지 남긴다.
    final class Probe: Sendable {
        let calls = Mutex<[String]>([])
        let onMain = Mutex<[String]>([])
        let staged = Mutex<[StagedEditDrafts]>([])
        func record(_ name: String) {
            calls.withLock { $0.append(name) }
            if Thread.isMainThread { onMain.withLock { $0.append(name) } }
        }
        var names: [String] { calls.withLock { $0 } }
        var mainNames: [String] { onMain.withLock { $0 } }
        /// `prefix`로 시작하는 첫 일의 차례
        func index(_ prefix: String) -> Int? { names.firstIndex { $0.hasPrefix(prefix) } }
    }

    static func files(_ probe: Probe, existing: Set<String> = [], renderFails: Bool = false) -> EditFiles {
        EditFiles(
            outputDirectory: { probe.record("dir"); return URL(filePath: "/편집본") },
            fileExists: { probe.record("exists \($0.lastPathComponent)"); return existing.contains($0.path) },
            createDirectory: { probe.record("mkdir \($0.path)") },
            removeFile: { probe.record("remove \($0.lastPathComponent)") },
            render: { job, output, progress in
                probe.record("render \(output.lastPathComponent)")
                progress?(1)
                if renderFails { throw Failure() }
            })
    }

    /// 가짜 넣기: 추가 목록은 메모리, 태그 읽기·초안 쓰기는 기록만(`stageFails`면 목록 저장이 실패한다)
    static func stager(_ probe: Probe, stageFails: Bool = false) -> StageEdit {
        StageEdit(
            staging: MemoryStaging(saveError: stageFails ? Failure() : nil).store,
            files: EditStagingFiles(
                readTrack: { url, addedOn in
                    probe.record("stage \(url.lastPathComponent)")
                    // 태그 없는 렌더 파일: 제목은 파일 이름(`StagedTrack.make`와 같다)
                    return StagedTrack(uuid: "new", path: url.path, title: url.deletingPathExtension().lastPathComponent, comment: "",
                                       duration: 8, addedOn: addedOn)
                },
                writeDrafts: { drafts in
                    probe.staged.withLock { $0.append(drafts) }
                    return { probe.record("rollback") }
                }),
            now: { Date(timeIntervalSince1970: 1_791_000_000) })
    }

    static func writer(_ probe: Probe, existing: Set<String> = [], renderFails: Bool = false, stageFails: Bool = false) -> RenderEdit {
        RenderEdit(files: files(probe, existing: existing, renderFails: renderFails), stager: stager(probe, stageFails: stageFails))
    }

    static func request(title: String = "곡 (Edit)") throws -> EditOutputRequest {
        let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(1, 2), BarRange(1, 2)])
        return EditOutputRequest(job: EditRenderJob(plan: .bars(edit), source: URL(filePath: "/음원/곡.mp3"), sourceOffset: 0.026),
                                 title: title, grid: [edit.outputGrid], cues: [EditableCue(kind: .memory, time: 0.5)], sourceTrack: nil)
    }

    @Test func 이름을_골라_렌더하고_추가한_곡에_넣는다() async throws {
        let probe = Probe()
        let writer = Self.writer(probe, existing: ["/편집본/곡- A (Edit).wav"])
        let request = try Self.request(title: "곡: A (Edit)")
        let staged = try await writer.write(request, progress: nil)
        // 있는 이름은 피해 번호를 붙이고, 고른 파일에 렌더한 뒤 그 파일을 넣는다.
        #expect(staged.path == "/편집본/곡- A (Edit) 2.wav" && staged.title == "곡- A (Edit) 2")
        let render = try #require(probe.index("render 곡- A (Edit) 2.wav")), stage = try #require(probe.index("stage 곡- A (Edit) 2.wav"))
        let folder = try #require(probe.index("mkdir /편집본"))
        #expect(folder < render && render < stage)
        // 넣기는 요청의 그리드·큐·제목을 그대로 초안으로 둔다(원곡 태그는 넣기가 채운다).
        let drafts = try #require(probe.staged.withLock { $0.first })
        #expect(drafts.grid?.segments == request.grid && drafts.cues.cues == request.cues && drafts.tags.fields.title == request.title)
        #expect(probe.mainNames.isEmpty, "메인 스레드에서 파일 입출력: \(probe.mainNames)")
    }

    @Test func 넣기에_실패하면_렌더한_파일을_지우고_던진다() async throws {
        let probe = Probe()
        let writer = Self.writer(probe, stageFails: true)
        await #expect(throws: Failure.self) { try await writer.write(try Self.request(), progress: nil) }
        let stage = try #require(probe.index("stage 곡 (Edit).wav")), remove = try #require(probe.index("remove 곡 (Edit).wav"))
        // 넣기가 만든 초안을 되돌리고 렌더한 파일을 지운다
        let rollback = try #require(probe.index("rollback"))
        #expect(stage < rollback && rollback < remove)
        #expect(probe.mainNames.isEmpty)
    }

    @Test func 렌더에_실패하면_넣지_않는다() async throws {
        let probe = Probe()
        let writer = Self.writer(probe, renderFails: true)
        await #expect(throws: Failure.self) { try await writer.write(try Self.request(), progress: nil) }
        // 반쯤 쓴 파일은 렌더러가 지운다. 넣지도, 남의 파일을 지우지도 않는다.
        #expect(probe.names.last == "render 곡 (Edit).wav" && !probe.names.contains { $0.hasPrefix("remove") || $0.hasPrefix("stage") })
    }

    @Test func 시작_전에_취소하면_아무_파일도_건드리지_않는다() async throws {
        let probe = Probe()
        let writer = Self.writer(probe)
        let request = try Self.request()
        let task = Task { try await writer.write(request, progress: nil) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.names.isEmpty)
    }

    @Test func 원곡_파일_있음은_메인_밖에서_본다() async {
        let probe = Probe()
        let writer = Self.writer(probe, existing: ["/음원/곡.mp3"])
        #expect(await writer.sourceExists(URL(filePath: "/음원/곡.mp3")))
        #expect(!(await writer.sourceExists(URL(filePath: "/음원/없음.mp3"))))
        #expect(probe.index("exists 곡.mp3") != nil && probe.mainNames.isEmpty)
    }
}
