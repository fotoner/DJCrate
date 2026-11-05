import Foundation

// USB 시점 스냅샷(#226)의 값과 순수 규칙. 뜨기·목록·보존 정리는 RekordboxKit `UsbPointSnapshot`, 되돌리기 계획은 `UsbPointRestore`에 있다.
// 이름·종류·고정은 로컬 시점 스냅샷(`RekordboxPointSnapshotMetadata`)과 같은 뜻이고, 보존 수는 USB 백업 정리와 같다.

/// 스냅샷 폴더의 `snapshot.json`
public struct UsbPointSnapshotMetadata: Codable, Sendable, Equatable {
    public var version = 1
    public var name: String
    public var kind: RekordboxPointSnapshotKind
    public var createdAt: Date
    public var pinned: Bool
    /// 뜬 볼륨(대문자 UUID). 되돌리기는 같은 볼륨에만 한다
    public var volumeUUID: String
    public var volumeName: String
    public var appVersion: String?
    /// 담은 파일: USB 상대 경로(NFC) → 크기·수정 시각·SHA-256. 파일은 스냅샷 폴더 `files/<상대 경로>`에 있다
    public var files: [String: UsbFingerprint.Stamp]

    public init(name: String, kind: RekordboxPointSnapshotKind, createdAt: Date, pinned: Bool = false, volumeUUID: String, volumeName: String,
                appVersion: String? = nil, files: [String: UsbFingerprint.Stamp]) {
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.pinned = pinned
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.appVersion = appVersion
        self.files = files
    }

    /// 담은 DB(사이드카 빼고): 상대 경로 → SHA-256
    public var databases: [String: String] {
        files.filter { UsbPointSnapshotRules.databaseOrder.contains($0.key) }.mapValues(\.sha256)
    }

    public var formats: Set<UsbFormat> {
        var formats: Set<UsbFormat> = []
        if files[UsbLayout.oneLibrary] != nil { formats.insert(.oneLibrary) }
        if files[UsbLayout.exportPdb] != nil { formats.insert(.deviceLibrary) }
        return formats
    }

    /// OneLibrary 사이드카(-wal·-shm·-journal)를 담았는지. 되돌리기는 사본 안에서 합친 DB를 쓴다
    public var hasSidecars: Bool {
        UsbLayout.oneLibrarySidecarSuffixes.contains { files[UsbLayout.oneLibrary + $0] != nil }
    }

    public var analysisFiles: Int { files.keys.filter { UsbPointSnapshotRules.isUnder($0, UsbLayout.analysisRoot) }.count }
    public var artworkFiles: Int { files.keys.filter { UsbPointSnapshotRules.isUnder($0, UsbLayout.artworkRoot) }.count }
    public var settingFiles: Int { files.keys.filter { UsbPointSnapshotRules.settingFiles.contains($0) }.count }
    public var totalSize: Int64 { files.values.reduce(0) { $0 + $1.size } }
}

/// 스냅샷 폴더 하나
public struct UsbPointSnapshotEntry: Sendable, Identifiable, Hashable {
    public var url: URL
    public var metadata: UsbPointSnapshotMetadata
    /// 폴더 이름(CLI가 고를 때 쓰는 ID)
    public var id: String { url.lastPathComponent }
    /// 이름이 있으면 이름, 없으면 ID
    public var displayName: String { metadata.name.isEmpty ? id : metadata.name }

    public init(url: URL, metadata: UsbPointSnapshotMetadata) {
        self.url = url
        self.metadata = metadata
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url && lhs.metadata == rhs.metadata }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// 스냅샷 → 변경 묶음(`UsbPointRestore.plan`). `changes`가 있으면 `UsbWriter.write`로 쓴다
public struct UsbPointRestoreResult: Sendable {
    /// nil = 쓰지 않음(막힘이거나 지금 USB가 스냅샷과 같다)
    public var changes: UsbChangeSet?
    public var blocks: [UsbBlock] = []
    public var notes: [String] = []
    /// 바꿀 DB 수
    public var databases = 0
    public var created = 0
    public var overwritten = 0
    public var removed = 0
    /// 지우기 허용 목록 밖이라 그대로 두는 파일 수(스냅샷 뒤 생긴 설정 파일 등)
    public var kept = 0
    /// 스냅샷 DB의 곡 중 지금 USB에 음원이 없는 곡 수(음원은 담지 않는다). nil = 확인하지 못함
    public var missingAudio: Int?

    public init() {}

    /// 지금 USB가 스냅샷과 같아 쓸 것이 없다
    public var isUnchanged: Bool { changes == nil && blocks.isEmpty }
}

public enum UsbPointSnapshotRules {
    /// 볼륨마다 남기는 수(USB 백업 정리 `UsbWriter.backupsToKeep`과 같다). 고정한 것은 이 수와 상관없이 남긴다
    public static let keep = 5
    /// 교체 순서(쓰기 절차와 같다)
    public static let databaseOrder = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
    /// 담는 DB 쪽 파일: 본 DB·OneLibrary 사이드카·pdb 둘. `export.pdb.bak`·동기화 선택·`ImportedHistory.xml`은 담지 않는다
    public static let databaseFiles = [UsbLayout.oneLibrary] + UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 }
        + [UsbLayout.exportPdb, UsbLayout.exportExtPdb]
    /// 담는 기기 설정 파일(usb-internals §6에서 읽는 넷). 이름만 연다
    public static let settingFiles = ["PIONEER/MYSETTING.DAT", "PIONEER/MYSETTING2.DAT", "PIONEER/DJMMYSETTING.DAT", "PIONEER/DEVSETTING.DAT"]
    /// 통째로 담는 폴더
    public static let folders = [UsbLayout.analysisRoot, UsbLayout.artworkRoot]

    /// 스냅샷 범위의 파일 경로인지(모양만 본다). 깨졌거나 누가 고친 `snapshot.json`이 범위 밖을 가리키면 되돌리기가 거부한다
    public static func isInScope(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.contains("\0"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let leaf = components.last, !UsbLayout.isAppleDouble(leaf), !UsbLayout.isTemp(leaf), !UsbLayout.isNeverRead(path),
              !UsbLayout.isSystemIgnored(path) else { return false }
        let key = UsbLayout.collisionKey(path)
        if (databaseFiles + settingFiles).contains(where: { UsbLayout.collisionKey($0) == key }) { return true }
        return folders.contains { isUnder(path, $0) }
    }

    /// `folder` 아래(그 폴더 자체는 아님). 성분을 충돌 키로 견준다
    public static func isUnder(_ path: String, _ folder: String) -> Bool {
        let prefix = UsbLayout.collisionKey(folder) + "/"
        let key = UsbLayout.collisionKey(path)
        return key.hasPrefix(prefix) && key.count > prefix.count
    }

    /// 보존 정리로 지울 스냅샷: 만든 시각 최근 순으로 `keep`번째 뒤의 것 중 고정하지 않은 것(USB 백업 정리와 같은 셈)
    public static func expired(_ entries: [UsbPointSnapshotEntry], keep: Int) -> [UsbPointSnapshotEntry] {
        let ordered = entries.sorted { ($0.metadata.createdAt, $0.id) > ($1.metadata.createdAt, $1.id) }
        return ordered.enumerated().filter { $0.offset >= keep && !$0.element.metadata.pinned }.map(\.element)
    }

    /// 그 스냅샷으로 되돌리면 DJCrate가 모르는 변경(기기가 남긴 재생 기록 등)을 잃는지. 스냅샷 뒤의 사건을 시각 순으로 따라간다.
    /// 상태가 바뀌는 곳마다 DB 셋의 SHA-256과 OneLibrary 사이드카를 본다(`usb-restore --discard-device-changes`, D13과 같은 기준).
    /// - 쓰기 전 상태가 따라온 상태와 다르면 그 사이 무언가 USB를 바꿨다. 수정·옮기기·동기화는 기기 행을 이어 쓰므로 그 결과에도 실린다
    /// - 이 스냅샷으로 돌려놓은 시점 되돌리기와 빈 USB 내보내기는 앞의 변경을 싣지 않는다. 담은 사이드카를 합친 DB는 해시가 달라지므로
    ///   해시가 아니라 어느 스냅샷을 돌려놓았는지로 본다. 다른 스냅샷으로 돌려놓은 되돌리기는 DB가 같지 않으면 모른다고 본다
    /// - `usb-restore`는 그 쓰기 전 상태로 돌아가므로 그때의 판정을 잇는다. 다시 계획·되돌리기 실패처럼 결과를 모르는 쓰기는 바뀐 것으로 본다
    /// - 정리로 지워진 기록 때문에 사건이 비면 상태가 이어지지 않아 바뀐 것으로 본다(모르면 묻는다). 지금이 스냅샷과 같으면 잃을 것이 없다
    public static func deviceChanged(since entry: UsbPointSnapshotEntry, events: [UsbVolumeEvent], current: UsbFingerprint) -> Bool {
        let snapshot = entry.metadata
        let base = snapshot.databases
        var state = base
        var changed = false
        /// 쓰기마다 그 쓰기 전 상태의 판정(그 쓰기를 `usb-restore`로 되돌리면 이 판정으로 돌아간다)
        var before: [String: Bool] = [:]
        for event in events.filter({ $0.date > snapshot.createdAt }).sorted(by: { $0.date < $1.date }) {
            switch event {
            case let .snapshot(_, databases, sidecars):
                if databases != state || sidecars { changed = true }
                state = databases
            case let .write(id, _, databases, sidecars, after, kind, outcome):
                let previous = changed || databases != state || sidecars
                before[id] = previous
                switch (outcome, kind) {
                case (.written, .carry), (.recovered, .carry), (.rolledBack, _), (.restored, _): changed = previous
                case (.written, .fresh), (.recovered, .fresh): changed = false
                case let (.written, .exact(restored)), let (.recovered, .exact(restored)): changed = restored != entry.id && after != base
                default: changed = true
                }
                state = after
            case let .restore(writeID, _, after):
                changed = before[writeID] ?? true
                state = after
            }
        }
        let sidecars = UsbLayout.oneLibrarySidecarSuffixes.contains { current.files[UsbLayout.oneLibrary + $0] != nil }
        let databases = current.files.filter { databaseOrder.contains($0.key) }.mapValues(\.sha256)
        if databases == base, !sidecars { return false }
        return changed || databases != state || sidecars
    }
}

/// 시점 스냅샷 뒤 DJCrate가 그 볼륨에서 본 것과 한 일(`UsbPointSnapshotRules.deviceChanged`의 사건). 스냅샷 정보와 쓰기 절차의
/// 백업 폴더 기록(manifest·journal·report·restored)에서 모은다
public enum UsbVolumeEvent: Sendable, Equatable {
    /// 시점 스냅샷을 떴다: 그때 DB 셋 해시와 OneLibrary 사이드카가 있었는지
    case snapshot(date: Date, databases: [String: String], sidecars: Bool)
    /// 쓰기 절차로 썼다: 쓰기 전 백업이 본 DB 셋(사이드카가 있었는지)과 결과
    case write(id: String, date: Date, before: [String: String], beforeSidecars: Bool, after: [String: String], kind: UsbWriteEventKind,
               outcome: UsbWriteReport.Outcome)
    /// `usb-restore`가 그 쓰기를 되돌렸다
    case restore(writeID: String, date: Date, after: [String: String])

    public var date: Date {
        switch self {
        case let .snapshot(date, _, _), let .write(_, date, _, _, _, _, _), let .restore(_, date, _): date
        }
    }
}

/// 쓰기가 앞 상태의 기기 행을 결과에 싣는지
public enum UsbWriteEventKind: Sendable, Equatable {
    /// 수정·옮기기·동기화: 기기 행을 이어 쓴다
    case carry
    /// 빈 USB 내보내기
    case fresh
    /// 시점 스냅샷 되돌리기: 그 스냅샷(ID)의 바이트를 그대로 돌려놓는다. 옛 기록처럼 모르면 빈 문자열
    case exact(snapshot: String)
}
