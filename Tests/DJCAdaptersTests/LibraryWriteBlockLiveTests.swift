import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 앱이 라이브러리를 읽은 뒤 보는 쓰기 막힘 판정(#327)은 `djc compat`와 같은 입력이면 같은 결과다.
/// 합성 사본(구조만 있는 7.2.18 DB)을 맞는 모양·버전 밖·구조 다름·DB 버전 다름·카운터 뒤짐으로 만들고, 조립 지점과 같은 실제 포트
/// (`LibraryPorts.live`)로 앱 판정을 해 `djc compat`가 쓰는 확인(`CLIComposition.compatibilityCheck`와 같은 `CompatibilityPorts.live`)과 견준다.
/// 설치된 rekordbox 버전만 두 쪽에 같은 값으로 바꿔 넣는다(이 Mac의 설치와 상관없게). 라이브 DB는 열지 않는다(사본만 준다).
@Suite("쓰기 막힘 판정 — djc compat와 같다(실제)")
struct LibraryWriteBlockLiveTests {
    enum Case: String, CaseIterable, Sendable {
        case verified, unsupportedVersion, schema, databaseVersion, counters

        var installed: String { self == .unsupportedVersion ? "7.3.1" : "7.2.18.0311" }

        /// 앱이 보일 이유(맞는 모양이면 nil)
        var expected: LibraryWriteBlock? {
            switch self {
            case .verified: nil
            case .unsupportedVersion: .unsupportedVersion("7.3.1")
            case .schema, .databaseVersion: .schema
            case .counters: .counters
            }
        }

        /// `djc compat`가 막히기 전에 알리는 줄 수(앱 → 구조 → 카운터)
        var findingsBeforeStop: Int {
            switch self {
            case .verified, .counters: 3
            case .unsupportedVersion, .schema, .databaseVersion: 1
            }
        }

        func prepare(_ fixture: RekordboxFixture) throws {
            switch self {
            case .verified, .unsupportedVersion: break
            case .schema: try fixture.execute("ALTER TABLE djmdCue ADD COLUMN LayoutExtra TEXT")
            case .databaseVersion: try fixture.execute("UPDATE djmdProperty SET DBVersion = '7000'")
            case .counters:
                // 합성 사본에 클라우드 동기화 카운터 정수 칸 하나만 넣는다(로컬 1000 < 클라우드 5000)
                try fixture.execute("INSERT INTO agentRegistry (registry_id, int_1, created_at, updated_at) VALUES ('lastUpdateCount', 5000, ?, ?)",
                                    [.text("2026-10-29 00:00:00.000 +00:00"), .text("2026-10-29 00:00:00.000 +00:00")])
            }
        }
    }

    @Test(arguments: Case.allCases)
    func 앱_판정은_djc_compat와_같은_자리에서_막힌다(_ scenario: Case) throws {
        let fixture = try RekordboxFixture()
        try scenario.prepare(fixture)
        let folder = try TemporaryFolder(prefix: "djc-write-block")
        let snapshot = folder.url.appending(path: "master-2026-10-29T000000.db")
        try FileManager.default.copyItem(at: fixture.database, to: snapshot)

        // djc compat
        var compat = CompatibilityPorts.live
        compat.installedAppVersion = { scenario.installed }
        var findings: [CompatibilityCheck.Finding] = []
        var refused = false
        do { try CompatibilityCheck(ports: compat).run(database: snapshot) { findings.append($0) } } catch { refused = true }

        // 앱: 조립 지점과 같은 실제 라이브러리 포트
        let location = LibraryLocation(rekordboxDirectory: folder.url, rekordboxDirectoryOverridden: true, snapshotDirectory: folder.url,
                                       opensExplicitCopy: false, explicitCopy: nil, database: folder.url.appending(path: "master.db"),
                                       shareRoot: nil, backupDirectory: folder.url.appending(path: "backups"),
                                       draftHome: folder.url.appending(path: "home"), movesDamagedDrafts: false)
        var ports = LibraryPorts.live(location: location, drafts: .live(writer: DraftWriter(), home: location.draftHome),
                                      batches: .live(url: folder.url.appending(path: "reflection.json")))
        ports.compatibility.installedAppVersion = { scenario.installed }
        let block = LibraryUseCases(ports: ports).load.writeBlock(snapshot: snapshot, backupDirectory: location.backupDirectory)

        #expect(refused == (scenario != .verified))
        #expect(findings.count == scenario.findingsBeforeStop)
        #expect(block == scenario.expected)
    }

    @Test func 백업_폴더에_쓸_수_없으면_compat를_통과해도_백업_폴더를_알린다() throws {
        let fixture = try RekordboxFixture()
        let folder = try TemporaryFolder(prefix: "djc-write-block-backup")
        let snapshot = folder.url.appending(path: "master-2026-10-29T000000.db")
        try FileManager.default.copyItem(at: fixture.database, to: snapshot)
        let locked = folder.url.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var compat = CompatibilityPorts.live
        compat.installedAppVersion = { "7.2.18" }
        let load = LoadLibrary(source: .live, music: .live(rekordboxDirectory: folder.url), drafts: .live(writer: DraftWriter(), home: folder.url),
                               order: ITunesRefreshCoordinator(), snapshots: SnapshotTaker { _ in snapshot },
                               usbSnapshots: UsbSyncSnapshots(stamp: { _ in throw DJCError.snapshotNotFound },
                                                              lease: { _, _ in throw DJCError.snapshotNotFound }),
                               compatibility: CompatibilityCheck(ports: compat), backups: .live())

        #expect(load.writeBlock(snapshot: snapshot, backupDirectory: locked.appending(path: "rekordbox-backups")) == .backupFolder)
        #expect(load.writeBlock(snapshot: snapshot, backupDirectory: folder.url.appending(path: "rekordbox-backups")) == nil)
    }
}
