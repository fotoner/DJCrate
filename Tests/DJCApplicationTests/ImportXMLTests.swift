import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// rekordbox XML 가져오기(유스케이스). 앱의 "rekordbox XML 가져오기…"와 CLI `xml-diff --draft`가 같은 규칙을 쓰는지,
/// 기존 초안을 덮지 않는지를 암호화 DB·파일 없이(메모리 라이브러리·메모리 초안 파일) 본다.
@Suite("rekordbox XML 가져오기")
struct ImportXMLTests {
    static let snapshot = URL(filePath: "/fake/master.db")

    static func track(_ id: String, title: String) -> Track {
        Track(id: id, uuid: "u\(id)", title: title, artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 128, lengthSeconds: 180, folderPath: "/music/\(id).mp3",
              comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    /// 곡 셋(1·2·3)의 제목이 XML에서 바뀌고, XML에만 있는 재생 목록 하나
    static func comparison() -> XMLImportComparison {
        let ids = ["1", "2", "3"]
        let library = XMLLibrary(tracks: ids.map { XMLLibrary.Track(key: $0, path: "/music/\($0).mp3", tags: [.title: "곡 \($0)"]) })
        let xml = XMLLibrary(tracks: ids.map { XMLLibrary.Track(key: "x\($0)", path: "/music/\($0).mp3", tags: [.title: "새 제목 \($0)"]) },
                             lists: [XMLLibrary.Node(name: "가져온 목록", entries: ["x1"])])
        return XMLImportComparison(snapshot: snapshot, share: nil, xml: xml, library: library,
                                   diff: XMLLibraryDiff.compute(xml: xml, library: library))
    }

    static func importer(files: MemoryDraftFiles, drafts: DraftStore = MemoryDrafts().store) -> ImportXML {
        let library = RekordboxLibrary(allTracks: ["1", "2", "3"].map { track($0, title: "곡 \($0)") }, cues: [], playCounts: [:])
        let counter = Mutex(0)
        return ImportXML(files: .unused, source: .memory([snapshot: library]), drafts: drafts, draftFiles: files.files,
                         newKey: { counter.withLock { $0 += 1; return "key-\($0)" } })
    }

    @Test func 고른_태그_차이를_초안으로_만들고_재생_목록_초안을_저장한다() throws {
        let files = MemoryDraftFiles()
        let result = try Self.importer(files: files).makeDraftsNow(Self.comparison(), selection: .all)
        #expect(result.tags == 3 && result.playlists == 1 && result.skipped.isEmpty)
        #expect(files.tag("u1")?.fields.title == "새 제목 1")
        #expect(!files.playlist.isEmpty)
    }

    @Test func 초안_파일과_저장_대기_입력과_부른_쪽의_초안이_있는_곡은_덮지_않는다() throws {
        let files = MemoryDraftFiles()
        files.put(TagDraft(trackUUID: "u1", base: TagFields()))
        let importer = Self.importer(files: files)
        // CLI: 초안 파일만 본다
        let cli = try importer.makeDraftsNow(Self.comparison(), selection: XMLImportDrafts.Selection(kinds: [.tag]))
        #expect(cli.tags == 2 && cli.skipped.map(\.subject) == ["곡 1"])
        #expect(files.tag("u1")?.fields.title == "", "있던 초안을 덮지 않는다")
        // 앱: 메모리 태그 초안이 있는 곡도 건너뛴다(계획이 파일과 같은 규칙으로 본다)
        let plan = try importer.plan(Self.comparison(), selection: XMLImportDrafts.Selection(kinds: [.tag]), playlistDraft: PlaylistDraft(),
                                     existing: [.tag: ["u2"]])
        #expect(plan.skipped.map(\.subject).sorted() == ["곡 1", "곡 2", "곡 3"])
    }

    @Test func 계획한_뒤_저장_직전에_생긴_초안은_곡_이름으로_알리고_건너뛴다() throws {
        let files = MemoryDraftFiles()
        let importer = Self.importer(files: files)
        var plan = XMLImportDrafts.Plan()
        plan.gridDrafts = [GridDraft(trackUUID: "uuid-9", base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])]
        plan.titles = ["uuid-9": "곡 이름"]
        files.put(plan.gridDrafts[0])
        let result = try importer.save(plan)
        #expect(result.raced.map(\.subject) == ["곡 이름"] && result.saved[.grid, default: 0] == 0)
    }

    @Test func 계획하는_동안_재생_목록_초안이_바뀌면_덮지_않고_알린다() throws {
        let files = MemoryDraftFiles()
        var changed = PlaylistDraft()
        try changed.append(.create(key: "other", name: "다른 목록", isFolder: false, parent: PlaylistRef(PlaylistLayout.root)),
                           rekordbox: PlaylistLayout())
        // 계획할 때는 빈 초안, 저장하기 직전에는 바뀐 초안
        files.queuePlaylistReads([PlaylistDraft(), changed])
        let result = try Self.importer(files: files).makeDraftsNow(Self.comparison(), selection: .all)
        #expect(result.playlists == 0)
        #expect(result.skipped.last?.kind == .playlist)
        #expect(files.playlist.isEmpty, "바뀐 초안을 덮지 않는다")
    }

    @MainActor
    @Test func 앱과_CLI는_같은_입력에_같은_초안을_만든다() async throws {
        let cliFiles = MemoryDraftFiles(), appFiles = MemoryDraftFiles()
        let cli = try Self.importer(files: cliFiles).makeDraftsNow(Self.comparison(), selection: .all)
        var memory = PlaylistDraft()
        let app = try await Self.importer(files: appFiles).makeDrafts(Self.comparison(), selection: .all, context: ImportXML.Context(
            playlists: ImportXML.PlaylistTarget(current: { memory }, save: { memory = $0 })))
        #expect(cli == app)
        #expect(cliFiles.tag("u2") == appFiles.tag("u2"))
        #expect(cliFiles.playlist == memory)
    }

    @MainActor
    @Test func 저장_대기_입력이_있는_곡의_큐_그리드는_앱도_CLI도_건너뛴다() async throws {
        let drafts = MemoryDrafts()
        var store = drafts.store
        store.unsavedUUIDs = { ["u3"] }
        let files = MemoryDraftFiles()
        let importer = Self.importer(files: files, drafts: store)
        let plan = try importer.plan(Self.comparison(), selection: .all, playlistDraft: PlaylistDraft())
        #expect(plan.skipped.isEmpty, "계획만으로는 저장 대기를 모른다(부르는 입구가 더한다)")
        var memory = PlaylistDraft()
        let app = try await importer.makeDrafts(Self.comparison(), selection: .all, context: ImportXML.Context(
            playlists: ImportXML.PlaylistTarget(current: { memory }, save: { memory = $0 })))
        // 태그는 저장 대기 대상이 아니라 그대로 만든다(큐·그리드만 저장 큐를 거친다)
        #expect(app.tags == 3)
    }

    /// 그리드 차이가 있는 곡 하나(분석 파일 그리드 120 BPM, XML은 첫 박만 옮김)
    static func gridImport(files: MemoryDraftFiles) -> (ImportXML, XMLImportComparison) {
        let segment = GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)
        let library = XMLLibrary(tracks: [XMLLibrary.Track(key: "1", path: "/music/1.mp3", tempos: [segment])])
        let xml = XMLLibrary(tracks: [XMLLibrary.Track(key: "x1", path: "/music/1.mp3", tempos: [GridSegment(start: 0.6, bpm: 120, firstBeatNumber: 1)])])
        let comparison = XMLImportComparison(snapshot: snapshot, share: URL(filePath: "/fake/share"), xml: xml, library: library,
                                             diff: XMLLibraryDiff.compute(xml: xml, library: library))
        let grid = BeatGrid(beats: (0..<340).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
        var track = Self.track("1", title: "곡 1")
        track = Track(id: track.id, uuid: track.uuid, title: track.title, artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                      releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: track.folderPath, comment: "",
                      importedOn: nil, analysisDataPath: "/A.DAT", imagePath: nil, isDeleted: false)
        let source = RekordboxLibrary(allTracks: [track], cues: [], playCounts: [:])
        return (ImportXML(files: .unused, source: .memory([snapshot: source], grids: ["/A.DAT": grid]), drafts: MemoryDrafts().store,
                          draftFiles: files.files, newKey: { "k" }), comparison)
    }

    @MainActor
    @Test func 덱에_올린_곡의_그리드는_덱이_받고_덱에서_고쳤으면_건너뛴다() async throws {
        var memory = PlaylistDraft()
        let playlists = ImportXML.PlaylistTarget(current: { memory }, save: { memory = $0 })
        // 덱이 같은 곡을 들고 고치지 않았으면 덱이 받는다(파일로 쓰지 않는다)
        let files = MemoryDraftFiles()
        let (importer, comparison) = Self.gridImport(files: files)
        var adopted: [GridDraft] = []
        let taken = try await importer.makeDrafts(comparison, selection: XMLImportDrafts.Selection(kinds: [.grid]), context: ImportXML.Context(
            playlists: playlists, deck: ImportXML.DeckGrid(state: { ("u1", false) }, adopt: { adopted.append($0); return true })))
        #expect(taken.grids == 1 && adopted.map(\.trackUUID) == ["u1"] && files.grid("u1") == nil)
        // 덱에서 고쳤으면 계획부터 건너뛴다
        let edited = try await importer.makeDrafts(comparison, selection: XMLImportDrafts.Selection(kinds: [.grid]), context: ImportXML.Context(
            playlists: playlists, deck: ImportXML.DeckGrid(state: { ("u1", true) }, adopt: { _ in true })))
        #expect(edited.grids == 0 && edited.skipped.map(\.kind) == [.grid])
        // 덱에 다른 곡이 있으면 파일로 쓴다
        let other = try await importer.makeDrafts(comparison, selection: XMLImportDrafts.Selection(kinds: [.grid]), context: ImportXML.Context(
            playlists: playlists, deck: ImportXML.DeckGrid(state: { ("u9", false) }, adopt: { _ in true })))
        #expect(other.grids == 1 && files.grid("u1") != nil)
    }
}

extension XMLFiles {
    /// 쓰지 않는 자리(가져오기 계획·저장 시험은 XML 파일을 열지 않는다)
    static var unused: XMLFiles {
        XMLFiles(read: { _ in throw XMLReadError(reason: "unused") }, library: { _, _, _ in throw XMLReadError(reason: "unused") },
                 checkOutput: { _ in }, exportLibrary: { _, _, _, _ in LibraryXMLSummary() }, item: { _ in .none },
                 reflectionPlan: { track, _, _, _ in
                     ReflectionXMLPlan(trackID: track.id, uuid: track.uuid, path: track.folderPath, title: track.title, marks: [], tempos: nil,
                                       blockers: [], cueChanged: false, gridChanged: false, before: ReflectionXMLMetadata(track), beforeMarks: [])
                 },
                 verifyReflection: { _, _, _, _ in ReflectionXMLCheck(result: .notYet, problems: []) },
                 writeReflection: { _, _, _ in }, writeStaged: { _, _, _ in })
    }
}
