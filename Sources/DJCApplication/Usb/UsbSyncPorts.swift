import DJCDomain
import Foundation

// USB 동기화 창(`UsbSync`)의 피동 포트. 파일 읽기(`UsbSyncFiles`)·짝짓기 키(`LocalLibraryKeysSource`)는 DJCAdapters의 실제 구현을
// 앱 조립 지점(`UsbAppSetup`)이 고르고, 라이브러리·USB 화면 상태와 쓰기 흐름·확인 창은 앱 화면 쪽(`UsbSyncModel`)이 붙인다.
// 화면으로 내보내는 상태·알림은 출력 포트 `UsbSyncOutput`(`UsbSync.swift`). 시험은 가짜를 넣는다(DJCApplicationTests `UsbSyncFakes`).

/// USB 동기화 선택 파일(rekordbox의 Sync/Playlists, 두 형식)을 읽은 값. 원문과 지문, 원본 목록에 맞춰 푸는 함수
public struct UsbSyncNativeSelection: Sendable {
    /// 형식별 원문(없는 형식은 키가 없다). 쓸 때 이 원문 그대로인지 다시 본다
    public var baseFiles: [UsbFormat: Data]
    /// 두 형식이 같은 선택일 때의 의미 지문(다르면 nil)
    public var semanticFingerprint: String?
    /// 원본 목록·로컬 DBID·USB 라이브러리·masterPlaylists6.xml의 rekordbox NODE로 선택을 푼다
    public var resolve: @Sendable (_ sourceNodes: [UsbSyncSourceNode], _ localDBID: Int64, _ library: UsbLibrary?,
                                   _ masterNodeIDs: Set<String>?) -> UsbSyncSelectionResolution

    public init(baseFiles: [UsbFormat: Data], semanticFingerprint: String?,
                resolve: @escaping @Sendable ([UsbSyncSourceNode], Int64, UsbLibrary?, Set<String>?) -> UsbSyncSelectionResolution) {
        self.baseFiles = baseFiles
        self.semanticFingerprint = semanticFingerprint
        self.resolve = resolve
    }
}

/// 볼륨별 동기화 선택 설정 파일(데이터 폴더의 `usb-sync-selections`)
public struct UsbSyncPreferencesFiles: Sendable {
    /// 없으면 nil
    public var load: @Sendable (_ volumeKey: String) throws -> UsbSyncPreferences?
    public var save: @Sendable (UsbSyncPreferences) throws -> Void

    public init(load: @escaping @Sendable (String) throws -> UsbSyncPreferences?, save: @escaping @Sendable (UsbSyncPreferences) throws -> Void) {
        self.load = load
        self.save = save
    }
}

/// 동기화가 읽는 파일(메인 액터 밖에서 부른다). 실제 구현은 DJCAdapters `UsbSyncFiles.live`
public struct UsbSyncFiles: Sendable {
    /// USB 루트의 동기화 선택 파일
    public var selection: @Sendable (_ root: URL, _ formats: Set<UsbFormat>) throws -> UsbSyncNativeSelection
    /// 로컬 스냅샷을 뜰 때 함께 복사한 masterPlaylists6.xml의 NODE(옛 스냅샷이거나 읽지 못하면 빈 배열)
    public var masterNodes: @Sendable (_ snapshot: URL) -> [MasterPlaylistNode]
    /// 그 폴더의 동기화 선택 설정 파일
    public var preferences: @Sendable (_ directory: URL) -> UsbSyncPreferencesFiles

    public init(selection: @escaping @Sendable (URL, Set<UsbFormat>) throws -> UsbSyncNativeSelection,
                masterNodes: @escaping @Sendable (URL) -> [MasterPlaylistNode],
                preferences: @escaping @Sendable (URL) -> UsbSyncPreferencesFiles) {
        self.selection = selection
        self.masterNodes = masterNodes
        self.preferences = preferences
    }
}

/// 동기화가 보는 로컬 라이브러리 화면 상태(읽을 때마다 지금 값)
public struct UsbSyncLibraryState: Sendable {
    /// 화면이 연 스냅샷(없으면 아직 읽지 않았다)
    public var snapshot: URL?
    /// 목록·곡 상태가 바뀔 때마다 느는 번호
    public var revision: Int
    /// 스냅샷 읽기를 시작할 때마다 느는 번호
    public var readEpoch: Int
    /// 동기화가 쓸 수 있는 스냅샷 출처(읽는 중이거나 바뀌면 nil)
    public var provenance: UsbSyncSnapshotProvenance?
    /// 로컬 rekordbox share(읽기만)
    public var share: URL
    public var isLoading: Bool
    /// rekordbox에 쓰는 중
    public var isWriting: Bool
    /// 쓰기 잠금이 라이브러리 조작을 허락하는지
    public var allowsInteraction: Bool

    public init(snapshot: URL?, revision: Int, readEpoch: Int, provenance: UsbSyncSnapshotProvenance?, share: URL, isLoading: Bool,
                isWriting: Bool, allowsInteraction: Bool) {
        self.snapshot = snapshot
        self.revision = revision
        self.readEpoch = readEpoch
        self.provenance = provenance
        self.share = share
        self.isLoading = isLoading
        self.isWriting = isWriting
        self.allowsInteraction = allowsInteraction
    }
}

/// 동기화가 보는 이 볼륨의 USB 화면 상태(읽을 때마다 지금 값)
public struct UsbSyncVolumeState: Sendable {
    /// 붙어 있는 볼륨(빠졌으면 nil)
    public var volume: UsbVolumeInfo?
    /// 읽은 라이브러리
    public var library: UsbLibrary?
    /// 내보낼 수 있는 빈 USB
    public var isEmptyExportable: Bool
    /// 어느 볼륨에든 쓰는 중
    public var isWriting: Bool
    public var isEjecting: Bool
    /// 이 볼륨의 쓰기 대기 초안
    public var draftEdits: [UsbLibraryEdit]

    public init(volume: UsbVolumeInfo?, library: UsbLibrary?, isEmptyExportable: Bool, isWriting: Bool, isEjecting: Bool,
                draftEdits: [UsbLibraryEdit]) {
        self.volume = volume
        self.library = library
        self.isEmptyExportable = isEmptyExportable
        self.isWriting = isWriting
        self.isEjecting = isEjecting
        self.draftEdits = draftEdits
    }
}

/// 이 볼륨의 USB 초안(쓰기 대기 목록과 같은 초안)
@MainActor
public struct UsbSyncDrafts {
    /// 초안에 더하기 전에 아는 막힘(이유와 할 일). 없으면 nil
    public var blockReason: @MainActor ([UsbLibraryEdit]) -> String?
    /// 초안에 더한다(쓰기 대기 목록에 보일 설명과 함께). 저장했으면 true
    public var append: @MainActor ([UsbLibraryEdit], _ detail: String) async -> Bool

    public init(blockReason: @escaping @MainActor ([UsbLibraryEdit]) -> String?, append: @escaping @MainActor ([UsbLibraryEdit], String) async -> Bool) {
        self.blockReason = blockReason
        self.append = append
    }
}

/// USB 쓰기 흐름(다른 USB 쓰기와 같은 잠금·미리 보기·확인 창·결과 알림)
@MainActor
public struct UsbSyncWriter {
    /// 빈 USB에 내보낸다. 썼으면 true
    public var export: @MainActor (UsbExportJob) async -> Bool
    /// 동기화 초안을 그 문맥으로 쓴다. 썼으면 true
    public var writeSyncDraft: @MainActor (UsbEditJob, [UsbLibraryEdit]) async -> Bool
    /// 쓰지 못했을 때 알린 결과의 설명(창에 다시 보인다)
    public var lastNoticeDetail: @MainActor () -> String?

    public init(export: @escaping @MainActor (UsbExportJob) async -> Bool, writeSyncDraft: @escaping @MainActor (UsbEditJob, [UsbLibraryEdit]) async -> Bool,
                lastNoticeDetail: @escaping @MainActor () -> String?) {
        self.export = export
        self.writeSyncDraft = writeSyncDraft
        self.lastNoticeDetail = lastNoticeDetail
    }
}

/// 동기화 창이 받는 포트 묶음
@MainActor
public struct UsbSyncPorts {
    public var library: @MainActor () -> UsbSyncLibraryState
    /// 지금 라이브러리 화면의 동기화 원본(rekordbox·iTunes 목록)
    public var sources: @MainActor () -> UsbSyncSource
    /// 동기화가 읽고 쓸 로컬 스냅샷 사본을 빌린다(지금 스냅샷이 동기화 출처가 아니거나 바뀌면 nil)
    public var leaseSnapshot: @MainActor () async -> UsbSyncSnapshotLease?
    /// 로컬 곡을 USB에 넣을 수 없는 까닭(넣을 수 있으면 nil)
    public var localSkip: @MainActor (_ contentID: String) -> UsbSyncSource.LocalSkip?
    public var volume: @MainActor () -> UsbSyncVolumeState
    /// USB를 모두 다시 읽는다
    public var refreshUsb: @MainActor () async -> Void
    /// USB 쓰기 창구(지금 볼륨 다시 보기·DB 지문·선택 파일 관문·rekordbox 실행 판정)
    public var service: any UsbWriting
    /// 파일 읽기. 없으면 선택·라이브러리를 읽지 못한 것으로 알린다
    public var files: UsbSyncFiles?
    /// 로컬 짝짓기 키. 없으면 선택·라이브러리를 읽지 못한 것으로 알린다
    public var localKeys: LocalLibraryKeysSource?
    /// 동기화 선택 설정 파일. 없으면 저장하지 않는다(시험·캡처의 기본)
    public var preferences: UsbSyncPreferencesFiles?
    public var confirmation: UserConfirmation
    /// 초안. 없으면 동기화 초안을 만들지 않는다
    public var drafts: UsbSyncDrafts?
    /// 쓰기 흐름. 없으면 쓰지 않는다
    public var writer: UsbSyncWriter?
    /// USB의 큐·그리드를 로컬 초안으로 가져온다(결과 문구)
    public var importCueGrid: @MainActor () async -> UsbCueGridImportSummary
    /// 새로 만들 USB 목록의 초안 키(앱은 `sync-<UUID>`)
    public var newPlaylistKey: () -> String
    /// 알리지 않는 오류 기록
    public var log: @MainActor (any Error) -> Void

    public init(library: @escaping @MainActor () -> UsbSyncLibraryState, sources: @escaping @MainActor () -> UsbSyncSource,
                leaseSnapshot: @escaping @MainActor () async -> UsbSyncSnapshotLease?,
                localSkip: @escaping @MainActor (String) -> UsbSyncSource.LocalSkip?, volume: @escaping @MainActor () -> UsbSyncVolumeState,
                refreshUsb: @escaping @MainActor () async -> Void, service: any UsbWriting, files: UsbSyncFiles?, localKeys: LocalLibraryKeysSource?,
                preferences: UsbSyncPreferencesFiles?, confirmation: UserConfirmation, drafts: UsbSyncDrafts?, writer: UsbSyncWriter?,
                importCueGrid: @escaping @MainActor () async -> UsbCueGridImportSummary, newPlaylistKey: @escaping () -> String,
                log: @escaping @MainActor (any Error) -> Void) {
        self.library = library
        self.sources = sources
        self.leaseSnapshot = leaseSnapshot
        self.localSkip = localSkip
        self.volume = volume
        self.refreshUsb = refreshUsb
        self.service = service
        self.files = files
        self.localKeys = localKeys
        self.preferences = preferences
        self.confirmation = confirmation
        self.drafts = drafts
        self.writer = writer
        self.importCueGrid = importCueGrid
        self.newPlaylistKey = newPlaylistKey
        self.log = log
    }
}
