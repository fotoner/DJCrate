import DJCAdapters
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCStorage
import Foundation
import RekordboxKit

extension CLIComposition {
    /// USB 쓰기 유스케이스(앱과 같은 `UsbWriteService`). 가드는 명령의 실물 쓰기 동의(`--allow-physical`)로 만들고,
    /// Mac 쪽 폴더(세션 사본·초안)는 DJC_HOME 아래다. `paths`(백업·저널·준비)는 명령이 넘긴다(시험은 임시 폴더)
    static func usb(allowPhysical: Bool, paths: UsbWritePaths) -> UsbWriteService {
        UsbWriteService(paths: paths, localCopies: DJCPaths.usbSnapshots, writeGuard: { .system(physicalWrite: allowPhysical) },
                        engine: .live(fileSystem: PosixUsbFileSystem()), device: usbDevice, drafts: usbDrafts, now: { Date() })
    }

    /// 이 Mac의 일(rekordbox 버전·라이브 master.db 판정·세션 사본·볼륨 정보)
    static var usbDevice: UsbDevice { .live() }

    /// USB 초안 파일(DJC_HOME 아래 `usb-drafts`)
    static var usbDrafts: UsbDraftFiles { .live(directory: DJCPaths.usbDrafts) }

    /// USB 쓰기의 Mac 쪽 폴더(DJC_HOME 아래 백업·저널·준비, 부를 때 없으면 만든다). 시험은 명령에 임시 폴더를 넘긴다
    static var usbWritePaths: UsbWritePaths { .default }

    /// USB DB를 Mac에서 읽으려고 뜨는 사본의 폴더(DJC_HOME 아래 `usb-snapshots`, `djc usb-info`)
    static var usbSnapshots: URL { DJCPaths.usbSnapshots }

    /// `--db`를 주지 않은 USB 명령이 읽는 가장 최근 스냅샷(읽기만 한다. 새로 뜨거나 정리하지 않는다)
    static func latestSnapshot() throws -> URL { try LibrarySnapshot.latest() }

    /// USB로 받지 않는 폴더: 실제 Pioneer 폴더·rekordbox 라이브러리(`DJC_REKORDBOX_DIR`를 따른다)·DJCrate 데이터 폴더
    static var liveLibraryFolders: [String] {
        [NSHomeDirectory() + "/Library/Pioneer", LibrarySnapshot.rekordboxDirectory.path, DJCIdentity.supportDirectory.path]
    }

    /// 링크를 따라간 실제 경로(realpath(3), 없으면 nil). USB로 받지 않는 폴더와 견줄 때 쓴다(Foundation 경로 정규화는 `/private`를 뗀다)
    static func realPath(_ path: String) -> String? { UsbScratchPath.realPath(path) }

    /// USB를 읽기만 하는 유스케이스(`djc usb-info`)
    static var usbRead: UsbRead { UsbRead(engine: .live(fileSystem: PosixUsbFileSystem()), device: usbDevice) }
}
