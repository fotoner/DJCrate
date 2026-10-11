import Foundation

// USB 동기화가 읽은 로컬 스냅샷의 출처와 그 사본의 소유권(값). 파일을 읽어 지문을 뜨고 사본을 만들고 지우는 일은
// DJCStorage(`UsbSyncSnapshotProvenance.capture`·`UsbSyncSnapshotLease.capture`)에 있다(#167).

/// 목록을 읽기 전후와 작업 사본을 만들 때 같은 파일인지 확인하는 값이다. 원문·경로를 오류에 담지 않는다(스냅샷에는 클라우드 토큰이 들어 있다).
public struct UsbSyncSnapshotProvenance: Sendable, Equatable {
    public let sourceURL: URL
    public let snapshotTime: String
    /// 같은 파일인지 견주는 지문(장치·inode·크기·수정 시각·SHA-256). 내용은 담지 않는다
    public let fingerprint: Fingerprint

    public struct Fingerprint: Sendable, Equatable {
        public let device: Int32
        public let inode: UInt64
        public let size: Int64
        public let modified: Date
        public let digest: Data

        public init(device: Int32, inode: UInt64, size: Int64, modified: Date, digest: Data) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modified = modified
            self.digest = digest
        }
    }

    public init(sourceURL: URL, snapshotTime: String, fingerprint: Fingerprint) {
        self.sourceURL = sourceURL
        self.snapshotTime = snapshotTime
        self.fingerprint = fingerprint
    }
}

/// 작업·시트가 강하게 소유하는 사본. 캐시된 job의 약한 참조(`reference`)만으로는 파일을 남기지 않는다.
/// 마지막 소유자가 놓으면 `release`(DJCStorage: 사본 폴더 지우기)를 부른다.
public final class UsbSyncSnapshotLease: Sendable, Equatable {
    public let database: URL
    public let provenance: UsbSyncSnapshotProvenance
    private let id: UUID
    private let release: @Sendable () -> Void

    /// - Parameters:
    ///   - id: 사본마다 새로 만든 ID(같은 사본인지 견준다)
    ///   - release: 소유가 끝날 때 사본을 치운다
    public init(database: URL, provenance: UsbSyncSnapshotProvenance, id: UUID, release: @escaping @Sendable () -> Void) {
        self.database = database
        self.provenance = provenance
        self.id = id
        self.release = release
    }

    public var reference: UsbSyncSnapshotReference { UsbSyncSnapshotReference(self, id: id) }
    public static func == (lhs: UsbSyncSnapshotLease, rhs: UsbSyncSnapshotLease) -> Bool { lhs.id == rhs.id }
    deinit { release() }
}

/// 초안·lastExports에 남겨도 사본을 붙잡지 않는 출처 참조다.
public final class UsbSyncSnapshotReference: @unchecked Sendable, Equatable {
    public let database: URL
    public let provenance: UsbSyncSnapshotProvenance
    private let id: UUID
    private let lock = NSLock()
    private weak var owner: UsbSyncSnapshotLease?

    fileprivate init(_ lease: UsbSyncSnapshotLease, id: UUID) {
        database = lease.database
        provenance = lease.provenance
        self.id = id
        owner = lease
    }
    public var lease: UsbSyncSnapshotLease? { lock.withLock { owner } }
    public static func == (lhs: UsbSyncSnapshotReference, rhs: UsbSyncSnapshotReference) -> Bool { lhs.id == rhs.id }
}
