import DJCDomain
import DJCStorage
import Foundation
import Testing

/// 편집본 초안 파일 쓰기(`EditStaging.writeDrafts`): 그리드·큐·태그 초안을 초안 폴더에 쓰고, 실패하면 이 쓰기가 바꾼 파일만 되돌린다.
/// 무엇을 둘지는 DJCDomainTests `StagedEditDraftsTests`, 넣는 순서는 DJCApplicationTests `StageEditTests`.
@Suite("편집본 초안 파일")
struct EditStagingTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-\(UUID().uuidString)")

    func drafts(grid: [GridSegment] = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]) -> StagedEditDrafts {
        StagedEditDrafts(track: StagedTrack(uuid: "new", path: "/편집본/곡 (Edit).wav", title: "곡 (Edit)", duration: 8, addedOn: "2026-10-09"),
                         grid: grid, cues: [EditableCue(kind: .memory, time: 0.5)], source: nil, title: "새 제목 (Edit)")
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appending(path: path).path) }

    @Test func 그리드·큐·태그_초안을_쓰고_되돌리기는_쓴_파일을_지운다() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let drafts = drafts()
        let rollBack = try EditStaging.writeDrafts(drafts, home: home)
        #expect(GridDraftStore.load(trackUUID: "new", directory: home.appending(path: "grid-drafts")) == drafts.grid)
        #expect(CueDraftStore.load(trackUUID: "new", directory: home.appending(path: "cue-drafts")) == drafts.cues)
        #expect(TagDraftStore.load(trackUUID: "new", directory: home.appending(path: "tag-drafts"))?.fields.title == "새 제목 (Edit)")
        // 추가 목록 저장이 실패하면 부른다
        rollBack()
        #expect(!exists("grid-drafts/new.json") && !exists("cue-drafts/new.json") && !exists("tag-drafts/new.json"))
    }

    @Test func 그리드가_없으면_그리드_초안_파일을_두지_않는다() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try EditStaging.writeDrafts(drafts(grid: []), home: home)
        #expect(!exists("grid-drafts/new.json") && exists("cue-drafts/new.json") && exists("tag-drafts/new.json"))
    }

    @Test func 중간에_실패하면_이_쓰기가_바꾼_파일만_전_내용으로_되돌린다() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "cue-drafts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // 같은 곡의 큐 초안이 이미 있었다(#174: 있던 파일은 그 내용으로 되살린다)
        let before = Data("{\"old\":true}".utf8)
        try before.write(to: home.appending(path: "cue-drafts/new.json"))
        // 태그 초안 폴더 자리에 파일이 있어 태그 쓰기가 실패한다
        try Data().write(to: home.appending(path: "tag-drafts"))
        #expect(throws: (any Error).self) { _ = try EditStaging.writeDrafts(drafts(), home: home) }
        #expect(!exists("grid-drafts/new.json"))
        #expect(try Data(contentsOf: home.appending(path: "cue-drafts/new.json")) == before)
    }
}
