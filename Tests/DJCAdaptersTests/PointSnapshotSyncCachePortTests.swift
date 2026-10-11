import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import RekordboxFixtures
import RekordboxKit
import Testing

/// 가짜 포트가 기대는 실제 구현의 약속. 시점 스냅샷·동기화 설정은 가짜(`MemoryPointSnapshotFiles`·`MemoryUsbSyncPreferences`)와 같은 계약 함수(PortTestKit)를 돌린다
@Suite("시점 스냅샷·동기화·캐시 포트 실제 구현의 약속")
struct PointSnapshotSyncCachePortTests {
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    @Test("시점 스냅샷: 계약(목록·찾기·고정·폴더 밖 거부) — 같은 DB와 견주면 다른 곳이 없고 크기가 있다")
    func pointSnapshotFiles() throws {
        let fixture = try RekordboxFixture()
        let files = PointSnapshotFiles.live(guard: Self.copyGuard)
        let folder = fixture.root.appending(path: "point-snapshots")
        try pointSnapshotFilesContract(files, database: fixture.database, shareRoot: fixture.shareRoot, directory: folder, now: now)
        let entry = try #require(files.list(folder).first)
        #expect(files.size(entry.url) > 0 && !files.isLiveAndRunning(fixture.database) && !files.isRekordboxRunning())
        #expect(try files.compare(entry, fixture.database, fixture.shareRoot).isEmpty)
    }

    @Test("자동 시점 스냅샷: 처음엔 뜨고 같은 날 다시 보면 미루며, 버리면 폴더가 사라진다")
    func autoSnapshot() throws {
        let fixture = try RekordboxFixture()
        let files = PointSnapshotFiles.live(guard: Self.copyGuard)
        let folder = fixture.root.appending(path: "point-snapshots")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard case let .took(entry) = try files.takeAutoIfDue(fixture.database, nil, folder, 7, now, calendar, { _, _ in true }) else {
            Issue.record("뜨지 않았다"); return
        }
        #expect(try files.takeAutoIfDue(fixture.database, nil, folder, 7, now, calendar, { _, _ in true }) == .skipped(.alreadyToday))
        try files.discard(entry.url)
        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
    }

    @Test("동기화 파일: 선택 파일이 없는 USB는 원문이 비고 선택·켜짐이 없으며, 옛 스냅샷의 NODE는 비고, 설정은 계약대로 읽고 쓴다")
    func syncFiles() throws {
        let folder = try TemporaryFolder()
        let usb = folder.url.appending(path: "usb")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        let native = try UsbSyncFiles.live.selection(usb, UsbFormat.defaultSet)
        #expect(native.baseFiles.isEmpty)
        let resolved = native.resolve([], 42, nil, nil)
        #expect(resolved.selection.selectedIDs.isEmpty && resolved.enabled == nil)
        #expect(UsbSyncFiles.live.masterNodes(folder.url.appending(path: "없는-스냅샷.db")).isEmpty)
        let preferences = UsbSyncFiles.live.preferences(folder.url.appending(path: "usb-sync-selections"))
        try usbSyncPreferencesContract(preferences)
        // 볼륨키가 폴더 밖을 가리키면 읽지 않는다(실제 구현만의 안전 규칙)
        #expect(throws: (any Error).self) { try preferences.load("../밖") }
    }

    @Test("캐시 폴더: 용량은 종류 목록 순서로 모두 보이고, 미리 보기 비우기는 고른 종류만 센다")
    func cacheFiles() throws {
        let folder = try TemporaryFolder()
        let paths = DJCCachePaths(root: folder.url)
        #expect(CacheFiles.live.usage(paths).map(\.kind) == DJCCacheKind.allCases)
        #expect(CacheFiles.live.clear([.waveforms], paths, [], true).map(\.kind) == [.waveforms])
        #expect(CacheFiles.live.backupUsage(folder.url).allSatisfy { $0.count == 0 })
    }
}
