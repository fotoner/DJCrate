import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxKit

extension UsbWriteGuard {
    /// 앱·CLI가 쓰는 가드(실물 쓰기 동의 없음): 디스크 이미지에만 쓴다
    public static var system: UsbWriteGuard { system(physicalWrite: false) }

    /// 앱·CLI가 쓰는 가드: DiskArbitration·statfs·hdiutil로 볼륨을 보고, rekordbox 실행·보호 경로·실물 관문을 본다.
    /// physicalWrite는 실물 쓰기 동의(앱은 내보내기 시트·쓰기 확인 창을 거친 쓰기, CLI `--allow-physical`)
    public static func system(physicalWrite: Bool) -> UsbWriteGuard {
        UsbWriteGuard(volume: { try UsbVolumes.info(root: $0) },
                      isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
                      protectedRoots: [
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer"),
                          LibrarySnapshot.rekordboxDirectory,
                          DJCIdentity.supportDirectory,
                          DJCPaths.userData,
                      ],
                      gate: UsbPhysicalWriteGate(consented: physicalWrite))
    }
}
