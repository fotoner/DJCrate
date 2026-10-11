import DJCApplication
import DJCDomain
import Foundation

extension AutoPointSnapshotRunner {
    /// 앱이 쓰는 것: 대상은 쓰기·복원과 같은 `LibraryStore.rekordboxDatabase`(#182). 볼지는 `isAllowed`가 가르고,
    /// 설정을 저장하지 않는 저장소(`settings.persist` 꺼짐)는 사용자가 끈 설정을 지킬 수 없어 뜨지 않는다.
    /// - Parameters:
    ///   - snapshots: 시점 스냅샷 폴더(데이터 폴더의 `point-snapshots`)
    ///   - files: 시점 스냅샷 파일(조립 지점이 실제 구현을 고른다)
    convenience init(store: LibraryStore, snapshots: URL, files: PointSnapshotFiles) {
        let settings = store.settings
        let allowed = Self.isAllowed(location: store.location, diagnosticRun: store.launch.isDiagnosticRun)
        let database = store.rekordboxDatabase
        self.init(environment: Environment(
            database: { [weak store] in store?.rekordboxDatabase ?? database },
            shareRoot: { [weak store] in store?.rekordboxShareRoot },
            snapshots: snapshots,
            enabled: { allowed && settings.persist && settings.value(SettingKeys.pointSnapshotAuto) },
            autoDays: { Int(settings.value(SettingKeys.pointSnapshotAutoDays)) },
            busy: { [weak store] in store?.isWritingRekordbox ?? true },
            writeCount: { [weak store] in store?.rekordboxWriteCount ?? 0 },
            files: files, now: { .now }, calendar: .current),
                  errorText: { AppErrorMessage.message(for: $0) },
                  log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                  onFailure: { [weak store] title, text in store?.toast = .notice(title, text) })
    }
}
