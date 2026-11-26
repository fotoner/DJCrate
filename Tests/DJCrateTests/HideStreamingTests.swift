@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 설정 '스트리밍 곡 숨기기': 곡 목록·곡 수에 보이는 것만 바꾼다. 재생 목록 편집·쓰기 내용은 설정과 무관하게 같아야 한다.
@MainActor
@Suite("스트리밍 곡 숨기기(앱)", .serialized)
struct HideStreamingTests {
    /// 로컬 곡 1·3·5·6, 스트리밍 곡 2(spotify)·4(apple-music)
    /// 목록 P = 1,2,3,4,5 · Q = 2,4(스트리밍뿐) · R = 1,3(스트리밍 없음), 재생 기록 h = 1,2,3
    static func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        let paths = ["1": "/synthetic/1.mp3", "2": "spotify:track:aaa", "3": "/synthetic/3.mp3",
                     "4": "apple-music:44", "5": "/synthetic/5.mp3", "6": "/synthetic/6.mp3"]
        for id in paths.keys.sorted() {
            var track = TrackSpec(id: id, uuid: "hide-\(id)")
            track.title = "합성 \(id)"
            track.folderPath = paths[id] ?? ""
            try fixture.add(track)
        }
        try fixture.add(playlists: [
            PlaylistSpec(id: "P", name: "스트리밍 섞인 목록", seq: 1, contentIDs: ["1", "2", "3", "4", "5"]),
            PlaylistSpec(id: "Q", name: "스트리밍뿐인 목록", seq: 2, contentIDs: ["2", "4"]),
            PlaylistSpec(id: "R", name: "로컬뿐인 목록", seq: 3, contentIDs: ["1", "3"]),
        ])
        try fixture.insert("djmdHistory", ["ID": .text("h"), "Name": .text("합성 기록"), "DateCreated": .text("2025-02-03"),
            "Seq": .int(1), "Attribute": .int(0), "ParentID": .text("root"), "rb_local_deleted": .int(0)])
        for (id, content, number) in [("e1", "1", 1), ("e2", "2", 2), ("e3", "3", 3)] {
            try fixture.insert("djmdSongHistory", ["ID": .text(id), "HistoryID": .text("h"), "ContentID": .text(content),
                "TrackNo": .int(number), "rb_local_deleted": .int(0)])
        }
        return fixture
    }

    /// - Parameter filesMissing: 켜면 파일 확인이 모든 곡을 '파일 없음'으로 본다
    static func makeStore(_ fixture: RekordboxFixture, hideStreaming: Bool = false, persist: Bool = false,
                          defaults: UserDefaults? = nil, filesMissing: TestSwitch? = nil) async -> LibraryStore {
        let defaults = defaults ?? TestDefaults.make("hide-streaming")
        let settings = SettingsStore(defaults: defaults, persist: persist)
        if persist { defaults.set(hideStreaming, forKey: SettingKeys.hideStreaming.name) }
        let store = LibraryStore.test(settings: settings, activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxDatabase: fixture.database,
                                 rekordboxShareRoot: fixture.shareRoot, arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database] _ in database },
                                 ports: { ports in
                                     guard let filesMissing else { return }
                                     let exists = ports.files.exists
                                     ports.files.exists = { filesMissing.isOn ? false : exists($0) }
                                 })
        await store.load(snapshot: fixture.database)
        if !persist, hideStreaming { store.hideStreaming = true }
        return store
    }

    static func ids(_ store: LibraryStore) -> [String] { store.displayRows.map(\.track.id) }

    /// 저장한 설정을 층마다 읽은 값(#257 진단). CI에서 끈 값이 켠 값으로 읽힌 적이 한 번 있었고, 로컬 부하 반복으로는 재현하지 못했다.
    /// 같은 영역의 새 인스턴스와 cfprefsd가 적은 plist를 함께 남겨, 다음 실패 때 값을 잃은 층을 가른다.
    static func persistedTrace(_ suite: String, _ defaults: UserDefaults) -> String {
        let name = SettingKeys.hideStreaming.name
        let fresh = TestDefaults.open(suite).object(forKey: name)
        let file = (try? Data(contentsOf: URL(filePath: suite + ".plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?[name]
        return "인스턴스=\(String(describing: defaults.object(forKey: name))) 새 인스턴스=\(String(describing: fresh)) plist=\(String(describing: file))"
    }

    // MARK: 설정 저장

    @Test func 기본은_꺼져_있고_켜면_저장해_다시_열어도_이어진다() async throws {
        let fixture = try Self.fixture()
        let suite = TestDefaults.suiteName("hide-streaming.save")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = await Self.makeStore(fixture, persist: true, defaults: defaults)
        #expect(!store.hideStreaming)
        #expect(Self.ids(store).count == 6)
        store.hideStreaming = true
        #expect(SettingsStore(defaults: defaults, persist: true).value(SettingKeys.hideStreaming))
        // 다시 연 저장소는 켠 채로 읽는다: 읽은 직후부터 스트리밍 곡이 목록·곡 수에 없다
        let reopened = await Self.makeStore(fixture, hideStreaming: true, persist: true, defaults: defaults)
        #expect(reopened.hideStreaming)
        #expect(Set(Self.ids(reopened)) == ["1", "3", "5", "6"])
        #expect(reopened.count(.all) == 4)
        // 첫 저장소가 켠 채여야 끄는 값이 저장된다(#257: 실패가 저장소 상태 때문인지 설정 영역 때문인지 가른다)
        #expect(store.hideStreaming)
        store.hideStreaming = false
        let saved = SettingsStore(defaults: defaults, persist: true).value(SettingKeys.hideStreaming)
        #expect(!saved, "\(Self.persistedTrace(suite, defaults))")
        // 자가 테스트(persist 없음)는 설정을 읽지도 저장하지도 않는다
        defaults.set(true, forKey: SettingKeys.hideStreaming.name)
        #expect(!SettingsStore(defaults: defaults, persist: false).value(SettingKeys.hideStreaming))
    }

    // MARK: 라이브러리 필터·곡 수·사이드바

    @Test func 켜고_끄면_곡_목록과_필터_곡_수가_바로_바뀌고_정렬은_그대로다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        #expect(store.displayRows.count == 6 && store.count(.all) == 6 && store.count(.streaming) == 2)
        let sort = [KeyPathComparator(\TrackRow.title, order: .forward)]
        store.sortOrder = sort
        #expect(Self.ids(store) == ["1", "2", "3", "4", "5", "6"])
        store.hideStreaming = true
        #expect(Self.ids(store) == ["1", "3", "5", "6"])
        #expect(store.count(.all) == 4 && store.count(.noCues) == 4)
        #expect(store.sortOrder == sort, "숨겨도 정렬은 그대로")
        #expect(!LibraryFilter.visible(commentPreset: store.commentPreset, hidingStreaming: store.hideStreaming).contains(.streaming))
        store.hideStreaming = false
        #expect(Self.ids(store) == ["1", "2", "3", "4", "5", "6"])
        #expect(store.count(.all) == 6 && store.count(.streaming) == 2 && store.sortOrder == sort)
    }

    @Test func 스트리밍_필터를_보던_중_켜면_전체로_옮긴다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        store.sidebar = .filter(.streaming)
        #expect(Self.ids(store).count == 2)
        store.hideStreaming = true
        #expect(store.sidebar == .filter(.all))
        #expect(Self.ids(store).count == 4)
        // 켠 동안 사이드바 필터로 스트리밍을 고르는 길이 없어도, 어떻게든 고르면 빈 목록이다(스트리밍 곡이 새지 않는다)
        store.sidebar = .filter(.streaming)
        #expect(store.displayRows.isEmpty)
    }

    @Test func 검색_결과에서도_스트리밍_곡이_빠진다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        store.search = "합성"
        #expect(store.displayRows.count == 6)
        store.hideStreaming = true
        #expect(Self.ids(store).count == 4 && !Self.ids(store).contains("2"))
        store.hideStreaming = false
        #expect(store.displayRows.count == 6)
    }

    @Test func 코멘트_프리셋을_바꿔도_숨긴_곡은_곡_수에_다시_들어오지_않는다() async throws {
        let missing = TestSwitch()
        let store = await Self.makeStore(try Self.fixture(), hideStreaming: true, filesMissing: missing)
        store.commentPreset = .anisong
        #expect(store.count(.all) == 4 && store.count(.emptyComment) == 4)
        store.commentPreset = .none
        #expect(store.count(.all) == 4)
        // 파일 확인 결과를 반영해도 마찬가지
        missing.set(true)
        store.checkMissingFiles()
        for _ in 0..<500 where store.isCheckingFiles { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.isCheckingFiles && store.count(.missingFile) == 4 && store.count(.all) == 4)
    }

    // MARK: 재생 목록·재생 기록

    @Test func 재생_목록과_재생_기록_보기와_곡_수에서_빠진다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        let node = try #require(store.playlists.playlistIndex["P"])
        #expect(store.count(playlist: node) == 5)
        store.sidebar = .playlist("P")
        #expect(Self.ids(store) == ["1", "2", "3", "4", "5"])
        let history = try #require(store.history.histories.first)
        #expect(store.count(history: history) == 3)
        store.hideStreaming = true
        #expect(Self.ids(store) == ["1", "3", "5"])
        #expect(store.count(playlist: try #require(store.playlists.playlistIndex["P"])) == 3)
        #expect(store.count(playlist: try #require(store.playlists.playlistIndex["Q"])) == 0)
        #expect(store.count(playlist: try #require(store.playlists.playlistIndex["R"])) == 2)
        #expect(store.count(history: history) == 2)
        store.sidebar = .history("h")
        #expect(Self.ids(store) == ["1", "3"])
        store.sidebar = .playlist("Q")
        #expect(store.displayRows.isEmpty && store.streamingHiddenInView == 2)
        store.hideStreaming = false
        #expect(Self.ids(store) == ["2", "4"] && store.streamingHiddenInView == 0)
        #expect(store.count(playlist: try #require(store.playlists.playlistIndex["P"])) == 5)
    }

    // MARK: 선택·덱

    @Test func 숨기는_곡은_선택에서도_빠지고_보이는_곡_선택은_남는다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        store.selection = ["1", "2", "3"]
        store.hideStreaming = true
        #expect(store.selection == ["1", "3"])
        // 재생 기록의 줄 ID(`history:…`)도 곡을 따라가 정리한다
        store.hideStreaming = false
        store.sidebar = .history("h")
        let streamingRow = try #require(store.displayRows.first { $0.track.id == "2" })
        let localRow = try #require(store.displayRows.first { $0.track.id == "1" })
        store.selection = [streamingRow.id, localRow.id]
        store.hideStreaming = true
        #expect(store.selection == [localRow.id])
        // 하나만 골랐던 곡이 숨으면 덱에 올릴 곡도 없다
        store.hideStreaming = false
        store.sidebar = .filter(.all)
        store.selection = ["2"]
        store.hideStreaming = true
        #expect(store.selection.isEmpty && store.primaryRow == nil && store.selectedRows.isEmpty)
    }

    @Test func 덱에_올라_있던_스트리밍_곡은_숨겨도_그대로_둔다() async throws {
        let store = await Self.makeStore(try Self.fixture())
        var loaded: [String?] = []
        store.onLoadToDeck = { loaded.append($0?.track.id) }
        store.loadToDeck(try #require(store.rowsByID["2"]))
        #expect(store.deckTrackID == "2" && loaded == ["2"])
        store.hideStreaming = true
        #expect(store.deckTrackID == "2" && loaded == ["2"], "덱을 내리거나 다시 올리지 않는다")
        store.hideStreaming = false
        #expect(store.deckTrackID == "2" && loaded == ["2"])
    }

    @Test func 쓰기_대기_목록은_숨기지_않는다() async throws {
        let store = await Self.makeStore(try Self.fixture(), hideStreaming: true)
        // 스트리밍 곡에 남아 있던 태그 초안: 쓰기 대기 목록이 곧 쓸 곡이라, 보이는 것과 쓰는 것이 같아야 한다
        store.tagDrafts["hide-2"] = TagDraft(trackUUID: "hide-2", base: TagFields())
        store.sidebar = .pending
        #expect(Self.ids(store) == ["2"] && store.streamingHiddenInView == 0)
    }

    // MARK: 재생 목록 편집은 설정과 무관하다

    @Test func 보이는_줄이_아니라_원래_항목으로_빼고_넣어_초안이_같다() async throws {
        let fixture = try Self.fixture()
        let off = await Self.makeStore(fixture)
        let on = await Self.makeStore(fixture, hideStreaming: true)
        for store in [off, on] {
            store.sidebar = .playlist("P")
            // 보이는 줄에서 3과 5를 골라 뺀다(숨은 줄이 있어도 3번째·5번째 자리로 가리킨다)
            let visible = store.displayRows.filter { ["3", "5"].contains($0.track.id) }
            store.selection = Set(visible.map(\.id))
            store.playlists.removeSelectedFromPlaylist()
            store.playlists.addTracks([try #require(store.rowsByID["6"])], toPlaylist: "P")
        }
        let expected: [PlaylistEdit] = [
            .removeTracks(playlist: .id("P"), entries: [.init(trackNo: 3, contentID: "3"), .init(trackNo: 5, contentID: "5")]),
            .addTracks(playlist: .id("P"), contentIDs: ["6"]),
        ]
        #expect(off.playlists.playlistDraft.edits == expected)
        #expect(on.playlists.playlistDraft.edits == expected)
        #expect(on.playlists.playlistDraft == off.playlists.playlistDraft)
        #expect(on.playlists.playlistProjection.layout.item("P")?.entries == off.playlists.playlistProjection.layout.item("P")?.entries)
        // 숨은 스트리밍 곡은 목록에 그대로 남고 번호만 다시 매겨진다
        #expect(on.playlists.playlistIndex["P"]?.trackIDs == ["1", "2", "4", "6"])
        #expect(Self.ids(on) == ["1", "6"] && Self.ids(off) == ["1", "2", "4", "6"])
    }

    @Test func 순서_바꾸기_초안도_설정과_같고_숨은_줄이_있으면_끌어_옮기지_않는다() async throws {
        let fixture = try Self.fixture()
        let off = await Self.makeStore(fixture)
        let on = await Self.makeStore(fixture, hideStreaming: true)
        off.sidebar = .playlist("P")
        on.sidebar = .playlist("P")
        #expect(off.playlists.canReorderDisplayedTracks)
        #expect(!on.playlists.canReorderDisplayedTracks, "숨은 줄이 끼어 있으면 놓을 자리가 모호하다: 검색으로 거른 목록과 같게 막는다")
        // 같은 명령(곡·앞 곡)은 설정과 관계없이 같은 초안을 만든다
        off.playlists.moveTracks(["5"], inPlaylist: "P", before: "1")
        on.playlists.moveTracks(["5"], inPlaylist: "P", before: "1")
        #expect(off.playlists.playlistDraft.edits == [.moveTracks(playlist: .id("P"), entries: [.init(trackNo: 5, contentID: "5")], to: 1)])
        #expect(on.playlists.playlistDraft == off.playlists.playlistDraft)
        // 스트리밍이 없는 목록은 숨기기를 켜도 끌어 옮길 수 있다
        on.sidebar = .playlist("R")
        #expect(on.streamingHiddenInView == 0 && on.playlists.canReorderDisplayedTracks)
        // 숨기기를 끄면 다시 옮길 수 있다
        on.sidebar = .playlist("P")
        on.hideStreaming = false
        #expect(on.playlists.canReorderDisplayedTracks)
    }

    @Test func 재생_기록으로_만든_재생_목록도_설정과_같다() async throws {
        let fixture = try Self.fixture()
        let off = await Self.makeStore(fixture)
        let on = await Self.makeStore(fixture, hideStreaming: true)
        off.playlists.createPlaylist(fromHistory: "h")
        on.playlists.createPlaylist(fromHistory: "h")
        // 이름·새 목록 키는 만들 때마다 다르니 편집 모양(곡)만 견준다
        func tracks(_ store: LibraryStore) -> [[String]] {
            store.playlists.playlistDraft.edits.compactMap { if case let .addTracks(_, ids) = $0 { ids } else { nil } }
        }
        #expect(tracks(off) == [["1", "2", "3"]])
        #expect(tracks(on) == tracks(off), "숨긴 곡도 기록에 있던 곡이라 목록에는 들어간다: 쓰는 내용은 설정과 무관하다")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 쓰기_미리_보기와_쓴_결과가_설정과_상관없이_같다() async throws {
        var results: [(outcomes: [PlaylistOutcome], rows: [[String: String]])] = []
        for hide in [false, true] {
            let fixture = try Self.fixture()
            let store = await Self.makeStore(fixture, hideStreaming: hide)
            store.sidebar = .playlist("P")
            let visible = store.displayRows.filter { ["3", "5"].contains($0.track.id) }
            store.selection = Set(visible.map(\.id))
            store.playlists.removeSelectedFromPlaylist()
            store.playlists.addTracks([try #require(store.rowsByID["6"])], toPlaylist: "P")
            store.playlists.moveTracks(["1"], inPlaylist: "P", before: nil)
            let preview = try await store.session.previewWrite(rows: [], playlists: true)
            let previewed = try #require(preview.report.playlistOutcomes)
            #expect(previewed.count == 3 && previewed.allSatisfy { $0.status == .written })
            let report = try await store.session.writeToRekordbox([], playlists: preview.batch.playlists)
            let written = try #require(report.playlistOutcomes)
            #expect(written == previewed)
            let rows = try fixture.rows("""
                SELECT PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist WHERE PlaylistID = 'P' AND rb_local_deleted = 0
                ORDER BY TrackNo
                """)
            results.append((written, rows))
        }
        // 설정을 켜고 쓴 결과도 끄고 쓴 결과와 곡 순서·번호가 칸 단위로 같다. 숨은 스트리밍 곡(2·4)은 지워지지도 옮겨지지도 않았다.
        #expect(results[0].outcomes == results[1].outcomes)
        #expect(results[0].rows == results[1].rows)
        #expect(results[1].rows.map { $0["ContentID"] ?? "" } == ["2", "4", "6", "1"])
        #expect(results[1].rows.map { $0["TrackNo"] ?? "" } == ["1", "2", "3", "4"])
    }

    // MARK: 검색·필터가 숨긴 스트리밍 곡에만 맞을 때(#348)

    /// 키·BPM이 있는 합성 라이브러리. 로컬 1은 3B·BPM 90, 로컬 3·5·6은 키가 없다. 숨기는 스트리밍 곡 2는 8A·BPM 128, 4는 8B·BPM 128이다.
    static func keyedFixture() throws -> RekordboxFixture {
        let fixture = try Self.fixture()
        for (id, name) in [("k8", "8A"), ("kb", "8B"), ("k3", "3B")] {
            try fixture.insert("djmdKey", ["ID": .text(id), "ScaleName": .text(name), "Seq": .int(1), "UUID": .text("key-\(id)"),
                                           "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        }
        try fixture.execute("UPDATE djmdContent SET KeyID = 'k3', BPM = 9000 WHERE ID = '1'")
        try fixture.execute("UPDATE djmdContent SET KeyID = 'k8', BPM = 12800 WHERE ID = '2'")
        try fixture.execute("UPDATE djmdContent SET KeyID = 'kb', BPM = 12800 WHERE ID = '4'")
        return fixture
    }

    /// 보고 있는 화면에서 검색·필터를 걸었을 때 가운데 안내가 [스트리밍 곡 보이기]를 내놓는가
    private func offersShowStreaming(_ store: LibraryStore) -> Bool {
        guard case let .noResults(guide) = EmptyListNotice.resolve(store: store) else { return false }
        return guide.offersShowStreaming
    }

    @Test func 검색이_숨긴_스트리밍_곡에만_맞으면_빈_목록_안내가_보이기를_바로_내놓는다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, hideStreaming: true)
        store.search = "합성 2"
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 1)
        let notice = EmptyListNotice.resolve(store: store)
        guard case let .noResults(guide) = notice else { Issue.record("검색 결과 없음 안내가 와야 한다: \(notice)"); return }
        #expect(guide.offersShowStreaming && guide.offersClearSearch)
        #expect(guide.title == "‘합성 2’에 맞는 곡을 찾지 못했습니다", "새 설명 문구를 더하지 않는다")
        // 그 단추가 부르는 입구: 검색어는 그대로 두고 숨긴 곡만 푼다
        store.showHiddenStreaming()
        #expect(!store.hideStreaming && store.search == "합성 2")
        #expect(Self.ids(store) == ["2"] && store.streamingHiddenMatching == 0)
        withExtendedLifetime(fixture) {}
    }

    @Test func 어떤_곡에도_안_맞는_검색은_보이기를_내놓지_않는다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, hideStreaming: true)
        store.search = "없는 곡"
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 0)
        #expect(!offersShowStreaming(store))
        // 숨기기가 꺼져 있으면 숨긴 곡이 없다
        store.hideStreaming = false
        #expect(store.streamingHiddenMatching == 0 && !offersShowStreaming(store))
        withExtendedLifetime(fixture) {}
    }

    @Test func 보이는_곡이_있으면_숨긴_곡을_세지_않는다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, hideStreaming: true)
        store.search = "합성"
        #expect(Self.ids(store) == ["1", "3", "5", "6"] && store.streamingHiddenInView == 2)
        #expect(store.streamingHiddenMatching == 0, "목록이 비었을 때만 따진다")
        withExtendedLifetime(fixture) {}
    }

    @Test func 검색과_BPM_범위와_키_조건을_함께_걸어도_같은_함수로_숨긴_곡을_판정한다() async throws {
        let fixture = try Self.keyedFixture()
        let store = await Self.makeStore(fixture, hideStreaming: true)
        // 검색 + BPM 범위 + 같은 키: 숨긴 2(8A·128)만 맞는다. 로컬 곡은 BPM·키가 맞지 않아 목록은 빈다
        store.search = "합성"
        store.filter = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A"))
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 1)
        #expect(offersShowStreaming(store))
        // 어울리는 키: 9A는 8A와 이웃이라 2가 맞고, 번호도 글자도 다른 8B인 4는 맞지 않는다
        store.filter = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("9A", mode: .compatible))
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 1)
        // 어느 곡이 맞았는지는 숨기기를 끈 실제 목록으로 본다: 2뿐이다
        store.hideStreaming = false
        #expect(Self.ids(store) == ["2"])
        store.hideStreaming = true
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 1)
        // 다른 표기: Camelot으로 바꿔 비교하므로 `Am`도 8A다
        store.filter = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("Am"))
        #expect(store.streamingHiddenMatching == 1)
        // BPM 범위가 숨긴 곡을 모두 벗어나면 안내는 그대로이고 보이기는 없다
        store.filter = TrackFilter(bpm: BPMRange(lower: 80, upper: 100), key: KeyCondition("8A"))
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 0 && !offersShowStreaming(store))
        // 검색이 숨긴 곡에 맞아도 키가 다르면 맞지 않는다(검색 "합성 4"는 4, 같은 키 8A는 8B와 다르다)
        store.search = "합성 4"
        store.filter = TrackFilter(key: KeyCondition("8A"))
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 0 && !offersShowStreaming(store))
        // 필터만 걸어도(검색어 없음) 같다: 8A와 어울리는 키(같은 번호의 8B 포함)에 BPM 120–130이면 숨긴 2·4가 맞는다
        store.search = ""
        store.filter = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A", mode: .compatible))
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 2 && offersShowStreaming(store))
        // 보이기를 누르면 그 조건에 맞는 곡이 돌아온다
        store.showHiddenStreaming()
        #expect(Self.ids(store) == ["2", "4"] && store.streamingHiddenMatching == 0)
        withExtendedLifetime(fixture) {}
    }

    @Test func 목록이나_검색을_바꾸면_숨긴_곡_수를_다시_센다() async throws {
        let fixture = try Self.fixture()
        let store = await Self.makeStore(fixture, hideStreaming: true)
        store.sidebar = .playlist("R")
        store.search = "합성 2"
        #expect(store.displayRows.isEmpty && store.streamingHiddenMatching == 0, "목록 R에는 스트리밍 곡이 없다")
        store.sidebar = .playlist("Q")
        #expect(store.streamingHiddenMatching == 1)
        store.search = ""
        #expect(store.streamingHiddenMatching == 0, "검색어도 필터도 없으면 이 안내가 아니라 스트리밍 곡뿐 안내가 말한다")
        // 쓰기 대기 같은 숨기지 않는 목록은 세지 않는다: 스트리밍 곡 2에 초안이 있으면 쓰기 대기는 그 곡을 숨기지 않고 그대로 보인다
        store.tagDrafts["hide-2"] = TagDraft(trackUUID: "hide-2", base: TagFields())
        store.search = "합성 2"
        store.sidebar = .pending
        #expect(Self.ids(store) == ["2"] && store.streamingHiddenMatching == 0)
        withExtendedLifetime(fixture) {}
    }
}
