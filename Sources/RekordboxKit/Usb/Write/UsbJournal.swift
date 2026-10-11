import DJCDomain
import Foundation

/// USB 쓰기 진행 기록. USB가 아니라 맥(`usb-sessions/<볼륨키>.json`)에 두어 USB가 뽑혀도 회복할 근거가 남는다.
/// 바꿀 때마다 내구 쓰기(`UsbDurableFile`)로 디스크에 내린 뒤 다음 USB 연산을 한다.
public struct UsbJournal: Codable, Sendable, Equatable {
    public typealias State = UsbJournalState

    /// 닫힌 상태(`UsbJournalState.closed`). 닫힌 저널은 다음 쓰기를 막지 않는다(드라이 런·다시 계획 포함). 앱·회복·백업 정리도 이것만 본다
    public static let closedStates: Set<State> = UsbJournalState.closed

    public var isClosed: Bool { Self.closedStates.contains(state) }

    public enum FileDisposition: String, Codable, Sendable { case created, reused, overwritten }
    public enum EntryState: String, Codable, Sendable { case pending, done }
    public enum RemovalState: String, Codable, Sendable { case pending, removed, skipped }
    public enum SkipReason: String, Codable, Sendable { case ppthDiffers, hashDiffers, notAllowed }

    /// 임시 쓰기와 실제 rename 진입을 구분한다. nil은 이 단계가 없던 일반 USB 옛 저널이다.
    public enum WritePhase: String, Codable, Sendable { case preparing, renamePending, renameEntered, done, externalChanged }

    /// 파일 변경 의도. 원래 쓰기의 temp와 복원 temp를 분리하고 완료는 폴더 fsync 뒤에 내린다.
    public struct FileMutation: Codable, Sendable, Equatable {
        public enum Operation: String, Codable, Sendable { case replace, delete }
        public enum Phase: String, Codable, Sendable { case copying, renamePending, renameEntered, deletePending, deleteEntered, done, externalChanged }
        /// 승인한 끝 성분 링크 자체의 신원. 링크 목적지는 읽거나 따라가지 않는다.
        public struct LinkIdentity: Codable, Sendable, Equatable {
            public var device: Int64
            public var inode: UInt64
            public var modificationSeconds: Int64
            public var modificationNanoseconds: Int64
        }
        public var destination: String
        public var operation: Operation
        public var tempName: String?
        public var backupSHA256: String?
        /// 의도 전 고정한 대상 내용(폐기 복원은 전체 승인 기준). nil은 부재 또는 expectedLink이며 백업 해시와 구분한다.
        public var expectedSHA256: String?
        /// nil 기대 해시와 링크를 구분한다. 이 칸이 없는 옛 의도는 재개 시 링크를 승인하지 않는다.
        public var expectedLink: LinkIdentity? = nil
        public var phase: Phase

        public init(destination: String, operation: Operation, tempName: String?, backupSHA256: String?,
                    expectedSHA256: String?, phase: Phase, expectedLink: LinkIdentity? = nil) {
            self.destination = destination
            self.operation = operation
            self.tempName = tempName
            self.backupSHA256 = backupSHA256
            self.expectedSHA256 = expectedSHA256
            self.expectedLink = expectedLink
            self.phase = phase
        }
    }

    /// 명시적 폐기 승인 때 고정한 대상. 두 값이 nil인 항목은 부재이며, 사전 자체의 누락과 구분한다.
    /// 원문·링크 목적지는 담지 않고 내용 해시와 끝 링크의 신원만 남긴다.
    public struct RestorationTarget: Codable, Sendable, Equatable {
        public var sha256: String?
        public var link: FileMutation.LinkIdentity?
    }

    /// 음원·분석 파일·아트워크 하나
    public struct FileEntry: Codable, Sendable, Equatable {
        public var destination: String
        /// 재사용이면 nil
        public var tempName: String?
        public var disposition: FileDisposition
        public var oldSHA256: String?
        /// 음원은 복사한 뒤에 채운다(그 전에 끊기면 임시 파일을 불완전으로 본다)
        public var newSHA256: String?
        public var size: Int64
        public var appleDoublePreexisted: Bool
        public var state: EntryState
        public var writePhase: WritePhase? = nil
        /// rollback을 마친 항목. 없던 칸인 옛 저널도 optional로 읽는다.
        public var rollbackCompleted: Bool? = nil

        public init(destination: String, tempName: String?, disposition: FileDisposition, oldSHA256: String?, newSHA256: String?,
                    size: Int64, appleDoublePreexisted: Bool, state: EntryState) {
            self.destination = destination
            self.tempName = tempName
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
            self.newSHA256 = newSHA256
            self.size = size
            self.appleDoublePreexisted = appleDoublePreexisted
            self.state = state
        }
    }

    /// DB 하나. 임시 파일을 쓰기 전에 pending으로 적고 rename 뒤 done
    public struct DatabaseEntry: Codable, Sendable, Equatable {
        public var destination: String
        public var format: UsbFormat
        public var tempName: String
        /// created = 쓰기 전에 없던 DB(내보내기, 백업에 없음), overwritten = 있던 DB(백업에 있음)
        public var disposition: FileDisposition
        public var oldSHA256: String?
        public var newSHA256: String
        public var appleDoublePreexisted: Bool
        /// 쓰기 전 USB에 있던 그 DB의 -wal·-shm·-journal(백업에 있음)
        public var sidecarsPreexisted: [String]
        public var state: EntryState
        public var writePhase: WritePhase? = nil
        /// rollback을 마친 항목. 없던 칸인 옛 저널도 optional로 읽는다.
        public var rollbackCompleted: Bool? = nil

        public init(destination: String, format: UsbFormat, tempName: String, disposition: FileDisposition, oldSHA256: String?,
                    newSHA256: String, appleDoublePreexisted: Bool, sidecarsPreexisted: [String], state: EntryState) {
            self.destination = destination
            self.format = format
            self.tempName = tempName
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
            self.newSHA256 = newSHA256
            self.appleDoublePreexisted = appleDoublePreexisted
            self.sidecarsPreexisted = sidecarsPreexisted
            self.state = state
        }
    }

    /// 쓰기 전 확인에서 정한 DB별 처리(회복이 옛 해시·새 해시로 분류하는 근거)
    public struct PlannedDatabase: Codable, Sendable, Equatable {
        public var destination: String
        public var disposition: FileDisposition
        public var oldSHA256: String?

        public init(destination: String, disposition: FileDisposition, oldSHA256: String?) {
            self.destination = destination
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
        }
    }

    public struct RemovalEntry: Codable, Sendable, Equatable {
        public var path: String
        public var state: RemovalState
        public var reason: SkipReason?

        public init(path: String, state: RemovalState, reason: SkipReason? = nil) {
            self.path = path
            self.state = state
            self.reason = reason
        }
    }

    public var formatVersion = 1
    /// 계획 전체(base·target·준비 폴더·ID 상한 포함). 회복이 이어 쓰거나 검증할 때 쓴다
    public var changes: UsbChangeSet
    public var volumeUUID: String
    public var volumeName: String
    public var state: State
    public var plannedDatabases: [PlannedDatabase] = []
    public var entries: [FileEntry] = []
    public var databases: [DatabaseEntry] = []
    public var createdDirs: [String] = []
    public var deletedSidecars: [String] = []
    public var removals: [RemovalEntry] = []
    public var backupDirectory: String?
    /// 백업 당시 manifest 전체의 해시. 항목을 함께 지운 손상도 재개 전에 찾는다. 옛 저널은 nil이다.
    public var backupManifestSHA256: String? = nil
    public var reportPath: String?
    /// `usb-restore`가 연 저널. 끊겨도 회복이 같은 방식(되돌리기)으로 마저 하고, 그 쓰기의 백업 기록은 건드리지 않는다
    public var restoringBackup = false
    /// 복원 시작 때 승인한 외부 변경 폐기. optional이라 이 칸이 없는 옛 저널도 읽는다.
    public var discardDeviceChanges: Bool? = nil
    /// 첫 의도 이전의 중단도 승인 당시 전체 대상만 이어받는다. 이 칸 없는 옛 승인은 기존 의도만 근거다.
    public var restorationBaseline: [String: RestorationTarget]? = nil
    /// optional로 두어 새 단계 칸이 없는 일반 USB 옛 저널도 읽는다.
    public var restorations: [FileMutation]? = nil
    /// DB 교체 전 사이드카 삭제도 한 항목씩 의도·완료를 내린다. deletedSidecars는 옛 저널용 목록이다.
    public var sidecarDeletions: [FileMutation]? = nil
    /// 발견한 외부 변경은 이후 temp 모양으로 정상 중단으로 재해석하지 않는다.
    public var externalChangesDetected: Bool? = nil
    /// 같은 복원 재개가 기존 승인을 다시 쓰지 못하게 한다. 새 명시적 복원 승인 때만 해제한다.
    public var restorationApprovalRequired: Bool? = nil
    /// 다음 임시 이름 번호
    public var nextSequence = 1
    public var updatedAt: Date

    public init(changes: UsbChangeSet, volumeUUID: String, volumeName: String, now: Date) {
        self.changes = changes
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        state = .planned
        updatedAt = now
    }

    public var session: String { changes.session }
    public var base: UsbFingerprint? { changes.base }
    public var target: UsbTargetFingerprint { changes.target }
    public var stagingDirectory: String { changes.stagingDirectory }
    public var idHighWater: [String: Int] { changes.idHighWater }

    /// DB 교체를 모두 마친 형식(Device Library는 export.pdb·exportExt.pdb 둘 다). 앱이 형식별 진행을 여기서 읽는다
    public var committedFormats: Set<UsbFormat> {
        Set(changes.databases.map(\.format)).filter { format in
            changes.databases.filter { $0.format == format }.allSatisfy { planned in
                databases.contains { $0.destination == planned.destination && $0.state == .done }
            }
        }
    }

    /// 지금 교체 중인(저널에 적었으나 rename 전인) DB의 형식
    public var committingFormat: UsbFormat? { databases.last { $0.state == .pending }?.format }

    /// 상태는 앞으로만 간다. 닫힌 저널은 움직이지 않는다(새 세션은 새 저널을 쓴다)
    public func canMove(to next: State) -> Bool {
        if isClosed { return false }
        switch next {
        case .planned: return false
        case .staged: return state == .planned
        case .dryRun, .backedUp: return state == .staged
        case .filesWritten: return state == .backedUp
        case .committing, .committed: return [.filesWritten, .committing].contains(state)
        case .cleaned: return state == .committed
        case .verified: return state == .cleaned
        // 되돌리기·회복은 어느 열린 상태에서든 닫는다
        case .rolledBack, .restoreFailed, .restorePending, .recovered: return true
        // 기기가 DB를 바꿨다는 판정은 USB에 쓰기 시작한 뒤에만 나온다
        case .needsReplan: return ![.planned, .staged].contains(state)
        case .restored: return [.restorePending, .restoreFailed].contains(state)
        }
    }

    public mutating func move(to next: State) throws {
        guard canMove(to: next) else {
            throw UsbError.readFailed(detail: "journal state \(state.rawValue) -> \(next.rawValue) not allowed")
        }
        state = next
    }

    /// 저널·manifest·보고서 JSON. 날짜는 기본(초 단위 실수)으로 둔다 — ISO 8601은 1초 아래를 버려 mtime이 어긋난다
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}
