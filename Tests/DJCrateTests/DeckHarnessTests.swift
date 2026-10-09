@testable import DJCrate
import DJCDomain
import Foundation
import Testing

@Suite("덱 테스트 재료")
@MainActor
struct DeckHarnessTests {
    @Test func DB와_음원_없이_독립된_폴더를_준비하고_정리한다() async throws {
        var first: DeckHarness? = try DeckHarness()
        let second = try DeckHarness()
        try await first?.loaded()
        try await second.loaded()
        let firstRoot = try #require(first?.root)
        #expect(firstRoot != second.root)
        #expect(first?.deck.canPlay == true && second.deck.canPlay)
        #expect(!FileManager.default.fileExists(atPath: firstRoot.appending(path: "master.db").path))
        #expect(!FileManager.default.fileExists(atPath: try #require(first?.deck.row).track.folderPath))

        first = nil
        #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
        #expect(FileManager.default.fileExists(atPath: second.root.path))
    }
}
