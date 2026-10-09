import DJCDomain
import Foundation

/// 엔진이 연 로컬 라이브러리 사본(읽기 전용 연결). 속은 어댑터만 안다. 세션이 끝나면(성공·실패·취소) 닫는다
public protocol UsbOpenedLibrary: AnyObject {
    func close()
}

/// USB DB 셋을 Mac 쪽 사본으로 뜬 것(`UsbSnapshot`): 사본 파일과 뜰 때의 USB DB 지문·사이드카 상태
public struct UsbDatabaseCopy: Sendable {
    public var oneLibrary: URL?
    public var exportPdb: URL?
    public var exportExtPdb: URL?
    public var fingerprint: UsbFingerprint
    /// OneLibrary 머리가 롤백 저널 모양인지(아니면 WAL 모양)
    public var rollbackHeader: Bool
    public var walPresent: Bool
    public var journalPresent: Bool

    public init(oneLibrary: URL?, exportPdb: URL?, exportExtPdb: URL?, fingerprint: UsbFingerprint, rollbackHeader: Bool,
                walPresent: Bool, journalPresent: Bool) {
        self.oneLibrary = oneLibrary
        self.exportPdb = exportPdb
        self.exportExtPdb = exportExtPdb
        self.fingerprint = fingerprint
        self.rollbackHeader = rollbackHeader
        self.walPresent = walPresent
        self.journalPresent = journalPresent
    }
}

/// pdb 사본을 읽은 것
public struct UsbDeviceLibraryRead: Sendable {
    public var library: UsbLibrary
    public var report: PdbReadReport

    public init(library: UsbLibrary, report: PdbReadReport) {
        self.library = library
        self.report = report
    }
}

/// 내보내기 빌더가 만든 것: 계획·막힘과, 조립에 그대로 넘길 모델(엔진만 아는 값)
public struct UsbExportBuilt: Sendable {
    public var plan: UsbExportPlan
    public var blocks: [UsbBlock]
    public var model: any Sendable

    public init(plan: UsbExportPlan, blocks: [UsbBlock], model: any Sendable) {
        self.plan = plan
        self.blocks = blocks
        self.model = model
    }

    /// 볼륨 막힘(이것이 있으면 조립하지 않는다)
    public var volumeBlocks: [UsbBlock] { blocks.filter { $0.scope == .volume } }
}

/// 내보내기 조립 입력(준비 폴더에 DB 셋·분석 파일·아트워크를 만든다)
public struct UsbExportAssembleInput {
    public var built: UsbExportBuilt
    public var local: any UsbOpenedLibrary
    public var share: URL
    public var staging: URL
    public var formats: Set<UsbFormat>
    public var session: String
    public var settingsFolder: URL?
    public var syncSelection: UsbSyncSelectionDraft?
    /// (끝낸 곡, 곡 수)
    public var progress: (Int, Int) -> Void
    public var isCancelled: () -> Bool

    public init(built: UsbExportBuilt, local: any UsbOpenedLibrary, share: URL, staging: URL, formats: Set<UsbFormat>, session: String,
                settingsFolder: URL?, syncSelection: UsbSyncSelectionDraft?, progress: @escaping (Int, Int) -> Void,
                isCancelled: @escaping () -> Bool) {
        self.built = built
        self.local = local
        self.share = share
        self.staging = staging
        self.formats = formats
        self.session = session
        self.settingsFolder = settingsFolder
        self.syncSelection = syncSelection
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

/// 수정 세션이 읽은 USB(두 형식을 사본으로 읽어 합친 것). 세션은 막힘만 보고 계획 때 엔진에 그대로 돌려준다
public struct UsbEditSourceRead: Sendable {
    public var blocks: [UsbBlock]
    public var source: any Sendable

    public init(blocks: [UsbBlock], source: any Sendable) {
        self.blocks = blocks
        self.source = source
    }
}

/// 수정 계획 입력
public struct UsbEditPlanInput {
    public var source: UsbEditSourceRead
    public var edits: [UsbLibraryEdit]
    /// 곡 더하기·갱신·동기화가 있을 때만 연 세션 사본
    public var local: (any UsbOpenedLibrary)?
    public var share: URL?
    public var volume: UsbVolumeInfo
    public var root: URL
    public var staging: URL
    public var session: String
    /// 닫힌 저널이 이어 쓰라고 남긴 ID 상한
    public var highWater: [String: Int]
    public var snapshotTakenAt: Date?
    public var appVersion: String?
    public var progress: (Int, Int) -> Void
    public var isCancelled: () -> Bool

    public init(source: UsbEditSourceRead, edits: [UsbLibraryEdit], local: (any UsbOpenedLibrary)?, share: URL?, volume: UsbVolumeInfo,
                root: URL, staging: URL, session: String, highWater: [String: Int], snapshotTakenAt: Date?, appVersion: String?,
                progress: @escaping (Int, Int) -> Void, isCancelled: @escaping () -> Bool) {
        self.source = source
        self.edits = edits
        self.local = local
        self.share = share
        self.volume = volume
        self.root = root
        self.staging = staging
        self.session = session
        self.highWater = highWater
        self.snapshotTakenAt = snapshotTakenAt
        self.appVersion = appVersion
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

/// 쓴 뒤 다시 읽어 검증하는 방식(형식별 검증기·쓰기 전 검사기)
public enum UsbWriteVerification: Sendable {
    case export(UsbExportAssembled)
    case edit(UsbEditResult)
    case migration(UsbMigrationResult)
}

/// `UsbWriter.write` 한 번. 가드·Mac 쪽 폴더는 세션이 조립 지점에서 받은 것을 그대로 넘긴다
public struct UsbWriteRequest: Sendable {
    public var changes: UsbChangeSet
    public var verification: UsbWriteVerification
    public var root: URL
    public var paths: UsbWritePaths
    public var writeGuard: UsbWriteGuard
    public var options: UsbWriteOptions
    /// 쓰기 직전 USB의 `._*`(검증이 이 쓰기가 남긴 것으로 세지 않게)
    public var preexistingAppleDoubles: Set<String>
    public var progress: @Sendable (UsbProgress) -> Void
    public var isCancelled: @Sendable () -> Bool

    public init(changes: UsbChangeSet, verification: UsbWriteVerification, root: URL, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard,
                options: UsbWriteOptions, preexistingAppleDoubles: Set<String>, progress: @escaping @Sendable (UsbProgress) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) {
        self.changes = changes
        self.verification = verification
        self.root = root
        self.paths = paths
        self.writeGuard = writeGuard
        self.options = options
        self.preexistingAppleDoubles = preexistingAppleDoubles
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

/// `UsbWriter.recover` 한 번(끝나지 않은 쓰기를 마저 쓰거나 되돌린다)
public struct UsbRecoverRequest: Sendable {
    public var root: URL
    public var paths: UsbWritePaths
    public var writeGuard: UsbWriteGuard
    public var discardTemp: Bool
    public var confirmName: String?
    public var expectedVolumeUUID: String?

    public init(root: URL, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard, discardTemp: Bool = false, confirmName: String?,
                expectedVolumeUUID: String?) {
        self.root = root
        self.paths = paths
        self.writeGuard = writeGuard
        self.discardTemp = discardTemp
        self.confirmName = confirmName
        self.expectedVolumeUUID = expectedVolumeUUID
    }
}

/// `UsbWriter.restore` 한 번(쓴 것을 그 쓰기 전 백업으로 되돌린다). backup이 nil이면 이 볼륨의 가장 최근 백업
public struct UsbRestoreRequest: Sendable {
    public var root: URL
    public var paths: UsbWritePaths
    public var writeGuard: UsbWriteGuard
    public var backup: URL?
    public var discardDeviceChanges: Bool
    public var confirmName: String?
    public var dryRun: Bool
    public var expectedVolumeUUID: String?

    public init(root: URL, paths: UsbWritePaths, guard writeGuard: UsbWriteGuard, backup: URL?, discardDeviceChanges: Bool,
                confirmName: String?, dryRun: Bool = false, expectedVolumeUUID: String?) {
        self.root = root
        self.paths = paths
        self.writeGuard = writeGuard
        self.backup = backup
        self.discardDeviceChanges = discardDeviceChanges
        self.confirmName = confirmName
        self.dryRun = dryRun
        self.expectedVolumeUUID = expectedVolumeUUID
    }
}

/// 볼륨 저널 파일의 상태(`UsbWriter.journalStatus`). 쓰기·되돌리기·회복과 앱이 같은 판정을 쓴다
public enum UsbJournalStatus: Equatable, Sendable {
    case missing
    /// 끝나지 않은 쓰기(회복해야 다음 쓰기를 한다)
    case open(UsbJournalState)
    /// 닫힌 저널. 다음 쓰기는 그 ID 상한을 이어 쓴다
    case closed(UsbJournalState, idHighWater: [String: Int])
    /// 파일은 있으나 읽지 못함(쓰기·되돌리기·회복 모두 막힌다)
    case corrupt
}

/// 동기화 선택 파일의 쓰기 관문 규칙(`UsbSyncSelectionStage`). 확인한 계약(비상 스위치)을 보므로 엔진 쪽에 있다
public struct UsbSyncSelectionGate: Sendable {
    /// 확인한 계약이 없거나 두 형식 중 한쪽 선택 파일만 있으면 막힘
    public var gateBlock: @Sendable (_ baseFiles: [UsbFormat: Data], _ formats: Set<UsbFormat>) -> UsbBlock?
    /// 확인한 계약이 없을 때의 막힘
    public var productionBlock: @Sendable () -> UsbBlock?
    /// 쓰기 전에 초안만 보고 아는 막힘
    public var draftBlock: @Sendable (UsbSyncSelectionDraft) -> UsbBlock?

    public init(gateBlock: @escaping @Sendable ([UsbFormat: Data], Set<UsbFormat>) -> UsbBlock?,
                productionBlock: @escaping @Sendable () -> UsbBlock?, draftBlock: @escaping @Sendable (UsbSyncSelectionDraft) -> UsbBlock?) {
        self.gateBlock = gateBlock
        self.productionBlock = productionBlock
        self.draftBlock = draftBlock
    }
}

/// USB 라이브러리 엔진(피동 포트): USB DB 셋 읽기(OneLibrary·Device Library), 내보내기·수정·옮기기의 계획·준비, 쓰기·회복·되돌리기·저널.
/// 실제 구현(`.live(fileSystem:)`)은 DJCAdapters가 RekordboxKit/Usb를 감싸 만든다(쓰기는 `UsbWriter.write` 한 곳). 유스케이스는 순서·판정만 한다.
public struct UsbLibraryEngine: Sendable {
    /// USB 볼륨을 읽기만 하는 일. USB에는 아무것도 쓰지 않고 열지 않는 경로는 열지 않는다
    public struct Read: Sendable {
        /// `PIONEER/rekordbox` 바로 아래 일반 파일 이름(없으면 빈 집합)
        public var rekordboxFileNames: @Sendable (_ root: URL) throws -> Set<String>
        /// lstat으로 있는지(링크도 있음으로 본다)
        public var exists: @Sendable (_ root: URL, _ relative: String) -> Bool
        /// 링크가 아닌 일반 파일인지
        public var isRegularFile: @Sendable (_ root: URL, _ relative: String) -> Bool
        /// DB 셋을 Mac 쪽 사본으로 뜬다(사본 폴더는 없거나 비어 있어야 한다)
        public var copyDatabases: @Sendable (_ root: URL, _ into: URL) throws -> UsbDatabaseCopy
        /// pdb 둘만 사본으로 뜬다(OneLibrary 사본이 온전하지 않을 때). pdb가 없으면 nil
        public var copyPdb: @Sendable (_ root: URL, _ into: URL) throws -> (export: URL, ext: URL?)?
        /// OneLibrary 사본을 읽는다(모르는 모양이면 `formatUnsupported`)
        public var oneLibrary: @Sendable (_ copy: URL) throws -> UsbLibrary
        /// pdb 사본을 읽는다(머리가 달라 읽지 못하면 `readFailed`)
        public var deviceLibrary: @Sendable (_ export: URL, _ ext: URL?) throws -> UsbDeviceLibraryRead
        /// pdb 사본의 왕복 검사(읽기 → 모델 → 다시 쓰기 → 다시 읽기). 문제 목록(빈 배열 = 통과)
        public var roundTrip: @Sendable (_ export: URL, _ ext: URL?) throws -> [String]
        /// 분석 파일(.DAT)의 PPTH에 적힌 곡 경로(읽지 못하면 nil)
        public var analysisTrackPath: @Sendable (_ root: URL, _ datRelative: String) -> String?
        /// 기기 설정 파일 셋(고정 이름만 연다)
        public var settings: @Sendable (_ root: URL) -> [UsbInfo.Setting]

        public init(rekordboxFileNames: @escaping @Sendable (URL) throws -> Set<String>, exists: @escaping @Sendable (URL, String) -> Bool,
                    isRegularFile: @escaping @Sendable (URL, String) -> Bool, copyDatabases: @escaping @Sendable (URL, URL) throws -> UsbDatabaseCopy,
                    copyPdb: @escaping @Sendable (URL, URL) throws -> (export: URL, ext: URL?)?, oneLibrary: @escaping @Sendable (URL) throws -> UsbLibrary,
                    deviceLibrary: @escaping @Sendable (URL, URL?) throws -> UsbDeviceLibraryRead,
                    roundTrip: @escaping @Sendable (URL, URL?) throws -> [String], analysisTrackPath: @escaping @Sendable (URL, String) -> String?,
                    settings: @escaping @Sendable (URL) -> [UsbInfo.Setting]) {
            self.rekordboxFileNames = rekordboxFileNames
            self.exists = exists
            self.isRegularFile = isRegularFile
            self.copyDatabases = copyDatabases
            self.copyPdb = copyPdb
            self.oneLibrary = oneLibrary
            self.deviceLibrary = deviceLibrary
            self.roundTrip = roundTrip
            self.analysisTrackPath = analysisTrackPath
            self.settings = settings
        }
    }

    /// 빈 USB 내보내기의 계획·준비(USB에는 쓰지 않는다)
    public struct Export: Sendable {
        /// `PIONEER/rekordbox/`(철자 무관) 바로 아래에 DB 파일 이름이 하나라도 있는지. 이름만 본다
        public var hasLibrary: @Sendable (_ root: URL) throws -> Bool
        /// DB는 없는데 `PIONEER/` 아래 남은 것이 있으면 그 막힘
        public var leftoverBlock: @Sendable (_ root: URL) -> UsbBlock?
        /// USB에 이미 있는 것(이름·ID·아트워크·분석 자리)
        public var existingContents: @Sendable (_ root: URL) throws -> UsbExistingState?
        /// 선택한 목록 모델(로컬·iTunes)에서 목록 트리. 반영하지 않은 목록이면 `writeRefused`
        public var layoutTree: @Sendable (_ layout: PlaylistLayout, _ rootIDs: [String]) throws -> [UsbPlaylistInput]
        /// 로컬 사본의 재생 목록 트리(폴더면 그 안까지)
        public var playlistTree: @Sendable (_ local: any UsbOpenedLibrary, _ rootIDs: [String]) throws -> [UsbPlaylistInput]
        /// 내보낼 곡 후보(없는 행·삭제된 행은 돌려주지 않는다)
        public var candidates: @Sendable (_ local: any UsbOpenedLibrary, _ share: URL, _ contentIDs: [String]) throws -> [UsbExportCandidate]
        /// 후보 음원과 USB의 그 파일이 같은 내용인지(크기·SHA-256). 이름이 겹칠 때만 부른다
        public var sameContent: @Sendable (_ sourcePath: String, _ usbFile: URL) -> Bool
        /// 계획 → 빌더(Device Library에 안 들어가는 곡은 빼고 다시 계획)
        public var build: @Sendable (_ request: UsbExportRequest, _ local: any UsbOpenedLibrary, _ share: URL, _ createdDate: String) throws
            -> UsbExportBuilt
        /// 준비 폴더에 DB 셋·분석 파일·아트워크를 만들고 변경 묶음을 얻는다
        public var assemble: @Sendable (UsbExportAssembleInput) throws -> UsbExportAssembled

        public init(hasLibrary: @escaping @Sendable (URL) throws -> Bool, leftoverBlock: @escaping @Sendable (URL) -> UsbBlock?,
                    existingContents: @escaping @Sendable (URL) throws -> UsbExistingState?,
                    layoutTree: @escaping @Sendable (PlaylistLayout, [String]) throws -> [UsbPlaylistInput],
                    playlistTree: @escaping @Sendable (any UsbOpenedLibrary, [String]) throws -> [UsbPlaylistInput],
                    candidates: @escaping @Sendable (any UsbOpenedLibrary, URL, [String]) throws -> [UsbExportCandidate],
                    sameContent: @escaping @Sendable (String, URL) -> Bool,
                    build: @escaping @Sendable (UsbExportRequest, any UsbOpenedLibrary, URL, String) throws -> UsbExportBuilt,
                    assemble: @escaping @Sendable (UsbExportAssembleInput) throws -> UsbExportAssembled) {
            self.hasLibrary = hasLibrary
            self.leftoverBlock = leftoverBlock
            self.existingContents = existingContents
            self.layoutTree = layoutTree
            self.playlistTree = playlistTree
            self.candidates = candidates
            self.sameContent = sameContent
            self.build = build
            self.assemble = assemble
        }
    }

    /// 이미 라이브러리가 있는 USB 수정의 읽기·계획·준비
    public struct Edit: Sendable {
        /// USB DB 사본을 떠서 두 형식을 읽고 합친다(전제 막힘 포함)
        public var load: @Sendable (_ root: URL, _ into: URL) throws -> UsbEditSourceRead
        /// 편집을 계획하고 준비 폴더에 만든다
        public var plan: @Sendable (UsbEditPlanInput) throws -> UsbEditResult

        public init(load: @escaping @Sendable (URL, URL) throws -> UsbEditSourceRead, plan: @escaping @Sendable (UsbEditPlanInput) throws -> UsbEditResult) {
            self.load = load
            self.plan = plan
        }
    }

    /// Device Library만 있는 USB에 OneLibrary 더하기의 계획·준비
    public struct Migration: Sendable {
        /// 이미 OneLibrary가 있는 USB의 막힘
        public var oneLibraryExistsBlock: UsbBlock
        /// USB DB 사본(`copyInto`) → 계획 → 준비 폴더
        public var plan: @Sendable (_ root: URL, _ copyInto: URL, _ staging: URL, _ session: String) throws -> UsbMigrationResult

        public init(oneLibraryExistsBlock: UsbBlock, plan: @escaping @Sendable (URL, URL, URL, String) throws -> UsbMigrationResult) {
            self.oneLibraryExistsBlock = oneLibraryExistsBlock
            self.plan = plan
        }
    }

    /// USB 큐·그리드 → 로컬 초안 가져오기의 읽기(rekordbox·USB에는 쓰지 않는다)
    public struct CueGrid: Sendable {
        /// 로컬 스냅샷 사본을 읽기 전용으로 열어 라이브 DB가 아닌지·DBID를 본 뒤 짝짓기 키를 읽는다
        public var localKeys: @Sendable (_ snapshot: URL) throws -> LocalLibraryKeys
        /// OneLibrary 사본에서 기기 큐 행이 있는 content_id
        public var deviceCueContentIDs: @Sendable (_ oneLibraryCopy: URL) throws -> Set<Int>
        /// USB 분석 파일 한 곡의 큐·박
        public var readTrack: @Sendable (_ root: URL, _ track: UsbTrack) throws -> UsbCueGridRead
        /// 로컬 분석 파일(.DAT) 자리(share 아래)
        public var analysisURL: @Sendable (_ analysisDataPath: String?, _ share: URL) -> URL?
        /// 로컬 분석 파일의 비트그리드
        public var localGrid: @Sendable (_ dat: URL) throws -> BeatGrid
        /// USB DB 셋이 사본을 뜬 때와 같은지(크기·시각·SHA-256)
        public var databasesUnchanged: @Sendable (_ since: UsbFingerprint, _ root: URL) throws -> Bool
        /// 로컬 큐로 시작하는 초안의 새 큐 ID(가져온 큐를 맞출 로컬 큐)
        public var newCueID: @Sendable () -> UUID

        public init(localKeys: @escaping @Sendable (URL) throws -> LocalLibraryKeys, deviceCueContentIDs: @escaping @Sendable (URL) throws -> Set<Int>,
                    readTrack: @escaping @Sendable (URL, UsbTrack) throws -> UsbCueGridRead,
                    analysisURL: @escaping @Sendable (String?, URL) -> URL?, localGrid: @escaping @Sendable (URL) throws -> BeatGrid,
                    databasesUnchanged: @escaping @Sendable (UsbFingerprint, URL) throws -> Bool,
                    newCueID: @escaping @Sendable () -> UUID) {
            self.localKeys = localKeys
            self.deviceCueContentIDs = deviceCueContentIDs
            self.readTrack = readTrack
            self.analysisURL = analysisURL
            self.localGrid = localGrid
            self.databasesUnchanged = databasesUnchanged
            self.newCueID = newCueID
        }
    }

    /// USB 쓰기 절차(`UsbWriter`): 쓰기·회복·되돌리기·저널·백업·DB 지문
    public struct Writer: Sendable {
        /// 쓰기 직전 USB의 `._*` 상대 경로
        public var preexistingAppleDoubles: @Sendable (_ root: URL) throws -> Set<String>
        public var write: @Sendable (UsbWriteRequest) throws -> UsbWriteReport
        public var recover: @Sendable (UsbRecoverRequest) throws -> UsbWriteReport
        public var restore: @Sendable (UsbRestoreRequest) throws -> UsbWriteReport
        public var journalStatus: @Sendable (_ paths: UsbWritePaths, _ volumeKey: String) -> UsbJournalStatus
        /// 이 볼륨의 백업 폴더(최근 것 먼저)
        public var backups: @Sendable (_ paths: UsbWritePaths, _ volumeKey: String) -> [URL]
        /// USB DB 파일(사이드카 포함)의 지금 지문(DB 파일의 크기·해시만 읽는다)
        public var databaseFingerprint: @Sendable (_ root: URL) throws -> UsbFingerprint

        public init(preexistingAppleDoubles: @escaping @Sendable (URL) throws -> Set<String>,
                    write: @escaping @Sendable (UsbWriteRequest) throws -> UsbWriteReport,
                    recover: @escaping @Sendable (UsbRecoverRequest) throws -> UsbWriteReport,
                    restore: @escaping @Sendable (UsbRestoreRequest) throws -> UsbWriteReport,
                    journalStatus: @escaping @Sendable (UsbWritePaths, String) -> UsbJournalStatus,
                    backups: @escaping @Sendable (UsbWritePaths, String) -> [URL],
                    databaseFingerprint: @escaping @Sendable (URL) throws -> UsbFingerprint) {
            self.preexistingAppleDoubles = preexistingAppleDoubles
            self.write = write
            self.recover = recover
            self.restore = restore
            self.journalStatus = journalStatus
            self.backups = backups
            self.databaseFingerprint = databaseFingerprint
        }
    }

    /// 세션 사본을 읽기 전용으로 연다(라이브 master.db 판정은 세션이 사본을 뜨기 전에 한다)
    public var openLocal: @Sendable (_ copy: URL) throws -> any UsbOpenedLibrary
    public var read: Read
    public var export: Export
    public var edit: Edit
    public var migration: Migration
    public var cueGrid: CueGrid
    public var writer: Writer
    public var syncGate: UsbSyncSelectionGate
    /// USB 동기화 선택 파일 원문(형식별, 없는 형식은 키가 없다)
    public var syncSelectionFiles: @Sendable (_ root: URL, _ formats: Set<UsbFormat>) throws -> [UsbFormat: Data]

    public init(openLocal: @escaping @Sendable (URL) throws -> any UsbOpenedLibrary, read: Read, export: Export, edit: Edit,
                migration: Migration, cueGrid: CueGrid, writer: Writer, syncGate: UsbSyncSelectionGate,
                syncSelectionFiles: @escaping @Sendable (URL, Set<UsbFormat>) throws -> [UsbFormat: Data]) {
        self.openLocal = openLocal
        self.read = read
        self.export = export
        self.edit = edit
        self.migration = migration
        self.cueGrid = cueGrid
        self.writer = writer
        self.syncGate = syncGate
        self.syncSelectionFiles = syncSelectionFiles
    }
}
