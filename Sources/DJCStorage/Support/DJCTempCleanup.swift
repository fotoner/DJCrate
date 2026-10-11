import DJCDomain
import Darwin
import DJCEnvironment
import Foundation
import RekordboxKit

/// 비정상 종료·강제 종료 뒤 남은 임시 파일·폴더 청소(#219). 앱이 켜질 때 뒤에서 조용히 돌고, 지운 것은 로그에만 남긴다.
/// 지우는 자리는 아래 다섯뿐이다. 초안·추가 목록·백업·USB 저널·허용·거부 목록은 이름도 읽지 않는다.
/// - 데이터 폴더의 `preview-waveforms.plist.sb-*`: 원자적 저장이 끊긴 임시 파일(다음 저장이 새 이름을 쓴다)
/// - `$TMPDIR/djc-preview-<UUID>/`: 쓰기 미리 보기의 DB 사본. 주인 pid가 이름에 없어 오래된 것만(`defer`가 못 지운 것)
/// - `$TMPDIR/djc-test-sandbox-<pid>/`: 시험 프로세스의 임시 폴더. 그 pid가 살아 있지 않을 때만
/// - USB 동기화 전용 DB 사본 `$TMPDIR/djc-usb-sync-snapshots/<pid>-<UUID>/`(`DJC_HOME`이 있으면 `<데이터 폴더>/usb-sync-snapshots/`):
///   클라우드 토큰이 든 사본이라 앱이 죽어 남은 것을 치운다. 그 pid가 살아 있지 않을 때만, pid가 없는 옛 이름은 하루 지난 것만
/// - `usb-staging/<세션>[-verify]/`: 회복용이라 pid가 아니라 저널로 판단한다. 닫히지 않은 저널이 가리키면 남기고,
///   읽지 못하는 저널이 있거나 USB 쓰기 잠금이 잡혀 있으면 통째로 건너뛰며, 저널이 아직 없는 계획 중일 수 있어 갓 만든 폴더도 남긴다
public enum DJCTempCleanup {
    /// 진행 중인 저장·복사와 겹치지 않게 이보다 새 임시 파일은 건드리지 않는다
    static let partialAge: TimeInterval = 600
    static let previewCopyAge: TimeInterval = 3_600
    static let stagingAge: TimeInterval = 86_400

    /// 시험 프로세스는 실제 `$TMPDIR`을 청소하지 않는다(시험이 사용자 쪽을 건드리지 않는다)
    public static var defaultTemporaryDirectory: URL {
        TestProcess.isRunning ? TestProcess.sandbox : FileManager.default.temporaryDirectory
    }

    /// 지운 항목을 돌려준다.
    @discardableResult
    public static func run(paths: DJCCachePaths = .current, temporaryDirectory: URL = defaultTemporaryDirectory,
                           now: Date = Date(), isProcessAlive: (pid_t) -> Bool = processAlive) -> [URL] {
        var targets = previewWaveformLeftovers(in: paths.root, now: now)
        targets += temporaryLeftovers(in: temporaryDirectory, now: now, isProcessAlive: isProcessAlive)
        targets += stagingLeftovers(paths: paths, now: now)
        for directory in [temporaryDirectory.appending(path: "djc-usb-sync-snapshots"), paths.root.appending(path: "usb-sync-snapshots")] {
            targets += syncSnapshotLeftovers(in: directory, now: now, isProcessAlive: isProcessAlive)
        }
        var removed: [URL] = []
        for target in targets {
            do { try FileManager.default.removeItem(at: target) } catch { continue }
            removed.append(target)
        }
        return removed
    }

    /// 앱 시작용: 지운 것이 있으면 이름만 로그로 남긴다(경로 앞부분은 적지 않는다).
    public static func runAndLog(paths: DJCCachePaths = .current) {
        let removed = run(paths: paths)
        guard !removed.isEmpty else { return }
        FileHandle.standardError.write(Data("임시 파일 청소 \(removed.count)개: \(removed.map(\.lastPathComponent).joined(separator: ", "))\n".utf8))
    }

    // MARK: 자리별 규칙

    static func previewWaveformLeftovers(in root: URL, now: Date) -> [URL] {
        entries(of: root).filter {
            $0.lastPathComponent.hasPrefix("preview-waveforms.plist.sb-") && isRegularFile($0) && age($0, now: now) > partialAge
        }
    }

    static func temporaryLeftovers(in directory: URL, now: Date, isProcessAlive: (pid_t) -> Bool) -> [URL] {
        let mine = ProcessInfo.processInfo.processIdentifier
        return entries(of: directory).filter { url in
            let name = url.lastPathComponent
            guard isDirectory(url) else { return false }
            if name.hasPrefix("djc-preview-") { return newestChange(url).map { now.timeIntervalSince($0) > previewCopyAge } ?? false }
            if name.hasPrefix("djc-test-sandbox-"), let pid = pid_t(name.dropFirst("djc-test-sandbox-".count)), pid > 0 {
                return pid != mine && !isProcessAlive(pid)
            }
            return false
        }
    }

    /// `UsbSyncSnapshotLease`의 사본 폴더(`<pid>-<UUID>`). 다른 실행이 쓰는 중인 사본은 남긴다
    static func syncSnapshotLeftovers(in directory: URL, now: Date, isProcessAlive: (pid_t) -> Bool) -> [URL] {
        let mine = ProcessInfo.processInfo.processIdentifier
        return entries(of: directory).filter { url in
            guard isDirectory(url) else { return false }
            let name = url.lastPathComponent
            // UUID 앞 토막이 숫자뿐일 수 있어 뒤가 온전한 UUID일 때만 pid로 읽는다
            if let dash = name.firstIndex(of: "-"), let pid = pid_t(name[..<dash]), pid > 0,
               UUID(uuidString: String(name[name.index(after: dash)...])) != nil {
                return pid != mine && !isProcessAlive(pid)
            }
            return newestChange(url).map { now.timeIntervalSince($0) > stagingAge } ?? false
        }
    }

    static func stagingLeftovers(paths: DJCCachePaths, now: Date) -> [URL] {
        let staging = paths.root.appending(path: "usb-staging")
        let folders = entries(of: staging).filter(isDirectory)
        guard !folders.isEmpty, let open = openSessions(in: paths.root.appending(path: "usb-sessions")) else { return [] }
        return folders.filter { folder in
            let name = folder.lastPathComponent
            if open.contains(where: { name == $0 || name == $0 + "-verify" }) { return false }
            return newestChange(folder).map { now.timeIntervalSince($0) > stagingAge } ?? false
        }
    }

    /// 닫히지 않은 저널이 가리키는 세션 이름. 읽지 못하는 저널이 있거나 쓰기 잠금이 잡혀 있으면 nil(통째로 건너뛴다)
    static func openSessions(in sessions: URL) -> Set<String>? {
        var open = Set<String>()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: sessions.appending(path: name)),
                  let journal = try? UsbJournal.decoder().decode(UsbJournal.self, from: data) else { return nil }
            guard !journal.isClosed else { continue }
            open.insert(journal.session)
            open.insert(URL(filePath: journal.stagingDirectory).lastPathComponent)
        }
        for name in names where name.hasSuffix(".lock") && DJCCache.isLocked(sessions.appending(path: name)) { return nil }
        return open
    }

    /// 그 pid의 프로세스가 있는지(권한이 없어도 있는 것이다)
    public static func processAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: 파일 도우미

    private static func entries(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func age(_ url: URL, now: Date) -> TimeInterval {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
        return now.timeIntervalSince(modified)
    }

    /// 폴더 안 가장 새 수정 시각(폴더 자신 포함). 읽지 못하면 nil이라 지우지 않는다.
    private static func newestChange(_ folder: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard var newest = try? folder.resourceValues(forKeys: keys).contentModificationDate else { return nil }
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in walker {
                if let date = try? url.resourceValues(forKeys: keys).contentModificationDate, date > newest { newest = date }
            }
        }
        return newest
    }
}
