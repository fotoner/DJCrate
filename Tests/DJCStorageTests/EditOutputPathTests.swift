import DJCStorage
import Foundation
import Testing

struct EditOutputPathTests {
    let music = URL(filePath: "/Users/someone/Music")

    @Test func 편집본은_음악_폴더의_DJCrate_편집본에_둔다() {
        let url = DJCPaths.editOutput(environment: [:], music: music)
        #expect(url.path == "/Users/someone/Music/DJCrate 편집본")
    }

    /// 테스트·자가 테스트가 사용자 음악 폴더에 파일을 만들지 않게 한다.
    @Test func DJC_HOME을_주면_그_아래_edits에_둔다() {
        let url = DJCPaths.editOutput(environment: ["DJC_HOME": "/tmp/djc-test"], music: music)
        #expect(url.path == "/tmp/djc-test/edits")
    }

    @Test func 빈_DJC_HOME은_없는_것으로_본다() {
        let url = DJCPaths.editOutput(environment: ["DJC_HOME": ""], music: music)
        #expect(url.path == "/Users/someone/Music/DJCrate 편집본")
    }
}
