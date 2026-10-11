import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 인텔리전트 재생 목록 읽기(#68). 합성 DB 행으로만 시험한다: rekordbox 7.2.18에서 만든 인텔리전트 목록은 아직 없다(묶음 3 M1).
/// 읽기는 조건 칸을 모델로 풀 뿐이고, 목록 구조·곡 항목·편집 가능 여부(`isSmart`)는 읽기를 더하기 전과 같아야 한다.
@Suite("인텔리전트 재생 목록 읽기 — 합성 행")
struct RekordboxSmartPlaylistReadTests {
    static let conditionXML = "<NODE Id=\"-1\" LogicalOperator=\"2\" AutomaticUpdate=\"1\">"
        + "<CONDITION PropertyName=\"artist\" Operator=\"8\" ValueUnit=\"\" ValueLeft=\"합성\" ValueRight=\"\"/>"
        + "<CONDITION PropertyName=\"year\" Operator=\"5\" ValueUnit=\"\" ValueLeft=\"2015\" ValueRight=\"2020\"/></NODE>"

    /// 폴더 20 안에: 일반 목록 10(곡 둘) · 인텔리전트 30(조건 칸 정상) · 31(Attribute 4인데 조건 칸 비어 있음) · 32(조건 칸이 깨짐) · 33(Attribute 0인데 조건 칸이 있음)
    func library() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "101"))
        try fixture.add(TrackSpec(id: "102"))
        try fixture.addPlaylist(id: "20", name: "폴더", seq: 1, attribute: 1)
        try fixture.addPlaylist(id: "10", name: "일반", parentID: "20", seq: 1, contentIDs: ["101", "102"])
        try fixture.addPlaylist(id: "30", name: "스마트 정상", parentID: "20", seq: 2, attribute: 4, smartList: Self.conditionXML)
        try fixture.addPlaylist(id: "31", name: "스마트 빈칸", parentID: "20", seq: 3, attribute: 4)
        try fixture.addPlaylist(id: "32", name: "스마트 깨짐", parentID: "20", seq: 4, attribute: 4, smartList: "<NODE")
        try fixture.addPlaylist(id: "33", name: "종류 어긋남", parentID: "20", seq: 5, attribute: 0, smartList: Self.conditionXML)
        return fixture
    }

    func playlist(_ id: String, in library: RekordboxLibrary) throws -> RekordboxPlaylist {
        try #require(library.playlists.first { $0.id == id })
    }

    @Test func 조건_칸을_모델로_읽는다() throws {
        let fixture = try library()
        let loaded = try RekordboxLibrary.load(snapshot: fixture.database)
        let smart = try playlist("30", in: loaded)
        let definition = try #require(smart.smartSource?.definition)
        #expect(definition.match == .any && definition.automaticUpdate)
        #expect(definition.conditions.map(\.propertyName) == ["artist", "year"])
        #expect(definition.conditions.map(\.operatorCode) == [8, 5])
        #expect(definition.conditions[1].right == "2020")
    }

    @Test func 읽지_못하는_조건_칸은_이유와_함께_남기고_목록은_그대로_보인다() throws {
        let fixture = try library()
        let loaded = try RekordboxLibrary.load(snapshot: fixture.database)
        for id in ["31", "32"] {
            let smart = try playlist(id, in: loaded)
            guard case let .unreadable(reason)? = smart.smartSource else {
                Issue.record("\(id)는 읽지 못해야 한다")
                continue
            }
            #expect(!reason.isEmpty)
            #expect(smart.isSmart && smart.trackIDs.isEmpty)
        }
        // 종류가 4가 아니면 조건 칸이 있어도 인텔리전트로 계산하지 않는다(예전부터 isSmart는 칸이 있으면 참)
        let odd = try playlist("33", in: loaded)
        #expect(odd.isSmart)
        guard case .unreadable? = odd.smartSource else {
            Issue.record("Attribute 0은 읽지 않는다")
            return
        }
    }

    @Test func 일반_목록과_폴더는_조건을_들지_않는다() throws {
        let fixture = try library()
        let loaded = try RekordboxLibrary.load(snapshot: fixture.database)
        for id in ["10", "20"] {
            let plain = try playlist(id, in: loaded)
            #expect(plain.smartSource == nil && !plain.isSmart, "\(id)")
        }
        #expect(try playlist("10", in: loaded).trackIDs == ["101", "102"])
    }

    @Test func 읽기를_더해도_목록_구조와_편집_가능_여부는_그대로다() throws {
        let fixture = try library()
        let loaded = try RekordboxLibrary.load(snapshot: fixture.database)
        let layout = PlaylistLayout(rekordbox: loaded.playlists)
        #expect(layout.childIDs(of: "20") == ["10", "30", "31", "32", "33"])
        for id in ["30", "31", "32", "33"] {
            let item = try #require(layout.item(id))
            #expect(item.isSmart && !item.isFolder && !item.holdsTracks && item.entries.isEmpty, "\(id)")
        }
        #expect(try #require(layout.item("10")).holdsTracks)
        // 사이드바 트리: 인텔리전트 목록은 곡을 들지 않고, 폴더 곡 모음에도 끼지 않는다
        let outline = PlaylistOutlineNode.tree(layout)
        let folder = try #require(outline.first)
        #expect(folder.children?.map(\.isSmart) == [false, true, true, true, true])
        #expect(folder.children?.dropFirst().allSatisfy { $0.trackIDs.isEmpty } == true)
        #expect(folder.trackIDs == ["101", "102"])
    }

    @Test func 조건_칸_글자는_쓰기_모듈의_목록_읽기와_같은_구조를_준다() throws {
        // 쓰기 쪽이 읽은 모양(초안 base)과 읽기 쪽 모양이 어긋나면 초안이 모두 '바뀐 목록'으로 막힌다
        let fixture = try library()
        let db = try fixture.open()
        defer { db.close() }
        let written = try RekordboxWriter.PlaylistTree.read(db).layout
        let read = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        #expect(written == read)
    }
}
