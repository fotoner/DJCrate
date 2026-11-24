@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 저장 뒤 ⌘Z(R12, #405)의 목록 몫: 태그(평점·곡 색 포함) 편집 → 자동 저장 → ⌘Z → 자동 저장 → DB 값이 편집 전과 같다.
/// 자동 저장은 엔진이 고르는 길(`autoInventory` → `chunk` → `autoWrite`)로 실제 관문이 합성 사본에 쓴다. `DJC_HOME`이 있을 때만 돈다.
@MainActor
@Suite("목록 저장 뒤 ⌘Z", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct LibraryUndoAfterSaveTests {
    @MainActor
    final class Rig {
        let fixture: RekordboxFixture
        let tracks: [TrackSpec]
        let store: LibraryStore
        let undo = UndoManager()
        var edits: [ReflectionUndoEdit] = []
        /// 켜면 쓴 뒤 다시 읽기(스냅샷 뜨기)가 실패한다
        let failingSnapshots = TestSwitch()

        /// - Parameter playlists: 맨 위에 둘 재생 목록(목록 ID는 정수 글자). `masterPlaylists6.xml`도 rekordbox 모양으로 둔다
        /// - Parameter before: 곡을 넣기 전에 사본에 할 일(이름 행 등)
        init(_ tracks: [TrackSpec], playlists: [PlaylistSpec] = [], before: ((RekordboxFixture) throws -> Void)? = nil) async throws {
            fixture = try RekordboxFixture()
            self.tracks = tracks
            try before?(fixture)
            try fixture.add(tracks: tracks)
            if !playlists.isEmpty {
                try fixture.add(playlists: playlists)
                let nodes = playlists.map { playlist in
                    let id = String(Int(playlist.id)!, radix: 16, uppercase: true)
                    let parent = playlist.parentID == "root" ? "0" : String(Int(playlist.parentID)!, radix: 16, uppercase: true)
                    return #"    <NODE Id="\#(id)" ParentId="\#(parent)" Attribute="\#(playlist.isFolder ? 1 : 0)" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#
                }
                let xml = ([#"<?xml version="1.0" encoding="UTF-8"?>"#, "", #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
                            #"  <PRODUCT Name="rekordbox" Version="7.2.18" Company="AlphaTheta"/>"#, "  <PLAYLISTS>"]
                           + nodes + ["  </PLAYLISTS>", "</MASTER_PLAYLIST>", ""]).joined(separator: "\r\n")
                try xml.write(to: fixture.root.appending(path: "masterPlaylists6.xml"), atomically: true, encoding: .utf8)
            }
            // 곡 색 표(rekordbox 기본 여덟 색)
            for (index, color) in TrackColor.rekordboxDefaults.enumerated() {
                try fixture.insert("djmdColor", ["ID": .text(color.id), "ColorCode": .null, "SortKey": .int(index + 1), "Commnt": .text(color.name),
                                                 "UUID": .text("c-\(color.id)"), "rb_data_status": .int(256), "rb_local_deleted": .int(0),
                                                 "rb_local_usn": .int(1_234)])
            }
            try fixture.execute("UPDATE djmdContent SET Rating = 0, ColorID = '0'")
            let database = fixture.database, failing = failingSnapshots
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("library-undo"), persist: false),
                                      activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      backupDirectory: fixture.backups, playlistDraftSaver: nil, mergeDraftSaver: { _ in },
                                      playlistImportURL: nil, stagingSaver: { _ in }, draftHome: fixture.root.appending(path: "drafts"),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:], takeLiveSnapshot: { _ in
                                          if failing.isOn { throw DJCError.writeRefused("합성 읽기 실패") }
                                          return database
                                      }, draftOrigin: .human)
            await store.load(snapshot: fixture.database)
            store.undoManager = undo
            store.onUndoAfterSave = { [weak self] in self?.edits.append($0) }
        }

        func row(_ track: TrackSpec) throws -> TrackRow { try #require(store.rowsByUUID[track.uuid]) }

        /// 사용자 동작 하나(앱에서는 이벤트가 끝나면 ⌘Z 묶음이 닫힌다): 한 시험 안의 두 동작이 한 묶음으로 합쳐지지 않게 따로 묶는다
        func event(_ body: () -> Void) {
            #expect(undo.groupingLevel == 0)
            let byEvent = undo.groupsByEvent
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
            undo.groupsByEvent = byEvent
        }

        /// 엔진이 고르는 길로 저장 대기를 자동으로 쓰고 다시 읽기까지 기다린다(`reloads`가 거짓이면 쓰기 잠금이 풀리기까지만)
        func autoSave(reloads: Bool = true) async throws {
            let session = store.session
            let inventory = await session.autoInventory(cancelled: [], needsConfirmation: [])
            let chunk = try #require(inventory.chunk(rowLimit: 200), "자동으로 쓸 편집이 없다: \(inventory)")
            guard case let .written(report, unwritten) = await session.autoWrite(chunk) else {
                Issue.record("자동 저장이 쓰지 못했다")
                return
            }
            #expect(unwritten.isEmpty && report.tagBlocked.isEmpty && report.playlistBlocked.isEmpty, "\(report.tagBlocked)")
            #expect(await waitForState(until: { !self.store.libraryBusy && self.store.lockedTracks.isEmpty && (!reloads || self.store.writtenAwaitingReload.isEmpty) }))
        }

        /// ⌘S로 고른 곡의 편집과 재생 목록 편집을 쓰고 다시 읽기까지 기다린다(확인 창은 시험 기본 답으로 확인한다)
        func save(_ rows: [TrackRow]) async throws {
            guard case .written = await store.session.write(rows: rows) else {
                Issue.record("⌘S가 쓰지 못했다")
                return
            }
            #expect(await waitForState(until: { !self.store.libraryBusy && self.store.lockedTracks.isEmpty && self.store.writtenAwaitingReload.isEmpty }))
        }

        /// 재생 목록 행(이름·차례·폴더)과 든 곡(곡·번호). ID·UUID·변경 번호·시각은 빼고 견준다
        func playlistValues() throws -> [[String: String]] {
            try fixture.rows("SELECT ID, Name, Seq, ParentID, Attribute FROM djmdPlaylist WHERE rb_local_deleted = 0 ORDER BY ParentID, Seq")
                + fixture.rows("SELECT PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist WHERE rb_local_deleted = 0 ORDER BY PlaylistID, TrackNo")
        }

        /// 곡 행의 태그 칸(제목·평점·곡 색·코멘트)
        func tagValues() throws -> [[String: String]] {
            try fixture.rows("SELECT ID, Title, Rating, ColorID, Commnt FROM djmdContent ORDER BY ID")
        }
    }

    @Test func 두_곡의_제목_평점_곡_색을_자동_저장_뒤_되돌리고_다시_저장하면_편집_전과_같다() async throws {
        let rig = try await Rig([TrackSpec(id: "500"), TrackSpec(id: "501")])
        let original = try rig.tagValues()
        let first = try rig.row(rig.tracks[0]), second = try rig.row(rig.tracks[1])
        rig.store.tags.applyTagEdits([(first, .title, "새 제목 1"), (second, .title, "새 제목 2"), (first, .rating, "4"), (second, .color, "3")])
        try await rig.autoSave()
        #expect(try rig.tagValues() != original)

        #expect(rig.undo.canUndo, "쓴 뒤 다시 읽어도 태그 ⌘Z가 남는다")
        rig.undo.undo()
        #expect(rig.store.tagDrafts.values.filter(\.hasChanges).count == 2)
        // 두 곡의 역편집은 한 번에 전부 쓰거나 전부 쓰지 않게 대기열에 든다
        #expect(rig.edits.count == 1 && rig.edits.first?.batch.commitPolicy == .allOrNothing && rig.edits.first?.rowCount == 2)
        try await rig.autoSave()
        #expect(try rig.tagValues() == original)
    }

    /// 아티스트도 쓰기 규칙에 걸리지 않으면 저장 뒤 되돌린다(S12): 편집 → 자동 저장 → ⌘Z → 자동 저장 → 곡의 아티스트 이름이 편집 전과 같다
    @Test func 아티스트_편집도_자동_저장_뒤_되돌리고_다시_저장하면_편집_전과_같다() async throws {
        var track = TrackSpec(id: "500")
        track.artistID = "11"
        let rig = try await Rig([track], before: { fixture in
            try fixture.insert("djmdArtist", ["ID": .text("11"), "Name": .text("원래 가수"), "UUID": .text("a-11"), "rb_local_deleted": .int(0),
                                              "rb_local_usn": .int(5)])
        })
        func artist() throws -> String? {
            try rig.fixture.rows("SELECT a.Name AS Name FROM djmdContent c LEFT JOIN djmdArtist a ON c.ArtistID = a.ID WHERE c.ID = '500'").first?["Name"]
        }
        let original = try artist()
        let row = try rig.row(rig.tracks[0])
        rig.store.tags.applyTagEdits([(row, .artist, "새 가수")])
        try await rig.autoSave()
        #expect(try artist() == "새 가수")
        #expect(rig.undo.canUndo)
        rig.undo.undo()
        try await rig.autoSave()
        #expect(try artist() == original)
    }

    // MARK: - 재생 목록(이름·순서·곡 넣기)

    static let tracks = [TrackSpec(id: "500"), TrackSpec(id: "501"), TrackSpec(id: "502")]
    static let playlists = [PlaylistSpec(id: "1001", name: "가", seq: 1, contentIDs: ["500"]),
                            PlaylistSpec(id: "1002", name: "나", seq: 2, contentIDs: ["500", "501", "502"]),
                            PlaylistSpec(id: "1003", name: "다", seq: 3)]

    enum PlaylistKind: CaseIterable { case rename, playlistOrder, trackOrder, addTracks }

    /// 편집 → 자동 저장 → ⌘Z → 자동 저장 → DB의 재생 목록이 편집 전과 같다(목록·곡 행 ID 제외)
    @Test(arguments: PlaylistKind.allCases)
    func 재생_목록_편집을_자동_저장_뒤_되돌리고_다시_저장하면_편집_전과_같다(_ kind: PlaylistKind) async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        let original = try rig.playlistValues()
        let playlists = rig.store.playlists
        switch kind {
        case .rename: playlists.renamePlaylist("1001", to: "새 이름")
        case .playlistOrder: playlists.movePlaylist("1003", into: PlaylistLayout.root, before: "1001")
        case .trackOrder: playlists.moveTracks(["502"], inPlaylist: "1002", before: "500")
        case .addTracks: playlists.addTracks([try rig.row(Self.tracks[1]), try rig.row(Self.tracks[2])], toPlaylist: "1001")
        }
        #expect(playlists.playlistDraft.steps.count >= 1)
        try await rig.autoSave()
        #expect(try rig.playlistValues() != original)
        #expect(playlists.playlistDraft.steps.isEmpty)

        #expect(rig.undo.canUndo, "쓴 뒤 다시 읽어도 재생 목록 ⌘Z가 남는다")
        rig.undo.undo()
        #expect(!playlists.playlistDraft.steps.isEmpty, "역편집 단계를 쌓는다")
        try await rig.autoSave()
        #expect(try rig.playlistValues() == original)
    }

    /// 새로 만든 목록은 쓰기 결과의 연결 ID로 찾는다. 만들기 자체는 되돌리지 않아(지우기는 범위 밖) 그 ⌘Z는 꺼진다
    @Test func 새로_만든_목록에_넣은_곡은_되돌리고_만들기는_실행_취소가_꺼진다() async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        let playlists = rig.store.playlists
        let created = try #require(playlists.createPlaylist(isFolder: false, name: "새 목록"))
        playlists.addTracks([try rig.row(Self.tracks[1])], toPlaylist: created)
        try await rig.autoSave()
        let made = try #require(rig.fixture.rows("SELECT ID FROM djmdPlaylist WHERE Name = '새 목록'").first?["ID"])
        #expect(try rig.fixture.rows("SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = ?", [.text(made)]).map { $0["ContentID"] } == ["501"])

        rig.undo.undo()
        try await rig.autoSave()
        #expect(try rig.fixture.rows("SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = ?", [.text(made)]).isEmpty)
        #expect(!rig.undo.canUndo, "목록 만들기는 저장 뒤 되돌리지 않는다")
    }

    // MARK: - ⌘Z 단계 판정(컨실 2라운드 A): 맨 위 단계만 판정하고 아래 단계는 차례가 왔을 때 판정한다

    /// 같은 칸을 두 번 고친 뒤 저장하면 ⌘Z 두 번이 차례대로 되돌린다(아래 단계를 저장 뒤 값으로 미리 판정해 빼지 않는다, O7·G11)
    @Test func 평점을_두_번_고치고_저장하면_실행_취소_두_번이_차례대로_되돌린다() async throws {
        let rig = try await Rig([TrackSpec(id: "500")])
        let original = try rig.tagValues()
        let row = try rig.row(rig.tracks[0])
        rig.store.tags.applyTagEdits([(row, .rating, "3")])
        rig.store.tags.applyTagEdits([(row, .rating, "5")])
        try await rig.autoSave()
        #expect(try rig.tagValues().first?["Rating"] == "5")
        let uuid = rig.tracks[0].uuid
        rig.undo.undo()
        #expect(rig.store.tagDrafts[uuid]?.fields.rating == "3")
        #expect(rig.undo.canUndo, "아래 단계(0 → 3)가 남는다")
        rig.undo.undo()
        #expect(rig.store.tagDrafts[uuid]?.fields.rating == "", "평점 없음(편집 전)")
        try await rig.autoSave()
        #expect(try rig.tagValues() == original)
    }

    @Test func 재생_목록_이름을_두_번_바꾸고_저장하면_실행_취소_두_번이_차례대로_되돌린다() async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        let original = try rig.playlistValues()
        let playlists = rig.store.playlists
        // 두 번의 이름 바꾸기는 따로 일어난 사용자 동작이다(앱에서는 이벤트마다 묶음이 닫힌다)
        rig.event { playlists.renamePlaylist("1001", to: "첫 이름") }
        rig.event { playlists.renamePlaylist("1001", to: "둘째 이름") }
        try await rig.autoSave()
        rig.undo.undo()
        #expect(rig.undo.canUndo, "아래 단계(가 → 첫 이름)가 남는다")
        rig.undo.undo()
        try await rig.autoSave()
        #expect(try rig.playlistValues() == original)
    }

    /// 같은 목록을 같은 자리로 다시 옮겨 같은 순서 편집이 쌓여도 그 단계가 더한 편집으로 옮긴 목록을 찾는다(컨실 4라운드 G·G23):
    /// [A,B]에서 B를 앞·뒤·다시 앞 → 저장 → ⌘Z가 A가 아니라 B를 옮긴다
    @Test func 같은_목록을_다시_옮겨도_실행_취소는_그_목록을_옮긴다() async throws {
        let rig = try await Rig(Self.tracks, playlists: [PlaylistSpec(id: "1001", name: "가", seq: 1), PlaylistSpec(id: "1002", name: "나", seq: 2)])
        let playlists = rig.store.playlists
        rig.event { playlists.movePlaylist("1002", into: PlaylistLayout.root, before: "1001") }
        rig.event { playlists.movePlaylist("1002", into: PlaylistLayout.root) }
        rig.event { playlists.movePlaylist("1002", into: PlaylistLayout.root, before: "1001") }
        try await rig.autoSave()
        rig.undo.undo()
        #expect(playlists.playlistDraft.edits.last == .reorder(playlist: .id("1002"), index: 1))
    }

    enum StuckKind: CaseIterable { case create, delete }

    /// 저장 뒤 되돌릴 수 없는 단계(목록 만들기·지우기)가 맨 위면 ⌘Z가 꺼지고 그 아래 다른 편집(태그)을 실행하지 않는다(S13·O8·G10)
    @Test(arguments: StuckKind.allCases)
    func 되돌릴_수_없는_맨_위_단계면_실행_취소가_꺼지고_아래_단계를_실행하지_않는다(_ kind: StuckKind) async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        let row = try rig.row(Self.tracks[0])
        rig.store.tags.applyTagEdits([(row, .title, "새 제목")])
        let playlists = rig.store.playlists
        switch kind {
        case .create: _ = try #require(playlists.createPlaylist(isFolder: false, name: "새 목록"))
        case .delete: playlists.deletePlaylist("1003")
        }
        // 목록 지우기는 자동 저장 범위 밖이라 ⌘S로 함께 쓴다
        try await rig.save([row])
        #expect(try rig.playlistValues().contains { $0["Name"] == "새 목록" } == (kind == .create))
        #expect(!rig.undo.canUndo, "맨 위가 되돌릴 수 없으면 메뉴가 꺼진다")
        if rig.undo.canUndo { rig.undo.undo() }
        #expect(rig.store.tagDrafts[Self.tracks[0].uuid]?.hasChanges != true, "아래 태그 단계를 실행하지 않는다")
        #expect(try rig.tagValues().first { $0["ID"] == "500" }?["Title"] == "새 제목")
    }

    /// 여러 곡 태그 단계는 쓴 곡 하나라도 역편집을 만들 수 없으면(바깥에서 바뀜) 단계 전체를 끈다: 남은 곡만 되돌려 따로 쓰지 않는다(컨실 2라운드 E·S16·G14)
    @Test func 여러_곡_태그_단계는_한_곡이라도_되돌릴_수_없으면_실행_취소가_꺼진다() async throws {
        let rig = try await Rig([TrackSpec(id: "500"), TrackSpec(id: "501"), TrackSpec(id: "502")])
        let first = try rig.row(rig.tracks[0]), second = try rig.row(rig.tracks[1])
        rig.store.tags.applyTagEdits([(first, .title, "새 제목 1"), (second, .title, "새 제목 2")])
        try await rig.autoSave()
        // rekordbox에서 501을 바꿨고, 다른 곡을 저장한 뒤 다시 읽기(⌘Z를 남기는 읽기)가 그 변경을 읽는다
        try rig.fixture.execute("UPDATE djmdContent SET Title = '바깥 제목' WHERE ID = '501'")
        rig.store.tags.applyTagEdits([(try rig.row(rig.tracks[2]), .title, "새 제목 3")])
        try await rig.autoSave()
        rig.undo.undo()
        #expect(!rig.undo.canUndo, "두 곡 단계가 맨 위가 되면 판정해 메뉴를 끈다")
        if rig.undo.canUndo { rig.undo.undo() }
        #expect(rig.store.tagDrafts[rig.tracks[0].uuid]?.hasChanges != true, "한 곡만 되돌리지 않는다")
    }

    /// 두 곡 태그를 쓴 뒤 다시 읽기 전에 바깥(CLI)이 한 곡에 새 초안을 저장해도 그 곡은 "쓴 곡"으로 센다: 그 곡의 역편집을 만들 수 없으니
    /// 단계 전체를 끈다(남은 곡만 되돌리지 않는다, 컨실 3라운드 E)
    @Test func 쓴_뒤_바깥이_새_초안을_둔_곡도_쓴_곡으로_세어_단계_전체를_끈다() async throws {
        let rig = try await Rig([TrackSpec(id: "500"), TrackSpec(id: "501")])
        let first = try rig.row(rig.tracks[0]), second = try rig.row(rig.tracks[1])
        rig.store.tags.applyTagEdits([(first, .title, "새 제목 1"), (second, .title, "새 제목 2")])
        rig.failingSnapshots.set(true)
        try await rig.autoSave(reloads: false)
        let cli = DraftStore.live(writer: DraftWriter(), home: rig.fixture.root.appending(path: "drafts"), origin: .cli)
        var outside = rig.store.tags.tagDraft(for: second)
        outside.fields.comment = "바깥 코멘트"
        cli.saveTags([outside])
        cli.flush()
        rig.failingSnapshots.set(false)
        await rig.store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(!rig.undo.canUndo, "한 곡만 되돌리지 않는다")
        if rig.undo.canUndo { rig.undo.undo() }
        #expect(rig.store.tagDrafts[rig.tracks[0].uuid]?.hasChanges != true)
    }

    /// 재생 목록을 쓴 뒤 다시 읽기를 기다리는 동안 누른 ⌘Z는 옛 목록 위에서 실행해 버리지 않고 미뤘다가, 새 목록을 읽은 뒤 실행한다(컨실 2라운드 F·S14·G12)
    @Test func 재생_목록을_쓴_뒤_다시_읽기를_기다리는_동안_누른_실행_취소는_읽은_뒤_실행한다() async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        let original = try rig.playlistValues()
        let playlists = rig.store.playlists
        playlists.renamePlaylist("1001", to: "새 이름")
        rig.failingSnapshots.set(true)
        try await rig.autoSave(reloads: false)
        #expect(rig.store.draftWriteReadPending)
        rig.undo.undo()
        #expect(playlists.playlistDraft.steps.isEmpty, "옛 목록 위에서 실행하지 않는다")
        rig.failingSnapshots.set(false)
        await rig.store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(!playlists.playlistDraft.steps.isEmpty, "새 목록을 읽은 뒤 실행한다")
        try await rig.autoSave()
        #expect(try rig.playlistValues() == original)
    }

    /// 쓴 뒤 rekordbox에서 그 목록을 바꿨으면 그 편집을 거꾸로 할 모양이 아니다: ⌘Z가 꺼진다
    @Test func 쓴_뒤_바깥에서_바뀐_목록의_실행_취소는_꺼진다() async throws {
        let rig = try await Rig(Self.tracks, playlists: Self.playlists)
        rig.store.playlists.renamePlaylist("1001", to: "새 이름")
        try await rig.autoSave()
        #expect(rig.undo.canUndo)
        try rig.fixture.execute("UPDATE djmdPlaylist SET Name = '바깥 이름' WHERE ID = '1001'")
        await rig.store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(rig.store.playlists.rekordboxPlaylists.item("1001")?.name == "바깥 이름")
        #expect(!rig.undo.canUndo)
    }
    /// 그 곡을 쓰는 동안 누른 태그 ⌘Z는 누른 요청으로 두었다가 잠금이 풀리면 실행한다(그 단계를 버리지 않는다, 컨실 S6)
    @Test func 쓰는_동안_누른_태그_실행_취소는_잠금이_풀리면_실행한다() async throws {
        let rig = try await Rig([TrackSpec(id: "500")])
        let row = try rig.row(rig.tracks[0])
        rig.store.tags.applyTagEdits([(row, .title, "첫 편집")])
        rig.store.tags.applyTagEdits([(row, .title, "둘째 편집")])
        rig.store.setLockedTracks([row.track.uuid])
        rig.undo.undo()
        #expect(rig.store.tagDrafts[row.track.uuid]?.fields.title == "둘째 편집", "쓰는 동안에는 되돌리지 않는다")
        rig.store.setLockedTracks([])
        #expect(rig.store.tagDrafts[row.track.uuid]?.fields.title == "첫 편집", "풀리면 누른 요청을 실행한다")
        #expect(rig.undo.canUndo)
        rig.undo.undo()
        #expect(rig.store.tagDrafts[row.track.uuid]?.hasChanges != true)
    }
    // MARK: - 미룬 ⌘Z(컨실 S5·G4, S6·O3)

    /// 쓴 뒤 다시 읽기가 실패해 새 rekordbox 값을 아직 모르는 곡의 ⌘Z는 미뤘다가, 다시 읽은 뒤 역편집으로 실행한다(단계를 버리지 않는다)
    @Test func 쓴_뒤_다시_읽기를_기다리는_곡의_태그_실행_취소는_읽은_뒤_역편집으로_실행한다() async throws {
        let rig = try await Rig([TrackSpec(id: "500")])
        let row = try rig.row(rig.tracks[0]), uuid = row.track.uuid
        let original = try rig.tagValues()
        rig.store.tags.applyTagEdits([(row, .title, "새 제목")])
        rig.failingSnapshots.set(true)
        try await rig.autoSave(reloads: false)
        #expect(rig.store.writtenAwaitingReload.contains(uuid))
        rig.undo.undo()
        #expect(rig.store.tagDrafts[uuid]?.hasChanges != true, "새 rekordbox 값을 모르는 동안은 되돌리지 않는다")
        rig.failingSnapshots.set(false)
        await rig.store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(rig.store.tagDrafts[uuid]?.fields.title == "시험 곡")
        #expect(rig.store.tagDrafts[uuid]?.hasChanges == true, "읽은 뒤 미룬 ⌘Z가 역편집을 만든다")
        try await rig.autoSave()
        #expect(try rig.tagValues() == original)
    }

    /// 잠긴 동안 누른 ⌘Z는 풀린 뒤 그 요청대로 실행되고, 그사이 다른 곡에서 한 편집의 실행 취소 차례를 바꾸지 않는다
    @Test func 잠긴_동안_누른_실행_취소는_그사이_새_편집보다_위로_올라오지_않는다() async throws {
        let rig = try await Rig([TrackSpec(id: "500"), TrackSpec(id: "501")])
        let first = try rig.row(rig.tracks[0]), second = try rig.row(rig.tracks[1])
        rig.store.tags.applyTagEdits([(first, .title, "A 편집")])
        rig.store.setLockedTracks([first.track.uuid])
        rig.undo.undo()
        #expect(rig.store.tagDrafts[first.track.uuid]?.fields.title == "A 편집", "잠긴 동안은 되돌리지 않는다")
        rig.store.tags.applyTagEdits([(second, .title, "B 편집")])
        rig.store.setLockedTracks([])
        #expect(rig.store.tagDrafts[first.track.uuid]?.hasChanges != true, "풀린 뒤 누른 요청대로 A를 되돌린다")
        #expect(rig.undo.canUndo)
        rig.undo.undo()
        #expect(rig.store.tagDrafts[second.track.uuid]?.hasChanges != true, "다음 ⌘Z는 그사이 한 B 편집을 되돌린다")
        #expect(!rig.undo.canUndo)
    }
}
