import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// CDJ 큐 편집(#280)을 큐 초안 파일에 옮기는 입구: 앱이 맡은 저장을 먼저 끝낸 뒤 그 위에 얹는다.
@Suite("LINK 큐 초안")
struct LinkCueDraftsTests {
    @Test func 앱이_맡은_저장을_끝낸_뒤_얹는다() async throws {
        let files = MemoryDraftFiles()
        let order = Mutex<[String]>([])
        let drafts = LinkCueDrafts(edits: EditDraftFiles(files: files.files), flush: {
            order.withLock { $0.append("flush:\(files.cue("u7") == nil ? "없음" : "있음")") }
        })
        let edit = LinkCueEdit(contentID: "7", deleted: false, kind: 0, inMs: 5_000, outMs: nil, comment: "")
        #expect(try await drafts.apply(edit, track: EditDraftFilesTests.track, rekordboxCues: []) == .applied)
        _ = try await drafts.apply(edit, track: EditDraftFilesTests.track, rekordboxCues: [])
        #expect(order.withLock { $0 } == ["flush:없음", "flush:있음"])
        #expect(files.cue("u7")?.cues.map(\.time) == [5])
    }
}
