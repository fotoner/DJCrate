import Foundation

/// 미정리 목록(R22): 앱의 쓰기가 라이브러리 변경을 마친 뒤 쓰기 기록을 지우기 직전에 백업 폴더에 적는 정리 할 일.
/// 보고서가 없어도 초안을 정리할 수 있게 쓴 항목과 판, 막힌 단계, 새 목록의 연결 ID를 적는다. 정리를 다 마친 뒤
/// (초안과 연결 ID를 다 저장한 뒤) 지운다. 목록을 적지 못하면 초안을 정리하지 않고 쓰기 기록을 남긴다(R11).
/// 목록은 그 목록을 남긴 실행의 초안 저장소 초안만 다룬다(대상·저장소가 다른 목록은 건드리지 않는다).
/// 적고 읽고 지우는 일은 쓰기 관문 포트가 한다. 여기는 형식과 이름만 정한다. 판(`version`)이 다르면 읽지 않는다.
public struct DraftCleanupList: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// 백업 폴더 안 목록 폴더(쓰기 백업 폴더 이름 모양이 아니라 백업 솎기에 걸리지 않는다)
    public static let folderName = "draft-cleanup"

    /// 백업 폴더의 목록 자리(작업마다 파일 하나)
    public static func url(backups: URL, operationID: String) -> URL {
        backups.appending(path: folderName, directoryHint: .isDirectory).appending(path: operationID + ".json", directoryHint: .notDirectory)
    }

    /// 재생 목록 단계 하나를 시도한 결과
    public enum StepOutcome: Codable, Equatable, Sendable {
        case written
        /// 막혀 쓰지 않았다(이유). 그 단계는 남긴다
        case blocked(String)
        /// 시도하지 않았다(앞 단계가 막힌 단위 등). 그 단계는 남긴다
        case notTried
    }

    /// 시도한 재생 목록 단계(시도한 차례)
    public struct PlaylistStep: Codable, Equatable, Sendable {
        public var revision: DraftRevision
        public var contentHash: DraftContentHash
        public var outcome: StepOutcome

        public init(revision: DraftRevision, contentHash: DraftContentHash, outcome: StepOutcome) {
            self.revision = revision
            self.contentHash = contentHash
            self.outcome = outcome
        }
    }

    /// 곡 넣기가 쓴 값(새 곡으로 옮긴 초안의 기준이 된다). 쓰지 않은 종류는 nil
    public struct TrackAddValues: Codable, Equatable, Sendable {
        public var cues: [EditableCue]?
        /// 분석과 함께 붙인 그리드
        public var grid: [GridSegment]?
        public var musicalKey: String?
        public var tags: TagFields?

        public init(cues: [EditableCue]? = nil, grid: [GridSegment]? = nil, musicalKey: String? = nil, tags: TagFields? = nil) {
            self.cues = cues
            self.grid = grid
            self.musicalKey = musicalKey
            self.tags = tags
        }
    }

    /// 곡 넣기 하나의 정리 할 일
    public struct TrackAdd: Codable, Equatable, Sendable {
        /// 추가 목록의 옛 UUID
        public var stagedUUID: String
        /// 넣은 곡의 새 UUID
        public var trackUUID: String
        /// 넣기에 쓴 초안의 판(이 판만 백업으로 옮기고 지운다. 넣는 동안 생긴 새 판은 새 곡의 제안이 된다)
        public var written: [WrittenDraft]
        /// 넣기로 쓴 값
        public var values: TrackAddValues
        /// 넣기에서 막혀 쓰지 못한 칸(새 판의 값을 그대로 옮긴다). 태그 칸은 `TagFields.Key` 원시값, 그 밖은 `cues`·`grid`
        public var blockedFields: [String]

        public init(stagedUUID: String, trackUUID: String, written: [WrittenDraft], values: TrackAddValues, blockedFields: [String]) {
            self.stagedUUID = stagedUUID
            self.trackUUID = trackUUID
            self.written = written
            self.values = values
            self.blockedFields = blockedFields
        }
    }

    public var version: Int
    /// 작업 ID(쓰기 기록과 같은 값)
    public var operationID: String
    /// 대상(R9의 잠금 키)
    public var target: RekordboxWriteLockKey
    /// 초안 저장소 위치(그 실행의 `DJC_HOME` 초안 폴더)
    public var draftHome: String
    /// 쓴 곡 초안
    public var written: [WrittenDraft]
    /// 시도한 재생 목록 단계
    public var playlistSteps: [PlaylistStep]
    /// 새 목록의 연결 ID(`new:키` → 실제 목록 ID). 남은 단계의 대상·목적지와 가져오기 연결에 옮긴다
    public var newPlaylistIDs: [String: String]
    public var trackAdds: [TrackAdd]

    public init(operationID: String, target: RekordboxWriteLockKey, draftHome: String, written: [WrittenDraft] = [],
                playlistSteps: [PlaylistStep] = [], newPlaylistIDs: [String: String] = [:], trackAdds: [TrackAdd] = []) {
        version = Self.formatVersion
        self.operationID = operationID
        self.target = target
        self.draftHome = draftHome
        self.written = written
        self.playlistSteps = playlistSteps
        self.newPlaylistIDs = newPlaylistIDs
        self.trackAdds = trackAdds
    }

    private enum CodingKeys: String, CodingKey {
        case version, operationID, target, draftHome, written, playlistSteps, newPlaylistIDs, trackAdds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "모르는 미정리 목록 판 \(version)")
        }
        operationID = try container.decode(String.self, forKey: .operationID)
        target = try container.decode(RekordboxWriteLockKey.self, forKey: .target)
        draftHome = try container.decode(String.self, forKey: .draftHome)
        written = try container.decode([WrittenDraft].self, forKey: .written)
        playlistSteps = try container.decode([PlaylistStep].self, forKey: .playlistSteps)
        newPlaylistIDs = try container.decode([String: String].self, forKey: .newPlaylistIDs)
        trackAdds = try container.decode([TrackAdd].self, forKey: .trackAdds)
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
