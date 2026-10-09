#if DEBUG
@testable import DJCrate
import DJCTestKit
import RekordboxFixtures
import DJCStorage
import Foundation
import Testing

@MainActor
@Suite("히스토리 자가 테스트 격리")
struct HistorySelfTestTests {
    @Test func 저장소를_만들기_전에_격리_환경과_명시한_사본을_확인한다() throws {
        let fixture = try RekordboxFixture()
        #expect(throws: (any Error).self) { try HistorySelfTest.startupDatabase(arguments: ["DJCrate", "--history-selftest"], environment: [:]) }
        let env = ["DJC_HOME": fixture.root.path, "DJC_REKORDBOX_DIR": fixture.root.path]
        #expect(throws: (any Error).self) { try HistorySelfTest.startupDatabase(arguments: ["DJCrate", "--history-selftest"], environment: env) }
        #expect(throws: (any Error).self) { try HistorySelfTest.startupDatabase(arguments: ["DJCrate", "--history-selftest", "--db", fixture.database.path], environment: env) }
        let snapshot = fixture.root.appending(path: "history-snapshot.db")
        try FileManager.default.copyItem(at: fixture.database, to: snapshot)
        let database = try HistorySelfTest.startupDatabase(arguments: ["DJCrate", "--history-selftest", "--db", snapshot.path], environment: env)
        #expect(database.path == UsbScratchPath.realPath(fixture.database.path))
    }

    @Test func 읽은_합성_사본과_다른_쓰기_대상을_거부한다() throws {
        let source = try RekordboxFixture(), other = try RekordboxFixture()
        // 픽스처는 한 틀을 복사해 처음엔 바이트가 같다. 다른 합성 DB가 되게 곡 하나를 더한다
        try other.add(TrackSpec())
        #expect(try HistorySelfTest.checkedDatabase(source.database, snapshot: source.database).path == UsbScratchPath.check(source.database.path, as: .existingFile))
        let snapshot = source.root.appending(path: "read.db")
        try FileManager.default.copyItem(at: source.database, to: snapshot)
        #expect(try HistorySelfTest.checkedDatabase(source.database, snapshot: snapshot).path == UsbScratchPath.realPath(source.database.path))
        #expect(throws: (any Error).self) { try HistorySelfTest.checkedDatabase(other.database, snapshot: source.database) }
    }

    @Test func 라이브_DB로_이어지는_심볼릭_링크와_하드_링크를_거부한다() throws {
        // 실제 라이브러리 대신 별도 합성 파일을 라이브 자리로 주입한다.
        let fakeLive = try RekordboxFixture(), target = try RekordboxFixture()
        let symbolic = target.root.appending(path: "symbolic.db"), hard = target.root.appending(path: "hard.db")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fakeLive.database)
        try FileManager.default.linkItem(at: fakeLive.database, to: hard)
        for database in [symbolic, hard] {
            #expect(throws: (any Error).self) { try HistorySelfTest.checkedDatabase(database, liveDatabase: fakeLive.database) }
        }
    }
}
#endif
