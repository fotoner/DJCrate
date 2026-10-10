@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 실험실 '인텔리전트 재생 목록 보기'(#68): 끄면(기본) 지금 dev와 같고, 켜면 조건을 계산한 곡을 읽기 전용으로 보인다.
/// 라이브러리는 모두 합성 행이다. rekordbox와 곡 수를 견주지 않았다(묶음 3 M1).
@MainActor
@Suite("인텔리전트 재생 목록 보기(앱)", .serialized)
struct SmartPlaylistAppTests {
    static func condition(_ property: String, _ op: Int, _ left: String, _ right: String = "") -> String {
        "<CONDITION PropertyName=\"\(property)\" Operator=\"\(op)\" ValueUnit=\"\" ValueLeft=\"\(left)\" ValueRight=\"\(right)\"/>"
    }

    static func smartList(_ conditions: String...) -> String {
        "<NODE Id=\"-1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\">" + conditions.joined() + "</NODE>"
    }

    /// 곡 1~6(연도 2014·2015·2016·2020·2021·없음).
    /// 폴더 F[일반 P(1,2) · 인텔리전트 S1(제목에 '합성'이고 연도 2015~2020 → 2,3,4) · S2(별점 조건: 계산 안 함) · S3(조건 칸이 빔)]
    static func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        for (id, year) in [("1", 2014), ("2", 2015), ("3", 2016), ("4", 2020), ("5", 2021), ("6", 0)] {
            var track = TrackSpec(id: id, uuid: "smart-\(id)")
            track.title = "합성 \(id)"
            track.folderPath = "/synthetic/\(id).mp3"
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET ReleaseYear = ? WHERE ID = ?", [.int(year), .text(id)])
        }
        try fixture.addPlaylist(id: "F", name: "폴더", seq: 1, attribute: 1)
        try fixture.addPlaylist(id: "P", name: "일반", parentID: "F", seq: 1, contentIDs: ["1", "2"])
        try fixture.addPlaylist(id: "S1", name: "연도 목록", parentID: "F", seq: 2, attribute: 4,
                                smartList: smartList(condition("name", 8, "합성"), condition("year", 5, "2015", "2020")))
        try fixture.addPlaylist(id: "S2", name: "별점 목록", parentID: "F", seq: 3, attribute: 4, smartList: smartList(condition("rating", 3, "3")))
        try fixture.addPlaylist(id: "S3", name: "빈 조건", parentID: "F", seq: 4, attribute: 4)
        return fixture
    }

    static func makeStore(_ fixture: RekordboxFixture, lab: Bool? = nil, persist: Bool = false, defaults: UserDefaults? = nil) async -> LibraryStore {
        let defaults = defaults ?? TestDefaults.make("smart-playlists")
        let settings = SettingsStore(defaults: defaults, persist: persist)
        if persist, let lab { defaults.set(lab, forKey: SettingKeys.labSmartPlaylists.name) }
        let store = LibraryStore.test(settings: settings, resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxDatabase: fixture.database,
                                 rekordboxShareRoot: fixture.shareRoot, arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database] _ in database })
        await store.load(snapshot: fixture.database)
        if !persist, lab == true { store.showSmartPlaylists = true }
        return store
    }

    static func ids(_ store: LibraryStore) -> [String] { store.displayRows.map(\.track.id).sorted() }

    // MARK: 끔(기본): 지금 dev와 같다

    @Test func 기본은_꺼져_있고_인텔리전트_목록은_빈_채로_보인다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture)
        #expect(!store.showSmartPlaylists)
        #expect(store.smartPlaylistResults.isEmpty)
        for id in ["S1", "S2", "S3"] {
            let node = try #require(store.playlistIndex[id])
            #expect(node.isSmart && node.trackIDs.isEmpty && store.playlistCounts[id] == 0, "\(id)")
        }
        store.sidebar = .playlist("S1")
        #expect(store.displayRows.isEmpty)
        // 일반 목록·폴더는 그대로
        #expect(store.playlistIndex["P"]?.trackIDs == ["1", "2"] && store.playlistCounts["P"] == 2)
        #expect(store.playlistIndex["F"]?.trackIDs == ["1", "2"])
    }

    @Test func 꺼져_있으면_인텔리전트_목록을_고쳐_보려_해도_조용하다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture)
        #expect(!store.blockSmartPlaylistEdit("S1"))
        #expect(store.playlistMessage == nil)
    }

    // MARK: 켬
    // 조건 계산(제목 포함·연도 범위 2015~2020 → 2,3,4)은 DJCDomainTests `SmartPlaylistEvaluatorTests`가 본다.
    // 켠 저장소가 계산한 곡을 목록·곡 수·보기에 넣는 연결은 아래 설정 바꾸기·스트리밍·저장 유지 시험이 본다.

    @Test func 켜도_계산하지_못하는_목록은_곡을_보이지_않고_이유를_든다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, lab: true)
        for id in ["S2", "S3"] {
            #expect(store.playlistIndex[id]?.trackIDs.isEmpty == true && store.playlistCounts[id] == 0, "\(id)")
            #expect(store.smartPlaylistResults[id]?.unsupportedReasons.isEmpty == false, "\(id)")
        }
        store.sidebar = .playlist("S2")
        #expect(store.displayRows.isEmpty)
    }

    @Test func 켜도_일반_목록과_폴더는_그대로고_껐다_켜면_처음_모양으로_돌아온다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture)
        let off = store.playlistTree, offCounts = store.playlistCounts
        store.showSmartPlaylists = true
        #expect(store.playlistTree != off)
        let folder = try #require(store.playlistIndex["F"])
        #expect(folder.trackIDs == ["1", "2"], "폴더 곡 모음에는 인텔리전트 목록 곡을 넣지 않는다")
        #expect(store.playlistIndex["P"]?.trackIDs == ["1", "2"])
        store.showSmartPlaylists = false
        #expect(store.playlistTree == off && store.playlistCounts == offCounts)
        #expect(store.smartPlaylistResults.isEmpty)
    }

    @Test func 목록을_보는_중에_설정을_바꾸면_곧바로_곡이_바뀐다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture)
        store.sidebar = .playlist("S1")
        #expect(store.displayRows.isEmpty)
        store.showSmartPlaylists = true
        #expect(Self.ids(store) == ["2", "3", "4"])
        store.showSmartPlaylists = false
        #expect(store.displayRows.isEmpty)
    }

    @Test func 켜도_스트리밍_곡_숨기기와_곡_수는_같은_규칙을_따른다() async throws {
        let fixture = try Self.fixture()
        try fixture.execute("UPDATE djmdContent SET FolderPath = 'spotify:track:abc' WHERE ID = '3'")
        let store = await Self.makeStore(fixture, lab: true)
        #expect(store.playlistCounts["S1"] == 3)
        store.hideStreaming = true
        #expect(store.playlistCounts["S1"] == 2)
        store.sidebar = .playlist("S1")
        #expect(Self.ids(store) == ["2", "4"])
    }

    // MARK: 켜도 편집은 막는다

    @Test func 켜도_이름_곡_순서_옮기기_지우기는_초안에_들어가지_않는다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, lab: true)
        let row = try #require(store.rowsByID["1"])
        store.renamePlaylist("S1", to: "다른 이름")
        store.addTracks([row], toPlaylist: "S1")
        store.movePlaylist("S1", into: PlaylistLayout.root)
        store.deletePlaylist("S1")
        #expect(store.playlistDraft.isEmpty)
        #expect(!store.canEditTracks(of: "S1"))
        store.sidebar = .playlist("S1")
        #expect(store.editablePlaylistID == nil && !store.canReorderDisplayedTracks)
        #expect(!store.trackPlaylists.contains { $0.item.id == "S1" })
        #expect(store.applyPlaylistEdits([.rename(playlist: .id("S1"), name: "x")], actionName: "시험") == false)
        #expect(store.playlistDraft.isEmpty)
    }

    @Test func 켜져_있으면_고쳐_보려_할_때_이유를_알린다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, lab: true)
        #expect(store.blockSmartPlaylistEdit("S1"))
        let message = try #require(store.playlistMessage)
        #expect(message.text == "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")
        // 일반 목록은 막지 않는다
        store.playlistMessage = nil
        #expect(!store.blockSmartPlaylistEdit("P"))
        #expect(store.playlistMessage == nil)
    }

    @Test func 켜도_rekordbox_목록_상태와_USB_내보내기_후보는_인텔리전트_목록을_그대로_다룬다() async throws {
        let fixture = try Self.fixture()
        for lab in [false, true] {
            let store = await Self.makeStore(fixture, lab: lab)
            // 초안을 얹기 전 rekordbox 목록 상태(쓰기·USB 후보가 보는 모양)에는 계산한 곡이 들어오지 않는다
            for id in ["S1", "S2", "S3"] {
                let item = try #require(store.rekordboxPlaylists.item(id))
                #expect(item.isSmart && !item.holdsTracks && item.entries.isEmpty, "\(id) lab=\(lab)")
            }
            let rows = UsbExportSelection.rows(store.rekordboxPlaylists)
            #expect(rows.first { $0.id == "S1" }?.isSmart == true && rows.first { $0.id == "S1" }?.trackCount == 0, "lab=\(lab)")
            #expect(rows.first { $0.id == "P" }?.trackCount == 2)
        }
        // USB 후보 읽기: DB 그대로 attribute 4·곡 없음
        let db = try fixture.open()
        defer { db.close() }
        let tree = try UsbExportCandidates.playlistTree(database: db, rootIDs: ["S1", "S2", "S3"])
        #expect(tree.map(\.attribute) == [4, 4, 4] && tree.allSatisfy { $0.trackLocalIDs.isEmpty })
    }

    // MARK: 설정 저장

    @Test func 켜_둔_설정은_저장돼_다시_열어도_이어진다() async throws {
        let fixture = try Self.fixture()
        let defaults = TestDefaults.make("smart-playlists.save")
        let store = await Self.makeStore(fixture, persist: true, defaults: defaults)
        #expect(!store.showSmartPlaylists)
        store.showSmartPlaylists = true
        #expect(SettingsStore(defaults: defaults, persist: true).value(SettingKeys.labSmartPlaylists))
        let reopened = await Self.makeStore(fixture, lab: true, persist: true, defaults: defaults)
        #expect(reopened.showSmartPlaylists)
        #expect(Set(reopened.playlistIndex["S1"]?.trackIDs ?? []) == ["2", "3", "4"])
        store.showSmartPlaylists = false
        #expect(!SettingsStore(defaults: defaults, persist: true).value(SettingKeys.labSmartPlaylists))
    }

    @Test func 자가_테스트_프로세스는_저장된_설정을_읽지_않는다() async throws {
        let fixture = try Self.fixture()
        let defaults = TestDefaults.make("smart-playlists.selftest")
        defaults.set(true, forKey: SettingKeys.labSmartPlaylists.name)
        #expect(!SettingsStore(defaults: defaults, persist: false).value(SettingKeys.labSmartPlaylists))
        let store = await Self.makeStore(fixture, persist: false, defaults: defaults)
        #expect(!store.showSmartPlaylists)
    }
}
