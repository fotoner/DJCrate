import DJCApplication
import DJCDomain
import Foundation

/// 코디네이터 결과를 보이는 곳(토스트). 앱은 `LibraryStore`
@MainActor
protocol UsbWriteHost: AnyObject {
    var toast: AppToast? { get set }
    /// 선택 당시 원본·revision·스냅샷을 비교한다. 원본을 모르는 호스트는 native 쓰기를 허용하지 않는다.
    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool
}

extension UsbWriteHost {
    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool { false }
}

extension LibraryStore: UsbWriteHost {
    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool {
        guard let snapshot = context.snapshot, snapshot.lease != nil,
              database == snapshot.database, snapshotURL == snapshot.provenance.sourceURL,
              snapshotReadEpoch == context.readEpoch, snapshotForUsbSync == snapshot.provenance,
              case .loaded = phase, lastError == nil,
              music.currentRefresh(snapshot: snapshot.provenance.sourceURL, revision: context.catalogRevision) == nil else { return false }
        return !isLoading && !isWritingRekordbox && writeLockPolicy.allowsLibraryInteraction
            && shareRoot == share
            && previewRevision == context.catalogRevision
            && UsbSyncSource.make(rekordbox: rekordboxPlaylists, iTunes: music.library) == context.source
    }
}

/// 저장해 둔 USB 흐름이 `LibraryStore`를 붙들지 않게 약하게 이어 주는 창구
@MainActor final class WeakUsbWriteHost: UsbWriteHost {
    private weak var store: LibraryStore?

    init(_ store: LibraryStore) { self.store = store }

    var toast: AppToast? {
        get { store?.toast }
        set { store?.toast = newValue }
    }

    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool {
        store?.usbSyncSourceIsCurrent(context, database: database, share: share) ?? false
    }
}

/// USB 동기화가 쓰는 라이브러리 사본 출처. 라이브러리 읽기 전후로 사본 지문(`UsbSyncSnapshotProvenance`)을 떠서 같으면 그 읽기의 출처로 둔다
/// (파일 교체가 목록 읽기와 겹치면 일반 화면은 유지하되 native 작업의 출처는 채택하지 않는다). 지문·작업 사본은 유스케이스(`LoadLibrary`)로 뜬다.
extension LibraryStore {
    /// 읽은 목록과 같은 DB를 확인한 때만 작업 전용 사본을 만들 수 있다.
    var snapshotForUsbSync: UsbSyncSnapshotProvenance? {
        usbSnapshotEpoch == snapshotReadEpoch ? usbSnapshotStamp : nil
    }

    /// - Parameter directory: 빌린 사본을 둘 폴더(nil이면 실제 구현의 기본 폴더, 시험은 임시 폴더)
    func leaseUsbSyncSnapshot(directory: URL? = nil) async -> UsbSyncSnapshotLease? {
        let epoch = snapshotReadEpoch
        guard let provenance = snapshotForUsbSync, snapshotURL == provenance.sourceURL else { return nil }
        let lease = await useCases.load.leaseUsbSnapshot(provenance, directory: directory)
        guard !Task.isCancelled, snapshotReadEpoch == epoch, snapshotURL == provenance.sourceURL,
              snapshotForUsbSync == provenance else { return nil }
        return lease
    }
}
