import DJCApplication
import DJCDomain
import Foundation

/// 사이드바가 USB를 보는 창구. 시험은 가짜로 바꾼다. 읽기는 모두 사본으로 한다(USB 위에서 SQLite를 열지 않는다).
@MainActor protocol UsbHost: AnyObject {
    /// 지금 연결된 볼륨(볼륨 정보만, 파일은 읽지 않는다)
    func volumes() -> [UsbVolumeInfo]
    /// 무엇이 든 USB인지·건강한지(`UsbRead.info`)
    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo
    /// 사본을 떠서 두 형식을 읽어 합친 라이브러리(`UsbRead.library`)
    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary
    func eject(_ volume: UsbVolumeInfo) async throws
    /// 볼륨이 붙거나 떨어질 때마다 새 목록
    var volumeEvents: AsyncStream<[UsbVolumeInfo]> { get }
}

/// 실제 USB: DiskArbitration으로 볼륨을 지켜보고, 읽기·꺼내기는 메인 액터 밖(분리된 작업)에서 한다.
/// 지켜보기·읽기·꺼내기의 실제 구현은 조립 지점(`UsbAppSetup`, `AppComposition+Usb.swift`)이 붙인다.
@MainActor final class SystemUsbHost: UsbHost {
    /// 볼륨 하나를 다루는 입출력. 메인 액터 밖에서 부른다
    struct IO: Sendable {
        var info: @Sendable (UsbVolumeInfo) throws -> UsbInfo
        var library: @Sendable (UsbVolumeInfo) throws -> UsbLibrary
        var eject: @Sendable (UsbVolumeInfo) async throws -> Void

        /// 읽기 직전에 그 자리의 볼륨을 다시 보고(`recheck`, nil이면 `UsbRead.currentVolume`) 그 새 정보로 사본을 뜬다(`snapshots/<볼륨키>/`).
        /// 사이드바가 들고 있던 정보는 앞선 훑기 때 것이라, 그 사이 같은 자리에 다른 볼륨이 붙었을 수 있다.
        static func reading(_ reader: UsbRead, snapshots: URL, recheck: (@Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo)? = nil,
                            eject: @escaping @Sendable (UsbVolumeInfo) async throws -> Void) -> IO {
            let recheck = recheck ?? { try reader.currentVolume(matching: $0) }
            return IO(info: { listed in
                          let volume = try recheck(listed)
                          let scratch = snapshots.appending(path: volume.usbKey).appending(path: "info-\(UUID().uuidString)")
                          return try reader.info(root: URL(filePath: volume.mountPoint), scratch: scratch, volume: volume)
                      },
                      library: { listed in
                          let volume = try recheck(listed)
                          return try reader.library(root: URL(filePath: volume.mountPoint), snapshots: snapshots, volumeKey: volume.usbKey,
                                                    volume: volume, now: Date()).library
                      },
                      eject: eject)
        }
    }

    private let io: IO
    private let current: @Sendable () -> [UsbVolumeInfo]
    /// 지켜보기를 멈추지 않게 붙들어 둔다(조립 지점이 만든 볼륨 지켜보기)
    private let monitor: AnyObject?
    let volumeEvents: AsyncStream<[UsbVolumeInfo]>

    init(io: IO, events: AsyncStream<[UsbVolumeInfo]>, current: @escaping @Sendable () -> [UsbVolumeInfo], monitor: AnyObject? = nil) {
        self.io = io
        self.volumeEvents = events
        self.current = current
        self.monitor = monitor
    }

    func volumes() -> [UsbVolumeInfo] { current() }

    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo {
        let io = io
        return try await BlockingWork.run { try io.info(volume) }
    }

    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary {
        let io = io
        return try await BlockingWork.run { try io.library(volume) }
    }

    func eject(_ volume: UsbVolumeInfo) async throws {
        let io = io
        try await Task.detached(priority: .userInitiated) { try await io.eject(volume) }.value
    }
}
