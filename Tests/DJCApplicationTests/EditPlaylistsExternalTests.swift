import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 쓰는 동안 바깥(CLI `djc draft playlist`)에서 재생 목록 초안 파일 뒤에 더한 편집(#260): 쓴 뒤 정리가 메모리 초안으로 덮어 지우지 않는다.
@MainActor
@Suite("재생 목록 초안 편집 — 쓰는 동안 바깥 편집")
struct EditPlaylistsExternalTests {
    static let rekordbox = PlaylistLayout(rekordbox: [RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false,
                                                                        trackIDs: [])])

    static func playlists(_ memory: MemoryDrafts) -> EditPlaylists {
        EditPlaylists(imports: .none, drafts: memory.store)
    }

    @Test func 쓰는_동안_CLI가_더한_편집은_쓴_편집만_빼고_남긴다() throws {
        let memory = MemoryDrafts()
        var written = PlaylistDraft()
        _ = try written.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        _ = try written.append(.rename(playlist: .id("P"), name: "막힐 이름"), rekordbox: Self.rekordbox)
        var disk = written
        _ = try disk.append(.addTracks(playlist: .id("P"), contentIDs: ["c1"]), rekordbox: Self.rekordbox)
        try memory.store.savePlaylistDraft(disk)
        let outcomes = [PlaylistOutcome(edit: written.steps[0].edit, playlistID: "900", name: "새 목록", status: .written),
                        PlaylistOutcome(edit: written.steps[1].edit, playlistID: "P", name: "목록", status: .blocked, reason: "막힘")]

        let cleanup = Self.playlists(memory).finishWrite(written, outcomes: outcomes, current: written,
                                                         imports: PlaylistImports(), importsLoadFailed: false)

        #expect(cleanup.draft?.edits == [.rename(playlist: .id("P"), name: "막힐 이름"), .addTracks(playlist: .id("P"), contentIDs: ["c1"])])
        #expect(memory.store.playlistDraft() == cleanup.draft)
        #expect(cleanup.ids == [PlaylistRef.new("k").layoutID: "900"])
    }

    @Test func 디스크_초안이_쓴_편집으로_시작하지_않으면_전처럼_메모리_초안에서_뺀다() throws {
        let memory = MemoryDrafts()
        var written = PlaylistDraft()
        _ = try written.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        var other = PlaylistDraft()
        _ = try other.append(.rename(playlist: .id("P"), name: "다른 초안"), rekordbox: Self.rekordbox)
        try memory.store.savePlaylistDraft(other)
        let outcome = PlaylistOutcome(edit: written.steps[0].edit, playlistID: "900", name: "새 목록", status: .written)

        let cleanup = Self.playlists(memory).finishWrite(written, outcomes: [outcome], current: written,
                                                         imports: PlaylistImports(), importsLoadFailed: false)

        #expect(cleanup.draft?.isEmpty == true && memory.store.playlistDraft().isEmpty)
    }
}
