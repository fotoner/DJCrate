import DJCDomain
import Darwin
import Foundation

/// 볼륨마다 한 번에 하나의 쓰기·회복·되돌리기만(맥 쪽 `usb-sessions/<볼륨키>.lock`에 flock).
/// 프로세스가 죽으면 커널이 풀어 준다.
public final class UsbVolumeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// 잡지 못하면 `volumeBusy`로 막는다
    public static func acquire(directory: URL, key: String) throws -> UsbVolumeLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appending(path: key + ".lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UsbIOError("open", path) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw UsbError.writeRefused([UsbBlock(code: "volumeBusy", scope: .volume,
                                                      message: String(ui: "다른 DJCrate 쓰기가 이 USB에 쓰는 중입니다. 끝난 뒤 다시 시도하세요"))])
            }
            throw UsbIOError("flock", path, code: code)
        }
        return UsbVolumeLock(descriptor: descriptor)
    }

    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
