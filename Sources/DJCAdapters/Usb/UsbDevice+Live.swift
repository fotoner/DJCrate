import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension UsbDevice {
    /// 이 Mac의 실제 일: rekordbox 버전(`/Applications`), 라이브 master.db 판정(`UsbLiveDatabase`), 세션 사본(`LibrarySnapshot.take`),
    /// realpath·statfs(`UsbScratchRoots`), 볼륨 정보(DiskArbitration·statfs·hdiutil, `UsbVolumes`), 파일 일(FileManager).
    /// - extraLiveDatabases: 더 거부할 master.db(시험이 덧붙인다). 이 Mac의 실제 rekordbox master.db와 이 실행의 rekordbox 폴더
    ///   (`DJC_REKORDBOX_DIR`) master.db는 이 목록과 상관없이 늘 거부한다(판정을 좁히지 못한다)
    public static func live(extraLiveDatabases: [URL] = []) -> UsbDevice {
        UsbDevice(appVersion: { RekordboxCompatibility.installedAppVersion() },
                  isVerifiedVersion: { (try? RekordboxCompatibility.checkApp(version: $0)) != nil },
                  isLiveDatabase: { UsbLiveDatabase.isLive($0, others: extraLiveDatabases) },
                  // 원본은 넘겨받은 사본이라 실행 중 확인·WAL 거부 없이 곁의 WAL을 사본 안에서 합친다. 옛 사본 정리는 목적지만 본다
                  copyLocalDatabase: { try LibrarySnapshot.take(from: $0, into: $1, force: true) },
                  snapshotTime: { try UsbSnapshotTime.resolve(explicit: $0, database: $1) },
                  realPath: { UsbScratchRoots.realPath($0) },
                  isUnderScratch: { UsbScratchRoots.isUnderAllowedRoot($0) },
                  mountedOn: { UsbScratchRoots.mountedOn($0) },
                  volumeInfo: { try UsbVolumes.info(root: $0) },
                  exists: { UsbSnapshotFolders.exists($0) },
                  names: { UsbSnapshotFolders.names(in: $0) },
                  remove: { UsbSnapshotFolders.remove($0) },
                  stat: { url in
                      try SnapshotFileAccess.posix.stat(url).map {
                          UsbLocalFileStamp(size: $0.size, modificationDate: $0.modificationDate, isRegularFile: $0.isRegularFile)
                      }
                  },
                  makeFolders: { paths, extra in try paths.makeFolders(extra) })
    }
}

extension LocalLibraryKeysSource {
    /// 스냅샷 사본을 읽기 전용으로 열어 읽는다(`LocalLibraryKeysReader`)
    public static let live = LocalLibraryKeysSource(load: { try LocalLibraryKeysReader.load(snapshot: $0) })
}

extension UsbDraftFiles {
    /// USB 초안 파일(`<directory>/<볼륨키>.json`, DJCStorage `UsbDraftStore`). 폴더는 조립 지점이 정한다(앱·CLI는 DJC_HOME 아래 `usb-drafts`)
    public static func live(directory: URL) -> UsbDraftFiles {
        let store = UsbDraftStore(directory: directory)
        return UsbDraftFiles(load: { try store.load(volumeKey: $0) }, save: { try store.save($0) },
                             append: { try store.append($0, volumeKey: $1, base: $2) }, discard: { try store.discard(volumeKey: $0) })
    }
}
