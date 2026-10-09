import DJCDomain
import Foundation
import RekordboxKit

/// 임시 폴더를 USB 루트로 쓰는 시험용 파일 시스템. `PosixUsbFileSystem`을 감싸 호출을 기록하고,
/// 실패·크래시·분리(마운트 사라짐)·AppleDouble(`._*`) 생성을 흉내 낸다.
/// 실패를 주입하지 않을 때도 이것을 쓴다. 그냥 쓰면 임시 폴더의 마운트 지점이 시스템 데이터 볼륨이라 쓰기 전 확인에서 막힌다.
public final class FaultyUsbFileSystem: UsbFileSystem, @unchecked Sendable {
    public enum Op: String, CaseIterable, Sendable {
        case stat, list, makeDirectory, writeNew, copyDataNew, setModificationDate, fullSync, syncDirectory
        case rename, remove, removeDirectoryIfEmpty, sha256, read, mountedOn
    }

    public enum Mode: Sendable {
        /// 그 연산 하나만 실패
        case error
        /// 그 연산부터 모든 연산(맥 쪽 포함) 실패. 쓰던 파일은 반쯤 남는다(프로세스가 죽은 것처럼)
        case crash
    }

    /// 연산이 닿는 곳. USB 루트 아래면 usb, 그 밖(백업·저널·준비 폴더)은 mac
    public enum Side: Sendable { case usb, mac, any }

    public struct InjectedFault: Error, CustomStringConvertible {
        public var op: Op
        public var path: String
        public var description: String { "injected fault: \(op.rawValue) \(path)" }
    }

    public let root: URL
    private let rootPaths: [String]
    private let inner = PosixUsbFileSystem(synchronizes: false)
    private let lock = NSLock()

    /// n번째(1부터) 그 연산에서 실패. 기본은 USB 쪽 연산만 센다(`failSide`, `failMatching`으로 좁힌다)
    public var failAt: (operation: Op, occurrence: Int, mode: Mode)?
    public var failSide: Side = .usb
    /// 기록 경로(USB는 루트 기준 상대 경로, 맥 쪽은 "mac:<이름>")가 맞는 연산만 센다
    public var failMatching: (@Sendable (String) -> Bool)?
    /// `mountedOn`이 USB 경로에 돌려줄 값. 기본은 루트의 realpath(임시 폴더가 마운트 지점으로 보인다). nil이면 실제 statfs
    public var simulatedMountPoint: String?
    /// 그 연산(USB 쪽, n번째)부터 분리된 것처럼: `mountedOn`이 다른 값을 돌려주고 USB 쪽 연산은 모두 실패
    public var unmountAt: (op: Op, occurrence: Int)?
    /// 연산 직전에 불린다(경쟁 흉내·그 순간의 저널 읽기)
    public var onOperation: ((Op, URL) -> Void)?
    /// 파일·폴더를 만들거나 이름을 바꿀 때 macOS처럼 `._<이름>`(4096바이트)을 만든다
    public var simulateAppleDouble = false
    /// 이 상대 경로로의 첫 rename을 두 단계로: 대상을 지운 뒤 원본 이름을 바꾸기 전에 크래시(FAT rename이 끊긴 모양)
    public var renameTwoPhaseOn: String?
    /// 조건이 맞는 연산은 그 하나만 실패(`.error`). 여러 곳을 함께 실패시킬 때 쓴다
    public var failWhen: ((Op, String) -> Bool)?

    private var recorded: [String] = []
    private var counts: [String: Int] = [:]
    private var crashed = false
    private var unmounted = false
    private var swapped = false

    public init(root: URL) {
        self.root = root
        let real = UsbScratchRoots.realPath(root.path)
        rootPaths = [root.path, real].compactMap { $0 }
        simulatedMountPoint = real ?? root.path
    }

    /// 호출 기록(연산 이름 + 경로). 가드 등이 `record`로 남긴 줄도 같은 순서로 들어간다
    public var calls: [String] { lock.withLock { recorded } }
    public var isCrashed: Bool { lock.withLock { crashed } }
    public var isUnmounted: Bool { lock.withLock { unmounted } }

    /// 같은 마운트 지점에 다른 볼륨이 붙은 것처럼: 마운트 지점·파일 연산은 그대로 되고, 붙잡아 둔 볼륨(`holdVolume`)만 다르다고 답한다
    public func swapVolume() {
        lock.withLock { swapped = true }
    }

    /// 다른 곳(가드·검증 흉내)에서 일어난 일을 같은 기록에 남긴다
    public func record(_ note: String) {
        lock.withLock { recorded.append(note) }
    }

    /// USB 루트 기준 상대 경로(NFC). 루트 밖이면 nil
    public func relative(_ url: URL) -> String? {
        let path = url.path
        for base in rootPaths {
            if path == base { return "" }
            if path.hasPrefix(base + "/") { return UsbLayout.nfc(String(path.dropFirst(base.count + 1))) }
        }
        return nil
    }

    private func label(_ url: URL) -> String {
        relative(url).map { $0.isEmpty ? "." : $0 } ?? "mac:" + url.lastPathComponent
    }

    /// 기록하고 주입한 실패를 낸다. 연산을 해도 되면 nil, 크래시 흉내로 반쯤 하고 멈출 연산이면 .crash
    private func begin(_ op: Op, _ url: URL, note: String? = nil) throws -> Mode? {
        onOperation?(op, url)
        let isUSB = relative(url) != nil
        let path = label(url)
        if !isCrashed, !(isUSB && isUnmounted), failWhen?(op, path) == true {
            lock.withLock { recorded.append(op.rawValue + " " + (note ?? path)) }
            throw InjectedFault(op: op, path: path)
        }
        return try lock.withLock { () throws -> Mode? in
            recorded.append(op.rawValue + " " + (note ?? path))
            if crashed { throw InjectedFault(op: op, path: path) }
            // 분리된 뒤에도 마운트 지점 조회는 답한다(다른 값을)
            if isUSB, unmounted, op != .mountedOn { throw InjectedFault(op: op, path: path) }
            if let unmountAt, unmountAt.op == op, isUSB {
                let key = "unmount"
                counts[key, default: 0] += 1
                if counts[key] == unmountAt.occurrence {
                    unmounted = true
                    throw InjectedFault(op: op, path: path)
                }
            }
            if let failAt, failAt.operation == op, sideMatches(isUSB), failMatching?(path) ?? true {
                let key = "fail"
                counts[key, default: 0] += 1
                if counts[key] == failAt.occurrence {
                    if failAt.mode == .crash {
                        crashed = true
                        return .crash
                    }
                    throw InjectedFault(op: op, path: path)
                }
            }
            return nil
        }
    }

    private func sideMatches(_ isUSB: Bool) -> Bool {
        switch failSide {
        case .usb: isUSB
        case .mac: !isUSB
        case .any: true
        }
    }

    private func appleDouble(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: UsbLayout.appleDoubleName(for: url.lastPathComponent))
    }

    private func makeAppleDouble(for url: URL) {
        guard simulateAppleDouble, relative(url) != nil else { return }
        let companion = appleDouble(for: url)
        if !FileManager.default.fileExists(atPath: companion.path) {
            FileManager.default.createFile(atPath: companion.path, contents: Data(count: 4096))
        }
    }

    // MARK: - UsbFileSystem

    public func stat(_ url: URL) throws -> UsbFileStat? {
        if try begin(.stat, url) == .crash { throw InjectedFault(op: .stat, path: label(url)) }
        return try inner.stat(url)
    }

    public func list(_ directory: URL) throws -> [String] {
        if try begin(.list, directory) == .crash { throw InjectedFault(op: .list, path: label(directory)) }
        return try inner.list(directory)
    }

    public func makeDirectory(_ url: URL) throws {
        if try begin(.makeDirectory, url) == .crash { throw InjectedFault(op: .makeDirectory, path: label(url)) }
        try inner.makeDirectory(url)
        makeAppleDouble(for: url)
    }

    public func writeNew(_ data: Data, to url: URL) throws {
        if try begin(.writeNew, url) == .crash {
            // 반쯤 쓰고 죽은 모양
            try? inner.writeNew(data.prefix(data.count / 2), to: url)
            throw InjectedFault(op: .writeNew, path: label(url))
        }
        try inner.writeNew(data, to: url)
        makeAppleDouble(for: url)
    }

    public func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String) {
        if try begin(.copyDataNew, url) == .crash {
            if let data = try? Data(contentsOf: source) { try? inner.writeNew(data.prefix(data.count / 2), to: url) }
            throw InjectedFault(op: .copyDataNew, path: label(url))
        }
        let result = try inner.copyDataNew(from: source, to: url, progress: progress)
        makeAppleDouble(for: url)
        return result
    }

    public func setModificationDate(_ url: URL, _ date: Date) throws {
        if try begin(.setModificationDate, url) == .crash { throw InjectedFault(op: .setModificationDate, path: label(url)) }
        try inner.setModificationDate(url, date)
    }

    public func fullSync(_ url: URL) throws {
        if try begin(.fullSync, url) == .crash { throw InjectedFault(op: .fullSync, path: label(url)) }
        try inner.fullSync(url)
    }

    public func syncDirectory(_ url: URL) throws {
        if try begin(.syncDirectory, url) == .crash { throw InjectedFault(op: .syncDirectory, path: label(url)) }
        try inner.syncDirectory(url)
    }

    public func rename(_ from: URL, to: URL) throws {
        if try begin(.rename, to, note: label(from) + " -> " + label(to)) == .crash {
            throw InjectedFault(op: .rename, path: label(to))
        }
        if let twoPhase = renameTwoPhaseOn, relative(to) == twoPhase {
            let hit = lock.withLock { () -> Bool in
                counts["twoPhase", default: 0] += 1
                return counts["twoPhase"] == 1
            }
            if hit {
                // FAT에서 대상을 먼저 지우고 이름을 바꾸다 끊긴 모양
                _ = try? inner.remove(to)
                lock.withLock { crashed = true }
                throw InjectedFault(op: .rename, path: label(to))
            }
        }
        try inner.rename(from, to: to)
        if simulateAppleDouble, relative(to) != nil {
            let fromCompanion = appleDouble(for: from), toCompanion = appleDouble(for: to)
            if FileManager.default.fileExists(atPath: fromCompanion.path) {
                try? FileManager.default.removeItem(at: toCompanion)
                try? FileManager.default.moveItem(at: fromCompanion, to: toCompanion)
            } else {
                makeAppleDouble(for: to)
            }
        }
    }

    public func remove(_ url: URL) throws {
        if try begin(.remove, url) == .crash { throw InjectedFault(op: .remove, path: label(url)) }
        try inner.remove(url)
    }

    public func removeDirectoryIfEmpty(_ url: URL) throws -> Bool {
        if try begin(.removeDirectoryIfEmpty, url) == .crash { throw InjectedFault(op: .removeDirectoryIfEmpty, path: label(url)) }
        return try inner.removeDirectoryIfEmpty(url)
    }

    public func sha256(_ url: URL, uncached: Bool) throws -> String {
        if try begin(.sha256, url) == .crash { throw InjectedFault(op: .sha256, path: label(url)) }
        return try inner.sha256(url, uncached: uncached)
    }

    public func read(_ url: URL, maxBytes: Int) throws -> Data {
        if try begin(.read, url) == .crash { throw InjectedFault(op: .read, path: label(url)) }
        return try inner.read(url, maxBytes: maxBytes)
    }

    public func readFile(root: UsbRoot, relativePath: String, maxBytes: Int) throws -> UsbFileRead? {
        let url = root.url.appending(path: relativePath)
        if try begin(.read, url) == .crash { throw InjectedFault(op: .read, path: label(url)) }
        return try inner.readFile(root: root, relativePath: relativePath, maxBytes: maxBytes)
    }

    public func holdVolume(_ root: URL) throws -> any UsbVolumeHold {
        Hold(inner: try inner.holdVolume(root), isSwapped: { [self] in lock.withLock { swapped } })
    }

    final class Hold: UsbVolumeHold, @unchecked Sendable {
        let inner: any UsbVolumeHold
        let isSwapped: @Sendable () -> Bool

        init(inner: any UsbVolumeHold, isSwapped: @escaping @Sendable () -> Bool) {
            self.inner = inner
            self.isSwapped = isSwapped
        }

        func isSameVolume() -> Bool { !isSwapped() && inner.isSameVolume() }
        func release() { inner.release() }
    }

    public func mountedOn(_ url: URL) throws -> String? {
        if try begin(.mountedOn, url) == .crash { throw InjectedFault(op: .mountedOn, path: label(url)) }
        guard relative(url) != nil else { return try inner.mountedOn(url) }
        if lock.withLock({ unmounted }) { return "/System/Volumes/Data" }
        return try simulatedMountPoint ?? inner.mountedOn(url)
    }
}
