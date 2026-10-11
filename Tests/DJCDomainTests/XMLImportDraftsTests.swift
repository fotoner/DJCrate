import Foundation
import Testing
@testable import DJCDomain

/// rekordbox XML 가져오기(#72)의 고른 차이 → 초안. 초안의 base는 지금 라이브러리 상태이고, 기존 초안은 덮지 않으며,
/// 초안이 담지 못하는 차이는 손실로 센다. 합성 값만 쓴다.
@Suite("rekordbox XML 가져오기 초안")
struct XMLImportDraftsTests {
    typealias Doc = XMLLibrary
    typealias Mark = XMLLibrary.Mark

    func track(_ id: String = "101", length: Int = 300, key: String? = "8A", rating: Int = 0, status: Int? = 0) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: "제목", artist: "A", album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: length, folderPath: "/m/\(id).mp3", comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: rating, dataStatus: status)
    }

    func grid(bpm: Double = 120, first: Double = 0.5, count: Int = 400) -> BeatGrid {
        BeatGrid(beats: (0..<count).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: bpm, time: first + Double($0) * 60 / bpm) })
    }

    func source(_ track: Track, cues: [Cue] = [], grid: BeatGrid? = nil, inPlaylist: Bool = false,
                existing: Set<XMLImportDrafts.Kind> = []) -> XMLImportDrafts.TrackSource {
        XMLImportDrafts.TrackSource(track: track, cues: cues, grid: grid, inPlaylist: inPlaylist, existing: existing)
    }

    func diff(cues: XMLLibraryDiff.CueChange? = nil, grid: XMLLibraryDiff.GridChange? = nil,
              tags: [XMLLibraryDiff.TagChange] = [], playlists: [XMLLibraryDiff.PlaylistChange] = []) -> XMLLibraryDiff.Result {
        var result = XMLLibraryDiff.Result()
        if cues != nil || grid != nil || !tags.isEmpty {
            result.tracks = [XMLLibraryDiff.TrackDiff(xmlKey: "1", libraryKey: "101", path: "/m/101.mp3", title: "제목",
                                                      cues: cues, grid: grid, tags: tags)]
        }
        result.playlists = playlists
        return result
    }

    func cueChange(library: [Mark], xml: [Mark]) -> XMLLibraryDiff.CueChange {
        XMLLibraryDiff.cueChange(xml: xml, library: library)!
    }

    // MARK: 큐

    @Test func 큐_초안은_지금_큐를_base로_XML_큐를_내용으로() throws {
        var loop = Cue(id: "c2", contentID: "101", kind: 0, inMsec: 40_000, name: "루프", colorTableIndex: nil, outMsec: 44_000)
        loop.activeLoop = 1
        let cues = [Cue(id: "c1", contentID: "101", kind: 1, inMsec: 20_000, name: "A", colorTableIndex: nil), loop]
        let change = cueChange(library: [Mark(kind: .hot(0), start: 20, name: "A"), Mark(kind: .memory, start: 40, end: 44, name: "루프")],
                               xml: [Mark(kind: .hot(1), start: 25, name: "B"), Mark(kind: .memory, start: 40, end: 44, name: "루프")])
        let plan = XMLImportDrafts.plan(diff: diff(cues: change), selection: .all,
                                        sources: ["101": source(track(),
                                                                cues: cues)], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.cueDrafts.first)
        #expect(draft.trackUUID == "uuid-101")
        #expect(draft.base.compactMap(\.sourceID).sorted() == ["c1", "c2"])
        // 같은 큐는 원래 행을 그대로 둔다(활성 루프 표시처럼 XML에 없는 칸을 잃지 않게)
        let kept = try #require(draft.cues.first { $0.sourceID == "c2" })
        #expect(kept.loop?.active == true)
        #expect(draft.cues.map(\.kind) == [.hot(1), .memory])
        #expect(draft.cues.first?.time == 25 && draft.cues.first?.name == "B" && draft.cues.first?.sourceID == nil)
        #expect(plan.losses.isEmpty && plan.skipped.isEmpty)
    }

    @Test func 같은_슬롯의_핫큐와_같은_위치의_메모리_큐는_원래_행을_고친다() throws {
        // 핫큐 색·활성 루프처럼 XML에 없는 칸을 잃지 않게 sourceID를 그대로 둔다
        var loop = Cue(id: "c2", contentID: "101", kind: 0, inMsec: 40_000, name: "루프", colorTableIndex: nil, outMsec: 44_000)
        loop.activeLoop = 1
        let cues = [Cue(id: "c1", contentID: "101", kind: 1, inMsec: 20_000, name: "A", colorTableIndex: 3, color: 9), loop]
        let change = cueChange(library: [Mark(kind: .hot(0), start: 20, name: "A"), Mark(kind: .memory, start: 40, end: 44, name: "루프")],
                               xml: [Mark(kind: .hot(0), start: 24, name: "새 A"), Mark(kind: .memory, start: 40, end: 48, name: "루프")])
        #expect(change.added.isEmpty && change.removed.isEmpty && change.modified.count == 2)
        let plan = XMLImportDrafts.plan(diff: diff(cues: change), selection: .all,
                                        sources: ["101": source(track(),
                                                                cues: cues)], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.cueDrafts.first)
        let hot = try #require(draft.cues.first { $0.sourceID == "c1" })
        #expect(hot.time == 24 && hot.name == "새 A" && hot.kind == .hot(0))
        let memory = try #require(draft.cues.first { $0.sourceID == "c2" })
        #expect(memory.loop?.end == 48 && memory.loop?.active == true)
        #expect(draft.cues.count == 2 && plan.losses.isEmpty)
    }

    @Test func XML에_없는_자동_큐는_초안에_남긴다() throws {
        let cues = [Cue(id: "auto", contentID: "101", kind: 0, inMsec: 500, name: "CUE(Auto)", colorTableIndex: nil),
                    Cue(id: "c1", contentID: "101", kind: 1, inMsec: 20_000, name: "", colorTableIndex: nil)]
        let change = cueChange(library: [Mark(kind: .memory, start: 0.5, name: "CUE(Auto)"), Mark(kind: .hot(0), start: 20, name: "")],
                               xml: [Mark(kind: .hot(0), start: 20, name: ""), Mark(kind: .hot(1), start: 30, name: "")])
        let plan = XMLImportDrafts.plan(diff: diff(cues: change), selection: .all,
                                        sources: ["101": source(track(),
                                                                cues: cues)], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.cueDrafts.first)
        #expect(draft.cues.compactMap(\.sourceID).sorted() == ["auto", "c1"])
        #expect(draft.cues.contains { $0.kind == .hot(1) && $0.time == 30 })
    }

    @Test func 담지_못하는_큐는_손실로_센다() throws {
        let xml = (0..<12).map { Mark(kind: .memory, start: Double($0 + 1), name: "") }
            + [Mark(kind: .hot(0), start: 50, name: ""), Mark(kind: .hot(0), start: 60, name: ""), Mark(kind: .hot(2), start: 900, name: "")]
        let plan = XMLImportDrafts.plan(diff: diff(cues: cueChange(library: [], xml: xml)), selection: .all,
                                        sources: ["101": source(track())], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        let draft = try #require(plan.cueDrafts.first)
        #expect(draft.cues.filter { $0.kind == .memory }.count == 10)
        #expect(draft.cues.filter { $0.kind == .hot(0) }.map(\.time) == [50])
        #expect(!draft.cues.contains { $0.time == 900 })
        #expect(draft.issues(duration: 300).isEmpty)
        #expect(plan.losses.count == 4 && plan.losses.allSatisfy { $0.kind == .cue && $0.libraryKey == "101" })
    }

    // MARK: 그리드

    @Test func 그리드_초안은_분석_파일_그리드를_base로() throws {
        let original = grid()
        let xml = [GridSegment(start: 0.52, bpm: 120, firstBeatNumber: 1)]
        let plan = XMLImportDrafts.plan(diff: diff(grid: .init(library: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], xml: xml)),
                                        selection: .all, sources: ["101": source(track(), grid: original)],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.gridDrafts.first)
        #expect(draft.base == GridDraft(trackUUID: "uuid-101", grid: original).base)
        #expect(draft.segments == xml && draft.hasChanges)
    }

    @Test func 반_박_안쪽으로_붙은_변속_지점은_쓰기에서_막히므로_손실() {
        // 쓰기는 경계의 반 박 안쪽 박을 새 구간 첫 박으로 대체한다(addTempoChange와 같은 규칙)
        let close = XMLLibraryDiff.GridChange(library: [], xml: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                                                 GridSegment(start: 10.7, bpm: 128, firstBeatNumber: 1),
                                                                 GridSegment(start: 10.9, bpm: 130, firstBeatNumber: 1)])
        let plan = XMLImportDrafts.plan(diff: diff(grid: close), selection: .all, sources: ["101": source(track(), grid: grid())],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(plan.gridDrafts.isEmpty && plan.losses.map(\.kind) == [.grid])
        #expect(plan.losses.first?.reason.contains("반 박") == true)
    }

    @Test func 분석_파일이_없거나_BPM이_범위_밖이면_그리드는_손실() {
        let change = XMLLibraryDiff.GridChange(library: [], xml: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        let none = XMLImportDrafts.plan(diff: diff(grid: change), selection: .all, sources: ["101": source(track())],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(none.gridDrafts.isEmpty && none.losses.map(\.kind) == [.grid])
        let fast = XMLLibraryDiff.GridChange(library: [], xml: [GridSegment(start: 0.5, bpm: 900, firstBeatNumber: 1)])
        let range = XMLImportDrafts.plan(diff: diff(grid: fast), selection: .all, sources: ["101": source(track(), grid: grid())],
                                         layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(range.gridDrafts.isEmpty && range.losses.map(\.kind) == [.grid])
    }

    // MARK: 태그

    @Test func 태그_초안은_지금_태그를_base로_바뀐_칸만() throws {
        let tags: [XMLLibraryDiff.TagChange] = [.init(key: .title, library: "제목", xml: "새 제목"), .init(key: .musicalKey, library: "8A", xml: "9A")]
        let plan = XMLImportDrafts.plan(diff: diff(tags: tags), selection: .all, sources: ["101": source(track())],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.tagDrafts.first)
        #expect(draft.base == TagFields(track: track()))
        #expect(draft.changedKeys == [.title, .musicalKey] && draft.fields.title == "새 제목" && draft.fields.musicalKey == "9A")
    }

    @Test func 쓸_수_없는_태그_칸은_손실로_빼고_나머지는_초안으로() throws {
        let tags: [XMLLibraryDiff.TagChange] = [.init(key: .artist, library: "A", xml: "B"),
                                                .init(key: .musicalKey, library: "8A", xml: "Dorian"),
                                                .init(key: .rating, library: "", xml: "4"),
                                                .init(key: .title, library: "제목", xml: "")]
        // 쓰기 규칙을 확인하지 않은 상태(258)의 곡은 평점을 뺀다. 재생 목록에 든 곡은 R65(2026-10-09)로 열어 넣는다.
        let plan = XMLImportDrafts.plan(diff: diff(tags: tags), selection: .all, sources: ["101": source(track(status: 258), inPlaylist: true)],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        let draft = try #require(plan.tagDrafts.first)
        #expect(draft.changedKeys == [.artist])
        let listed = XMLImportDrafts.plan(diff: diff(tags: tags), selection: .all, sources: ["101": source(track(), inPlaylist: true)],
                                          layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(listed.tagDrafts.first?.changedKeys == [.artist, .rating] && listed.losses.count == 2)
        #expect(plan.losses.count == 3 && plan.losses.allSatisfy { $0.kind == .tag })
    }

    // MARK: 기존 초안·고르기

    @Test func 기존_초안이_있는_곡은_덮지_않고_건너뛴다() {
        let change = cueChange(library: [], xml: [Mark(kind: .memory, start: 1, name: "")])
        let tags: [XMLLibraryDiff.TagChange] = [.init(key: .artist, library: "A", xml: "B")]
        let plan = XMLImportDrafts.plan(diff: diff(cues: change, tags: tags), selection: .all,
                                        sources: ["101": source(track(),
                                                                existing: [.cue])], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(plan.cueDrafts.isEmpty && plan.tagDrafts.count == 1)
        #expect(plan.skipped.count == 1 && plan.skipped[0].kind == .cue && plan.skipped[0].reason.contains("초안"))
    }

    @Test func 고른_종류와_곡만_초안으로() {
        let change = cueChange(library: [], xml: [Mark(kind: .memory, start: 1, name: "")])
        let tags: [XMLLibraryDiff.TagChange] = [.init(key: .artist, library: "A", xml: "B")]
        var selection = XMLImportDrafts.Selection.all
        selection.kinds = [.tag]
        let plan = XMLImportDrafts.plan(diff: diff(cues: change, tags: tags), selection: selection, sources: ["101": source(track())],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(plan.cueDrafts.isEmpty && plan.tagDrafts.count == 1)
        selection = .all
        selection.trackKeys = ["999"]
        let none = XMLImportDrafts.plan(diff: diff(cues: change, tags: tags), selection: selection, sources: ["101": source(track())],
                                        layout: PlaylistLayout(), playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(none.isEmpty)
        // 종류별로 고른 곡: 태그 탭에서 모두 빼면 큐만 만든다
        let perKind = XMLImportDrafts.plan(diff: diff(cues: change, tags: tags), selection: .init(tracksByKind: [.tag: []]),
                                           sources: ["101": source(track())], layout: PlaylistLayout(), playlistDraft: PlaylistDraft(),
                                           newKey: { UUID().uuidString })
        #expect(perKind.cueDrafts.count == 1 && perKind.tagDrafts.isEmpty)
    }

    // MARK: 재생 목록

    func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false, tracks: [String] = []) -> PlaylistLayout.Item {
        PlaylistLayout.Item(id: id, name: name, parentID: parent, isFolder: folder,
                            entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    @Test func 없는_목록은_폴더까지_만들어_곡을_넣는다() throws {
        let layout = PlaylistLayout([(item("f1", "셋", folder: true), 1)])
        let missing = [XMLLibraryDiff.PlaylistChange(kind: .missing, path: ["셋", "새 폴더", "B"], libraryID: nil, xmlEntries: ["101", "102"],
                                                     libraryEntries: [], unmatchedEntries: 0),
                       XMLLibraryDiff.PlaylistChange(kind: .missing, path: ["새 목록"], libraryID: nil, xmlEntries: [],
                                                     libraryEntries: [], unmatchedEntries: 0)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: missing), selection: .all, sources: [:], layout: layout, playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        let draft = try #require(plan.playlistDraft)
        let projected = draft.project(onto: layout).layout
        let folder = try #require(projected.children(of: "f1").first)
        #expect(folder.name == "새 폴더" && folder.isFolder)
        let list = try #require(projected.children(of: folder.id).first)
        #expect(list.name == "B" && list.trackIDs == ["101", "102"])
        #expect(projected.children(of: PlaylistLayout.root).map(\.name).contains("새 목록"))
        #expect(plan.playlistLists == 2 && plan.losses.isEmpty)
    }

    @Test func 곡이_다른_목록은_XML_순서로_바꾼다() throws {
        let layout = PlaylistLayout([(item("p1", "A", tracks: ["101", "102", "103"]), 1)])
        let changed = [XMLLibraryDiff.PlaylistChange(kind: .changed, path: ["A"], libraryID: "p1", xmlEntries: ["102", "101"],
                                                     libraryEntries: ["101", "102", "103"], unmatchedEntries: 0)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: changed), selection: .all, sources: [:], layout: layout, playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        let draft = try #require(plan.playlistDraft)
        #expect(draft.project(onto: layout).layout.item("p1")?.trackIDs == ["102", "101"])
    }

    @Test func 못_맞춘_항목이_있는_목록은_바꾸지_않고_손실로_알린다() throws {
        // XML 목록의 곡 하나를 맞추지 못했다: 통째로 바꾸면 라이브러리의 그 곡 항목이 알림 없이 사라진다
        let layout = PlaylistLayout([(item("p1", "A", tracks: ["101", "102"]), 1)])
        let changed = [XMLLibraryDiff.PlaylistChange(kind: .changed, path: ["A"], libraryID: "p1", xmlEntries: ["102"],
                                                     libraryEntries: ["101", "102"], unmatchedEntries: 1)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: changed), selection: .all, sources: [:], layout: layout, playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        #expect(plan.playlistDraft == nil)
        #expect(plan.losses.count == 1 && plan.losses[0].reason.contains("1"))
    }

    @Test func 없는_목록은_만들되_못_맞춘_항목_수를_손실로_센다() throws {
        let missing = [XMLLibraryDiff.PlaylistChange(kind: .missing, path: ["새"], libraryID: nil, xmlEntries: ["101"],
                                                     libraryEntries: [], unmatchedEntries: 2)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: missing), selection: .all, sources: [:], layout: PlaylistLayout(),
                                        playlistDraft: PlaylistDraft(), newKey: { UUID().uuidString })
        #expect(plan.playlistLists == 1)
        #expect(plan.losses.count == 1 && plan.losses[0].kind == .playlist && plan.losses[0].reason.contains("2"))
    }

    @Test func 뒤에_곡만_더한_목록은_곡_넣기만_한다() throws {
        let layout = PlaylistLayout([(item("p1", "A", tracks: ["101", "102"]), 1)])
        let changed = [XMLLibraryDiff.PlaylistChange(kind: .changed, path: ["A"], libraryID: "p1", xmlEntries: ["101", "102", "103"],
                                                     libraryEntries: ["101", "102"], unmatchedEntries: 0)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: changed), selection: .all, sources: [:], layout: layout, playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        let draft = try #require(plan.playlistDraft)
        #expect(draft.steps.map(\.edit) == [.addTracks(playlist: .id("p1"), contentIDs: ["103"])])
        #expect(draft.project(onto: layout).layout.item("p1")?.trackIDs == ["101", "102", "103"])
    }

    @Test func 인텔리전트_목록과_경로가_같으면_그렇게_알린다() throws {
        let layout = PlaylistLayout([(PlaylistLayout.Item(id: "s1", name: "스마트", isSmart: true), 1)])
        let missing = [XMLLibraryDiff.PlaylistChange(kind: .missing, path: ["스마트"], libraryID: nil, xmlEntries: ["101"],
                                                     libraryEntries: [], unmatchedEntries: 0)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: missing), selection: .all, sources: [:], layout: layout, playlistDraft: PlaylistDraft(),
                                        newKey: { UUID().uuidString })
        #expect(plan.playlistDraft == nil)
        #expect((plan.losses + plan.skipped).map(\.reason) == [XMLImportDrafts.smartListReason])
    }

    @Test func 비교하지_않은_곡이_든_목록과_초안이_있는_목록은_건너뛴다() throws {
        // 스트리밍 곡(104)은 비교에 없으니 목록을 바꾸면 사라진다
        let layout = PlaylistLayout([(item("p1", "A", tracks: ["101", "104"]), 1), (item("p2", "B", tracks: ["101"]), 2)])
        var existing = PlaylistDraft()
        try existing.append(.rename(playlist: .id("p2"), name: "B2"), rekordbox: layout)
        let changes = [XMLLibraryDiff.PlaylistChange(kind: .changed, path: ["A"], libraryID: "p1", xmlEntries: [], libraryEntries: ["101"],
                                                     unmatchedEntries: 0),
                       XMLLibraryDiff.PlaylistChange(kind: .changed, path: ["B"], libraryID: "p2", xmlEntries: [], libraryEntries: ["101"],
                                                     unmatchedEntries: 0)]
        let plan = XMLImportDrafts.plan(diff: diff(playlists: changes), selection: .all, sources: [:], layout: layout, playlistDraft: existing,
                                        newKey: { UUID().uuidString })
        #expect(plan.playlistDraft == nil)
        #expect(plan.losses.map(\.kind) == [.playlist] && plan.skipped.map(\.kind) == [.playlist])
    }
}
