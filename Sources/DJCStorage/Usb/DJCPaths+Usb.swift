import DJCDomain
import Foundation
import RekordboxKit

/// USB 쓰기의 맥 쪽 폴더(모두 DJC_HOME 아래)
extension DJCPaths {
    /// 쓰기 전 백업: usb-backups/<볼륨키>/<시각>-<이름>/
    public static var usbBackups: URL { userData.appending(path: "usb-backups") }
    /// USB DB를 맥에서 열려고 뜬 사본
    public static var usbSnapshots: URL { userData.appending(path: "usb-snapshots") }
    public static var usbDrafts: URL { userData.appending(path: "usb-drafts") }
    /// USB마다 기억하는 동기화 선택·목록 연결
    public static var usbSyncSelections: URL { userData.appending(path: "usb-sync-selections") }
    /// 저널(<볼륨키>.json)·잠금(<볼륨키>.lock)
    public static var usbSessions: URL { userData.appending(path: "usb-sessions") }
    /// 쓰기 전에 만든 파일(분석·아트워크·DB)
    public static var usbStaging: URL { userData.appending(path: "usb-staging") }
    /// USB에서 가져와 보존한 기기 재생 기록(기록마다 JSON 한 파일, `UsbHistoryStore`). USB → Mac 보존만 한다
    public static var usbHistories: URL { userData.appending(path: "usb-histories") }
}

extension UsbWritePaths {
    /// DJC_HOME 아래 세 폴더(만들지 않는다). 앱은 USB에 쓸 때 `makeFolders`로 만든다(저널을 보기만 할 때는 만들지 않는다)
    public static var djcHome: UsbWritePaths {
        UsbWritePaths(backups: DJCPaths.usbBackups, sessions: DJCPaths.usbSessions, staging: DJCPaths.usbStaging)
    }

    /// DJC_HOME 아래 세 폴더(없으면 만든다)
    public static var `default`: UsbWritePaths {
        let paths = djcHome
        for url in [paths.backups, paths.sessions, paths.staging] { try? paths.makeFolder(url) }
        return paths
    }

    /// 세 폴더와 `extra`(세션 사본 폴더 등)를 주인만 읽는 폴더로 만든다(있으면 그대로)
    public func makeFolders(_ extra: [URL] = []) throws {
        for url in [backups, sessions, staging] + extra { try makeFolder(url) }
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
