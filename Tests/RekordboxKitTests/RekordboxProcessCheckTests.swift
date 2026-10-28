import DJCDomain
import Foundation
@testable import RekordboxKit
import Synchronization
import Testing

/// 쓰기 관문의 rekordbox 실행 확인(#323): 확인하지 못하면(띄우지 못함·종료 코드 0·1 밖·신호·시간 초과) 켜진 것으로 본다.
/// 전에는 꺼진 것으로 봐 관문이 열렸다. 실행부는 주입한다. 실제 프로세스 시험은 임시 폴더의 스크립트와 고유한 이름의 프로세스만 찾아
/// 이 Mac의 rekordbox 실행 여부에 흔들리지 않는다. 시간 초과를 보지 않는 시험은 넉넉한 시간(`patient`)을 줘 부하에도 결과가 같다(TEST-30)
@Suite("rekordbox 실행 확인")
struct RekordboxProcessCheckTests {
    /// 이름마다 정한 결과를 돌려주고 물은 이름을 남기는 가짜 실행부
    final class Probes: Sendable {
        let answers: [String: RekordboxProcessCheck.Probe]
        let asked = Mutex<[String]>([])
        init(_ answers: [String: RekordboxProcessCheck.Probe]) { self.answers = answers }
        var check: RekordboxProcessCheck {
            RekordboxProcessCheck { [self] name in
                asked.withLock { $0.append(name) }
                return answers[name] ?? .exited(1)
            }
        }
    }

    static let failures: [RekordboxProcessCheck.Probe] = [.launchFailed, .exited(2), .exited(3), .signaled, .timedOut]
    /// 시간 초과를 보지 않는 실제 실행의 시간 제한
    static let patient: Duration = .seconds(60)

    @Test func 확인하지_못하면_켜진_것으로_본다() {
        for failure in Self.failures {
            let rekordbox = Probes(["rekordbox": failure])
            #expect(rekordbox.check.state() == .unknown, "\(failure)")
            // 어느 쪽이든 막으므로 rekordboxAgent는 띄워 보지 않는다(띄우는 수를 늘리지 않는다)
            #expect(rekordbox.asked.withLock { $0 } == ["rekordbox"], "\(failure)")
            #expect(rekordbox.check.isRunning(), "\(failure)")
            let agent = Probes(["rekordbox": .exited(1), "rekordboxAgent": failure])
            #expect(agent.check.state() == .unknown, "\(failure)")
            #expect(agent.check.isRunning(), "\(failure)")
        }
    }

    @Test func Agent만_켜져_있으면_Agent다() {
        let probes = Probes(["rekordbox": .exited(1), "rekordboxAgent": .exited(0)])
        #expect(probes.check.state() == .agentOnly)
        #expect(probes.check.isRunning())
    }

    @Test func 둘_다_없으면_꺼짐이다() {
        let probes = Probes(["rekordbox": .exited(1), "rekordboxAgent": .exited(1)])
        #expect(probes.check.state() == .stopped)
        #expect(probes.asked.withLock { $0 } == ["rekordbox", "rekordboxAgent"])
        #expect(!probes.check.isRunning())
    }

    @Test func rekordbox가_켜져_있으면_Agent는_보지_않는다() {
        let probes = Probes(["rekordbox": .exited(0), "rekordboxAgent": .exited(1)])
        #expect(probes.check.state() == .running)
        #expect(probes.asked.withLock { $0 } == ["rekordbox"])
    }

    // MARK: - 실제 프로세스(주입한 실행 파일)

    /// 임시 폴더에 실행할 수 있는 sh 스크립트를 만든다. `$2`는 찾는 이름이다(`-x 이름`)
    static func script(_ body: String, in folder: TemporaryFolder) throws -> URL {
        let url = folder.url.appending(path: "probe")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func 띄우지_못하면_켜짐이다() throws {
        let folder = try TemporaryFolder()
        let check = RekordboxProcessCheck.pgrep(executable: folder.url.appending(path: "없는-pgrep"))
        #expect(check.state() == .unknown)
    }

    @Test func 종료_코드가_0_1_밖이면_켜짐이다() throws {
        let folder = try TemporaryFolder()
        let check = RekordboxProcessCheck.pgrep(executable: try Self.script("exit 2", in: folder), timeout: Self.patient)
        #expect(check.state() == .unknown)
    }

    @Test func 신호로_끝나면_켜짐이다() throws {
        // SIGHUP(1)으로 끝나도 종료 코드 1(없음)로 읽지 않는다
        let folder = try TemporaryFolder()
        let executable = try Self.script("kill -HUP $$", in: folder)
        #expect(RekordboxProcessCheck.run(executable, ["-x", "rekordbox"], timeout: Self.patient) == .signaled)
        #expect(RekordboxProcessCheck.pgrep(executable: executable, timeout: Self.patient).state() == .unknown)
    }

    /// 600초 잠드는 프로세스는 언제 떠도 300ms 안에 끝나지 않는다. 고유한 이름으로 띄워 끝낸 뒤 목록에서 사라지는지 본다
    @Test func 시간_안에_끝나지_않으면_켜짐이고_그_프로세스를_끝낸다() async throws {
        let folder = try TemporaryFolder()
        let sleeper = try Self.uniqueSleep(in: folder)
        #expect(RekordboxProcessCheck.run(URL(filePath: "/bin/sh"), ["-c", "exec '\(sleeper.path)' 600"], timeout: .milliseconds(300)) == .timedOut)
        #expect(await Self.wait { RekordboxProcessList.names()?.contains(sleeper.lastPathComponent) == false }, "멈춘 프로세스를 남기지 않는다")
        let check = RekordboxProcessCheck.pgrep(executable: try Self.script("exec /bin/sleep 600", in: folder), timeout: .milliseconds(300))
        #expect(check.state() == .unknown)
    }

    @Test func 실제_실행에서도_Agent만_있으면_Agent다() throws {
        let folder = try TemporaryFolder()
        let check = RekordboxProcessCheck.pgrep(executable: try Self.script(#"[ "$2" = rekordboxAgent ]"#, in: folder), timeout: Self.patient)
        #expect(check.state() == .agentOnly)
    }

    /// 메인 스레드에서 불러도 끝 알림을 받는다(반영 세션은 메인 액터에서 관문을 부른다). 끝을 못 받으면 시간 초과로 '모름'이 된다
    @MainActor
    @Test func 메인_스레드에서도_끝을_받는다() throws {
        let folder = try TemporaryFolder()
        let check = RekordboxProcessCheck.pgrep(executable: try Self.script("exit 1", in: folder), timeout: Self.patient)
        #expect(check.state() == .stopped)
    }

    // MARK: - 두 길이 같은 프로세스를 찾는다

    /// 고유한 이름으로 띄운 프로세스를 pgrep과 프로세스 목록이 모두 찾는다(rekordbox 이름은 띄우지 않는다: 이 Mac의 다른 일이 켜진 것으로 본다).
    /// 링크로 띄워 커널 이름(`p_comm`)은 sleep이고 첫 인자의 이름만 고유하다. pgrep이 보는 이름을 목록도 본다
    @Test func pgrep과_프로세스_목록이_같은_이름을_찾는다() async throws {
        let folder = try TemporaryFolder()
        let executable = try Self.uniqueSleep(in: folder)
        let name = executable.lastPathComponent
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "exec '\(executable.path)' 600"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(await Self.wait { RekordboxProcessList.names()?.contains(name) == true })
        #expect(RekordboxProcessCheck.run(URL(filePath: "/usr/bin/pgrep"), ["-x", name], timeout: Self.patient) == .exited(0))
        #expect(process.isRunning, "찾은 것이 끝난 프로세스가 아니다")
        #expect(RekordboxProcessCheck.run(URL(filePath: "/usr/bin/pgrep"), ["-x", name + "x"], timeout: Self.patient) == .exited(1))
    }

    /// /bin/sleep을 가리키는 고유한 이름(16바이트 안)의 링크. 셸이 링크 경로로 exec하면 프로세스 이름이 링크 이름이라 그 프로세스만 찾는다
    /// (시스템 실행 파일을 복사하면 macOS가 띄우자마자 끝낸다. `Process`로 링크를 바로 띄우면 이름이 sleep이 된다)
    static func uniqueSleep(in folder: TemporaryFolder) throws -> URL {
        let executable = folder.url.appending(path: "djc" + String(UInt64.random(in: 0..<(1 << 40)), radix: 16))
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(filePath: "/bin/sleep"))
        return executable
    }

    /// `KERN_PROCARGS2` 모양: 인자 수(Int32) · 실행 경로 · NUL 채움 · 인자들
    @Test func 프로세스_인자에서_첫_인자를_꺼낸다() {
        func layout(_ text: String) -> ArraySlice<UInt8> { ArraySlice([2, 0, 0, 0] + Array(text.utf8)) }
        #expect(RekordboxProcessList.firstArgument(in: layout("/bin/sleep\0\0\0djcx\0600\0")) == "djcx")
        #expect(RekordboxProcessList.firstArgument(in: layout("/Applications/rekordbox 7/rekordbox.app/Contents/MacOS/rekordbox\0/Applications/rekordbox 7/rekordbox.app/Contents/MacOS/rekordbox\0"))
                == "/Applications/rekordbox 7/rekordbox.app/Contents/MacOS/rekordbox")
        #expect(RekordboxProcessList.firstArgument(in: layout("/bin/sleep\0\0")) == nil, "인자가 없다")
        #expect(RekordboxProcessList.firstArgument(in: ArraySlice([2, 0])) == nil, "인자 수도 다 못 읽었다")
    }

    @Test func 프로세스_목록을_읽지_못하면_모름이다() {
        #expect(RekordboxProcessList.state(names: { nil }) == .unknown)
        #expect(RekordboxProcessList.state(names: { ["launchd", "rekordboxAgent"] }) == .agentOnly)
        #expect(RekordboxProcessList.state(names: { ["launchd"] }) == .stopped)
    }

    /// 조건이 참이 될 때까지 기다린다(TEST-30·32: 걸린 시간으로 판정하지 않는다. 300초는 멈추지 않게 하는 안전망이다)
    static func wait(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
