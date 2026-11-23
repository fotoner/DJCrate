import Foundation

/// 바깥에서 고친 재생 목록 단계의 사본(R22). 쓴 단계는 내용 해시가 달라도 초안에서 빼고 연결 ID도 옮긴다. 다만 해시가 달랐던 단계는
/// 바깥에서 고친 지금 내용을 실제 목록 ID와 함께 백업 폴더에 이 사본으로 남긴 뒤에만 뺀다. 사본을 남기지 못하면 그 단계와 미정리 목록을
/// 그대로 두고 그 대상의 다음 쓰기를 보류한다(재생 목록 단계는 서로 이어져 있어 하나만 제안으로 남기면 목록이 갈라진다).
/// 사본은 되살리지 않는다(사본만 남긴다, 후속). 판(`version`)이 다르면 읽지 않는다.
public struct PlaylistStepCopy: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// 백업 폴더 안 사본 폴더
    public static let folderName = "playlist-step-copies"

    /// 사본 자리: `<폴더>/playlist-step-copies/<판>.json`
    public static func url(folder: URL, revision: DraftRevision) -> URL {
        folder.appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: "\(revision.value).json", directoryHint: .notDirectory)
    }

    public var version: Int
    public var revision: DraftRevision
    /// 단계가 고치는 실제 목록 ID(새 목록이면 쓴 뒤 받은 ID). 모르면 nil
    public var playlistID: String?
    /// 바깥에서 고친 지금 단계와 그 단계가 기대는 base
    public var step: PlaylistDraft.Step
    public var base: [String: PlaylistDraft.Base]
    /// 쓴 내용의 해시와 지금 내용의 해시
    public var writtenHash: DraftContentHash
    public var currentHash: DraftContentHash

    public init(revision: DraftRevision, playlistID: String?, step: PlaylistDraft.Step, base: [String: PlaylistDraft.Base],
                writtenHash: DraftContentHash, currentHash: DraftContentHash) {
        version = Self.formatVersion
        self.revision = revision
        self.playlistID = playlistID
        self.step = step
        self.base = base
        self.writtenHash = writtenHash
        self.currentHash = currentHash
    }

    private enum CodingKeys: String, CodingKey { case version, revision, playlistID, step, base, writtenHash, currentHash }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "모르는 재생 목록 사본 판 \(version)")
        }
        revision = try container.decode(DraftRevision.self, forKey: .revision)
        playlistID = try container.decodeIfPresent(String.self, forKey: .playlistID)
        step = try container.decode(PlaylistDraft.Step.self, forKey: .step)
        base = try container.decode([String: PlaylistDraft.Base].self, forKey: .base)
        writtenHash = try container.decode(DraftContentHash.self, forKey: .writtenHash)
        currentHash = try container.decode(DraftContentHash.self, forKey: .currentHash)
    }
}
