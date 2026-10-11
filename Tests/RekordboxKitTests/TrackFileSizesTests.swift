import Foundation
import RekordboxFixtures
import Testing
@testable import RekordboxKit

/// 곡 행의 파일 크기 읽기(#62): 후보를 크기로 맞출 때 쓴다. 사본 DB를 읽기만 한다.
@Suite("곡 행 파일 크기")
struct TrackFileSizesTests {
    @Test func 요청한_곡의_크기만_읽고_0이거나_지운_곡은_뺀다() throws {
        let fixture = try RekordboxFixture()
        for id in ["1", "2", "3", "4"] { try fixture.add(TrackSpec(id: id)) }
        try fixture.execute("UPDATE djmdContent SET FileSize = 123456 WHERE ID = '1'")
        try fixture.execute("UPDATE djmdContent SET FileSize = 0 WHERE ID = '2'")
        try fixture.execute("UPDATE djmdContent SET FileSize = 777, rb_local_deleted = 1 WHERE ID = '3'")
        try fixture.execute("UPDATE djmdContent SET FileSize = 999 WHERE ID = '4'")

        let sizes = try TrackFileSizes.load(snapshot: fixture.database, trackIDs: ["1", "2", "3"])
        #expect(sizes == ["1": 123_456])
    }

    @Test func 곡을_하나도_요청하지_않으면_DB를_열지_않고_빈_사전이다() throws {
        // 없는 경로를 줘도 열지 않으므로 던지지 않는다
        #expect(try TrackFileSizes.load(snapshot: URL(filePath: "/nonexistent/master.db"), trackIDs: []).isEmpty)
    }

    @Test func 큰_파일_크기도_64비트로_읽는다() throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.execute("UPDATE djmdContent SET FileSize = 5368709120 WHERE ID = '1'")
        #expect(try TrackFileSizes.load(snapshot: fixture.database, trackIDs: ["1"]) == ["1": 5_368_709_120])
    }
}
