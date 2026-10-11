import DJCDomain
import Foundation

/// 시점 스냅샷 파일(피동 포트). 실제 구현은 DJCAdapters `PointSnapshotFiles.live(guard:)`(RekordboxKit `RekordboxPointSnapshot`·
/// `RekordboxPointSnapshotDiff`)이고, 대상이 라이브 DB인지·rekordbox가 켜져 있는지는 쓰기 관문의 가드로 본다. 시험은 메모리 가짜.
public struct PointSnapshotFiles: Sendable {
    /// 지금 라이브러리를 스냅샷으로 남긴다(보관 일수가 지난 자동 스냅샷은 정리한다)
    public var create: @Sendable (_ name: String, _ database: URL, _ shareRoot: URL?, _ directory: URL, _ autoDays: Int, _ now: Date) throws
        -> RekordboxPointSnapshotEntry
    /// 스냅샷 폴더의 스냅샷(최근 것부터)
    public var list: @Sendable (_ directory: URL) -> [RekordboxPointSnapshotEntry]
    /// 폴더 이름 또는 겹치지 않는 이름으로 찾는다
    public var find: @Sendable (_ key: String, _ directory: URL) -> RekordboxPointSnapshotEntry?
    public var setPinned: @Sendable (_ pinned: Bool, _ entry: URL, _ directory: URL) throws -> Void
    /// 지운다(고정한 것은 실제 구현이 거부한다)
    public var delete: @Sendable (_ entry: URL, _ directory: URL) throws -> Void
    /// 스냅샷과 지금 라이브러리를 견준다(읽기만)
    public var compare: @Sendable (_ entry: RekordboxPointSnapshotEntry, _ database: URL, _ shareRoot: URL?) throws -> RekordboxPointSnapshotDiff
    /// 폴더의 논리 크기
    public var size: @Sendable (_ url: URL) -> Int64
    /// 스냅샷 폴더가 라이브러리와 같은 디스크라 클론으로 뜰 수 있는지
    public var canClone: @Sendable (_ source: URL, _ directory: URL) -> Bool
    /// 대상이 라이브 DB이고 rekordbox가 켜져 있는지(복원 전에 미리 알린다. 쓰기 관문이 다시 본다)
    public var isLiveAndRunning: @Sendable (_ database: URL) -> Bool
    /// rekordbox·rekordboxAgent가 켜져 있는지(자동 스냅샷이 실패를 알릴지 볼 때)
    public var isRekordboxRunning: @Sendable () -> Bool
    /// 때가 됐으면 자동 스냅샷을 뜨고 보존 정리를 한다(#228, 클론이 안 되면 뜨지 않는다)
    public var takeAutoIfDue: @Sendable (_ database: URL, _ shareRoot: URL?, _ directory: URL, _ autoDays: Int, _ now: Date, _ calendar: Calendar,
                                         _ canClone: @escaping @Sendable (URL, URL) -> Bool) throws -> RekordboxPointSnapshotAutoOutcome
    /// 뜨는 동안 쓰기가 끼어든 스냅샷을 버린다
    public var discard: @Sendable (_ entry: URL) throws -> Void

    public init(create: @escaping @Sendable (String, URL, URL?, URL, Int, Date) throws -> RekordboxPointSnapshotEntry,
                list: @escaping @Sendable (URL) -> [RekordboxPointSnapshotEntry],
                find: @escaping @Sendable (String, URL) -> RekordboxPointSnapshotEntry?,
                setPinned: @escaping @Sendable (Bool, URL, URL) throws -> Void, delete: @escaping @Sendable (URL, URL) throws -> Void,
                compare: @escaping @Sendable (RekordboxPointSnapshotEntry, URL, URL?) throws -> RekordboxPointSnapshotDiff,
                size: @escaping @Sendable (URL) -> Int64, canClone: @escaping @Sendable (URL, URL) -> Bool,
                isLiveAndRunning: @escaping @Sendable (URL) -> Bool, isRekordboxRunning: @escaping @Sendable () -> Bool,
                takeAutoIfDue: @escaping @Sendable (URL, URL?, URL, Int, Date, Calendar, @escaping @Sendable (URL, URL) -> Bool) throws
                    -> RekordboxPointSnapshotAutoOutcome,
                discard: @escaping @Sendable (URL) throws -> Void) {
        self.create = create
        self.list = list
        self.find = find
        self.setPinned = setPinned
        self.delete = delete
        self.compare = compare
        self.size = size
        self.canClone = canClone
        self.isLiveAndRunning = isLiveAndRunning
        self.isRekordboxRunning = isRekordboxRunning
        self.takeAutoIfDue = takeAutoIfDue
        self.discard = discard
    }
}

/// 시점 스냅샷 목록 한 줄. 쓰기 전 백업도 같은 줄 모양으로 함께 보인다.
public struct PointSnapshotRow: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case point(RekordboxPointSnapshotEntry)
        /// 쓰기 전 백업(`isWrite`가 거짓이면 복원 직전 백업)
        case backup(URL, isWrite: Bool)
    }

    public var source: Source
    public var date: Date
    public var name: String
    public var kind: String
    public var bytes: Int64?

    public init(source: Source, date: Date, name: String, kind: String, bytes: Int64?) {
        self.source = source
        self.date = date
        self.name = name
        self.kind = kind
        self.bytes = bytes
    }

    public var id: String {
        switch source {
        case let .point(entry): Self.pointID(entry)
        case let .backup(url, _): "backup:" + url.lastPathComponent
        }
    }

    public static func pointID(_ entry: RekordboxPointSnapshotEntry) -> String { "point:" + entry.id }

    public var entry: RekordboxPointSnapshotEntry? {
        if case let .point(entry) = source { return entry }
        return nil
    }

    public var pinned: Bool { entry?.metadata.pinned == true }
}

/// 시점 스냅샷이 막힌 이유(파일을 보기 전에 안다)
public enum PointSnapshotRefusal: Error, Equatable, Sendable {
    /// rekordbox에 쓰는 중 등(그 이유 문구)
    case busy(String)
    /// 고정한 스냅샷은 지우지 않는다
    case pinned
    /// 라이브 라이브러리인데 rekordbox가 켜져 있다
    case rekordboxRunning

    public var message: String {
        switch self {
        case let .busy(reason): reason
        case .pinned: String(ui: "고정한 시점 스냅샷은 지우지 않습니다. 고정을 푼 뒤 지우세요")
        case .rekordboxRunning: String(ui: "rekordbox가 켜져 있어 복원하지 않았습니다. rekordbox를 완전히 종료한 뒤 다시 누르세요")
        }
    }
}

/// 지우기 결과
public enum PointSnapshotDeleteOutcome: Sendable {
    case refused(PointSnapshotRefusal)
    case cancelled
    case deleted
    case failed(any Error)
}

/// 복원 결과
public enum PointSnapshotRestoreOutcome: Sendable {
    case refused(PointSnapshotRefusal)
    /// 비교하지 못해 묻지 않았다
    case compareFailed(any Error)
    case cancelled
    case restored(RekordboxPointRestoreReport)
    case failed(any Error)
}

/// 시점 스냅샷 유스케이스(#224·#225): 한 라이브러리(대상 DB·share)와 그 스냅샷 폴더·쓰기 전 백업 폴더. 앱 창(`PointSnapshotModel`)과
/// CLI(`djc snapshot-point`)가 같은 유스케이스를 쓴다. 대상은 조립 지점이 정하고(앱은 반영 세션과 같은 곳), 기본값이 없다.
/// 파일 일은 메인 액터 밖에서 한다. 복원 자체는 반영 세션(`ReflectionSession.restorePointSnapshot`)이 하고, 여기서는 비교·확인까지의 순서를 정한다.
public struct PointSnapshots: Sendable {
    public var database: URL
    public var shareRoot: URL?
    /// 시점 스냅샷 폴더
    public var directory: URL
    /// 쓰기 전 백업 폴더(보기만 한다. 되돌리기는 '쓰기 전으로 복원…')
    public var backupDirectory: URL
    public var files: PointSnapshotFiles
    public var backups: RekordboxBackups

    public init(database: URL, shareRoot: URL?, directory: URL, backupDirectory: URL, files: PointSnapshotFiles, backups: RekordboxBackups) {
        self.database = database
        self.shareRoot = shareRoot
        self.directory = directory
        self.backupDirectory = backupDirectory
        self.files = files
        self.backups = backups
    }

    // MARK: - 목록

    /// 시점 스냅샷(최근 것부터)
    public func entries() -> [RekordboxPointSnapshotEntry] { files.list(directory) }

    /// 쓰기 전 백업(최근 것부터)
    public func writeBackups() -> [RekordboxWriteBackup] { backups.list(backupDirectory) }

    /// 시점 스냅샷과 쓰기 전 백업을 최근 것부터 한 목록으로. 크기는 논리 크기다(클론이면 실제 사용은 더 작다).
    public func rows() -> [PointSnapshotRow] {
        let points = entries().map { entry in
            PointSnapshotRow(source: .point(entry), date: entry.metadata.createdAt, name: Self.rowName(entry.metadata),
                             kind: entry.metadata.kind.title, bytes: files.size(entry.url))
        }
        let writes = writeBackups().map { backup in
            PointSnapshotRow(source: .backup(backup.url, isWrite: backup.isWrite), date: backup.createdAt,
                             name: Self.backupTitles(backup).prefix(3).joined(separator: ", "),
                             kind: backup.isWrite ? String(ui: "쓰기 전 백업") : String(ui: "복원 직전 백업"),
                             bytes: files.size(backup.url))
        }
        return (points + writes).sorted { $0.date > $1.date }
    }

    /// 목록과 클론 가능 여부(메인 액터와 협력 풀 밖에서 읽는다)
    public func load() async -> (rows: [PointSnapshotRow], canClone: Bool) {
        let points = self
        return await BlockingWork.run {
            (points.rows(), points.files.canClone(points.database.deletingLastPathComponent(), points.directory))
        }
    }

    /// 복원 직전 스냅샷은 이름 대신 무엇으로 되돌리기 전인지 보인다
    public static func rowName(_ metadata: RekordboxPointSnapshotMetadata) -> String {
        guard metadata.name.isEmpty, let target = metadata.restoredFrom else { return metadata.name }
        return String(ui: "‘\(target)’ 복원 전")
    }

    /// 쓰기 전 백업 줄의 이름: 그때 쓴 곡(그리드·게인만 쓴 곡도, 곡마다 한 번)
    public static func backupTitles(_ backup: RekordboxWriteBackup) -> [String] {
        let extra = backup.report.map { ($0.gridWritten + $0.gainWritten).map(\.title) } ?? []
        var seen = Set<String>()
        return (backup.titles + extra).filter { seen.insert($0).inserted }
    }

    /// `pin <ID>`처럼 고른 스냅샷(폴더 이름 또는 겹치지 않는 이름)
    public func find(_ key: String) throws -> RekordboxPointSnapshotEntry {
        guard let entry = files.find(key, directory) else {
            throw DJCError.writeRefused(String(ui: "시점 스냅샷 ‘\(key)’을 찾지 못했습니다. djc snapshot-point list로 ID를 확인하세요"))
        }
        return entry
    }

    // MARK: - 만들기·고정·지우기·비교

    /// 지금 라이브러리를 스냅샷으로 남긴다. 막혔으면(`blockReason`) 파일을 보지 않고 거부한다(`PointSnapshotRefusal.busy`).
    public func create(name: String, autoDays: Int, now: Date, blockReason: String? = nil) async throws -> RekordboxPointSnapshotEntry {
        if let blockReason { throw PointSnapshotRefusal.busy(blockReason) }
        let points = self
        return try await BlockingWork.run {
            try points.files.create(name, points.database, points.shareRoot, points.directory, autoDays, now)
        }
    }

    public func setPinned(_ pinned: Bool, _ entry: RekordboxPointSnapshotEntry) throws {
        try files.setPinned(pinned, entry.url, directory)
    }

    /// 묻지 않고 지운다(CLI: 명령이 곧 동의다). 고정한 것은 실제 구현이 거부한다
    public func delete(_ entry: RekordboxPointSnapshotEntry) async throws {
        let points = self, url = entry.url
        try await BlockingWork.run { try points.files.delete(url, points.directory) }
    }

    /// 지운 스냅샷은 되살릴 수 없어 한 번 묻는다. 고정한 것은 묻지도 않는다.
    /// - Parameter working: 지우는 동안(확인 창 뒤) 켜고 끝나면 끈다
    @MainActor
    public func delete(_ entry: RekordboxPointSnapshotEntry, confirmation: UserConfirmation,
                       working: @MainActor (Bool) -> Void = { _ in }) async -> PointSnapshotDeleteOutcome {
        guard !entry.metadata.pinned else { return .refused(.pinned) }
        guard confirmation.confirm(Self.deleteConfirmation(entry)) else { return .cancelled }
        working(true)
        defer { working(false) }
        do {
            try await delete(entry)
            return .deleted
        } catch {
            return .failed(error)
        }
    }

    /// 지우기 확인 창. 이름이 없는 스냅샷은 시각으로 부른다
    public static func deleteConfirmation(_ entry: RekordboxPointSnapshotEntry) -> ReflectionPrompt {
        let title = entry.metadata.name.isEmpty ? entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened) : entry.metadata.name
        return ReflectionPrompt(title: String(ui: "시점 스냅샷 ‘\(title)’을 지울까요?"),
                                text: String(ui: "지운 스냅샷은 되살릴 수 없습니다. rekordbox 라이브러리는 그대로입니다."),
                                confirm: String(ui: "지우기"), destructive: true)
    }

    /// 고른 스냅샷과 지금 라이브러리를 견준다(읽기만)
    public func compare(_ entry: RekordboxPointSnapshotEntry) async throws -> RekordboxPointSnapshotDiff {
        let points = self
        return try await BlockingWork.run {
            try points.files.compare(entry, points.database, points.shareRoot)
        }
    }

    // MARK: - 복원

    /// 막힘(쓰는 중·rekordbox 켜짐)을 먼저 보고, 비교한 뒤 확인 창 하나로 묻고, 확인하면 그 시점으로 되돌린다(복원 직전 상태는 시점 스냅샷으로 남는다).
    /// - Parameters:
    ///   - compared: 비교 결과(확인 창 전에 화면에 보인다)
    ///   - working: 비교하는 동안·되돌리는 동안 켜고 끝나면 끈다(확인 창을 띄우는 동안은 꺼져 있다)
    ///   - perform: 되돌린다(바뀌는 곡을 받는다. 앱은 반영 세션: 쓰기 잠금·다시 읽기까지, 대상은 쓰기와 같은 곳)
    @MainActor
    public func restore(_ entry: RekordboxPointSnapshotEntry, blockReason: String? = nil, confirmation: UserConfirmation,
                        compared: @MainActor (RekordboxPointSnapshotDiff) -> Void = { _ in },
                        working: @MainActor (Bool) -> Void = { _ in },
                        perform: @MainActor (RekordboxPointSnapshotEntry, Set<String>) async throws -> RekordboxPointRestoreReport)
        async -> PointSnapshotRestoreOutcome {
        if let blockReason { return .refused(.busy(blockReason)) }
        if files.isLiveAndRunning(database) { return .refused(.rekordboxRunning) }
        working(true)
        let diff: RekordboxPointSnapshotDiff
        do {
            diff = try await compare(entry)
        } catch {
            working(false)
            return .compareFailed(error)
        }
        working(false)
        compared(diff)
        guard confirmation.confirm(Self.restoreConfirmation(entry, diff: diff)) else { return .cancelled }
        working(true)
        defer { working(false) }
        do {
            return .restored(try await perform(entry, diff.changedTrackUUIDs))
        } catch {
            return .failed(error)
        }
    }

    /// 복원 확인 창(하나). 무엇이 바뀌는지는 펼쳐 보기에, 클라우드 동기화 흔적은 한 줄로(#229 확인 전, 막지 않는다).
    public static func restoreConfirmation(_ entry: RekordboxPointSnapshotEntry, diff: RekordboxPointSnapshotDiff) -> ReflectionPrompt {
        let when = entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
        var lines = [String(ui: "rekordbox 라이브러리 전체(DB·재생 목록·분석 파일·앨범아트)를 \(when) 시점으로 되돌립니다. 그 뒤 rekordbox와 DJCrate에서 바꾼 것은 사라집니다."),
                     String(ui: "지금 상태는 ‘복원 직전’ 스냅샷으로 남겨 다시 되돌릴 수 있습니다. DJCrate 초안은 그대로 둡니다.")]
        if diff.isEmpty { lines.append(String(ui: "지금 라이브러리와 다른 곳이 없습니다.")) }
        if diff.cloudSyncedSince(entry) { lines.append("⚠︎ " + RekordboxPointSnapshotDiff.cloudSyncNote) }
        lines.append(String(ui: "끝날 때까지 rekordbox를 켜지 마세요."))
        var details = diff.summary
        for group in diff.details(limit: 20) { details += ["", group.title + ":"] + group.items.map { "• " + $0 } }
        return ReflectionPrompt(title: String(ui: "rekordbox를 ‘\(entry.displayName)’ 시점으로 복원할까요?"), text: lines.joined(separator: "\n\n"),
                                confirm: String(ui: "이 시점으로 복원"), destructive: true, details: details)
    }
}
