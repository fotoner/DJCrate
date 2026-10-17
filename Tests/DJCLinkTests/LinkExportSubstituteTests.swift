@testable import DJCLink
import Testing

/// FLAC·ALAC을 WAV로 바꿔 끼울 때(#277): 같은 음원을 가리키는 곡이 여럿이면 경로·형식·곡 정보를 모두 함께 바꾼다(PR #279 리뷰).
/// 경로만 모두 바꾸고 형식은 한 곡만 바꾸면 나머지 곡이 WAV 경로를 FLAC 형식으로 내보낸다.
@Suite("LINK WAV 바꿔 끼우기")
struct LinkExportSubstituteTests {
    @Test func 같은_원본을_가리키는_행과_곡_id를_모두_고른다() {
        let paths = ["/m/a.flac", "/m/b.mp3", "/m/a.flac", "/m/c.flac"]
        let ids: [UInt64] = [11, 12, 13, 14]
        let shared = LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 0)
        #expect(shared.map(\.row) == [0, 2])
        #expect(shared.map(\.id) == ["11", "13"])
        #expect(LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 3).map(\.id) == ["14"])
        #expect(LinkExportServer.substitutionTargets(paths: paths, ids: ids, of: 9).isEmpty)
    }
}
