import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 파일만 쓰는 편집본 넣기(`StageEdit.files`, CLI 실험·시험이 쓴다): 실제 태그 읽기·초안 파일·추가 목록 파일까지.
@MainActor
@Suite("편집본 넣기 — 파일")
struct StageEditFilesTests {
    let broken = Data("{\"깨진".utf8)

    func request(_ output: URL, grid: [GridSegment] = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]) -> EditStagingRequest {
        // 태그 없는 WAV라 곡 제목은 파일 이름이다. 새 제목을 태그 초안으로 둔다
        EditStagingRequest(file: output, grid: grid, cues: [EditableCue(kind: .memory, time: 0.5)], source: nil, title: "새 제목 (Edit)")
    }

    @Test func 추가한_곡과_초안_파일을_만들고_같은_파일은_두_번_넣지_않는다() async throws {
        let folder = try TemporaryFolder(prefix: "djc-stage-files")
        let home = folder.url
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let staged = try await StageEdit.files(home: home).stage(request(output))
        #expect(staged.path == output.path.precomposedStringWithCanonicalMapping && staged.bpm == 120 && abs(staged.duration - 4) < 0.01)
        #expect(StagedTrackFile.load(url: home.appending(path: StagedTrackFile.fileName)).map(\.uuid) == [staged.uuid])
        #expect(GridDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "grid-drafts")) != nil)
        #expect(CueDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "cue-drafts"))?.cues.map(\.time) == [0.5])
        #expect(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts"))?.fields.title == "새 제목 (Edit)")
        #expect(staged.title == "원곡 (Edit)")
        await #expect(throws: DJCError.self) { try await StageEdit.files(home: home).stage(self.request(output)) }
        #expect(StagedTrackFile.load(url: home.appending(path: StagedTrackFile.fileName)).count == 1)
    }

    @Test func 손상된_추가_목록을_새_목록으로_덮지_않는다() async throws {
        let folder = try TemporaryFolder(prefix: "djc-stage-files")
        let home = folder.url
        try broken.write(to: home.appending(path: StagedTrackFile.fileName))
        let output = try AudioFixture.wav(seconds: 4, in: home, name: "원곡 (Edit).wav")
        let staged = try await StageEdit.files(home: home).stage(request(output))
        #expect(StagedTrackFile.load(url: home.appending(path: StagedTrackFile.fileName)).map(\.uuid) == [staged.uuid])
        let preserved = FileManager.default.enumerator(at: home.appending(path: DamagedDrafts.folderName), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(preserved.map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["staged.json"])
    }
}
