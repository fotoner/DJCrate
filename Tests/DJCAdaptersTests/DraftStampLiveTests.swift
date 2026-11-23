import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 초안 출처·판·해시(R5·R22 저장소 몫)의 실제 구현: 같은 계약 함수(PortTestKit)를 가짜(`MemoryDrafts`·`MemoryDraftFiles`)와 실제 저장소에 돌리고,
/// 앱 포트와 CLI 포트가 같은 초안 폴더를 나눠 쓸 때의 제안 판정과 판 지정 삭제를 본다.
@MainActor
@Suite("초안 도장(실제 저장소)")
struct DraftStampLiveTests {
    nonisolated static func cue(_ uuid: String, at time: Double = 1) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(kind: .memory, time: time)]
        return draft
    }

    static let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])

    static func playlist(_ edits: [PlaylistEdit]) throws -> PlaylistDraft {
        var draft = PlaylistDraft()
        for edit in edits { try draft.append(edit, rekordbox: rekordbox) }
        return draft
    }

    static func written(_ store: DraftStore, _ key: DraftKey) throws -> WrittenDraft {
        let stamp = try #require(store.stamp(key))
        return WrittenDraft(key: key, revision: stamp.revision, contentHash: stamp.contentHash)
    }

    // MARK: 계약 함수(가짜와 같은 함수)

    @Test func 출처와_판_계약() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let human = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try draftRevisionContract(human, cli: human.with(origin: .cli), editOutside: { try CueDraftStore.save($0, directory: places.cue) })
    }

    @Test func 재생_목록_단계_판_계약() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let backups = folder.url.appending(path: "backups")
        // 사본을 남길 폴더 자리를 일반 파일로 막아 사본 쓰기 실패를 주입한다
        let copyFolder = backups.appending(path: "2026-11-24_120000", directoryHint: .isDirectory)
        let store = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try playlistStepRevisionContract(store, backups: backups,
                                         editOutside: { try PlaylistDraftStore.save($0, url: places.playlist) },
                                         failCopies: { fails in
            try? FileManager.default.removeItem(at: copyFolder)
            if fails {
                try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: copyFolder.path, contents: Data())
            }
        },
                                         readCopy: { try JSONDecoder().decode(PlaylistStepCopy.self, from: Data(contentsOf: $0)) })
    }

    @Test func 곡별_초안_파일_도장_계약() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try draftFilesStampContract({ DraftFiles.live(home: folder.url).with(origin: $0) },
                                    editOutside: { try CueDraftStore.save($0, directory: places.cue) })
    }

    // MARK: 출처는 포트 조립에서 정한다

    @Test func 조립한_포트의_출처가_도장에_적힌다() throws {
        let folder = try TemporaryFolder()
        let bare = DraftStore.live(writer: DraftWriter(), home: folder.url)
        #expect(bare.origin == .unknown && DraftFiles.live(home: folder.url).origin == .unknown)
        let human = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        #expect(human.origin == .human)
        for origin in [DraftOrigin.cli, .link, .restored, .agent] {
            let variant = human.with(origin: origin)
            #expect(variant.origin == origin)
            variant.saveCue(Self.cue(origin.rawValue))
            variant.flush()
            #expect(human.stamp(DraftKey(.cue, origin.rawValue))?.origins == [origin])
        }
        bare.saveCue(Self.cue("모름"))
        bare.flush()
        #expect(bare.stamp(DraftKey(.cue, "모름"))?.origins == [.unknown])
    }

    @Test func 출처만_다른_포트는_같은_저장_큐와_폴더를_쓴다() throws {
        let folder = try TemporaryFolder()
        let human = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let link = human.with(origin: .link)
        human.saveCue(Self.cue("a", at: 1))
        // 한 포트의 flush가 다른 포트의 걸린 저장도 끝낸다(같은 큐)
        link.saveCue(Self.cue("a", at: 2))
        human.flush()
        #expect(human.cueDraft("a")?.cues.first?.time == 2)
        #expect(human.stamp(DraftKey(.cue, "a"))?.origins == [.human, .link])
    }

    // MARK: 제안 판정(앱·CLI)

    @Test func 앱_편집_포트가_저장한_초안은_모든_종류가_제안이_아니다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        app.saveCue(Self.cue("a"))
        app.saveGrid(GridDraft(trackUUID: "a", base: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)],
                               segments: [GridSegment(start: 0.2, bpm: 124, firstBeatNumber: 1)]))
        app.saveGain(-3, trackUUID: "a")
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.comment = "코멘트"
        app.saveTags([tag])
        let artwork = ArtworkDraftStore.edit(trackUUID: "a", base: ArtworkBase(imagePath: ""), image: Data("그림".utf8), imageName: "a.png")
        try app.saveArtwork(artwork)
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "a", title: "가", duration: 60, offset: 0, cues: []),
                                        removing: [], base: "b")
        try app.saveMergeDrafts([merge])
        app.flush()
        for kind in DraftKey.Kind.allCases {
            let key = DraftKey(kind, "a")
            #expect(app.stamp(key)?.isHumanOnly == true, "\(kind)")
            #expect(app.currentHash(key) == app.stamp(key)?.contentHash, "\(kind)")
            #expect(app.suggestion(key) == nil, "\(kind)")
        }
    }

    /// 시험 셋 1: `djc draft`가 만든 초안은 ⌘S 전에 쓰이지 않는다(앱이 그 초안을 제안으로 본다)
    @Test func CLI가_만든_초안은_앱에서_제안이다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        try cli.saveCue(Self.cue("a"))
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.comment = "AI가 고침"
        try cli.saveTag(tag)
        #expect(app.stamp(DraftKey(.cue, "a"))?.origins == [.cli])
        #expect(app.suggestion(DraftKey(.cue, "a")) == .notHuman && app.suggestion(DraftKey(.tag, "a")) == .notHuman)
    }

    /// 시험 셋 2: 사람이 고친 초안을 CLI가 다시 고치면 제안이 된다
    @Test func 사람이_고친_초안을_CLI가_다시_고치면_제안이다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        app.saveCue(Self.cue("a", at: 1))
        app.flush()
        #expect(app.suggestion(DraftKey(.cue, "a")) == nil)
        try cli.saveCue(Self.cue("a", at: 2))
        #expect(app.suggestion(DraftKey(.cue, "a")) == .mixedOrigins)
        #expect(app.stamp(DraftKey(.cue, "a"))?.origins == [.human, .cli])
    }

    /// 시험 셋 3: 초안 파일만 바깥에서 바뀌면 제안이 된다
    @Test func 초안_파일만_바깥에서_바뀌면_제안이다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        app.saveCue(Self.cue("a", at: 1))
        app.flush()
        #expect(app.suggestion(DraftKey(.cue, "a")) == nil)
        try CueDraftStore.save(Self.cue("a", at: 9), directory: places.cue)
        #expect(app.suggestion(DraftKey(.cue, "a")) == .contentChanged)
    }

    @Test func 업데이트_전부터_있던_초안은_출처를_몰라_제안이다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try CueDraftStore.save(Self.cue("a"), directory: places.cue)
        try PlaylistDraftStore.save(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]), url: places.playlist)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        #expect(app.stamp(DraftKey(.cue, "a")) == nil && app.suggestion(DraftKey(.cue, "a")) == .unknownOrigin)
        #expect(app.playlistSuggestions() == [.unknownOrigin])
        // 없는 초안은 제안이 아니다
        #expect(app.suggestion(DraftKey(.cue, "없음")) == nil)
    }

    @Test func 옛_형식_게인_파일은_격리하지_않고_읽고_제안으로_본다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Data(#"{"old":-2.5}"#.utf8).write(to: places.gain)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        #expect(try app.gainDrafts() == ["old": -2.5] && app.gainDraftUUIDs() == ["old"])
        #expect(app.preserveDamaged().isEmpty && FileManager.default.fileExists(atPath: places.gain.path))
        #expect(app.suggestion(DraftKey(.gain, "old")) == .unknownOrigin)
        app.saveGain(-1, trackUUID: "new")
        app.flush()
        #expect(app.suggestion(DraftKey(.gain, "new")) == nil && app.suggestion(DraftKey(.gain, "old")) == .unknownOrigin)
    }

    @Test func 재생_목록_단계의_제안_판정은_단계마다_본다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        let first = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])])
        try app.savePlaylistDraft(first)
        #expect(app.playlistSuggestions() == [nil])
        // CLI가 단계를 더하면 앞 단계는 사람 도장 그대로, 새 단계만 제안이다
        let both = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "새")])
        try cli.savePlaylist(both)
        #expect(app.playlistSuggestions() == [nil, .notHuman])
        // 바깥이 단계 내용만 고치면(단계 수 같음) 그 단계가 제안이다
        try PlaylistDraftStore.save(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["7"]),
                                                                       .rename(playlist: .id("B"), name: "새")]), url: places.playlist)
        #expect(app.playlistSuggestions() == [.contentChanged, .notHuman])
    }

    // MARK: 쓴 뒤 정리는 실제로 쓴 판만 지운다

    @Test func 쓰는_도중_새로_저장한_초안은_앱이든_CLI든_정리가_남긴다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        app.saveCue(Self.cue("a", at: 1))
        app.saveCue(Self.cue("b", at: 1))
        app.flush()
        let a = try Self.written(app, DraftKey(.cue, "a")), b = try Self.written(app, DraftKey(.cue, "b"))
        // 쓰는 동안 같은 곡에 새 큐 초안: a는 앱이, b는 CLI가
        app.saveCue(Self.cue("a", at: 2))
        try cli.saveCue(Self.cue("b", at: 2))
        let result = try app.removeWritten([a, b])
        #expect(result == DraftRemoval(kept: [a, b]))
        #expect(app.cueDraft("a")?.cues.first?.time == 2 && app.cueDraft("b")?.cues.first?.time == 2)
        // 새 초안의 출처가 남는다
        #expect(app.stamp(DraftKey(.cue, "a"))?.origins == [.human] && app.stamp(DraftKey(.cue, "b"))?.origins == [.human, .cli])
    }

    @Test func 판과_해시가_같으면_지우고_도장도_지운다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        app.saveCue(Self.cue("a"))
        app.saveGain(-3, trackUUID: "g")
        app.saveGain(-4, trackUUID: "h")
        app.flush()
        let a = try Self.written(app, DraftKey(.cue, "a")), g = try Self.written(app, DraftKey(.gain, "g"))
        #expect(try app.removeWritten([a, g]) == DraftRemoval(removed: [a, g]))
        #expect(app.cueDraft("a") == nil && app.stamp(DraftKey(.cue, "a")) == nil)
        // 게인은 모든 곡이 한 파일이라 쓴 곡만 빠진다
        #expect(try app.gainDrafts() == ["h": -4] && app.stamp(DraftKey(.gain, "g")) == nil && app.stamp(DraftKey(.gain, "h")) != nil)
    }

    @Test func 정리는_앞서_걸린_저장_뒤에_한다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        app.saveCue(Self.cue("a", at: 1))
        app.flush()
        let old = try Self.written(app, DraftKey(.cue, "a"))
        // 저장 큐에 걸린 새 저장이 아직 안 끝났어도 정리는 그 저장을 끝낸 뒤 판을 견준다
        app.saveCue(Self.cue("a", at: 2))
        #expect(try app.removeWritten([old]) == DraftRemoval(kept: [old]))
        #expect(app.cueDraft("a")?.cues.first?.time == 2)
    }

    @Test func 이대로_둔다는_제안으로_바꾸고_지우지_않는다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        app.saveCue(Self.cue("a"))
        app.flush()
        let written = try Self.written(app, DraftKey(.cue, "a"))
        let marked = try app.markSuggestions([written], [])
        let stamp = try #require(app.stamp(DraftKey(.cue, "a")))
        #expect(marked == [written.revision: stamp.revision] && stamp.origins == [.human, .unknown])
        #expect(app.suggestion(DraftKey(.cue, "a")) == .unknownOrigin && app.cueDraft("a") != nil)
        #expect(try app.removeWritten([written]) == DraftRemoval(kept: [written]))
    }

    // MARK: 가짜와 실제가 같은 해시를 적는다

    @Test func 가짜와_실제_저장소가_같은_내용에_같은_해시를_적는다() throws {
        let folder = try TemporaryFolder()
        let live = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let memory = MemoryDrafts().store
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.comment = "코멘트"
        let grid = GridDraft(trackUUID: "a", base: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)],
                             segments: [GridSegment(start: 0.2, bpm: 124, firstBeatNumber: 1)])
        let artwork = ArtworkDraftStore.edit(trackUUID: "a", base: ArtworkBase(imagePath: ""), image: Data("그림".utf8), imageName: "a.png")
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "a", title: "가", duration: 60, offset: 0, cues: []),
                                        removing: [], base: "b")
        // 큐 ID가 달라 해시가 갈리지 않게 같은 큐를 두 저장소에 넣는다
        let cue = Self.cue("a")
        for store in [live, memory] {
            store.saveCue(cue)
            store.saveGrid(grid)
            store.saveGain(-3, trackUUID: "a")
            store.saveTags([tag])
            try store.saveArtwork(artwork)
            try store.saveMergeDrafts([merge])
            store.flush()
        }
        for kind in DraftKey.Kind.allCases {
            let key = DraftKey(kind, "a")
            #expect(live.stamp(key)?.contentHash == memory.stamp(key)?.contentHash && live.stamp(key) != nil, "\(kind)")
        }
        // 재생 목록 단계도 같은 함수(`DraftContentHash(step:in:)`)다
        let playlist = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "새")])
        try live.savePlaylistDraft(playlist)
        try memory.savePlaylistDraft(playlist)
        #expect(live.playlistStamps().map(\.contentHash) == memory.playlistStamps().map(\.contentHash))
    }

    // MARK: 프로세스 사이

    @Test func 앱과_CLI가_동시에_저장해도_판이_겹치지_않는다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        let uuids = (0..<30).map { "t\($0)" }
        DispatchQueue.concurrentPerform(iterations: uuids.count) { index in
            if index.isMultiple(of: 2) { app.saveCue(Self.cue(uuids[index])) } else { try? cli.saveCue(Self.cue(uuids[index])) }
        }
        app.flush()
        let revisions = uuids.compactMap { app.stamp(DraftKey(.cue, $0))?.revision }
        #expect(revisions.count == uuids.count && Set(revisions).count == uuids.count)
        for (index, uuid) in uuids.enumerated() {
            #expect(app.stamp(DraftKey(.cue, uuid))?.origins == (index.isMultiple(of: 2) ? [.human] : [.cli]))
        }
    }

    @Test func 곡별_초안_파일_삭제는_도장도_지운다() throws {
        let folder = try TemporaryFolder()
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try cli.saveCue(Self.cue("a"))
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.comment = "x"
        try cli.saveTag(tag)
        #expect(app.stamp(DraftKey(.cue, "a")) != nil && app.stamp(DraftKey(.tag, "a")) != nil)
        try cli.removeCue("a")
        try cli.removeTag("a")
        #expect(app.stamp(DraftKey(.cue, "a")) == nil && app.stamp(DraftKey(.tag, "a")) == nil)
    }
}
