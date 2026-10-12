import DJCApplication
import DJCDomain
import Foundation
import Testing

/// CLI `djc draft playlist`의 유스케이스(#260): 재생 목록 초안 파일에 편집 묶음을 쌓는다. 계획 규칙은 `EditPlaylistsBatchTests`가 본다.
/// 여기서는 저장·미리 보기·막힘·경쟁·손상 파일을 메모리 포트로 본다.
@Suite("초안 파일 바로 고치기 — 재생 목록")
struct EditDraftFilesPlaylistTests {
    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "P1", name: "세트", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
        (PlaylistLayout.Item(id: "S1", name: "자동", isSmart: true), 2),
    ])

    static func edits(_ files: MemoryDraftFiles) -> EditDraftFiles {
        let counter = Counter()
        return EditDraftFiles(files: files.files, newKey: { "k\(counter.next())" })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    static func stack(_ edits: EditDraftFiles, _ requests: [PlaylistEditRequest], allOrNothing: Bool = false,
                      dryRun: Bool = false) throws -> EditPlaylists.Batch {
        try edits.stackPlaylistEdits(requests, rekordbox: rekordbox, contentIDs: ["1", "2"], allOrNothing: allOrNothing, dryRun: dryRun)
    }

    @Test func 쌓은_편집은_기존_초안_뒤에_저장하고_미리_보기는_저장하지_않는다() throws {
        let files = MemoryDraftFiles()
        var existing = PlaylistDraft()
        try existing.append(.rename(playlist: .id("P1"), name: "앱 이름"), rekordbox: Self.rekordbox)
        files.setPlaylist(existing)
        let edits = Self.edits(files)
        let request = PlaylistEditRequest.create(name: "새 목록", isFolder: false, parent: .ref(.root), position: nil, alias: nil, tracks: ["2"])
        let preview = try Self.stack(edits, [request], dryRun: true)
        #expect(preview.hasChanges && files.playlist == existing)
        let batch = try Self.stack(edits, [request])
        #expect(files.playlist == batch.draft)
        #expect(batch.draft.edits.first == .rename(playlist: .id("P1"), name: "앱 이름"))
        #expect(batch.outcomes.first?.playlistID == "new:k2" && batch.outcomes.first?.name == "새 목록")
    }

    @Test func 막힌_요청만_있으면_쌓지_않고_이유를_알린다() throws {
        let files = MemoryDraftFiles()
        let edits = Self.edits(files)
        #expect(EditDraftFilesTests.code { _ = try Self.stack(edits, [.delete(.ref(.id("S1"))), .addTracks(.ref(.id("P1")), contentIDs: ["9"])]) }
            == "playlist_edit_blocked")
        do {
            _ = try Self.stack(edits, [.delete(.ref(.id("S1")))])
        } catch let failure as ReadFailure {
            #expect(failure.message.contains("#1") && failure.message.contains("인텔리전트"))
        }
        // 하나라도 막히면 쌓지 않기: 쌓을 수 있는 요청이 있어도 멈춘다
        #expect(EditDraftFilesTests.code {
            _ = try Self.stack(edits, [.rename(.ref(.id("P1")), name: "새"), .delete(.ref(.id("S1")))], allOrNothing: true)
        } == "playlist_edit_blocked")
        #expect(files.playlist.isEmpty)
        // 일부만 막히면 나머지를 쌓는다
        let batch = try Self.stack(edits, [.rename(.ref(.id("P1")), name: "새"), .delete(.ref(.id("S1")))])
        #expect(batch.outcomes.map(\.status) == [.stacked, .skipped] && files.playlist.edits == [.rename(playlist: .id("P1"), name: "새")])
    }

    @Test func 바뀐_것이_없으면_저장하지_않고_성공한다() throws {
        let files = MemoryDraftFiles()
        let edits = Self.edits(files)
        let batch = try Self.stack(edits, [.addTracks(.ref(.id("P1")), contentIDs: ["1"])])
        #expect(!batch.hasChanges && batch.outcomes.first?.status == .unchanged && files.playlist.isEmpty)
    }

    @Test func 계획하는_동안_초안이_바뀌면_덮지_않는다() throws {
        let files = MemoryDraftFiles()
        var app = PlaylistDraft()
        try app.append(.rename(playlist: .id("P1"), name: "앱이 그사이 고침"), rekordbox: Self.rekordbox)
        files.queuePlaylistReads([PlaylistDraft(), app])
        files.setPlaylist(app)
        #expect(EditDraftFilesTests.code { _ = try Self.stack(Self.edits(files), [.addTracks(.ref(.id("P1")), contentIDs: ["2"])]) } == "draft_changed")
        #expect(files.playlist == app)
    }

    @Test func 초안_파일을_잡지_못하면_쌓지_않고_미리_보기는_한다() throws {
        // 앱이 rekordbox에 쓰는 동안(또는 다른 djc가 고치는 동안) 초안 파일 잠금을 들고 있다
        let files = MemoryDraftFiles()
        files.setPlaylistLocked(true)
        let request = PlaylistEditRequest.rename(.ref(.id("P1")), name: "새")
        #expect(EditDraftFilesTests.code { _ = try Self.stack(Self.edits(files), [request]) } == "draft_busy")
        #expect(files.playlist.isEmpty)
        #expect(try Self.stack(Self.edits(files), [request], dryRun: true).hasChanges)
        files.setPlaylistLocked(false)
        #expect(try Self.stack(Self.edits(files), [request]).hasChanges && !files.playlist.isEmpty)
    }

    @Test func 읽지_못하는_초안_파일은_덮지_않는다() {
        let files = MemoryDraftFiles()
        var broken = files.files
        broken.readPlaylist = { throw CocoaError(.fileReadCorruptFile) }
        let saves = Counter()
        broken.savePlaylist = { _ in _ = saves.next() }
        let edits = EditDraftFiles(files: broken, newKey: { "k" })
        #expect(EditDraftFilesTests.code { _ = try Self.stack(edits, [.rename(.ref(.id("P1")), name: "새")]) } == "invalid_draft")
        #expect(saves.next() == 1)
        var failing = files.files
        failing.savePlaylist = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(EditDraftFilesTests.code { _ = try Self.stack(EditDraftFiles(files: failing, newKey: { "k" }), [.rename(.ref(.id("P1")), name: "새")]) }
            == "draft_io_failed")
    }
}
