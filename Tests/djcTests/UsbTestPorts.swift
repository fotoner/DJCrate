import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

/// CLI 시험의 USB 조립: 앱·CLI와 같은 실제 어댑터(엔진·이 Mac의 일)를 붙이고 시험이 바꾸는 것만 바꾼다
extension UsbDevice {
    /// - appVersion: 이 Mac의 rekordbox 버전(시험은 정해 둔다)
    /// - mountedOn·volumeInfo: 마운트 지점·볼륨 정보(nil이면 실제 statfs·DiskArbitration)
    static func testing(appVersion: String? = "7.2.18", mountedOn: (@Sendable (String) -> String?)? = nil,
                        volumeInfo: (@Sendable (URL) throws -> UsbVolumeInfo)? = nil) -> UsbDevice {
        var device = UsbDevice.live()
        device.appVersion = { appVersion }
        if let mountedOn { device.mountedOn = mountedOn }
        if let volumeInfo { device.volumeInfo = volumeInfo }
        return device
    }
}

extension UsbRead {
    static func testing(appVersion: String? = "7.2.18", mountedOn: (@Sendable (String) -> String?)? = nil,
                        volumeInfo: (@Sendable (URL) throws -> UsbVolumeInfo)? = nil) -> UsbRead {
        UsbRead(engine: .live(fileSystem: PosixUsbFileSystem()),
                device: .testing(appVersion: appVersion, mountedOn: mountedOn, volumeInfo: volumeInfo))
    }
}
