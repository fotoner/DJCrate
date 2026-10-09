import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 편집본 넣기 유스케이스: 중복 확인 → 태그 읽기 → 초안 쓰기 → 추가 목록에 덧붙이기(실패하면 초안 되돌리기).
/// 추가 목록은 `StagingStore` 한 길(메인 액터)로만 고친다(adv2 N8). 파일 없이 가짜 포트로 본다.
@Suite("편집본 넣기")
@MainActor
struct StageEditTests {
    struct Failure: Error {}

    /// 가짜 포트: 부른 일과 그때 메인 스레드였는지 남긴다. 추가 목록은 메모리.
    final class Probe: Sendable {
        let list: Mutex<[StagedTrack]>
        let calls = Mutex<[String]>([])
        let onMain = Mutex<[String]>([])
        let drafts = Mutex<[StagedEditDrafts]>([])
        let saveFails: Bool
        init(list: [StagedTrack] = [], saveFails: Bool = false) {
            self.list = Mutex(list)
            self.saveFails = saveFails
        }
        func record(_ name: String) {
            calls.withLock { $0.append(name) }
            if Thread.isMainThread { onMain.withLock { $0.append(name) } }
        }
        var names: [String] { calls.withLock { $0 } }
        var mainNames: [String] { onMain.withLock { $0 } }
        var tracks: [StagedTrack] { list.withLock { $0 } }

        func stager(readTrack: (@Sendable (URL, String) async throws -> StagedTrack)? = nil) -> StageEdit {
            StageEdit(
                staging: StagingStore(tracks: { self.record("tracks"); return self.tracks },
                                      save: { tracks in
                                          self.record("save")
                                          if self.saveFails { throw Failure() }
                                          self.list.withLock { $0 = tracks }
                                      }),
                files: EditStagingFiles(
                    readTrack: readTrack ?? { url, addedOn in
                        self.record("read")
                        return StagedTrack(uuid: "new", path: url.path, title: "태그 제목", duration: 8, addedOn: addedOn)
                    },
                    writeDrafts: { drafts in
                        self.record("drafts")
                        self.drafts.withLock { $0.append(drafts) }
                        return { self.record("rollback") }
                    }),
                // 2026-10-09 23:30 UTC
                now: { Date(timeIntervalSince1970: 1_791_588_600) })
        }
    }

    static let file = URL(filePath: "/편집본/곡 (Edit).wav")
    static func request(file: URL = file) -> EditStagingRequest {
        EditStagingRequest(file: file, grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
                           cues: [EditableCue(kind: .memory, time: 0.5)], source: nil, title: "곡 (Edit)")
    }
    static func staged(_ path: String) -> StagedTrack {
        StagedTrack(uuid: UUID().uuidString, path: path, title: "있던 곡", duration: 1, addedOn: "2026-10-01")
    }

    @Test func 초안을_쓰고_지금_목록에_덧붙인다() async throws {
        let earlier = Self.staged("/음원/앞 곡.wav")
        let probe = Probe(list: [earlier])
        let staged = try await probe.stager().stage(Self.request())
        #expect(staged.uuid == "new" && staged.addedOn == "2026-10-09" && staged.bpm == 120 && staged.gridConfident == true)
        #expect(probe.tracks.map(\.uuid) == [earlier.uuid, "new"])
        #expect(probe.names == ["tracks", "read", "drafts", "tracks", "save"])
        // 목록은 메인 액터에서, 태그 읽기·초안 쓰기는 메인 밖에서
        #expect(probe.mainNames == ["tracks", "tracks", "save"], "\(probe.mainNames)")
        let drafts = try #require(probe.drafts.withLock { $0.first })
        #expect(drafts.track.uuid == "new" && drafts.cues.cues.map(\.time) == [0.5] && drafts.tags.fields.title == "곡 (Edit)")
    }

    @Test func 이미_추가한_파일이면_읽지도_쓰지도_않고_막는다() async throws {
        // NFD로 적힌 같은 경로도 같은 파일이다
        let probe = Probe(list: [Self.staged(Self.file.path.decomposedStringWithCanonicalMapping)])
        await #expect(throws: DJCError.self) { try await probe.stager().stage(Self.request()) }
        #expect(probe.names == ["tracks"] && probe.tracks.count == 1)
    }

    @Test func 목록_저장이_실패하면_이_넣기가_쓴_초안을_되돌린다() async throws {
        let probe = Probe(saveFails: true)
        await #expect(throws: Failure.self) { try await probe.stager().stage(Self.request()) }
        #expect(probe.names.suffix(2) == ["save", "rollback"] && probe.tracks.isEmpty)
    }

    @Test func 기다리는_사이_목록이_바뀌면_바뀐_목록에_덧붙인다() async throws {
        let probe = Probe()
        let other = Self.staged("/음원/다른 곡.wav")
        // 태그를 읽는 사이 다른 곳(그리드 추정 등)이 목록을 저장했다
        let stager = probe.stager(readTrack: { url, addedOn in
            await MainActor.run { probe.list.withLock { $0.append(other) } }
            return StagedTrack(uuid: "new", path: url.path, title: "태그 제목", duration: 8, addedOn: addedOn)
        })
        _ = try await stager.stage(Self.request())
        #expect(probe.tracks.map(\.uuid) == [other.uuid, "new"])
    }

    @Test func 기다리는_사이_같은_파일이_들어오면_막고_초안을_되돌린다() async throws {
        let probe = Probe()
        let stager = probe.stager(readTrack: { url, addedOn in
            await MainActor.run { probe.list.withLock { $0.append(Self.staged(url.path)) } }
            return StagedTrack(uuid: "new", path: url.path, title: "태그 제목", duration: 8, addedOn: addedOn)
        })
        await #expect(throws: DJCError.self) { try await stager.stage(Self.request()) }
        #expect(probe.names.last == "rollback" && probe.tracks.count == 1 && probe.tracks.first?.uuid != "new")
    }
}
