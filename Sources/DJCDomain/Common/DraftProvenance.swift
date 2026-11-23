import CryptoKit
import Foundation

// 초안 출처·판·내용 해시(자동 저장 R5·R22). 초안 하나의 단위는 (곡, 종류)와 재생 목록 편집 단계다.
// 출처와 판은 초안 폴더 옆 사이드카에 적는다(DJCStorage). 여기는 값과 해시의 정규 형식만 정한다.

/// 초안을 저장한 쪽. 출처는 초안을 저장한 포트가 정한다: 앱의 편집 포트는 사람 편집, CLI는 CLI, LINK 초안은 LINK,
/// 복원이 되살린 초안은 되살림이다. 사람 편집만 자동 저장하고 나머지는 제안이다(⌘S·저장 단추로 함께 쓴다).
/// JSON(사이드카·`djc drafts`)에는 원시값을 그대로 쓴다.
public enum DraftOrigin: String, Codable, CaseIterable, Comparable, Sendable {
    /// 앱에서 사람이 한 편집
    case human
    /// CLI(`djc draft` 등)
    case cli
    /// AI·스킬이 CLI로 만든 초안
    case agent
    /// CDJ가 LINK로 보낸 편집
    case link
    /// 복원이 되살린 초안
    case restored
    /// 출처를 모름(업데이트 전부터 있던 초안 포함)
    case unknown

    /// 적는 차례(`allCases` 차례)
    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// 초안의 판: 초안을 저장할 때마다 새로 받는 번호. 쓰기 뒤 정리는 실제로 쓴 판만 지운다(R22).
/// 판은 초안 저장소(초안 폴더) 하나 안에서 겹치지 않는다: 종류와 곡에 상관없이 저장소 전체에서 늘어나는 번호다. 그래서 판 하나로
/// 곡 초안과 재생 목록 단계를 가리킬 수 있다. 번호를 주는 일은 초안 저장소 구현이 한다. JSON에는 수 하나로 적는다.
public struct DraftRevision: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { String(value) }

    public init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(UInt64.self) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// 초안 내용의 해시. 바깥에서 고친 초안(판은 그대로인데 내용이 다른 초안)을 가려낸다.
/// 정규 형식은 키를 정렬한 JSON(빈칸 없음, `/`를 풀지 않음)의 SHA-256, 소문자 16진 64자다. 그래서 같은 내용이면 프로세스·실행이
/// 달라도 같은 값이고 사전·칸을 적는 차례에 기대지 않는다. 배열의 차례는 내용으로 본다. 형식을 바꾸면 남은 해시가 모두 어긋난다.
public struct DraftContentHash: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hex: String

    public init(hex: String) { self.hex = hex }

    /// 값의 해시. 값을 JSON으로 만들지 못하면(NaN 등) 던진다
    public init(of value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(value))
        hex = digest.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws { hex = try decoder.singleValueContainer().decode(String.self) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension DraftContentHash {
    /// 재생 목록 단계 하나의 해시: 단계(편집·기대는 목록·다시 적용한 기준)와 그 단계가 실제로 견주는 기준을 함께 넣는다.
    /// 기준은 낡음 판정(`PlaylistDraft.staleReason(for:rekordbox:)`)과 같다: 단계에 다시 적용한 기준(`recoveryBase`)이 있으면 그것만,
    /// 없으면 공유 `base` 가운데 그 단계의 `depends`에 든 목록만. 그래서 편집이 같아도 견주는 기준이 바뀌면 다른 해시이고,
    /// 다른 단계 때문에 공유 base가 바뀌어도(그 목록에 기대지 않거나 고정된 기준을 쓰는 단계는) 같은 해시다.
    /// 메모리 구현과 실제 저장소가 이 함수 하나를 쓴다
    public init(step: PlaylistDraft.Step, in draft: PlaylistDraft) throws {
        struct Content: Encodable {
            var step: PlaylistDraft.Step
            var base: [String: PlaylistDraft.Base]
        }
        let depends = Set(step.depends)
        let bases = step.recoveryBase ?? draft.base
        // 식별자(`Step.id`)는 내용이 아니다: 저장소가 식별자를 부여해도 해시는 그대로다
        var content = step
        content.id = nil
        try self.init(of: Content(step: content, base: bases.filter { depends.contains($0.key) }))
    }
}

/// 곡 초안 하나를 가리킨다: (종류, 곡 UUID). 합치기 초안은 합치기 초안 ID로 가리킨다. 재생 목록 단계는 판으로 가리킨다.
public struct DraftKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cue, grid, gain, tag, artwork, merge
    }

    public var kind: Kind
    /// 곡 UUID(합치기는 합치기 초안 ID)
    public var id: String

    public init(_ kind: Kind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (Kind.allCases.firstIndex(of: lhs.kind)!, lhs.id) < (Kind.allCases.firstIndex(of: rhs.kind)!, rhs.id)
    }

    public var description: String { "\(kind.rawValue):\(id)" }
}

/// 초안 하나(곡 초안 또는 재생 목록 단계)의 출처·판·내용 해시. 초안을 저장할 때마다 새 판과 그때의 해시를 적는다.
public struct DraftStamp: Hashable, Codable, Sendable {
    public var revision: DraftRevision
    /// 이 초안에 손댄 출처(사람 편집 뒤 CLI가 고치면 둘 다). 차례 없이 모으고 JSON에는 `DraftOrigin` 차례로 적는다
    public var origins: Set<DraftOrigin>
    /// 저장한 때의 내용 해시
    public var contentHash: DraftContentHash

    public init(revision: DraftRevision, origins: Set<DraftOrigin>, contentHash: DraftContentHash) {
        self.revision = revision
        self.origins = origins
        self.contentHash = contentHash
    }

    /// 사람 편집만 든 도장인지. 출처만 보는 판정이다(해시가 맞는지는 지금 내용과 견줘 따로 본다, R5)
    public var isHumanOnly: Bool { origins == [.human] }

    private enum CodingKeys: String, CodingKey { case revision, origins, contentHash }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(DraftRevision.self, forKey: .revision)
        origins = Set(try container.decode([DraftOrigin].self, forKey: .origins))
        contentHash = try container.decode(DraftContentHash.self, forKey: .contentHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(origins.sorted(), forKey: .origins)
        try container.encode(contentHash, forKey: .contentHash)
    }
}

/// 쓰기에 든 곡 초안 하나: 어느 초안의 어느 판을 어떤 내용으로 썼는지. 쓰기 기록·미정리 목록·판 지정 삭제가 같은 값을 쓴다.
/// 해시는 쓰기 묶음에 실제로 읽어 넣은 내용의 해시다(도장의 저장 때 해시가 아니다).
/// 정리는 판과 해시가 모두 같은 초안만 지운다. 판이 같고 해시가 다르면 지우지 않고 제안으로 남긴다(R22).
public struct WrittenDraft: Hashable, Codable, Sendable {
    public var key: DraftKey
    public var revision: DraftRevision
    public var contentHash: DraftContentHash

    public init(key: DraftKey, revision: DraftRevision, contentHash: DraftContentHash) {
        self.key = key
        self.revision = revision
        self.contentHash = contentHash
    }
}
