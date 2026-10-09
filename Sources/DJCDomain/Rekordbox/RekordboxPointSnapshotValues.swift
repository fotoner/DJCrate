import Foundation

// 시점 스냅샷(#220·#223·#224)의 값: 종류·정보(`snapshot.json`)·항목·복원 결과. 뜨기·복원·보존 정리는 RekordboxKit
// `RekordboxPointSnapshot`·`RekordboxWriter.restore(pointSnapshot:)`에 있고 옛 이름(`RekordboxPointSnapshot.Entry` 등)은 typealias로 남는다(#167).
// 스냅샷 폴더의 `snapshot.json`을 그대로 읽어야 하므로 저장 칸 이름을 바꾸지 않는다.

/// 시점 스냅샷 종류(`RekordboxPointSnapshot.Kind`)
public enum RekordboxPointSnapshotKind: String, Codable, Sendable, CaseIterable {
    /// 사용자가 이름을 붙여 남긴 것
    case manual
    /// 자동으로 남긴 것(#228)
    case auto
    /// 시점 스냅샷으로 복원하기 직전 상태(#225)
    case beforeRestore

    public var title: String {
        switch self {
        case .manual: String(ui: "수동")
        case .auto: String(ui: "자동")
        case .beforeRestore: String(ui: "복원 직전")
        }
    }
}

/// 스냅샷 폴더의 `snapshot.json`(`RekordboxPointSnapshot.Metadata`)
public struct RekordboxPointSnapshotMetadata: Codable, Sendable, Equatable {
    public var version = 1
    public var name: String
    public var kind: RekordboxPointSnapshotKind
    public var createdAt: Date
    public var pinned: Bool
    /// `djmdProperty.DBID`. 복원은 다른 라이브러리의 스냅샷을 거부한다
    public var libraryID: String?
    /// 변경 카운터(`agentRegistry`의 정수 칸만). 복원 확인 창이 클라우드 동기화 흔적을 볼 때 쓴다(#229)
    public var localUpdateCount: Int?
    public var cloudUpdateCount: Int?
    /// 삭제되지 않은 곡 수(목록에 보인다)
    public var trackCount: Int?
    /// 담은 항목(`master.db`, `masterPlaylists6.xml`, `playlists3.sync`, `share/PIONEER/USBANLZ`, `share/PIONEER/Artwork`)
    public var items: [String]
    /// 같은 볼륨이라 클론으로 떴는지
    public var cloned: Bool?
    /// 복원 직전 스냅샷이면 되돌린 스냅샷의 이름(없으면 ID, #225)
    public var restoredFrom: String?
    /// 뜬 원본 `master.db`의 크기·수정 시각. 자동 스냅샷(#228)이 그 뒤 라이브러리가 바뀌었는지 볼 때 쓴다(옛 스냅샷에는 없다)
    public var source: RekordboxPointSnapshotSourceStamp?

    public init(name: String, kind: RekordboxPointSnapshotKind, createdAt: Date, pinned: Bool = false, libraryID: String? = nil,
                localUpdateCount: Int? = nil, cloudUpdateCount: Int? = nil, trackCount: Int? = nil, items: [String] = [], cloned: Bool? = nil) {
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.pinned = pinned
        self.libraryID = libraryID
        self.localUpdateCount = localUpdateCount
        self.cloudUpdateCount = cloudUpdateCount
        self.trackCount = trackCount
        self.items = items
        self.cloned = cloned
    }
}

/// 스냅샷을 뜬 원본 `master.db`의 크기·수정 시각. 다음 자동 스냅샷이 "그 뒤 바뀌었는지" 볼 때 쓴다.
/// 수정 시각은 소수 초까지 그대로 비교하려고 날짜가 아니라 1970년부터의 초로 적는다.
public struct RekordboxPointSnapshotSourceStamp: Codable, Sendable, Equatable {
    public var size: Int64
    public var modified: Double

    public init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }
}

/// 스냅샷 폴더 하나(`RekordboxPointSnapshot.Entry`)
public struct RekordboxPointSnapshotEntry: Sendable, Identifiable, Hashable {
    public var url: URL
    public var metadata: RekordboxPointSnapshotMetadata
    /// 폴더 이름(CLI가 고를 때 쓰는 ID)
    public var id: String { url.lastPathComponent }
    /// 이름이 있으면 이름, 없으면 ID
    public var displayName: String { metadata.name.isEmpty ? id : metadata.name }

    public init(url: URL, metadata: RekordboxPointSnapshotMetadata) {
        self.url = url
        self.metadata = metadata
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url && lhs.metadata == rhs.metadata }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// 시점 스냅샷 복원 결과(`RekordboxWriter.PointRestoreReport`)
public struct RekordboxPointRestoreReport: Sendable {
    /// 되돌린 스냅샷
    public var restored: RekordboxPointSnapshotEntry
    /// 복원 직전 상태를 남긴 스냅샷(이것으로 다시 복원하면 복원 전으로 돌아간다)
    public var beforeRestore: RekordboxPointSnapshotEntry

    public init(restored: RekordboxPointSnapshotEntry, beforeRestore: RekordboxPointSnapshotEntry) {
        self.restored = restored
        self.beforeRestore = beforeRestore
    }
}

/// 자동 시점 스냅샷(#228)을 뜨지 않은 이유(`RekordboxPointSnapshot.AutoSkip`, 오류가 아니라 다음 기회로 미룬 것)
public enum RekordboxPointSnapshotAutoSkip: String, Sendable, Equatable {
    case rekordboxRunning
    case walPending
    case alreadyToday
    case unchanged
    case noClone
    case noDatabase
}

/// 자동 시점 스냅샷을 볼 때의 결과(`RekordboxPointSnapshot.AutoOutcome`)
public enum RekordboxPointSnapshotAutoOutcome: Sendable, Equatable {
    case took(RekordboxPointSnapshotEntry)
    case skipped(RekordboxPointSnapshotAutoSkip)
}
