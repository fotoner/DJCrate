import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
@testable import DJCrate
import RekordboxFixtures
import RekordboxKit
import Testing

/// 앱이 뒤에서 남기는 자동 시점 스냅샷(#228). 합성 사본과 그 옆 폴더에만 뜨고, 시각·켜짐·쓰는 중은 주입한다.
@MainActor
@Suite("자동 시점 스냅샷 실행")
struct AutoPointSnapshotRunnerTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    /// 쓰는 중 여부와 받은 알림
    final class Probe {
        var busy = false
        var toasts: [String] = []
        /// rekordbox 쓰기를 시작한 횟수. `writesDuringSnapshot`이면 물을 때마다 늘어 뜨는 동안 쓰기가 끼어든 것처럼 보인다
        var writes = 0
        var writesDuringSnapshot = false
        func writeCount() -> Int {
            if writesDuringSnapshot { writes += 1 }
            return writes
        }
    }

    func runner(_ fixture: RekordboxFixture, enabled: Bool = true, probe: Probe = Probe()) -> AutoPointSnapshotRunner {
        runner(root: fixture.root, enabled: enabled, probe: probe)
    }

    /// DB 내용을 읽기 전에 끝나는 시험은 임시 폴더 경로만 준다
    func runner(root: URL, enabled: Bool = true, probe: Probe = Probe()) -> AutoPointSnapshotRunner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = now
        var files = PointSnapshotFiles.live(guard: Self.copyGuard)
        files.canClone = { _, _ in true }
        return AutoPointSnapshotRunner(environment: .init(
            database: { root.appending(path: "master.db") }, shareRoot: { nil }, snapshots: root.appending(path: "point-snapshots"),
            enabled: { enabled }, autoDays: { 7 }, busy: { probe.busy }, writeCount: { probe.writeCount() }, files: files, now: { now },
            calendar: calendar),
            onFailure: { title, _ in probe.toasts.append(title) })
    }

    func snapshots(_ fixture: RekordboxFixture) -> [RekordboxPointSnapshot.Entry] { snapshots(root: fixture.root) }

    func snapshots(root: URL) -> [RekordboxPointSnapshot.Entry] {
        RekordboxPointSnapshot.list(in: root.appending(path: "point-snapshots"))
    }

    @Test func 켜져_있으면_뒤에서_뜨고_같은_날_다시_불러도_하나뿐이다() async throws {
        let fixture = try RekordboxFixture()
        let runner = runner(fixture)
        guard case .took = await runner.runIfDue() else { Issue.record("뜨지 않았다"); return }
        #expect(await runner.runIfDue() == .skipped(.alreadyToday))
        #expect(snapshots(fixture).map(\.metadata.kind) == [.auto])
    }

    @Test func 설정에서_끄면_뜨지_않는다() async throws {
        let folder = try TemporaryFolder()
        #expect(await runner(root: folder.url, enabled: false).runIfDue() == nil)
        #expect(snapshots(root: folder.url).isEmpty)
    }

    @Test func rekordbox에_쓰는_중이면_미루고_끝나면_뜬다() async throws {
        let fixture = try RekordboxFixture()
        let probe = Probe()
        probe.busy = true
        let runner = runner(fixture, probe: probe)
        #expect(await runner.runIfDue() == nil)
        #expect(snapshots(fixture).isEmpty)
        probe.busy = false
        guard case .took = await runner.runIfDue() else { Issue.record("쓰기가 끝난 뒤에도 뜨지 않았다"); return }
    }

    @Test func 뜨는_동안_DJCrate가_rekordbox에_쓰기_시작하면_그_스냅샷을_버리고_알리지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let probe = Probe()
        probe.writesDuringSnapshot = true
        #expect(await runner(fixture, probe: probe).runIfDue() == nil)
        #expect(snapshots(fixture).isEmpty)
        #expect(probe.toasts.isEmpty)
    }

    @Test func 실패는_확인_창_없이_한_번만_작은_알림으로_알린다() async throws {
        let root = try TemporaryFolder()
        // 링크 거부는 DB 내용을 읽기 전에 일어나 DB는 복사만 되는 아무 바이트 파일이면 된다
        try Data("fake".utf8).write(to: root.url.appending(path: "master.db"))
        // 분석 폴더 안의 심볼릭 링크는 스냅샷이 거부한다(다시 해도 같은 실패)
        let folder = root.url.appending(path: "share/PIONEER/USBANLZ/abc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: URL(filePath: "/etc/hosts"))
        let probe = Probe()
        let runner = runner(root: root.url, probe: probe)
        #expect(await runner.runIfDue() == nil)
        #expect(await runner.runIfDue() == nil)
        #expect(probe.toasts == ["자동 시점 스냅샷을 남기지 못했습니다"])
        #expect(snapshots(root: root.url).isEmpty)
    }

    @Test func 자동_스냅샷은_기본으로_켜져_있다() {
        #expect(SettingKeys.pointSnapshotAuto.defaultValue)
        #expect(SettingKeys.all.contains(SettingKeys.pointSnapshotAuto.name))
    }

    // MARK: 어떤 실행에서 보는가(측정·자가 테스트·캡처 실행에는 디스크 일을 끼우지 않는다)

    /// 앱에 있는 개발용 실행 인자(자가 테스트·측정·화면 캡처). 90초 뒤 디스크 일이 끼면 안 되는 실행들이다.
    nonisolated static let diagnosticArguments = [
        "--resize-perf=all", "--resize-perf=width,height", "--ui-perf=all", "--ui-perf=sidebar,sort", "--ui-perf-capture=/tmp/x", "--scroll-perf",
        "--write-selftest", "--flip-selftest", "--usb-selftest", "--edit-selftest", "--itunes-selftest", "--loop-selftest",
        "--metronome-jump-selftest", "--key-routing-selftest", "--playlist-recovery-selftest", "--hotcue-click-selftest",
        "--xml-export-capture=/tmp/x", "--usb-migrate-capture=/tmp/x", "--async-guidance-capture=/tmp/x",
        "--search-layout-captures=/tmp/x", "--paused-hotcue-captures=/tmp/x", "--perf-capture=/tmp/x", "--autoplay", "--reflection-layout=/tmp/x",
    ]

    /// 조립 지점처럼 실행 인자·환경을 위치 값과 개발용 실행 판정으로 풀어 묻는다
    static func allowed(arguments: [String], environment: [String: String]) -> Bool {
        AutoPointSnapshotRunner.isAllowed(location: LibraryLocation.resolve(arguments: arguments, environment: environment),
                                          diagnosticRun: LibraryLaunchOptions(arguments: arguments).isDiagnosticRun)
    }

    @Test(arguments: diagnosticArguments)
    func 자가_테스트·측정·캡처_실행은_자동_스냅샷을_보지_않는다(argument: String) {
        #expect(!Self.allowed(arguments: ["DJCrate", argument], environment: [:]))
        // 사본 rekordbox 폴더를 줘도, 다른 인자와 함께 줘도 같다
        #expect(!Self.allowed(arguments: ["DJCrate", "--select", "32395449", argument],
                                                   environment: ["DJC_REKORDBOX_DIR": "/tmp/copy"]))
    }

    @Test func 평범한_실행과_곡을_고른_실행은_본다() {
        #expect(Self.allowed(arguments: ["DJCrate"], environment: [:]))
        #expect(Self.allowed(arguments: ["DJCrate", "--select", "32395449"], environment: ["DJC_HOME": "/tmp/home"]))
        // 첫 인자는 실행 파일 경로라 이름에 시험 같은 말이 있어도 상관없다
        #expect(Self.allowed(arguments: ["/tmp/--write-selftest/DJCrate"], environment: [:]))
    }

    @Test func 명시한_사본은_사본_rekordbox_폴더가_있어도_보지_않는다() {
        let copy = ["DJC_REKORDBOX_DIR": "/tmp/copy"]
        #expect(!Self.allowed(arguments: ["DJCrate", "--db", "/tmp/copy/master.db"], environment: copy))
        #expect(!Self.allowed(arguments: ["DJCrate"], environment: copy.merging(["DJC_DB": "/tmp/copy/master.db"]) { $1 }))
        #expect(!Self.allowed(arguments: ["DJCrate", "--db", "/tmp/copy/master.db"], environment: [:]))
        // 사본 폴더만 줬다고 명시한 사본이 되지는 않는다
        #expect(Self.allowed(arguments: ["DJCrate"], environment: copy))
    }

    @Test func 앱이_쓰는_생성자도_그_판단을_따른다() {
        func enabled(_ arguments: [String], environment: [String: String] = [:]) -> Bool {
            // 설정 저장소는 저장하는 쪽이라 실행 인자 판단만 가른다
            let settings = SettingsStore(defaults: TestDefaults.make("autosnap"), persist: true, sharedFile: nil)
            let store = LibraryStore.test(settings: settings, resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                          arguments: arguments, environment: environment, launch: LibraryLaunchOptions(arguments: arguments))
            return AutoPointSnapshotRunner(store: store, snapshots: FileManager.default.temporaryDirectory.appending(path: "djc-autosnap-unused"),
                                           files: .live(guard: Self.copyGuard)).environment.enabled()
        }
        #expect(enabled(["DJCrate"]))
        #expect(!enabled(["DJCrate", "--resize-perf=all"]))
        #expect(!enabled(["DJCrate", "--xml-export-capture=/tmp/x"]))
        #expect(!enabled(["DJCrate", "--db", "/tmp/copy/master.db"], environment: ["DJC_REKORDBOX_DIR": "/tmp/copy"]))
    }
}
