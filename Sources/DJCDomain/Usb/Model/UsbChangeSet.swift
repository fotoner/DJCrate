import Foundation

/// 파일 하나를 USB에 어떻게 두는지
public enum UsbDisposition: String, Codable, Sendable {
    /// 없던 파일을 만든다(같은 이름이 있으면 막는다)
    case create
    /// 있던 파일을 바꾼다(지금 해시가 계획과 같아야 한다)
    case overwrite
    /// 이미 같은 파일이라 쓰지 않는다
    case reuse
}

/// 음원: 로컬 원본 → USB
public struct UsbFileCopy: Codable, Hashable, Sendable {
    public var source: String
    /// USB 상대 경로(NFC)
    public var destination: String
    public var size: Int64
    public var sourceSHA1: String?
    public var modificationDate: Date
    public var disposition: UsbDisposition

    public init(source: String, destination: String, size: Int64, sourceSHA1: String?, modificationDate: Date, disposition: UsbDisposition) {
        self.source = source
        self.destination = destination
        self.size = size
        self.sourceSHA1 = sourceSHA1
        self.modificationDate = modificationDate
        self.disposition = disposition
    }
}

/// 분석 파일·아트워크·설정·동기화 선택: 준비 폴더 파일 → USB
public struct UsbFileWrite: Codable, Hashable, Sendable {
    public var staged: String
    public var destination: String
    public var sha256: String
    public var size: Int64
    public var modificationDate: Date?
    public var disposition: UsbDisposition
    /// 분석 파일 덮어쓰기면 USB 파일의 PPTH가 이것이어야 한다(다른 곡 분석 파일을 덮지 않게)
    public var expectedExistingPPTH: String?
    /// 덮어쓰기 대상의 계획 때 해시
    public var expectedExistingSHA256: String?
    /// 동기화 선택 파일은 DB 교체를 마친 뒤에만 확정한다. 옛 저널은 nil(기존 파일 단계)이다.
    public var afterDatabases: Bool?

    public init(staged: String, destination: String, sha256: String, size: Int64, modificationDate: Date?, disposition: UsbDisposition,
                expectedExistingPPTH: String? = nil, expectedExistingSHA256: String? = nil, afterDatabases: Bool? = nil) {
        self.staged = staged
        self.destination = destination
        self.sha256 = sha256
        self.size = size
        self.modificationDate = modificationDate
        self.disposition = disposition
        self.expectedExistingPPTH = expectedExistingPPTH
        self.expectedExistingSHA256 = expectedExistingSHA256
        self.afterDatabases = afterDatabases
    }
}

/// USB DB 파일 하나를 통째로 바꾼다(`UsbLayout.oneLibrary`·`exportPdb`·`exportExtPdb`)
public struct UsbDatabaseReplacement: Codable, Hashable, Sendable {
    public var format: UsbFormat
    public var destination: String
    public var staged: String
    public var sha256: String
    public var size: Int64

    public init(format: UsbFormat, destination: String, staged: String, sha256: String, size: Int64) {
        self.format = format
        self.destination = destination
        self.staged = staged
        self.sha256 = sha256
        self.size = size
    }
}

/// 지울 파일. 크기·해시(분석 파일은 PPTH도)가 계획과 같을 때만 지운다
public struct UsbFileRemoval: Codable, Hashable, Sendable {
    public var path: String
    public var expectedSHA256: String
    public var expectedSize: Int64
    /// 분석 파일이면 필수
    public var expectedPPTH: String?
    /// 음원이면 되돌릴 때 다시 복사할 로컬 원본
    public var localOriginal: String?
    public var localOriginalSHA1: String?

    public init(path: String, expectedSHA256: String, expectedSize: Int64, expectedPPTH: String?, localOriginal: String?,
                localOriginalSHA1: String?) {
        self.path = path
        self.expectedSHA256 = expectedSHA256
        self.expectedSize = expectedSize
        self.expectedPPTH = expectedPPTH
        self.localOriginal = localOriginal
        self.localOriginalSHA1 = localOriginalSHA1
    }
}

/// 쓴 뒤 USB가 이래야 한다(검증 단계)
public struct UsbTargetFingerprint: Codable, Hashable, Sendable {
    /// 상대 경로 → 크기·SHA-256(해시가 nil이면 크기만 본다)
    public var mustExist: [String: UsbTreeStamp]
    public var mustNotExist: Set<String>

    public init(mustExist: [String: UsbTreeStamp], mustNotExist: Set<String>) {
        self.mustExist = mustExist
        self.mustNotExist = mustNotExist
    }
}

/// USB에 한 번에 쓸 변경 묶음. 형식(OneLibrary·pdb)을 모르는 채로 파일 단위로만 적는다
public struct UsbChangeSet: Codable, Sendable, Equatable {
    /// `UsbLayout.newSessionID()`
    public var session: String
    public var label: String
    public var purpose: UsbVolumePurpose
    public var formats: Set<UsbFormat>
    public var requiredRules: Set<UsbProvisionalRule>
    /// 교체 순서는 늘 exportLibrary.db → export.pdb → exportExt.pdb(적은 순서와 무관)
    public var databases: [UsbDatabaseReplacement]
    public var copies: [UsbFileCopy]
    public var writes: [UsbFileWrite]
    public var removals: [UsbFileRemoval]
    /// 수정이면 필수: 계획 때 USB DB 파일 지문(`UsbWriter.databaseFingerprint`)
    public var base: UsbFingerprint?
    public var target: UsbTargetFingerprint
    public var stagingDirectory: String
    public var idHighWater: [String: Int]
    /// 선택·원본 ID·Dev_ID 검증 기대값. nil인 기존 묶음은 동기화 파일을 건드리지 않는다.
    public var syncSelection: UsbSyncSelectionVerification?

    public init(session: String, label: String, purpose: UsbVolumePurpose, formats: Set<UsbFormat>, requiredRules: Set<UsbProvisionalRule>,
                databases: [UsbDatabaseReplacement], copies: [UsbFileCopy], writes: [UsbFileWrite], removals: [UsbFileRemoval],
                base: UsbFingerprint?, target: UsbTargetFingerprint, stagingDirectory: String, idHighWater: [String: Int],
                syncSelection: UsbSyncSelectionVerification? = nil) {
        self.session = session
        self.label = label
        self.purpose = purpose
        self.formats = formats
        self.requiredRules = requiredRules
        self.databases = databases
        self.copies = copies
        self.writes = writes
        self.removals = removals
        self.base = base
        self.target = target
        self.stagingDirectory = stagingDirectory
        self.idHighWater = idHighWater
        self.syncSelection = syncSelection
    }
}

/// 쓰기 단계(lab `--pause-after`가 받는 이름)
public enum UsbWriteStage: String, Codable, Sendable, CaseIterable {
    case precheck, staged, backedUp, files, commitOneLibrary, commitExport, commitExportExt, cleaned, verified
}

public struct UsbWriteOptions: Sendable {
    public var dryRun = false
    public var confirmName: String? = nil
    /// 음원도 쓴 뒤 매체에서 다시 읽어 해시를 본다
    public var verifyAudio = false
    /// lab 전용: 이 단계를 마친 뒤 `pauseHandler`를 부른다
    public var pauseAfter: UsbWriteStage? = nil
    public var pauseHandler: (@Sendable (UsbWriteStage) -> Void)? = nil
    /// 사용자가 확인한 볼륨의 UUID(앱은 확인 창에 보인 볼륨). 주면 쓰기를 열 때 지금 그 자리의 볼륨과 비교해 다르면 막는다
    public var expectedVolumeUUID: String? = nil

    public init(dryRun: Bool = false, confirmName: String? = nil, verifyAudio: Bool = false,
                pauseAfter: UsbWriteStage? = nil, pauseHandler: (@Sendable (UsbWriteStage) -> Void)? = nil,
                expectedVolumeUUID: String? = nil) {
        self.dryRun = dryRun
        self.confirmName = confirmName
        self.expectedVolumeUUID = expectedVolumeUUID
        self.verifyAudio = verifyAudio
        self.pauseAfter = pauseAfter
        self.pauseHandler = pauseHandler
    }
}

/// 진행 이벤트. 쓰기 절차가 backup…recover를 내고, 세션이 planning·staging을 앞에 더한다
public struct UsbProgress: Sendable, Hashable {
    public enum Phase: String, Codable, Sendable { case planning, staging, backup, files, commit, cleanup, verify, restore, recover }

    public var phase: Phase
    /// 이 단계에서 끝낸 항목(곡·파일·DB) 수
    public var completedItems: Int
    /// 0 = 모름
    public var totalItems: Int
    public var completedBytes: Int64
    /// 0 = 모름
    public var totalBytes: Int64
    /// DB 교체 전까지 true, 그 뒤 false
    public var cancellable: Bool

    public init(phase: Phase, completedItems: Int = 0, totalItems: Int = 0, completedBytes: Int64 = 0, totalBytes: Int64 = 0,
                cancellable: Bool) {
        self.phase = phase
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.cancellable = cancellable
    }
}

/// 맥 쪽 폴더(모두 DJC_HOME 아래)
public struct UsbWritePaths: Sendable {
    /// usb-backups/<볼륨키>/<시각>-<이름>/
    public var backups: URL
    /// usb-sessions/ — 저널 <볼륨키>.json, 잠금 <볼륨키>.lock
    public var sessions: URL
    /// usb-staging/
    public var staging: URL

    public init(backups: URL, sessions: URL, staging: URL) {
        self.backups = backups
        self.sessions = sessions
        self.staging = staging
    }
}
