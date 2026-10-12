import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// `djc draft playlist`(#260): 재생 목록 편집을 앱과 같은 `playlist-drafts.json`에 쌓는다. 계획 규칙은 DJCApplicationTests가 보고,
/// 여기서는 인자·편집 JSON·출력·종료 코드와 저장한 파일을 합성 사본으로 본다.
@Suite("CLI 재생 목록 초안")
struct PlaylistDraftCommandTests {
    let cli = DraftCommandTests()

    /// 곡 101·102·103, 맨 위: 폴더 F · 세트 P1(101·102) · 지울 목록 P2 · 인텔리전트 S
    func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        try fixture.add(tracks: ["101", "102", "103"].map { TrackSpec(id: $0, uuid: "track-\($0)") })
        try fixture.add(playlists: [
            PlaylistSpec(id: "900", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "901", name: "세트", seq: 2, contentIDs: ["101", "102"]),
            PlaylistSpec(id: "902", name: "지울 목록", seq: 3),
            PlaylistSpec(id: "903", name: "자동", seq: 4),
        ])
        try fixture.execute("UPDATE djmdPlaylist SET Attribute = 4 WHERE ID = '903'")
        return fixture
    }

    func draftFile(_ fixture: RekordboxFixture) -> URL { fixture.root.appending(path: "home/playlist-drafts.json") }

    func write(_ json: String, in fixture: RekordboxFixture) throws -> URL {
        let url = fixture.root.appending(path: "edits.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    static let edits = """
        {"edits": [
          {"op": "create", "name": "새 폴더", "folder": true, "as": "@f"},
          {"op": "create", "name": "피크", "parent": "@f", "as": "@p", "tracks": ["103"]},
          {"op": "move", "playlist": "901", "parent": "@f", "before": "@p"},
          {"op": "delete", "playlist": "name:지울 목록"},
          {"op": "add", "playlist": "@p", "tracks": ["101", "103"]},
          {"op": "rename", "playlist": "903", "name": "고친 자동"}
        ]}
        """

    @Test func 묶음_파일의_편집을_쌓고_막힌_편집은_이유와_함께_건너뛴다() throws {
        let fixture = try fixture()
        let file = try write(Self.edits, in: fixture)
        let preview = try cli.run(["playlist", "apply", "--file", file.path, "--dry-run"], fixture: fixture)
        #expect(preview.status == 0)
        #expect(!FileManager.default.fileExists(atPath: draftFile(fixture).path))

        let output = try cli.run(["playlist", "apply", "--file", file.path], fixture: fixture)
        #expect(output.status == 0)
        let data = try #require(try output.document()["data"] as? [String: Any])
        #expect(data["kind"] as? String == "playlist" && data["action"] as? String == "apply" && data["dryRun"] as? Bool == false)
        #expect(data["stacked"] as? Int == 5 && data["skipped"] as? Int == 1 && data["hasChanges"] as? Bool == true)
        let results = try #require(data["results"] as? [[String: Any]])
        #expect(results.map { $0["status"] as? String } == ["stacked", "stacked", "stacked", "stacked", "stacked", "skipped"])
        #expect(results[3]["playlistID"] as? String == "902" && results[3]["name"] as? String == "지울 목록")
        #expect((results[4]["ignored"] as? [String]) == ["103"])
        #expect((results[5]["reason"] as? String)?.contains("인텔리전트") == true)
        let aliases = try #require(data["aliases"] as? [String: String])
        let folder = try #require(aliases["@f"]), list = try #require(aliases["@p"])
        #expect(folder.hasPrefix("new:") && list.hasPrefix("new:"))

        // 앱과 같은 파일에 쌓았다: 편집마다 지금 rekordbox 목록 상태를 base로 적었다
        let draft = PlaylistDraftStore.load(url: draftFile(fixture))
        #expect(draft.edits.count == 7)
        #expect(draft.base["901"]?.entries.map(\.contentID) == ["101", "102"] && draft.base["902"]?.name == "지울 목록")
        let layout = draft.project(onto: try RekordboxLibraryLayout.read(fixture))
        #expect(layout.blocked.allSatisfy { $0 == nil })
        #expect(layout.layout.childIDs(of: folder) == ["901", list])
        #expect(layout.layout.item(list)?.trackIDs == ["103", "101"])

        // 다음 실행은 앞서 쌓은 초안 위에 쌓는다(만든 목록은 new:키로 가리킨다)
        let next = try cli.run(["playlist", "rename", list, "피크 타임"], fixture: fixture)
        #expect(next.status == 0)
        #expect(PlaylistDraftStore.load(url: draftFile(fixture)).project(onto: try RekordboxLibraryLayout.read(fixture)).layout.item(list)?.name == "피크 타임")
    }

    @Test func 하위_명령은_편집_하나를_쌓고_막히면_종료_코드_1이다() throws {
        let fixture = try fixture()
        let created = try cli.run(["playlist", "create", "새 목록", "--parent", "900", "--tracks", "101,102"], fixture: fixture)
        #expect(created.status == 0)
        let item = try #require((try created.document()["data"] as? [String: Any])?["results"] as? [[String: Any]]).first
        let id = try #require(item?["playlistID"] as? String)
        #expect(try cli.run(["playlist", "order", id, "102", "101"], fixture: fixture).status == 0)
        #expect(try cli.run(["playlist", "remove", "901", "102"], fixture: fixture).status == 0)
        #expect(try cli.run(["playlist", "move", "902", "--parent", "900", "--index", "0"], fixture: fixture).status == 0)
        let draft = PlaylistDraftStore.load(url: draftFile(fixture))
        let layout = draft.project(onto: try RekordboxLibraryLayout.read(fixture)).layout
        #expect(layout.item(id)?.trackIDs == ["102", "101"] && layout.item("901")?.trackIDs == ["101"])
        #expect(layout.childIDs(of: "900") == ["902", id])

        let blocked = try cli.run(["playlist", "delete", "903"], fixture: fixture)
        #expect(blocked.status == 1 && blocked.stdout.isEmpty)
        let error = try #require(try blocked.document(error: true)["error"] as? [String: Any])
        #expect(error["code"] as? String == "playlist_edit_blocked")
        #expect((error["message"] as? String)?.contains("인텔리전트") == true)
        // 이름이 겹치면 고르지 않는다
        _ = try cli.run(["playlist", "create", "세트"], fixture: fixture)
        let ambiguous = try cli.run(["playlist", "add", "name:세트", "103"], fixture: fixture)
        #expect(ambiguous.status == 1)
        let message = (try ambiguous.document(error: true)["error"] as? [String: Any])?["message"] as? String
        #expect(message?.contains("ID로 가리키세요") == true)
        #expect(PlaylistDraftStore.load(url: draftFile(fixture)).steps.count == draft.steps.count + 1)
    }

    @Test(arguments: [
        #"{"edits": [{"op": "drop", "playlist": "901"}]}"#,
        #"{"edits": [{"op": "rename", "playlist": "901"}]}"#,
        #"{"edits": [{"op": "rename", "playlist": "901", "name": "x", "nmae": "y"}]}"#,
        #"{"edits": [{"op": "move", "playlist": "901", "before": "902", "index": 0}]}"#,
        #"{"edits": [{"op": "create", "name": "x", "as": "f"}]}"#,
        #"{"edits": [{"op": "create", "name": "x", "folder": true, "tracks": ["101"]}]}"#,
        #"{"edits": [{"op": "add", "playlist": "901", "tracks": []}]}"#,
        #"{"edits": []}"#,
        #"{"edit": []}"#,
        "not json",
    ])
    func 잘못된_편집_JSON은_아무것도_쌓지_않고_인자_오류다(json: String) throws {
        let fixture = try fixture()
        let file = try write(json, in: fixture)
        let output = try cli.run(["playlist", "apply", "--file", file.path], fixture: fixture)
        #expect(output.status == 1)
        #expect((try output.document(error: true)["error"] as? [String: Any])?["code"] as? String == "invalid_arguments")
        #expect(!FileManager.default.fileExists(atPath: draftFile(fixture).path))
    }

    @Test func 하나라도_막히면_쌓지_않는_선택과_글_출력() throws {
        let fixture = try fixture()
        let file = try write(Self.edits, in: fixture)
        let refused = try cli.run(["playlist", "apply", "--file", file.path, "--all-or-nothing"], fixture: fixture)
        #expect(refused.status == 1)
        #expect(!FileManager.default.fileExists(atPath: draftFile(fixture).path))
        let text = try cli.run(["playlist", "apply", "--file", file.path], fixture: fixture, json: false)
        let lines = String(decoding: text.stdout, as: UTF8.self)
        #expect(text.status == 0)
        #expect(lines.contains("쌓은 편집 5") && lines.contains("✗ #6 rename ‘자동’ (903)") && lines.contains("rekordbox에는 아직 쓰지 않았습니다"))
    }
}

/// 사본의 재생 목록 트리(앱이 스냅샷을 읽을 때와 같은 모양)
enum RekordboxLibraryLayout {
    static func read(_ fixture: RekordboxFixture) throws -> PlaylistLayout {
        PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
    }
}
