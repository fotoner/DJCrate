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

    @Test func NFS가_여는_폴더는_곡_경로의_앞_세_단계다() {
        // DJLinkKit `Files.exports`: 앞 세 단계 아래에 무엇이 더 있을 때만 폴더를 연다(얕은 경로는 그 파일 하나만)
        let roots = LinkExportServer.exportRoots(trackPaths: ["/Users/dj/Music/a.mp3", "/Users/dj/Music/sub/b.flac",
                                                              "/Volumes/Ext/Music/c.flac", "/Volumes/Ext/d.mp3"])
        #expect(roots == ["/Users/dj/Music", "/Volumes/Ext/Music"])
        #expect(LinkExportServer.isExported("/Users/dj/Music/DJCrate/LINK/a.wav", roots: roots))
        #expect(!LinkExportServer.isExported("/Users/other/Music/DJCrate/LINK/a.wav", roots: roots))
        #expect(!LinkExportServer.isExported("/Users/dj/Music", roots: roots))
    }

    @Test func 바꾼_파일이_연_폴더_밖이면_곡_정보의_경로는_원본_그대로_둔다() {
        // #287: 외장 디스크의 곡만 내어 주면 ~/Music 아래 변환본은 NFS가 찾지 못한다. 원본 이름으로 내어 주므로 경로를 바꾸지 않는다
        let wav = "/Users/dj/Music/DJCrate/LINK/c-1.wav"
        let outside = LinkExportServer.exportRoots(trackPaths: ["/Volumes/Ext/Music/c.flac"])
        #expect(LinkExportServer.servedPath(original: "/Volumes/Ext/Music/c.flac", substitute: wav, roots: outside) == "/Volumes/Ext/Music/c.flac")
        // 음악 폴더의 곡이 하나라도 있으면 변환본 경로를 그대로 준다(CDJ-2000nexus 실기로 확인한 길)
        let inside = LinkExportServer.exportRoots(trackPaths: ["/Volumes/Ext/Music/c.flac", "/Users/dj/Music/a.mp3"])
        #expect(LinkExportServer.servedPath(original: "/Volumes/Ext/Music/c.flac", substitute: wav, roots: inside) == wav)
    }
}
