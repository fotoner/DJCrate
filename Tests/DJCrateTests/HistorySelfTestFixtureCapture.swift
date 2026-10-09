import DJCStorage
import DJCTestKit
import RekordboxFixtures
import Foundation
import RekordboxKit
import Testing

/// 히스토리 앱 자가 테스트용 사본. 음원·USB·사용자 데이터는 열지 않는다.
struct HistorySelfTestFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_HISTORY_SELFTEST_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_HISTORY_SELFTEST_FIXTURE"] else { return }
        let root = URL(filePath: try UsbScratchPath.check(path, as: .outputDirectory))
        let fixture = try historyFixture()
        try fixture.execute("UPDATE djmdContent SET Title = '히스토리 시험 ' || ID, rb_data_status = 0, DJPlayCount = 0, MasterSongID = ID, FileNameL = 'history-' || ID || '.mp3'")
        try fixture.insert("djmdHistory", ["ID": .text("2026"), "Name": .text("2026"), "Attribute": .int(1),
                                          "ParentID": .text("root"), "Seq": .int(1), "UUID": .text("2026"), "rb_local_deleted": .int(0)])
        try FileManager.default.createDirectory(at: fixture.shareRoot.appending(path: "PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: fixture.root.appending(path: "history-snapshot.db"))
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
