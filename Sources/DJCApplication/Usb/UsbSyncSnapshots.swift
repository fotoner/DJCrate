import DJCDomain
import Foundation

/// 라이브러리 목록을 읽은 사본의 지문과 USB 동기화 작업 사본(피동 포트). 목록 읽기 전후로 지문을 떠서 같으면 그 읽기의 출처로 두고,
/// native 동기화는 그 지문이 그대로인 사본에서만 작업 전용 사본을 빌린다. 실제 구현은 DJCAdapters(`UsbSyncSnapshots.live`,
/// DJCStorage의 지문 뜨기·사본 만들기). 둘 다 파일을 읽으므로 메인 밖에서 부른다.
public struct UsbSyncSnapshots: Sendable {
    /// 사본의 지문(장치·inode·크기·시각·SHA-256). 뜨지 못하면 던진다
    public var stamp: @Sendable (_ snapshot: URL) throws -> UsbSyncSnapshotProvenance
    /// 지문이 그대로인 사본에서 작업 전용 사본을 빌린다. `directory`는 빌린 사본을 둘 폴더(nil이면 실제 구현의 기본 폴더).
    /// 사본이 바뀌었거나 뜨지 못하면 던진다
    public var lease: @Sendable (_ provenance: UsbSyncSnapshotProvenance, _ directory: URL?) throws -> UsbSyncSnapshotLease

    public init(stamp: @escaping @Sendable (_ snapshot: URL) throws -> UsbSyncSnapshotProvenance,
                lease: @escaping @Sendable (_ provenance: UsbSyncSnapshotProvenance, _ directory: URL?) throws -> UsbSyncSnapshotLease) {
        self.stamp = stamp
        self.lease = lease
    }
}
