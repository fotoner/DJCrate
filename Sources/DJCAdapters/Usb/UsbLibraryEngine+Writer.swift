import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension UsbLibraryEngine.Writer {
    /// USB 쓰기 절차의 실제 구현: `UsbWriter.write`·`recover`·`restore`만 부른다(관문·백업·저널·검증·되돌리기는 그 안).
    /// 가드·Mac 쪽 폴더는 요청에 담겨 온 것(세션·쓰기 유스케이스가 조립 지점에서 받은 것)을 그대로 넘기고 기본값을 두지 않는다.
    /// - fileSystem: USB 파일 연산(앱·CLI는 `PosixUsbFileSystem()`, 자가 테스트·시험은 기록하거나 마운트를 흉내 내는 것)
    public static func live(fileSystem: any UsbFileSystem) -> Self {
        Self(
            preexistingAppleDoubles: { try UsbInvariantVerifier.appleDoubles(on: UsbRoot($0)) },
            write: { request in
                let (verifiers, inspectors) = checks(request.verification, preexisting: request.preexistingAppleDoubles)
                return try UsbWriter.write(request.changes, root: UsbRoot(request.root), paths: request.paths, guard: request.writeGuard,
                                           fileSystem: fileSystem, verifiers: verifiers, inspectors: inspectors, options: request.options,
                                           ppthReader: UsbExportAssembly.ppthReader, progress: request.progress,
                                           isCancelled: request.isCancelled)
            },
            recover: { request in
                try UsbWriter.recover(root: UsbRoot(request.root), paths: request.paths, guard: request.writeGuard, fileSystem: fileSystem,
                                      discardTemp: request.discardTemp, confirmName: request.confirmName,
                                      expectedVolumeUUID: request.expectedVolumeUUID)
            },
            restore: { request in
                try UsbWriter.restore(root: UsbRoot(request.root), paths: request.paths, backup: request.backup, guard: request.writeGuard,
                                      fileSystem: fileSystem, discardDeviceChanges: request.discardDeviceChanges,
                                      confirmName: request.confirmName, dryRun: request.dryRun,
                                      expectedVolumeUUID: request.expectedVolumeUUID)
            },
            journalStatus: { paths, volumeKey in
                switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
                case .missing: .missing
                case let .open(journal): .open(journal.state)
                case let .closed(journal): .closed(journal.state, idHighWater: journal.changes.idHighWater)
                case .corrupt: .corrupt
                }
            },
            backups: { UsbWriter.backups(paths: $0, volumeKey: $1) },
            databaseFingerprint: { try UsbWriter.databaseFingerprint(root: UsbRoot($0), fileSystem: fileSystem) })
    }

    /// 형식별 쓰기 뒤 검증기와 쓰기 전 검사기(내보내기: 빈 볼륨, 수정: 수정 전제, 옮기기: 원래 파일 그대로)
    static func checks(_ verification: UsbWriteVerification, preexisting: Set<String>)
        -> (verifiers: [any UsbWriteVerifier], inspectors: [any UsbWriteInspector]) {
        switch verification {
        case let .export(assembled):
            (UsbExportAssembly.verifiers(for: assembled, preexistingAppleDoubles: preexisting), [UsbEmptyVolumeInspector()])
        case let .edit(result):
            (result.verifiers(preexistingAppleDoubles: preexisting), [UsbEditInspector()])
        case let .migration(result):
            (result.verifiers(preexistingAppleDoubles: preexisting), [UsbMigrationInspector()])
        }
    }
}
