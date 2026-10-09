import DJCDomain
import Foundation

/// 부분 선택 트리만으로는 원본 값을 복구할 수 없으므로 앱 재시도가 처음 본 원본을 함께 보관한다.
public struct UsbExportSyncSourceContext: Sendable, Equatable {
    public var source: UsbSyncSource
    public var catalogRevision: Int
    /// 읽기 시작에 바뀌므로 quiet 결과를 아직 채택하지 않은 동안도 옛 작업을 막는다.
    public var readEpoch: Int = 0
    /// 원래 URL·목록 읽기 지문·시각을 보관한다. 캐시 참조는 사본을 소유하지 않는다.
    public var snapshot: UsbSyncSnapshotReference? = nil

    public init(source: UsbSyncSource, catalogRevision: Int, readEpoch: Int = 0, snapshot: UsbSyncSnapshotReference? = nil) {
        self.source = source
        self.catalogRevision = catalogRevision
        self.readEpoch = readEpoch
        self.snapshot = snapshot
    }
}

/// 앱의 USB 내보내기 한 번: 로컬 스냅샷 사본의 목록·곡을 어느 볼륨에 어떤 형식으로
public struct UsbExportJob: Sendable, Equatable {
    /// 로컬 스냅샷 사본(라이브 master.db는 세션이 거부한다)
    public var database: URL
    /// 로컬 rekordbox share(읽기만)
    public var share: URL
    public var volume: UsbVolumeInfo
    public var selection: UsbSelection
    public var formats: Set<UsbFormat>
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    public var snapshotTime: String?
    /// 부분 선택을 적용한 로컬·iTunes 목록. 기존 내보내기는 nil로 DB 목록을 읽는다.
    public var playlistLayout: PlaylistLayout? = nil
    /// rekordbox가 다시 여는 USB 동기화 선택. 일반 내보내기는 nil로 그대로 둔다.
    public var syncSelection: UsbSyncSelectionDraft? = nil
    /// 원본이 바뀐 재시도는 동기화 화면에서 다시 준비한다. 세션 옵션에는 앱 상태를 넘기지 않는다.
    public var syncSourceContext: UsbExportSyncSourceContext? = nil
    /// 실행·재시도 시트의 소유권. lastExports에는 이 값 없이 보관한다.
    public var snapshotLease: UsbSyncSnapshotLease? = nil

    public init(database: URL, share: URL, volume: UsbVolumeInfo, selection: UsbSelection, formats: Set<UsbFormat>, snapshotTime: String?,
                playlistLayout: PlaylistLayout? = nil, syncSelection: UsbSyncSelectionDraft? = nil,
                syncSourceContext: UsbExportSyncSourceContext? = nil, snapshotLease: UsbSyncSnapshotLease? = nil) {
        self.database = database
        self.share = share
        self.volume = volume
        self.selection = selection
        self.formats = formats
        self.snapshotTime = snapshotTime
        self.playlistLayout = playlistLayout
        self.syncSelection = syncSelection
        self.syncSourceContext = syncSourceContext
        self.snapshotLease = snapshotLease
    }

    public var volumeKey: String { volume.usbKey }
    public var root: URL { URL(filePath: volume.mountPoint) }

    /// 쓰기 유스케이스 입력. 스냅샷 시각이 없으면 동기화 원본을 고른 때의 시각을 쓴다(앱 상태는 넘기지 않는다)
    public var input: UsbExportInput {
        UsbExportInput(database: database, share: share, volume: volume, selection: selection, formats: formats,
                       snapshotTime: snapshotTime ?? syncSourceContext?.snapshot?.provenance.snapshotTime,
                       playlistLayout: playlistLayout, syncSelection: syncSelection)
    }

    public var options: UsbExportOptions { input.options }
}

/// 앱의 USB 수정 한 번: 이 볼륨에 쌓인 초안을 쓴다(`UsbEditSession.writeDraft`)
public struct UsbEditJob: Sendable, Equatable {
    /// 앱이 이미 연 로컬 스냅샷 사본(곡 더하기·갱신과 음원 지우기 확인에 쓴다. 새로 뜨지 않는다)
    public var database: URL?
    /// 로컬 rekordbox share(읽기만)
    public var share: URL?
    public var volume: UsbVolumeInfo
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    public var snapshotTime: String?
    /// native 선택 초안은 만든 때의 전체 원본을 확인 창 뒤까지 고정한다.
    public var syncSourceContext: UsbExportSyncSourceContext? = nil

    public init(database: URL?, share: URL?, volume: UsbVolumeInfo, snapshotTime: String?, syncSourceContext: UsbExportSyncSourceContext? = nil) {
        self.database = database
        self.share = share
        self.volume = volume
        self.snapshotTime = snapshotTime
        self.syncSourceContext = syncSourceContext
    }

    public var volumeKey: String { volume.usbKey }
    public var root: URL { URL(filePath: volume.mountPoint) }

    /// 쓰기 유스케이스 입력. 스냅샷 시각이 없으면 동기화 원본을 고른 때의 시각을 쓴다(앱 상태는 넘기지 않는다)
    public var input: UsbEditInput {
        UsbEditInput(database: database, share: share, volume: volume,
                     snapshotTime: snapshotTime ?? syncSourceContext?.snapshot?.provenance.snapshotTime)
    }
}

/// 쓰기 취소 표지. 메인 액터에서 켜고 쓰기 절차(메인 액터 밖)가 읽는다
public final class UsbCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}
