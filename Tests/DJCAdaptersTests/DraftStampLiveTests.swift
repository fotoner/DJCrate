import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
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

    @Test func 재생_목록_단계_식별자_계약() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let human = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try playlistStepIdentityContract(human: human, cli: human.with(origin: .cli),
                                         rawWrite: { try PlaylistDraftStore.save($0, url: places.playlist) },
                                         restart: { DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human) },
                                         backups: folder.url.appending(path: "backups"))
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

    // MARK: 리뷰 1라운드(S1~S5)

    /// S1: 단계의 판은 해시가 아니라 단계에 저장한 식별자로 잇는다. 같은 내용의 단계가 둘이어도(같은 곡 넣기 → 빼기 → 다시 넣기)
    /// 초안 저장과 도장 갱신 사이에 멈춘 뒤 재시작 정리가 마지막 단계까지 지우지 않는다
    @Test func 같은_내용의_단계가_둘이어도_멈춘_뒤_정리가_마지막_추가를_지우지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let rekordbox = Self.rekordbox
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        try draft.append(.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 1, contentID: "9")]), rekordbox: rekordbox)
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        #expect(draft.steps.count == 3)
        try app.savePlaylistDraft(draft)
        let stamps = app.playlistStamps()
        #expect(stamps.count == 3 && Set(stamps.map(\.revision)).count == 3)
        let written = [WrittenPlaylistStep(revision: stamps[0].revision, contentHash: stamps[0].contentHash)]
        // 정리가 초안 파일에서 쓴 첫 단계를 뺀 뒤 도장을 갱신하기 전에 멈췄다
        var remaining = app.playlistDraft()
        remaining.removeSteps(at: [0])
        try PlaylistDraftStore.save(remaining, url: places.playlist)
        // 재시작: 새 프로세스의 저장소가 같은 미정리 목록으로 정리한다
        let restarted = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let result = try restarted.removeWrittenSteps(PlaylistStepCleanup(written: written, newPlaylistIDs: [:],
                                                                           backups: folder.url.appending(path: "backups"), backupFolder: "b"))
        #expect(result.removed.isEmpty && result.notFound == [written[0].revision])
        #expect(restarted.playlistDraft().edits == [.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 1, contentID: "9")]),
                                                    .addTracks(playlist: .id("A"), contentIDs: ["9"])])
        // 남은 두 단계는 각자의 판을 쓴다
        #expect(restarted.playlistStamps().map(\.revision) == [stamps[1].revision, stamps[2].revision])
    }

    /// S2: 기존 단계에 합쳐진 편집(CLI가 만든 새 목록의 이름을 앱에서 바꿈 → 만들기 단계에 합쳐짐)은 새 판을 받고 출처를 합친다
    @Test func 기존_단계에_합쳐진_편집은_새_판을_받고_출처를_합쳐_제안이다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let cli = DraftFiles.live(home: folder.url).with(origin: .cli)
        var created = PlaylistDraft()
        try created.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        try cli.savePlaylist(created)
        let first = app.playlistStamps()
        #expect(first.count == 1 && first[0].origins == [.cli])
        // 앱이 읽어 이름을 바꾼다: 만들기 단계에 합쳐져 단계는 하나다
        var loaded = app.playlistDraft()
        try loaded.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: Self.rekordbox)
        #expect(loaded.steps.count == 1)
        try app.savePlaylistDraft(loaded)
        let second = app.playlistStamps()
        #expect(second.count == 1 && second[0].revision > first[0].revision && second[0].origins == [.cli, .human])
        #expect(app.playlistSuggestions() == [.mixedOrigins])
    }

    /// S2(도장 없는 옛 단계): 도장 없는 기존 단계에 합쳐지면 모름을 유지한다
    @Test func 도장_없는_옛_단계에_합쳐진_편집은_모름을_유지한다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        var created = PlaylistDraft()
        try created.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        try PlaylistDraftStore.save(created, url: places.playlist)
        var loaded = app.playlistDraft()
        try loaded.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: Self.rekordbox)
        try app.savePlaylistDraft(loaded)
        let stamps = app.playlistStamps()
        #expect(stamps.count == 1 && stamps[0].origins.contains(.unknown) && stamps[0].origins.contains(.human))
        #expect(app.playlistSuggestions() == [.unknownOrigin])
    }

    /// S3: 덮어쓰기 전에 지금 파일 내용의 해시를 저장된 도장과 견준다. 다르면(바깥에서 고쳤다) 출처에 모름을 더한다
    @Test func 바깥에서_고친_태그_초안을_앱이_덮어쓰면_모름이_섞여_제안이다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.title = "원래"
        app.saveTags([tag])
        app.flush()
        #expect(app.suggestion(DraftKey(.tag, "a")) == nil)
        // 바깥(도장을 적지 않는 쓰기)이 코멘트를 더했다
        var outside = tag
        outside.fields.comment = "AI가 더한 코멘트"
        try TagDraftStore.save(outside, directory: places.tags)
        // 앱이 자기 메모리 값에서 제목만 바꿔 저장한다
        var edited = tag
        edited.fields.title = "새 제목"
        app.saveTags([edited])
        app.flush()
        #expect(app.stamp(DraftKey(.tag, "a"))?.origins == [.human, .unknown])
        #expect(app.suggestion(DraftKey(.tag, "a")) == .unknownOrigin)
    }

    @Test func 바깥에서_고친_초안은_큐_그리드_게인_합치기도_덮어쓰면_모름이_섞인다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "m", title: "가", duration: 60, offset: 0, cues: []),
                                        removing: [], base: "b")
        app.saveCue(Self.cue("a", at: 1))
        app.saveGain(-3, trackUUID: "g")
        try app.saveMergeDrafts([merge])
        app.flush()
        try CueDraftStore.save(Self.cue("a", at: 9), directory: places.cue)
        try GainDraftStore.save(-8, trackUUID: "g", url: places.gain)
        var outsideMerge = merge
        outsideMerge.base = "바깥"
        try DuplicateMergeDraftStore.save([outsideMerge], url: places.merge)
        app.saveCue(Self.cue("a", at: 2))
        app.saveGain(-4, trackUUID: "g")
        try app.saveMergeDrafts([merge])
        app.flush()
        for key in [DraftKey(.cue, "a"), DraftKey(.gain, "g"), DraftKey(.merge, "m")] {
            #expect(app.stamp(key)?.origins == [.human, .unknown], "\(key)")
        }
    }

    @Test func 바깥에서_고친_재생_목록_단계를_앱이_저장하면_그_단계는_모름이_섞인다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try app.savePlaylistDraft(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]))
        // 바깥이 단계 내용만 고쳤다(단계 수 같음)
        let outside = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["7"])])
        try PlaylistDraftStore.save(outside, url: places.playlist)
        // 앱이 그 위에 한 단계를 더해 저장한다
        var more = outside
        try more.append(.rename(playlist: .id("B"), name: "새"), rekordbox: Self.rekordbox)
        try app.savePlaylistDraft(more)
        let stamps = app.playlistStamps()
        #expect(stamps.count == 2 && stamps[0].origins == [.human, .unknown] && stamps[1].origins == [.human])
        #expect(app.playlistSuggestions() == [.unknownOrigin, nil])
    }

    /// S4(범위 밖, 저장소만 고정): 복원이 되살린 초안의 출처 `.restored`는 호출부(W2-D)가 정한다. 저장소는 곡 초안과 재생 목록 단계 모두에 적는다
    @Test func 되살림_출처_포트는_곡_초안과_재생_목록_단계_모두에_되살림을_적는다() throws {
        let folder = try TemporaryFolder()
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        let restored = app.with(origin: .restored)
        restored.saveCue(Self.cue("a"))
        restored.flush()
        try restored.savePlaylistDraft(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]))
        #expect(app.stamp(DraftKey(.cue, "a"))?.origins == [.restored])
        #expect(app.playlistStamps().map(\.origins) == [[.restored]])
        #expect(app.suggestion(DraftKey(.cue, "a")) == .notHuman && app.playlistSuggestions() == [.notHuman])
    }

    /// S5(앱): 초안 잠금을 잡지 못하면 저장하지 않고 지금의 저장 실패로 알린다
    @Test func 잠금을_잡지_못하면_앱_저장은_실패로_알리고_초안을_쓰지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try FileManager.default.createDirectory(at: DraftStampStore.lockURL(home: folder.url), withIntermediateDirectories: true)
        let failure = Mutex<DraftSaveFailure?>(nil)
        app.saveCue(Self.cue("a")) { result in failure.withLock { $0 = result } }
        app.flush()
        #expect(failure.withLock { $0 } != nil && !app.failures().isEmpty)
        #expect(CueDraftStore.load(trackUUID: "a", directory: places.cue) == nil)
        #expect(throws: (any Error).self) { try app.savePlaylistDraft(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])])) }
        #expect(!FileManager.default.fileExists(atPath: places.playlist.path))
    }

    /// S6: CLI의 재생 목록 쌓기는 원본 재확인과 저장을 한 초안 잠금 안에서 한다. 계획을 끝내고 저장하려는 순간 앱의 쓴 뒤 정리가
    /// 쓴 단계를 빼면(잠금을 쥔 동안) `draft_changed`로 끝나고 쓴 단계가 되살아나지 않는다
    @Test func CLI_재생_목록_쌓기는_저장_직전에_끼어든_정리가_쓴_단계를_되살리지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let app = DraftStore.live(writer: DraftWriter(), home: folder.url, origin: .human)
        try app.savePlaylistDraft(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]))
        let live = DraftFiles.live(home: folder.url).with(origin: .cli)
        var wrapped = live
        let attempting = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let original = try #require(live.savePlaylistIfUnchanged)
        wrapped.savePlaylistIfUnchanged = { expected, draft in
            attempting.signal()
            return try original(expected, draft)
        }
        let outcome = Mutex<String?>(nil)
        let edits = EditDraftFiles(files: wrapped)
        let request = PlaylistEditRequest.create(name: "새 목록", isFolder: false, parent: .ref(.root), position: nil, alias: nil, tracks: [])
        try DraftStampStore.withLock(home: folder.url) {
            DispatchQueue.global().async {
                do {
                    _ = try edits.stackPlaylistEdits([request], rekordbox: Self.rekordbox, contentIDs: ["9"], allOrNothing: false, dryRun: false)
                    outcome.withLock { $0 = "ok" }
                } catch let failure as ReadFailure {
                    outcome.withLock { $0 = failure.code }
                } catch {
                    outcome.withLock { $0 = "other" }
                }
                finished.signal()
            }
            // CLI가 계획을 끝내고 저장하려는 순간(잠금을 기다린다). 그 틈에 정리가 쓴 단계를 뺀다
            attempting.wait()
            try PlaylistDraftStore.save(PlaylistDraft(), url: places.playlist)
        }
        finished.wait()
        #expect(outcome.withLock { $0 } == "draft_changed")
        #expect(PlaylistDraftStore.load(url: places.playlist).isEmpty)
    }

    /// S5(CLI): 잠금을 잡지 못하면 CLI는 초안 입출력 실패로 알리고 저장하지 않는다
    @Test func 잠금을_잡지_못하면_CLI_저장은_초안_입출력_실패이고_저장하지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try FileManager.default.createDirectory(at: DraftStampStore.lockURL(home: folder.url), withIntermediateDirectories: true)
        let edits = EditDraftFiles(files: DraftFiles.live(home: folder.url).with(origin: .cli))
        let request = EditDraftFiles.CueRequest(time: 10, loopEnd: nil, beats: nil, slot: 1, name: "B", active: false)
        let track = Track(id: "7", uuid: "u7", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                          releaseYear: nil, trackNumber: nil, key: nil, bpm: 128, lengthSeconds: 120, folderPath: "/m/a.mp3", comment: "",
                          importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: 0, dataStatus: 256)
        var code: String?
        do { _ = try edits.addCue({ request }, track: track, rekordboxCues: [], dryRun: false) } catch let failure as ReadFailure { code = failure.code }
        #expect(code == "draft_io_failed")
        #expect(CueDraftStore.load(trackUUID: "u7", directory: places.cue) == nil)
    }
}
