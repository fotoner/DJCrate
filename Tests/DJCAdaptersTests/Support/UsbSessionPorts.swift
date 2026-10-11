import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

/// 세션 통합 시험의 조립: 앱·CLI와 같은 실제 어댑터(엔진·이 Mac의 일·초안 파일)를 붙이고, 시험이 바꾸는 것만 바꾼다
/// (마운트를 흉내 내는 파일 시스템, 세션 사본 뜨기 기록, rekordbox 버전, 더 거부할 master.db)
extension UsbDevice {
    /// - extraLive: 앱·CLI의 `.live()`에 시험이 더 거부할 경로. 라이브 master.db(실제·이 실행의 rekordbox 폴더)는 `UsbLiveDatabase`가 늘 거부한다
    /// - appVersion: 이 Mac의 rekordbox 버전(시험은 확인한 버전으로 정해 둔다)
    /// - localCopy: 세션 사본 뜨기(nil이면 실제 `LibrarySnapshot.take`)
    static func testing(extraLive: [URL] = [], appVersion: String? = "7.2.18",
                        localCopy: (@Sendable (URL, URL) throws -> URL)? = nil) -> UsbDevice {
        var device = UsbDevice.live(extraLiveDatabases: extraLive)
        device.appVersion = { appVersion }
        if let localCopy { device.copyLocalDatabase = localCopy }
        return device
    }

    /// 실제 세션 사본 뜨기(앱·CLI와 같다)
    static let liveLocalCopy: @Sendable (URL, URL) throws -> URL = UsbDevice.live().copyLocalDatabase
}

extension UsbRead {
    /// 실제 엔진·이 Mac의 일로 읽는다(앱·CLI와 같다)
    static var live: UsbRead { UsbRead(engine: .live(fileSystem: PosixUsbFileSystem()), device: .live()) }
}
