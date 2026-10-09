@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 막힌 초안이 여러 곡·종류·재생 목록에 섞인 합성 라이브러리(#232).
/// 초안의 기준(`base`)이 지금 rekordbox와 달라 모두 쓸 수 없는 상태다. 곡·초안 값은 고정이라 같은 시나리오를 둘 만들어 같은 선택의 결과를 견줄 수 있다.
/// 현재값은 합성 사본 DB·분석 파일에서 실제로 읽는다. 초안은 메모리(`recoveryMemoryInput`·`tagDrafts`)에 두고 저장 폴더는 `home`(저장소의 초안 폴더)이다.
@MainActor
struct RecoveryScenario {
    /// 줄 하나: 곡 이름("A"·"B"·"C")과 종류, 또는 재생 목록 ID
    enum Target: Hashable {
        case draft(String, DraftRecoveryKind)
        case playlist(String)
        var label: String {
            switch self {
            case let .draft(name, kind): "\(name).\(kind.label)"
            case let .playlist(id): "목록 \(id)"
            }
        }
    }

    let fixture: RekordboxFixture
    let store: LibraryStore
    private(set) var rows: [String: TrackRow] = [:]
    /// 곡 D의 그리드 초안(`withHalfAnalysedTrack`일 때). 기준은 지금 rekordbox와 같고 다른 이유로 쓰지 못한다.
    private(set) var halfAnalysedGrid: GridDraft?
    var home: URL { fixture.root }

    static func uuid(_ name: String) -> String { "recovery-\(name.lowercased())" }

    /// 곡 A·B·C와 목록 P1·P2의 초안 일곱 줄(A 태그·큐, B 태그·그리드, C 큐(대상 다시 지정 필요), 목록 둘)
    /// - Parameter withHalfAnalysedTrack: 분석 파일이 `.DAT`뿐인 곡 D를 더하고 기준이 지금과 같은 그리드 초안을 둔다.
    ///   rekordbox가 바뀌어서가 아니라 반쪽 분석이라 막히는 초안이다(`allTargets`에는 넣지 않는다).
    static func make(withHalfAnalysedTrack: Bool = false) async throws -> RecoveryScenario {
        let fixture = try RekordboxFixture()
        func spec(_ track: String, cues: [CueSpec] = []) -> TrackSpec {
            var spec = TrackSpec(id: "9\(["A": 1, "B": 2, "C": 3, "D": 4][track] ?? 0)", uuid: uuid(track))
            spec.title = "합성 곡 \(track)"
            spec.cues = cues
            return spec
        }
        let a = spec("A", cues: [CueSpec(id: "cue-a1", kind: 0, inMsec: 3000)])
        var b = spec("B")
        b.fileType = 11; b.length = 60
        b.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path
        b.analysisDataPath = "/PIONEER/USBANLZ/recovery-b/ANLZ0000.DAT"
        var newCueC = CueSpec(id: "cue-c-new", kind: 0, inMsec: 4250)
        newCueC.comment = "인트로"
        let c = spec("C", cues: [newCueC])
        try fixture.add(tracks: [a, b, c])
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(b.id)])
        let beats = AnlzBuilder.beats(bpm: 160, first: 200, count: 160)
        try fixture.putAnalysis(for: b, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        var halfGrid: GridDraft?
        if withHalfAnalysedTrack {
            var d = spec("D")
            d.fileType = 11; d.length = 60
            d.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio, name: "half.wav").path
            d.analysisDataPath = "/PIONEER/USBANLZ/recovery-d/ANLZ0000.DAT"
            try fixture.add(d)
            try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(d.id)])
            try fixture.putAnalysis(for: d, dat: AnlzBuilder.dat(beats: beats), ext: nil)
            var draft = GridDraft(trackUUID: d.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: d)))
            draft.shift(by: 0.01)
            halfGrid = draft
        }
        try fixture.add(playlists: [PlaylistSpec(id: "P1", name: "합성 목록 하나", seq: 1, contentIDs: [a.id, b.id]),
                                    PlaylistSpec(id: "P2", name: "합성 목록 둘", seq: 2, contentIDs: [c.id])])
        // 초안은 옛 rekordbox 상태를 기준으로 만들어 뒀고, 그 뒤 rekordbox에서 바뀐 것처럼 합성 사본이 다르다.
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("recovery"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root, rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                 arguments: ["test", "--db", fixture.database.path], environment: ["DJC_REKORDBOX_DIR": fixture.root.path])
        await store.load(snapshot: fixture.database)
        var scenario = RecoveryScenario(fixture: fixture, store: store)
        scenario.halfAnalysedGrid = halfGrid
        for track in withHalfAnalysedTrack ? ["A", "B", "C", "D"] : ["A", "B", "C"] {
            let row: TrackRow = try #require(store.rowsByUUID[uuid(track)])
            scenario.rows[track] = row
        }

        scenario.installDrafts()

        var drafts = PlaylistDraft()
        let layout = store.rekordboxPlaylists
        try drafts.append(.rename(playlist: .id("P1"), name: "내 이름 하나"), rekordbox: layout)
        try drafts.append(.rename(playlist: .id("P2"), name: "내 이름 둘"), rekordbox: layout)
        store.playlistDraft = drafts
        try fixture.execute("UPDATE djmdPlaylist SET Name = '외부 이름 하나' WHERE ID = 'P1'")
        try fixture.execute("UPDATE djmdPlaylist SET Name = '외부 이름 둘' WHERE ID = 'P2'")
        store.rekordboxPlaylists = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        store.refreshPlaylists()
        return scenario
    }

    /// 초안을 메모리에 올린다(메인 창을 띄우면 창이 덱의 초안으로 바꿔 두므로, 그 뒤에 다시 올릴 수 있다).
    func installDrafts() {
        var memory = Self.memoryDrafts()
        if let halfAnalysedGrid { memory[Self.uuid("D") + "/grid"] = .grid(halfAnalysedGrid) }
        store.recoveryMemoryInput = { uuid, kind in memory[uuid + "/" + String(describing: kind)] }
        for (track, draft) in Self.tagDrafts(rows: rows) { store.tagDrafts[Self.uuid(track)] = draft }
    }

    private static func memoryDrafts() -> [String: RecoveryDraft] {
        // A: 큐 시각을 rekordbox에서 옮겼고 내가 이름을 붙였다(내 편집을 그대로 다시 쌓을 수 있다)
        let oldA = EditableCue(sourceID: "cue-a1", kind: .memory, time: 2)
        var cueA = CueDraft(trackUUID: uuid("A"))
        cueA.base = [oldA]; cueA.cues = [oldA]; cueA.cues[0].name = "내 큐"
        // B: 그리드 BPM을 rekordbox에서 바꿨고 나는 첫 박 번호를 옮겼다
        let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
        var gridB = GridDraft(trackUUID: uuid("B"), base: base, segments: base)
        gridB.segments[0].firstBeatNumber = 3
        // C: 내가 고친 큐가 rekordbox에서 다시 만들어져 ID가 달라졌다(대상을 사람이 이어야 한다)
        let oldC = EditableCue(sourceID: "cue-c-old", kind: .memory, time: 4, name: "인트로")
        var cueC = CueDraft(trackUUID: uuid("C"))
        cueC.base = [oldC]; cueC.cues = [oldC]; cueC.cues[0].name = "내 큐 C"
        return [uuid("A") + "/cues": .cues(cueA), uuid("B") + "/grid": .grid(gridB), uuid("C") + "/cues": .cues(cueC)]
    }

    private static func tagDrafts(rows: [String: TrackRow]) -> [String: TagDraft] {
        // A: 제목이 rekordbox에서 바뀌었고 나는 코멘트를 적었다(칸이 겹치지 않는다)
        var baseA = TagFields(track: rows["A"]!.track); baseA.title = "옛 제목 A"
        var tagA = TagDraft(trackUUID: uuid("A"), base: baseA); tagA.fields.comment = "내 코멘트"
        // B: 장르가 rekordbox에서 바뀌었고 나는 아티스트를 고쳤다
        var baseB = TagFields(track: rows["B"]!.track); baseB.genre = "옛 장르"
        var tagB = TagDraft(trackUUID: uuid("B"), base: baseB); tagB.fields.artist = "내 아티스트"
        return ["A": tagA, "B": tagB]
    }

    /// 시나리오의 모든 줄(곡 순서대로 종류, 그다음 재생 목록)
    nonisolated static let allTargets: [Target] = [.draft("A", .tags), .draft("A", .cues), .draft("B", .tags), .draft("B", .grid),
                                       .draft("C", .cues), .playlist("P1"), .playlist("P2")]

    /// 쓰기 미리 보기가 읽는 초안 파일을 저장소의 초안 폴더(합성 사본 옆 `drafts`)에 남기고 쓰기 대기로 알린다. 끝나면 `removeDraftFiles()`로 지운다.
    func saveDraftFiles() throws {
        let places = store.draftLocations
        for (_, draft) in store.tagDrafts where draft.hasChanges { try TagDraftStore.save(draft, directory: store.tagDraftDirectory) }
        for track in ["A", "B", "C", "D"] {
            let uuid = Self.uuid(track)
            if case let .cues(draft)? = store.recoveryMemoryInput?(uuid, .cues) {
                try CueDraftStore.save(draft, directory: places.cue)
                store.draftChanged(trackUUID: uuid, kind: .cue, exists: true)
            }
            if case let .grid(draft)? = store.recoveryMemoryInput?(uuid, .grid) {
                try GridDraftStore.save(draft, directory: places.grid)
                store.draftChanged(trackUUID: uuid, kind: .grid, exists: true)
            }
        }
        store.testDrafts.flush()
    }

    func removeDraftFiles() {
        for track in ["A", "B", "C", "D"] {
            let uuid = Self.uuid(track)
            try? TagDraftStore.remove(trackUUID: uuid, directory: store.tagDraftDirectory)
            try? CueDraftStore.remove(trackUUID: uuid, directory: store.draftLocations.cue)
            try? FileManager.default.removeItem(at: store.draftLocations.grid.appending(path: "\(uuid).json"))
        }
        store.testDrafts.flush()
    }

    /// 큐 하나의 모양(`id`는 곡마다 새로 만들어져 견주지 않는다)
    struct CueShape: Equatable {
        struct Item: Equatable {
            var sourceID: String?
            var kind: EditableCue.Kind
            var time: Double
            var name: String
            var loop: EditableCue.Loop?
            init(_ cue: EditableCue) { sourceID = cue.sourceID; kind = cue.kind; time = cue.time; name = cue.name; loop = cue.loop }
        }
        var base: [Item]
        var cues: [Item]
        init(_ draft: CueDraft) { base = draft.base.map(Item.init); cues = draft.cues.map(Item.init) }
    }

    /// 저장된 초안과 재생 목록 초안(폴더에서 다시 읽은 것). 두 시나리오의 결과를 견주는 데 쓴다.
    struct Outcome: Equatable {
        var tags: [String: TagDraft]
        var cues: [String: CueShape]
        var grids: [String: GridDraft]
        var playlists: PlaylistDraft
    }

    /// 초안이 있는 곡만 담는다(없으면 키가 없다).
    /// 견줄 때 어느 부분이 다른지(시험 실패 메시지용)
    func differences(_ a: Outcome, _ b: Outcome) -> [String] {
        var result: [String] = []
        if a.tags != b.tags { result.append("태그 초안: \(a.tags.keys.sorted()) ↔ \(b.tags.keys.sorted())") }
        if a.cues != b.cues { result.append("큐 초안: \(a.cues.keys.sorted()) ↔ \(b.cues.keys.sorted())") }
        if a.grids != b.grids { result.append("그리드 초안: \(a.grids.keys.sorted()) ↔ \(b.grids.keys.sorted())") }
        if a.playlists != b.playlists { result.append("재생 목록 초안: \(a.playlists.steps.count) ↔ \(b.playlists.steps.count)") }
        return result
    }

    func outcome() -> Outcome {
        store.testDrafts.flush()
        var cues: [String: CueShape] = [:], grids: [String: GridDraft] = [:]
        for track in ["A", "B", "C"] {
            if let draft = CueDraftStore.load(trackUUID: Self.uuid(track), directory: home.appending(path: "cue-drafts")) { cues[track] = CueShape(draft) }
            if let draft = GridDraftStore.load(trackUUID: Self.uuid(track), directory: home.appending(path: "grid-drafts")) { grids[track] = draft }
        }
        // 같은 프로세스의 다른 시험이 시험 폴더에 남긴 태그 초안이 라이브러리를 읽을 때 섞일 수 있어, 이 시나리오의 곡만 견준다.
        let ours = Set(["A", "B", "C", "D"].map(Self.uuid))
        let tags = Dictionary(uniqueKeysWithValues: store.tagDrafts.filter { ours.contains($0.key) }.map { ($0.key, $0.value) })
        return Outcome(tags: tags, cues: cues, grids: grids, playlists: store.playlistDraft)
    }
}
