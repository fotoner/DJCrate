import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 막힌 초안 복구(유스케이스, #232). 사본·암호화 DB 없이 메모리 라이브러리를 돌려주는 가짜 읽기와 메모리 초안으로 규칙을 본다.
@Suite("막힌 초안 복구")
struct RecoverDraftsTests {
    static let source = URL(filePath: "/fake/rekordbox/master.db")
    static let share = URL(filePath: "/fake/rekordbox/share")

    static func track(_ uuid: String, title: String = "곡", length: Int = 180, analysis: String? = "/A.DAT") -> Track {
        Track(id: "id-\(uuid)", uuid: uuid, title: title, artist: "가수", album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: length, folderPath: "/music/\(uuid).mp3",
              comment: "", importedOn: nil, analysisDataPath: analysis, imagePath: nil, isDeleted: false)
    }

    /// 읽을 때마다 같은 라이브러리·그리드를 돌려주는 가짜 읽기(부른 횟수와 받은 그리드 초안을 센다)
    final class Reader: Sendable {
        let library: Mutex<RekordboxLibrary>
        let grids: [String: BeatGrid]
        let calls = Mutex(0)
        init(_ library: RekordboxLibrary, grids: [String: BeatGrid] = [:]) { self.library = Mutex(library); self.grids = grids }
        var port: RecoveryReader {
            RecoveryReader { [self] _, _, drafts in
                calls.withLock { $0 += 1 }
                var loaded: [String: Result<BeatGrid?, any Error>] = [:]
                for draft in drafts { loaded[draft.trackUUID] = .success(grids[draft.trackUUID]) }
                return (library.withLock { $0 }, loaded)
            }
        }
    }

    static func grid(bpm: Double, start: Double = 0.5, beats: Int = 360) -> BeatGrid {
        BeatGrid(beats: (0..<beats).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: bpm, time: start + Double($0) * 60 / bpm) })
    }

    @Test func 곡_줄_여럿의_현재값을_사본_하나로_읽고_찾지_못한_곡은_그_줄만_실패한다() async throws {
        let reader = Reader(RekordboxLibrary(allTracks: [Self.track("a", title: "rekordbox 제목")], cues: [], playCounts: [:]))
        let recover = RecoverDrafts(reader: reader.port, drafts: MemoryDrafts().store)
        var edited = TagDraft(trackUUID: "a", base: TagFields(track: Self.track("a", title: "옛 제목")))
        edited.fields.title = "내 제목"
        let missing = RecoveryDraft.tags(TagDraft(trackUUID: "없음", base: TagFields()))
        let results = try await recover.readCurrent([.tags(edited), missing], source: Self.source, share: Self.share)
        #expect(reader.calls.withLock { $0 } == 1)
        let current = try results[0].get()
        guard case let .tags(draft) = current.draft else { Issue.record("태그 현재값"); return }
        #expect(draft.base.title == "rekordbox 제목" && current.row?.track.uuid == "a")
        #expect(throws: (any Error).self) { try results[1].get() }
    }

    @Test func 비교한_뒤_현재값이_바뀌면_적용하지_않는다() throws {
        let base = TagFields(track: Self.track("a", title: "옛 제목"))
        var original = TagDraft(trackUUID: "a", base: base)
        original.fields.title = "내 제목"
        let shown = RecoveryRead(draft: .tags(TagDraft(track: Self.track("a", title: "rekordbox 제목"))), row: nil, grid: nil)
        let review = DraftRecoveryReview(original: .tags(original), current: shown.draft, title: "곡", currentRow: nil, currentGrid: nil)
        // 같은 현재값이면 고른 대로 새 기준을 만든다
        guard case let .tags(kept) = try RecoverDrafts.resolve(review, latest: shown, choice: .keepEditing) else { Issue.record("태그"); return }
        #expect(kept.fields.title == "내 제목" && kept.base.title == "rekordbox 제목")
        guard case let .tags(current) = try RecoverDrafts.resolve(review, latest: shown, choice: .useCurrent) else { Issue.record("태그"); return }
        #expect(!current.hasChanges)
        // 저장 직전에 다시 읽은 값이 다르면 그대로 남긴다
        let changed = RecoveryRead(draft: .tags(TagDraft(track: Self.track("a", title: "또 바뀐 제목"))), row: nil, grid: nil)
        #expect(throws: (any Error).self) { try RecoverDrafts.resolve(review, latest: changed, choice: .keepEditing) }
    }

    @Test func 구간으로_재현되지_않는_현재_그리드에는_내_그리드_편집을_다시_얹지_않는다() async throws {
        // 내 편집: 120 BPM 그리드를 121로. 그 뒤 rekordbox에서 125 BPM이 되고 한 박이 3ms 어긋났다(균일한 구간으로 다시 만들 수 없다)
        var original = GridDraft(trackUUID: "g", grid: Self.grid(bpm: 120, beats: 120))
        original.segments[0].bpm = 121
        var beats = Self.grid(bpm: 125, beats: 125).beats
        beats[2].time += 0.003
        let complex = BeatGrid(beats: beats)
        #expect(GridEditEligibility.reconstructionErrorMilliseconds(of: complex, duration: 60) > 2)
        let reader = Reader(RekordboxLibrary(allTracks: [Self.track("g", length: 60)], cues: [], playCounts: [:]), grids: ["g": complex])
        let recover = RecoverDrafts(reader: reader.port, drafts: MemoryDrafts().store)
        let read = try await recover.readCurrent([.grid(original)], source: Self.source, share: Self.share)[0].get()
        let review = DraftRecoveryReview(original: .grid(original), current: read.draft, title: "곡", currentRow: read.row, currentGrid: read.grid)
        #expect(review.keepRefusal != nil)
        #expect(throws: (any Error).self) { try RecoverDrafts.resolve(review, latest: read, choice: .keepEditing) }
        // 현재값 사용은 된다
        #expect((try? RecoverDrafts.resolve(review, latest: read, choice: .useCurrent)) != nil)
    }

    @MainActor
    @Test func 저장에_실패하면_기존_입력을_저장_큐에_돌려놓고_던진다() throws {
        let memory = MemoryDrafts()
        var store = memory.store
        let failures = Mutex<[DraftSaveFailure]>([])
        store.failures = { failures.withLock { $0 } }
        let recover = RecoverDrafts(reader: Reader(RekordboxLibrary(allTracks: [], cues: [], playCounts: [:])).port, drafts: store)
        let original = CueDraft(trackUUID: "c")
        var resolved = original
        resolved.cues = [EditableCue(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .memory, time: 1, name: "새 큐")]
        failures.withLock { $0 = [DraftSaveFailure(kind: .cue, trackUUID: "c", revision: 1, reason: "디스크가 가득 찼습니다")] }
        #expect(throws: (any Error).self) { try recover.save(.cues(resolved), restoring: .cues(original)) }
        #expect(memory.cue("c") == nil, "실패한 새 기준 대신 기존 입력(고친 것 없음 = 지우기)이 남는다")
        failures.withLock { $0 = [] }
        try recover.save(.cues(resolved), restoring: .cues(original))
        #expect(memory.cue("c")?.cues.count == 1)
    }

    @Test func 원본은_명시한_사본이면_연_사본이고_아니면_라이브_DB다() throws {
        let opened = URL(filePath: "/copies/master.db")
        func location(explicit: Bool) -> LibraryLocation {
            LibraryLocation(rekordboxDirectory: URL(filePath: "/live"), rekordboxDirectoryOverridden: false, snapshotDirectory: URL(filePath: "/snapshots"),
                            opensExplicitCopy: explicit, explicitCopy: explicit ? opened : nil, database: URL(filePath: "/target/master.db"),
                            shareRoot: nil, backupDirectory: URL(filePath: "/backups"), draftHome: URL(filePath: "/home"), movesDamagedDrafts: false)
        }
        #expect(try RecoverDrafts.draftSource(location: location(explicit: false), opened: opened).database.path == "/live/master.db")
        #expect(try RecoverDrafts.draftSource(location: location(explicit: true), opened: opened).database == opened)
        #expect(throws: (any Error).self) { try RecoverDrafts.draftSource(location: location(explicit: true), opened: nil) }
        // 재생 목록은 쓰기 대상 DB와 그 옆 share를 본다(곡 초안과 다르다, 옛 동작 그대로)
        let playlist = RecoverDrafts.playlistSource(location: location(explicit: false), opened: opened)
        #expect(playlist.database.path == "/target/master.db" && playlist.share.path == "/target/share")
    }

    @Test func 재생_목록은_다시_적용하거나_그_목록의_막힌_편집만_버린다() async throws {
        let library = RekordboxLibrary(allTracks: [Self.track("a"), Self.track("b")], cues: [], playCounts: [:],
                                       playlists: [RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false, trackIDs: ["id-a"])])
        let recover = RecoverDrafts(reader: Reader(library).port, drafts: MemoryDrafts().store)
        let current = try await recover.readPlaylistCurrent(source: Self.source, share: Self.share)
        #expect(current.contentIDs == ["id-a", "id-b"] && current.rows["id-a"]?.track.uuid == "a")
        // 지금은 없는 목록에 곡을 넣은 초안은 막힌다
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: PlaylistRef("P"), contentIDs: ["id-b"]),
                         rekordbox: PlaylistLayout(rekordbox: library.playlists))
        let gone = PlaylistRecoveryCurrent(layout: PlaylistLayout(), contentIDs: current.contentIDs, titles: current.titles, rows: current.rows)
        let review = try RecoverDrafts.review(playlist: "P", draft: draft, current: gone)
        #expect(review.blockedOffsets == [0])
        #expect(try RecoverDrafts.resolvePlaylist(review, reapply: false, latest: gone).isEmpty)
        // 비교 뒤 라이브러리가 또 바뀌면 그대로 둔다
        #expect(throws: (any Error).self) { try RecoverDrafts.resolvePlaylist(review, reapply: false, latest: current) }
        // 막힌 편집이 없으면 비교할 것이 없다
        #expect(throws: (any Error).self) { try RecoverDrafts.review(playlist: "P", draft: draft, current: current) }
    }
}
