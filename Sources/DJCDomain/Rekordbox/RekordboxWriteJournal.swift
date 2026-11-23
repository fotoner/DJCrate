import Foundation

/// 파일의 크기와 수정 시각(1970년부터 나노초, 비교가 어긋나지 않게 정수로 적는다). 쓰기 기록과 자동 저장의 조용함 조건(R2)이 쓴다
public struct RekordboxFileStamp: Codable, Hashable, Sendable {
    public var size: Int64
    public var modifiedNanoseconds: Int64

    public init(size: Int64, modifiedNanoseconds: Int64) {
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// 쓰기 기록(R11): 대상 master.db 옆 `master.db.djc-write`. 라이브러리를 처음 바꾸기 직전(실행 재확인 뒤)에 남기고
/// 라이브러리 변경이 모두 끝나거나 복구가 끝나면 지운다. 쓰는 동안과 중단됐을 때만 있어서 재부팅 뒤에도 남고
/// `DJC_HOME`이 다른 CLI도 본다. 남은 기록은 중단으로 다룬다(판정·거절·기록으로 복원).
/// 남기고 고치고 지우고 판정하는 일은 쓰기 입구(RekordboxKit)와 쓰기 관문 포트가 한다. 여기는 형식과 이름만 정한다.
/// 경로는 모두 절대 경로 글자로 적는다. 판(`version`)이 다르면 읽지 않는다(옛 판은 없다).
public struct RekordboxWriteJournal: Codable, Equatable, Sendable {
    /// 지금 형식의 판
    public static let formatVersion = 1
    /// master.db 이름 뒤에 붙는 이름. SQLite(`-journal`·`-wal`·`-shm`)와 rekordbox(`master.backup*`)가 쓰는 이름과 겹치지 않는다
    public static let fileSuffix = ".djc-write"

    /// 대상의 쓰기 기록 자리: 링크를 푼 master.db 옆. 링크를 푸는 일(realpath)은 입출력이라 부르는 쪽이 한다
    /// (잠금 키와 같은 정규화: 쓰기 잠금 포트의 `resolve`, 쓰기 입구의 같은 함수). 그래야 파일·폴더 링크와 원본이 같은 기록을 본다
    public static func url(resolvedDatabase: URL) -> URL {
        resolvedDatabase.deletingLastPathComponent()
            .appending(path: resolvedDatabase.lastPathComponent + fileSuffix, directoryHint: .notDirectory)
    }

    /// 쓰기의 종류
    public enum Kind: String, Codable, Sendable {
        /// 변경 카운터를 올리는 DB COMMIT을 하는 쓰기. 표시가 없고 지금 카운터가 시작 카운터와 같으면 판정이 조용히 지운다
        case counter
        /// 그 밖의 모두: BPM이 그대로인 그리드만 든 초안 쓰기(ROLLBACK 뒤 파일만 바꿈), 쓰기 전으로 복원, 시점 복원, iTunes 동기화
        case files
    }

    /// 쓰기 입구(R9의 입구, 기록으로 복원하는 방법이 입구마다 다르다)
    public enum Entry: String, Codable, Sendable {
        /// 초안 쓰기(`RekordboxWriter.write`, 재생 목록 쓰기 포함)
        case drafts
        case trackAdd
        case trackDelete
        /// 쓰기 전 백업으로 복원(`RekordboxWriter.restore`)
        case restore
        /// 시점 복원
        case pointRestore
        /// iTunes 동기화(`playlists3.sync`)
        case iTunesSync
    }

    /// 기록에 붙는 표시. 표시가 있는 기록은 카운터와 상관없이 중단이다
    public enum Mark: String, Codable, CaseIterable, Comparable, Sendable {
        /// 자동 복구(`recover`)가 첫 변경 전에 적는다
        case recovering
        /// 복구가 실패해 남은 기록
        case recoveryFailed
        /// 기록으로 복원을 시작했다
        case restoring

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// 되돌릴 근거
    public struct Basis: Codable, Equatable, Sendable {
        /// 쓰기 전 백업 폴더
        public var writeBackup: String?
        /// 시점 스냅샷(시점 복원의 목표)
        public var pointSnapshot: String?
        /// iTunes 동기화 전 파일(`itunes-sync-before.xml`)
        public var iTunesSyncBefore: String?

        public init(writeBackup: String? = nil, pointSnapshot: String? = nil, iTunesSyncBefore: String? = nil) {
            self.writeBackup = writeBackup
            self.pointSnapshot = pointSnapshot
            self.iTunesSyncBefore = iTunesSyncBefore
        }
    }

    /// 이 쓰기가 바꾸거나 만들 파일 하나
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        /// 원본 사본. nil이면 이 쓰기가 만드는 파일이라 되돌릴 때 지운다
        public var original: String?

        public init(path: String, original: String?) {
            self.path = path
            self.original = original
        }
    }

    /// 이 쓰기에 든 초안(앱의 초안 쓰기·곡 넣기). "이대로 둔다"가 적힌 판의 초안만 제안으로 바꾼다
    public struct Drafts: Codable, Equatable, Sendable {
        /// 초안 저장소 위치(그 실행의 `DJC_HOME` 초안 폴더)
        public var home: String
        public var written: [WrittenDraft]
        /// 쓴 재생 목록 단계의 판(시도한 차례)
        public var playlistSteps: [DraftRevision]

        public init(home: String, written: [WrittenDraft] = [], playlistSteps: [DraftRevision] = []) {
            self.home = home
            self.written = written
            self.playlistSteps = playlistSteps
        }
    }

    /// 시점 복원이 적는 것
    public struct PointRestore: Codable, Equatable, Sendable {
        /// 첫 변경 전에 뜬 복원 직전 스냅샷. 기록으로 복원할 때 새로 뜨지 않고 이것을 다시 쓴다
        public var snapshotBeforeRestore: String
        /// 만들 임시 폴더 이름(`.djc-restore-*`·`.djc-old-*`). 다시 한 복원의 검증이 끝난 뒤 지운다
        public var temporaryFolders: [String]

        public init(snapshotBeforeRestore: String, temporaryFolders: [String]) {
            self.snapshotBeforeRestore = snapshotBeforeRestore
            self.temporaryFolders = temporaryFolders
        }
    }

    public var version: Int
    /// 작업 ID(미정리 목록과 잇는다)
    public var operationID: String
    public var kind: Kind
    public var entry: Entry
    public var basis: Basis
    public var files: [File]
    public var drafts: Drafts?
    /// 시작 카운터(카운터 쓰기)
    public var startCounter: Int?
    /// 마지막으로 DB를 바꾼 뒤의 master.db 크기·시각. DB를 바꿀 때마다 고쳐 적고, rekordbox가 켜진 것을 보고 멈출 때는 고치지 않는다
    public var database: RekordboxFileStamp?
    /// DB를 파일로 바꾸는 복원의 준비 사본(`.djc-restore`) 크기·시각. 바꾼 뒤의 DB도 이 값을 그대로 가진다
    public var restoreCopy: RekordboxFileStamp?
    /// 표시(JSON에는 `Mark` 차례로 적는다)
    public var marks: Set<Mark>
    public var pointRestore: PointRestore?

    public init(operationID: String, kind: Kind, entry: Entry, basis: Basis = Basis(), files: [File] = [], drafts: Drafts? = nil,
                startCounter: Int? = nil, database: RekordboxFileStamp? = nil, restoreCopy: RekordboxFileStamp? = nil, marks: Set<Mark> = [],
                pointRestore: PointRestore? = nil) {
        version = Self.formatVersion
        self.operationID = operationID
        self.kind = kind
        self.entry = entry
        self.basis = basis
        self.files = files
        self.drafts = drafts
        self.startCounter = startCounter
        self.database = database
        self.restoreCopy = restoreCopy
        self.marks = marks
        self.pointRestore = pointRestore
    }

    private enum CodingKeys: String, CodingKey {
        case version, operationID, kind, entry, basis, files, drafts, startCounter, database, restoreCopy, marks, pointRestore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "모르는 쓰기 기록 판 \(version)")
        }
        operationID = try container.decode(String.self, forKey: .operationID)
        kind = try container.decode(Kind.self, forKey: .kind)
        entry = try container.decode(Entry.self, forKey: .entry)
        basis = try container.decode(Basis.self, forKey: .basis)
        files = try container.decode([File].self, forKey: .files)
        drafts = try container.decodeIfPresent(Drafts.self, forKey: .drafts)
        startCounter = try container.decodeIfPresent(Int.self, forKey: .startCounter)
        database = try container.decodeIfPresent(RekordboxFileStamp.self, forKey: .database)
        restoreCopy = try container.decodeIfPresent(RekordboxFileStamp.self, forKey: .restoreCopy)
        marks = Set(try container.decode([Mark].self, forKey: .marks))
        pointRestore = try container.decodeIfPresent(PointRestore.self, forKey: .pointRestore)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(kind, forKey: .kind)
        try container.encode(entry, forKey: .entry)
        try container.encode(basis, forKey: .basis)
        try container.encode(files, forKey: .files)
        try container.encodeIfPresent(drafts, forKey: .drafts)
        try container.encodeIfPresent(startCounter, forKey: .startCounter)
        try container.encodeIfPresent(database, forKey: .database)
        try container.encodeIfPresent(restoreCopy, forKey: .restoreCopy)
        try container.encode(marks.sorted(), forKey: .marks)
        try container.encodeIfPresent(pointRestore, forKey: .pointRestore)
    }

    /// 파일에 적는 형식(키 정렬)
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// 파일 내용을 읽는다. 모르는 판·깨진 내용이면 던진다
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
