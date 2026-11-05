import DJCDomain
import DJCEnvironment
import Foundation
import Testing

/// #195: 파형·분석·음량 캐시가 `DJC_HOME`을 따른다. `DJC_HOME`이 없을 때의 경로는 설치한 앱이 쓰던 그대로여야 한다(캐시를 잃지 않게).
@Suite("캐시 위치")
struct CachePathsTests {
    /// 설치한 앱이 지금까지 쓰던 사용자 폴더. 폴더를 열지 않고 경로 글자만 비교한다.
    let userSupport = NSHomeDirectory() + "/Library/Application Support/DJCrate"

    @Test func 실제_사용자_폴더_경로가_바이트_단위로_그대로다() {
        #expect(DJCIdentity.userSupportDirectory.path == userSupport)
    }

    @Test func DJC_HOME이_없으면_캐시는_옛_경로_그대로다() {
        for environment in [[:], ["DJC_HOME": ""]] as [[String: String]] {
            let root = DJCIdentity.dataDirectory(environment: environment, support: DJCIdentity.userSupportDirectory)
            let paths = DJCCachePaths(root: root)
            #expect(root.path == userSupport)
            #expect(paths.waveforms.path == userSupport + "/waveforms")
            #expect(paths.analysis.path == userSupport + "/analysis")
            #expect(paths.loudness.path == userSupport + "/loudness.json")
        }
    }

    @Test func DJC_HOME이_있으면_같은_모양으로_그_아래에_둔다() {
        let home = "/private/tmp/djc-home-\(UUID())"
        let support = URL(filePath: "/private/tmp/not-used-support")
        let root = DJCIdentity.dataDirectory(environment: ["DJC_HOME": home], support: support)
        let paths = DJCCachePaths(root: root)
        #expect(root.path == home)
        #expect(paths.waveforms.path == home + "/waveforms")
        #expect(paths.analysis.path == home + "/analysis")
        #expect(paths.loudness.path == home + "/loudness.json")
        #expect(![paths.waveforms, paths.analysis, paths.loudness].contains { $0.path.hasPrefix(support.path) })
    }

    /// 시험·자가 테스트가 실제 사용자 폴더에 캐시를 쓰지 않는다: 이 프로세스의 기본 캐시 위치가 사용자 폴더 밖이다.
    @Test func 시험_프로세스의_캐시는_실제_사용자_폴더_밖이다() {
        let current = DJCCachePaths.current
        for url in [current.waveforms, current.analysis, current.loudness] {
            #expect(!url.path.hasPrefix(userSupport + "/"), "\(url.path)")
        }
        // LINK WAV 변환본은 사용자 음악 폴더에 쓰지 않는다(#287)
        #expect(!current.linkAudio.path.hasPrefix(NSHomeDirectory() + "/Music/"), "\(current.linkAudio.path)")
    }

    @Test func LINK_WAV_변환본은_음악_폴더에_두고_DJC_HOME이_있으면_그_아래에_둔다() {
        // CDJ가 NFS로 읽으므로 음원이 보통 있는 ~/Music 아래다(#277). 데이터 폴더(DJC_HOME)를 따르지 않으면 자가 테스트가 사용자 음악 폴더에 썼다
        let music = URL(filePath: NSHomeDirectory() + "/Music/DJCrate/LINK")
        for environment in [[:], ["DJC_HOME": ""]] as [[String: String]] {
            #expect(DJCIdentity.linkAudioDirectory(environment: environment, fallback: music) == music)
        }
        let home = "/private/tmp/djc-home-\(UUID())"
        #expect(DJCIdentity.linkAudioDirectory(environment: ["DJC_HOME": home], fallback: music).path == home + "/link-audio")
    }

    /// 실물 USB 거부 목록(`usb-physical-deny.json`)은 `supportDirectory`에 고정이다. 안전 목록이라 `DJC_HOME`을 따라가면 안 된다.
    @Test func supportDirectory는_DJC_HOME을_따라가지_않는다() {
        #expect(DJCIdentity.supportDirectory == TestProcess.sandbox.appending(path: "support"))
        let root = DJCIdentity.dataDirectory(environment: ["DJC_HOME": "/private/tmp/x"], support: DJCIdentity.supportDirectory)
        #expect(root.path == "/private/tmp/x")
    }
}
