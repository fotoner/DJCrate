import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 앱의 USB 조립 지점: 쓰기 유스케이스(`UsbWriteService`)·읽기(`UsbRead`)·볼륨 지켜보기에 실제 구현(DJCAdapters·DJCStorage)을 붙인다.
/// 포트의 실제 구현은 여기서만 고른다. Mac 쪽 폴더(백업·저널·준비·세션 사본·초안)는 모두 DJC_HOME 아래다.
enum UsbAppComposition {
    /// 앱의 쓰기 창구. 앱의 쓰기는 모두 쓰기 확인 창(볼륨 이름·"실물 USB입니다"를 보인다)을 거친 뒤에 부르므로 그 확인을 실물 쓰기 동의로 본다.
    /// 디스크 이미지만 읽는 실행(자가 테스트·DJC_HOME 시험 실행)은 동의가 없어 실물에 쓰지 않는다. 폴더는 USB에 쓸 때 만든다
    /// - writeGuard: 자가 테스트만 보호 폴더를 바꾼 가드를 넘긴다(nil이면 이 Mac의 가드)
    static func writeService(policy: UsbReadPolicy = .current(), paths: UsbWritePaths = .djcHome, localCopies: URL = DJCPaths.usbSnapshots,
                             drafts: URL = DJCPaths.usbDrafts, fileSystem: any UsbFileSystem = PosixUsbFileSystem(),
                             writeGuard: (@Sendable () -> UsbWriteGuard)? = nil) -> UsbWriteService {
        let consent = policy.physicalWriteConsent
        return UsbWriteService(paths: paths, localCopies: localCopies, writeGuard: writeGuard ?? { .system(physicalWrite: consent) },
                               engine: .live(fileSystem: fileSystem), device: .live(), drafts: .live(directory: drafts), now: { Date() })
    }

    /// 사이드바 읽기 입출력: 사본은 `snapshots/<볼륨키>/`에 뜨고, 꺼내기는 DiskArbitration
    static func hostIO(snapshots: URL = DJCPaths.usbSnapshots,
                       recheck: (@Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo)? = nil) -> SystemUsbHost.IO {
        .reading(.live, snapshots: snapshots, recheck: recheck, eject: { try await UsbVolumeMonitor.eject(mountPoint: $0.mountPoint) })
    }

    /// DiskArbitration으로 지켜보는 호스트. 디스크 이미지만 읽는 실행은 실물 볼륨을 지켜보는 목록에도 넣지 않는다
    @MainActor static func host(policy: UsbReadPolicy) -> SystemUsbHost {
        let monitor = UsbVolumeMonitor(diskImagesOnly: policy == .diskImagesOnly)
        return SystemUsbHost(io: hostIO(), events: monitor.start(), current: { monitor.volumes }, monitor: monitor)
    }

    /// USB 기기 재생 기록 보존(#43)의 실제 구현: DJC_HOME의 `usb-histories/`(손상 파일은 데이터 폴더의 damaged-drafts로).
    /// 라이브러리 포트 묶음(`LibraryPorts.usbHistories`)에 붙인다
    static func historyFiles() -> UsbHistoryFiles {
        .live(directory: DJCPaths.usbHistories, home: DJCPaths.userData)
    }
}

extension UsbRead {
    /// 이 Mac의 실제 USB 읽기(엔진·이 Mac의 일)
    static var live: UsbRead { UsbRead(engine: .live(fileSystem: PosixUsbFileSystem()), device: .live()) }
}

/// 앱 시작 때 사이드바 USB 절을 붙인다
@MainActor
enum UsbAppSetup {
    /// 실제 USB 호스트로 `UsbStore`를 만들어 붙이고 지켜보기를 시작한다. 로컬 짝짓기 키는 스냅샷을 읽을 때마다 뒤에서 다시 읽는다.
    /// 끝나지 않은 쓰기가 있는 볼륨이 나타나면 알림만 띄운다(회복은 사용자가 누를 때만)
    static func attach(to store: LibraryStore) {
        guard store.usb == nil else { return }
        let policy = UsbReadPolicy.current()
        let keys = LocalLibraryKeysCache()
        let source = LocalLibraryKeysSource.live
        let service = UsbAppComposition.writeService(policy: policy)
        let usb = UsbStore(host: UsbAppComposition.host(policy: policy), readPolicy: policy, writeService: service, localLibrary: { keys.current },
                           journal: { service.journal(volumeKey: $0) })
        // 초안은 DJC_HOME 아래(시험 실행이 사용자 초안을 건드리지 않게)
        usb.drafts = .live(directory: DJCPaths.usbDrafts)
        usb.syncSelectionDirectory = DJCPaths.usbSyncSelections
        usb.syncFiles = .live
        usb.localKeys = source
        usb.onPendingJournal = { [weak store] volume in
            Task { await store?.usbCoordinator?.offerRecovery(volume) }
        }
        #if DEBUG
        // 시험 실행이 어떤 볼륨을 읽는지 로그로 확인한다(버퍼 없이 바로 쓴다)
        FileHandle.standardOutput.write(Data("USB 읽기 정책: \(policy.name)\n".utf8))
        #endif
        store.usb = usb
        store.onSnapshotLoaded = { [weak store, weak usb] _ in
            // 읽기가 채택한 키를 쓴다(`LoadLibrary.open`). 뒤늦은 별도 파일 읽기가 더 새 사본의 키를 덮지 않게 한다.
            keys.set(store?.history.historyLocalKeys)
            Task { await usb?.localLibraryChanged() }
        }
        // 보존한 기록을 먼저 읽어 둔다(USB를 읽으면 그와 견줘 새 기록만 보존한다)
        connectHistories(store: store, usb: usb)
        Task { await usb.watch() }
    }

    /// USB 기기 재생 기록 보존(#43)을 잇는다: 보존한 기록을 읽고, USB 라이브러리를 읽거나 로컬 짝을 다시 계산할 때마다
    /// 새 기록을 DJCrate 데이터 폴더에 보존한다(USB·rekordbox 라이브러리에는 쓰지 않는다). 보존 파일은 라이브러리 포트 묶음이 정한다
    /// (앱은 `UsbAppComposition.historyFiles`, 시험은 임시 폴더). 보존 파일이 없으면 아무것도 보존하지 않는다
    static func connectHistories(store: LibraryStore, usb: UsbStore) {
        store.history.startLoadingArchivedHistories()
        usb.onLibraryEvaluated = { [weak store] volume, library, matches in
            store?.history.importUsbHistories(volume: volume, library: library, matches: matches)
        }
    }
}
