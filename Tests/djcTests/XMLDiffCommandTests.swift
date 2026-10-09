import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `djc xml-diff`(#72 가져오기): 인자·라이브 DB 거부·요약 줄·JSON. 라이브러리는 합성 사본, XML은 그 사본을 내보내 고친 것이다.
@Suite("XML 가져오기 차이 명령")
struct XMLDiffCommandTests {
    func library() throws -> RekordboxFixture { try XMLExportCommandTests().library() }

    /// 사본을 내보낸 XML에 `edit`을 적용해 파일로 둔다.
    func xml(_ fixture: RekordboxFixture, edit: (String) -> String = { $0 }) throws -> URL {
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let url = fixture.root.appending(path: "in-\(UUID().uuidString).xml")
        try Data(edit(RekordboxLibraryXML.document(collection)).utf8).write(to: url)
        return url
    }

    @Test func 인자는_db와_xml이_필수이고_옵션을_엄격히_받는다() throws {
        let request = try XMLDiffCommand.request(["xml-diff", "--db", "/tmp/a.db", "--xml", "/tmp/i.xml", "--share", "/tmp/s", "--json"])
        #expect(request == XMLDiffCommand.Request(database: URL(filePath: "/tmp/a.db"), xml: URL(filePath: "/tmp/i.xml"),
                                                   share: URL(filePath: "/tmp/s"), noAnalysis: false, json: true))
        let minimal = try XMLDiffCommand.request(["xml-diff", "--db", "/tmp/a.db", "--xml", "/tmp/i.xml"])
        #expect(minimal.share == nil && !minimal.json && !minimal.noAnalysis && minimal.limit == 50)
        #expect(try XMLDiffCommand.request(["xml-diff", "--db", "/a", "--xml", "/b", "--limit", "0"]).limit == 0)
        for bad in [["xml-diff"], ["xml-diff", "--db", "/tmp/a.db"], ["xml-diff", "--xml", "/tmp/i.xml"],
                    ["xml-diff", "--db", "/tmp/a.db", "--xml"], ["xml-diff", "--db", "/a", "--xml", "/b", "--live"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--no-analysis", "--share", "/s"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--limit", "-1"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "extra"]] {
            #expect(throws: UsageError.self) { _ = try XMLDiffCommand.request(bad) }
        }
    }

    @Test func 내보낸_XML과_비교하면_차이가_없다() throws {
        let fixture = try library()
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: try xml(fixture), share: nil))
        #expect(report.diff.isEmpty && report.diff.matching.matched == 1)
        let text = XMLDiffCommand.lines(report, limit: 50).joined(separator: "\n")
        #expect(text.contains("XML 곡 1 · 맞춘 곡 1 · 라이브러리에 없는 곡 0 · 여러 곡에 맞는 곡 0"))
        #expect(text.contains("차이가 없습니다"))
    }

    @Test func 차이를_종류별로_세고_곡마다_요약한다() throws {
        let fixture = try library()
        let url = try xml(fixture) {
            $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#)
                .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="22.000" Num="0""#)
                .replacingOccurrences(of: #"<NODE Name="셋""#, with: #"<NODE Name="새 셋""#)
        }
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil))
        let text = XMLDiffCommand.lines(report, limit: 50).joined(separator: "\n")
        #expect(text.contains("큐가 다른 곡 1 · 그리드가 다른 곡 0 · 태그가 다른 곡 1"))
        #expect(text.contains("없는 재생 목록 1 · 곡이 다른 재생 목록 0"))
        #expect(text.contains("/Music/시험.mp3") && text.contains("큐 +0 ~1 −0") && text.contains("제목"))
        #expect(text.contains("새 셋"))
        // 목록을 줄이면 남은 수를 알린다
        let short = XMLDiffCommand.lines(report, limit: 0).joined(separator: "\n")
        #expect(!short.contains("/Music/시험.mp3") && short.contains("곡 1개는 줄였습니다"))
    }

    @Test func JSON은_종류별_개수와_곡별_차이를_담는다() throws {
        let fixture = try library()
        let url = try xml(fixture) { $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#) }
        let report = try XMLDiffCommand.report(.init(database: fixture.database, xml: url, share: nil, json: true))
        let data = try XMLDiffCommand.json(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "xml-diff")
        let body = try #require(object["data"] as? [String: Any])
        let counts = try #require(body["counts"] as? [String: Int])
        #expect(counts["tagTracks"] == 1 && counts["cueTracks"] == 0)
        let matching = try #require(body["matching"] as? [String: Int])
        #expect(matching["matched"] == 1)
        let tracks = try #require(body["tracks"] as? [[String: Any]])
        #expect(tracks.first?["libraryID"] as? String == "101")
        let tags = try #require(tracks.first?["tags"] as? [[String: String]])
        #expect(tags == [["key": "title", "library": "시험 곡", "xml": "새 제목"]])
    }

    @Test func 라이브_master_db는_열지_않는다() throws {
        let fixture = try library()
        let live = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: ReadFailure.self) {
            _ = try XMLDiffCommand.report(.init(database: live, xml: try xml(fixture), share: nil))
        }
    }

    @Test func 읽을_수_없는_XML은_이유와_함께_막는다() throws {
        let fixture = try library()
        let bad = fixture.root.appending(path: "bad.xml")
        try Data("<plist/>".utf8).write(to: bad)
        #expect(throws: RekordboxXMLReader.ReadError.self) {
            _ = try XMLDiffCommand.report(.init(database: fixture.database, xml: bad, share: nil))
        }
        let error = try #require(throws: ReadFailure.self) {
            _ = try XMLDiffCommand.report(.init(database: fixture.database, xml: fixture.root.appending(path: "없음.xml"), share: nil))
        }
        #expect(error.code == "missing_xml")
    }

    // MARK: 초안 만들기(--draft)

    @Test func draft_인자는_only로_종류를_고른다() throws {
        let request = try XMLDiffCommand.request(["xml-diff", "--db", "/a", "--xml", "/b", "--draft", "--only", "cue,tag"])
        #expect(request.draft && request.kinds == [.cue, .tag])
        #expect(try XMLDiffCommand.request(["xml-diff", "--db", "/a", "--xml", "/b", "--draft"]).kinds == Set(XMLImportDrafts.Kind.allCases))
        for bad in [["xml-diff", "--db", "/a", "--xml", "/b", "--only", "cue"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--draft", "--only", "cue,모름"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--draft", "--draft"],
                    ["xml-diff", "--db", "/a", "--xml", "/b", "--draft", "--json"]] {
            #expect(throws: UsageError.self) { _ = try XMLDiffCommand.request(bad) }
        }
    }

    @Test func 고른_차이를_초안_폴더에만_쓰고_기존_초안은_덮지_않는다() throws {
        let fixture = try library()
        let url = try xml(fixture) {
            $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#)
                .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="22.000" Num="0""#)
                .replacingOccurrences(of: #"<NODE Name="셋""#, with: #"<NODE Name="새 셋""#)
        }
        let before = try Data(contentsOf: fixture.database)
        let home = fixture.root.appending(path: "home")
        let uuid = try RekordboxLibrary.load(snapshot: fixture.database).tracks.first { $0.id == "101" }!.uuid
        let request = XMLDiffCommand.Request(database: fixture.database, xml: url, share: nil, draft: true)
        let report = try XMLDiffCommand.report(request)
        let lines = try XMLDiffCommand.makeDrafts(report, request: request, home: home).joined(separator: "\n")
        #expect(lines.contains("초안을 만들었습니다: 큐 1 · 그리드 0 · 태그 1 · 재생 목록 1"))
        let tag = try JSONDecoder().decode(TagDraft.self, from: Data(contentsOf: home.appending(path: "tag-drafts/\(uuid).json")))
        #expect(tag.base.title == "시험 곡" && tag.fields.title == "새 제목")
        let cue = try JSONDecoder().decode(CueDraft.self, from: Data(contentsOf: home.appending(path: "cue-drafts/\(uuid).json")))
        #expect(cue.cues.map(\.time) == [22] && cue.base.map(\.time) == [20])
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "playlist-drafts.json").path))
        #expect(try Data(contentsOf: fixture.database) == before, "사본 DB는 그대로")

        // 다시 가져오면 덮지 않고 건너뛴다
        let again = try XMLDiffCommand.makeDrafts(report, request: request, home: home).joined(separator: "\n")
        #expect(again.contains("초안을 만들었습니다: 큐 0 · 그리드 0 · 태그 0 · 재생 목록 0"))
        #expect(again.contains("이 곡에 큐 초안이 이미 있어 덮지 않았습니다"))
        #expect(again.contains("같은 이름의 목록이 재생 목록 초안에 이미 있어 덮지 않았습니다"))
        let kept = try JSONDecoder().decode(TagDraft.self, from: Data(contentsOf: home.appending(path: "tag-drafts/\(uuid).json")))
        #expect(kept == tag)
    }

    @Test func only로_고른_종류만_초안으로_만든다() throws {
        let fixture = try library()
        let url = try xml(fixture) {
            $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#)
                .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="22.000" Num="0""#)
        }
        let home = fixture.root.appending(path: "home")
        let request = XMLDiffCommand.Request(database: fixture.database, xml: url, share: nil, draft: true, kinds: [.tag])
        let lines = try XMLDiffCommand.makeDrafts(try XMLDiffCommand.report(request), request: request, home: home)
        #expect(lines.joined(separator: "\n").contains("초안을 만들었습니다: 큐 0 · 그리드 0 · 태그 1 · 재생 목록 0"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "cue-drafts").path))
    }

    @Test func DJCrate가_켜져_있으면_재생_목록_초안은_쓰지_않고_그리드는_경고한다() throws {
        // 앱은 재생 목록 초안 파일을 다시 읽지 않아 다음 저장이 CLI가 쓴 것을 덮는다
        let fixture = try library()
        let url = try xml(fixture) {
            $0.replacingOccurrences(of: #"Name="시험 곡""#, with: #"Name="새 제목""#)
                .replacingOccurrences(of: #"<NODE Name="셋""#, with: #"<NODE Name="새 셋""#)
        }
        let home = fixture.root.appending(path: "home")
        let request = XMLDiffCommand.Request(database: fixture.database, xml: url, share: nil, draft: true)
        let lines = try XMLDiffCommand.makeDrafts(try XMLDiffCommand.report(request), request: request, home: home, appRunning: true)
            .joined(separator: "\n")
        #expect(lines.contains("초안을 만들었습니다: 큐 0 · 그리드 0 · 태그 1 · 재생 목록 0"))
        #expect(lines.contains("DJCrate가 켜져 있어 재생 목록 초안은 만들지 않았습니다"))
        #expect(lines.contains("덱에 올린 곡"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "playlist-drafts.json").path))
    }
}
