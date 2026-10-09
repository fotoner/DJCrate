import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension UsbSyncSnapshots {
    /// 사본 지문·작업 사본(DJCStorage). 빌린 사본의 기본 폴더는 `DJC_HOME/usb-sync-snapshots`(없으면 임시 폴더)이고,
    /// 라이브 DB 거부와 놓을 때 지우기는 DJCStorage `capture`가 한다
    public static let live = UsbSyncSnapshots(
        stamp: { try UsbSyncSnapshotProvenance.capture($0) },
        lease: { try UsbSyncSnapshotLease.capture($0, directory: $1 ?? UsbSyncSnapshotLease.defaultDirectory) })
}
