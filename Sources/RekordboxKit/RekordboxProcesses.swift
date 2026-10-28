import DJCDomain
import Darwin
import Foundation

/// 쓰기 관문의 rekordbox 실행 확인(#323). 이름마다 `pgrep -x`를 띄운다(앱 감지 서비스의 프로세스 목록 읽기와 서로 다른 길로 본다).
/// 띄우지 못하거나, 종료 코드가 0(있음)·1(없음) 밖이거나, 신호로 끝나거나, 시간 안에 끝나지 않으면 '모름'이고 켜진 것으로 다룬다.
/// 전에는 이때 꺼진 것으로 봐 관문이 열렸다.
public struct RekordboxProcessCheck: Sendable {
    /// 이름 하나를 찾아본 결과
    public enum Probe: Sendable, Equatable {
        /// 끝났다(pgrep: 0 있음, 1 없음, 그 밖은 오류)
        case exited(Int32)
        /// 신호로 끝났다(종료 코드가 아니다)
        case signaled
        /// 띄우지 못했다
        case launchFailed
        /// 시간 안에 끝나지 않았다(남은 프로세스는 끝낸다)
        case timedOut
    }

    /// pgrep 하나를 기다리는 시간
    public static let timeout: Duration = .seconds(2)

    /// 이름 하나를 찾는 실행부(시험은 가짜를 준다)
    public var probe: @Sendable (String) -> Probe

    public init(probe: @escaping @Sendable (String) -> Probe) {
        self.probe = probe
    }

    /// `executable -x 이름`을 띄운다. 시험은 다른 실행 파일·짧은 시간을 준다
    public static func pgrep(executable: URL = URL(filePath: "/usr/bin/pgrep"), timeout: Duration = timeout) -> Self {
        Self { name in run(executable, ["-x", name], timeout: timeout) }
    }

    /// 앱·CLI의 관문이 쓰는 확인
    public static let system = pgrep()

    /// 이름 목록 차례로 본다. 켜진 rekordbox를 찾거나 확인하지 못하면 거기서 멈춘다(어느 쪽이든 막으므로 띄우는 수를 늘리지 않게)
    public func state() -> RekordboxRunState {
        var found: [String] = []
        for name in RekordboxRunState.processNames {
            switch probe(name) {
            case .exited(0): found.append(name)
            case .exited(1): break
            default: return .unknown
            }
            if RekordboxRunState(runningNames: found) == .running { break }
        }
        return RekordboxRunState(runningNames: found)
    }

    /// 쓰기를 막는가(꺼짐만 막지 않는다)
    public func isRunning() -> Bool { state().blocksWrites }

    /// 끝 알림을 세마포어로 기다린다(메인 스레드에서 불러도 런 루프 없이 받는다). 시간을 넘기면 띄운 PID에만 SIGKILL을 보내고 거둔다
    static func run(_ executable: URL, _ arguments: [String], timeout: Duration) -> Probe {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .launchFailed }
        let parts = timeout.components
        guard finished.wait(timeout: .now() + Double(parts.seconds) + Double(parts.attoseconds) / 1e18) == .success else {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
            return .timedOut
        }
        return process.terminationReason == .exit ? .exited(process.terminationStatus) : .signaled
    }
}

/// 앱 감지 서비스의 프로세스 목록 읽기(#323). 프로세스를 띄우지 않고 커널의 프로세스 표(sysctl `KERN_PROC_ALL`)를 읽는다.
/// 프로세스마다 커널의 짧은 이름(`p_comm`, 16바이트까지)과 첫 인자(argv[0])의 마지막 경로 이름을 함께 센다.
/// `pgrep -x`는 첫 인자의 이름을 본다(링크·`exec -a`로 띄우면 `p_comm`과 다르다). 둘 다 세면 관문이 켜짐으로 볼 때 이 목록도 켜짐으로 본다.
public enum RekordboxProcessList {
    /// 이 Mac의 모든 프로세스 이름. 읽지 못하면 nil
    public static func names() -> [String]? {
        guard let procs = processTable() else { return nil }
        // 인자는 프로세스마다 읽는다. 인자 영역의 최대 크기(`KERN_ARGMAX`) 버퍼 하나를 돌려 쓴다
        var argMax: Int32 = 0, length = MemoryLayout<Int32>.size
        var argMaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let hasArgMax = sysctl(&argMaxMIB, u_int(argMaxMIB.count), &argMax, &length, nil, 0) == 0 && argMax > 0
        var buffer = [UInt8](repeating: 0, count: hasArgMax ? Int(argMax) : 0)
        return procs.flatMap { proc -> [String] in
            let comm = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard hasArgMax, let first = firstArgument(pid: proc.kp_proc.p_pid, buffer: &buffer),
                  let base = first.split(separator: "/").last.map(String.init), base != comm else { return [comm] }
            return [comm, base]
        }
    }

    /// 프로세스 표. 크기를 물은 뒤 읽는 사이 프로세스가 늘면 ENOMEM이다. 여유를 두고 몇 번 다시 읽는다
    static func processTable() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            var bytes = procs.count * stride
            let result = procs.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &bytes, nil, 0) }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return Array(procs.prefix(bytes / stride))
        }
        return nil
    }

    /// 프로세스의 첫 인자(`KERN_PROCARGS2`). 다른 사용자의 프로세스·끝난 프로세스처럼 읽지 못하면 nil
    static func firstArgument(pid: pid_t, buffer: inout [UInt8]) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }) == 0 else { return nil }
        return firstArgument(in: buffer.prefix(size))
    }

    /// `KERN_PROCARGS2` 모양에서 첫 인자를 꺼낸다: 인자 수(Int32) 다음에 실행 경로, NUL 채움, 인자들이 온다
    static func firstArgument(in bytes: ArraySlice<UInt8>) -> String? {
        var index = bytes.startIndex + MemoryLayout<Int32>.size
        guard index < bytes.endIndex else { return nil }
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        let start = index
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        return index > start ? String(decoding: bytes[start..<index], as: UTF8.self) : nil
    }

    /// 프로세스 목록으로 판정한다. 읽지 못하면 '모름'
    public static func state(names: () -> [String]? = names) -> RekordboxRunState {
        names().map { RekordboxRunState(runningNames: $0) } ?? .unknown
    }
}
