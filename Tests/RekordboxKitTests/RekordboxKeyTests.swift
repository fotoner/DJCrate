@testable import RekordboxKit
import Testing

@Suite("rekordbox 키")
struct RekordboxKeyTests {
    @Test func 키_복호화() throws {
        let key = try RekordboxKey.derive()
        #expect(key.count == 64)
        #expect(key.hasPrefix("402fd"))
    }
}
