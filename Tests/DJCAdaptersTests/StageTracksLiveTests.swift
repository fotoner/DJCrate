import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// 추가한 곡의 키(#124)를 실제 포트(음원 태그·조성 분석)로: 파일 태그에 키가 있으면 그것, 없으면 조성 추정.
@Suite("추가한 곡 키 — 실제 음원")
struct StageTracksLiveTests {
    static func stage() -> StageTracks {
        StageTracks(files: .live, analysis: .live, drafts: MemoryDrafts().store, source: .memory([:]), today: { "2026-10-09" },
                    staging: StagingStore(tracks: { [] }, save: { _ in }), imports: .none, newKey: { "key" })
    }

    @Test func 태그가_없으면_합성_음원의_조성을_추정한다() async throws {
        let folder = try TemporaryFolder(prefix: "djc-staged-key")
        let directory = folder.url
        let stage = Self.stage()
        let minor = try ChordFixture.wav(ChordFixture.aMinor, seconds: 30, in: directory, name: "a-minor.wav")
        let found = try #require(await stage.key(fileAt: minor, grid: nil, offset: 0, duration: 30, cacheKey: nil))
        #expect(found.key == "8A" && found.source == .estimate)
        let major = try ChordFixture.wav(ChordFixture.dMajor, seconds: 30, in: directory, name: "d-major.wav")
        #expect(await stage.key(fileAt: major, grid: nil, offset: 0, duration: 30, cacheKey: nil)?.key == "10B")
        // 태그가 있으면 추정하지 않는다.
        let tagged = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), textFrames: [("TKEY", "C#m")],
                                          in: directory, name: "tagged.mp3")
        let fromTag = await stage.key(fileAt: tagged, grid: nil, offset: 0, duration: 1, cacheKey: nil)
        #expect(fromTag?.key == "12A" && fromTag?.source == .tag)
        // 읽을 수 없는 파일은 표시하지 않고 다음에 다시 본다.
        #expect(await stage.key(fileAt: directory.appending(path: "없음.wav"), grid: nil, offset: 0, duration: 1, cacheKey: nil) == nil)
    }
}
