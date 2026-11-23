import Foundation

/// 재생 목록 단계 하나의 도장 한 줄: 단계 식별자(`PlaylistDraft.Step.id`)와 그 단계의 도장(출처·판·해시)
public struct PlaylistStampEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var stamp: DraftStamp

    public init(id: UUID, stamp: DraftStamp) {
        self.id = id
        self.stamp = stamp
    }
}

/// 재생 목록 단계의 식별자·도장 규칙(자동 저장 R5·R22). 도장은 단계에 저장한 식별자로 단계를 잇는다. 해시로 다시 붙이지 않는다:
/// 같은 내용의 단계가 둘이면(같은 곡 넣기 → 빼기 → 다시 넣기) 해시로는 어느 단계의 판인지 가를 수 없다.
/// 순수 규칙이라 초안 저장소(실제)와 메모리 구현이 같은 함수를 쓴다. 식별자와 판 번호는 부르는 쪽이 준다(핵심부는 만들지 않는다).
public enum PlaylistStepStamping {
    /// 식별자·도장을 맞춘 결과
    public struct Result: Equatable, Sendable {
        /// 모든 단계가 식별자를 가진 초안
        public var draft: PlaylistDraft
        /// `draft.steps`와 같은 차례의 도장
        public var entries: [PlaylistStampEntry]
        /// 입력과 달라졌다(초안 파일의 식별자나 도장 사이드카를 다시 적어야 한다)
        public var changed: Bool
    }

    /// 단계의 내용 해시(`DraftContentHash(step:in:)`, 해시를 못 구하면 빈 해시)
    public static func hash(_ step: PlaylistDraft.Step, in draft: PlaylistDraft) -> DraftContentHash {
        (try? DraftContentHash(step: step, in: draft)) ?? DraftContentHash(hex: "")
    }

    /// 파일에 있는 초안의 단계에 식별자를 맞추고 도장 줄을 맞춘다.
    /// - 식별자가 있고 겹치지 않는 단계는 그 식별자로 도장을 잇는다. 도장이 없는 단계는 새 판과 모름 출처의 도장을 받는다
    ///   (초안 저장과 도장 갱신 사이에 멈춘 단계, 도장을 모르는 쪽이 더한 단계).
    /// - 식별자가 없는 단계(옛 파일)는 새 식별자와 모름 도장을 받는다.
    /// - 예외: 식별자가 하나도 없고 단계 수가 도장 줄 수와 같으면(식별자를 모르는 쪽이 파일 전체를 다시 쓴 경우) 같은 자리의 도장을 잇는다.
    ///   내용이 바뀌었으면 해시가 어긋나 제안·사본 대상이 된다(W0 계약)
    public static func adopt(_ draft: PlaylistDraft, entries: [PlaylistStampEntry], newID: () -> UUID,
                             newRevision: () throws -> DraftRevision) throws -> Result {
        var ids = draft.stepIDs
        var seen = Set<UUID>()
        for index in ids.indices {
            if let id = ids[index], !seen.insert(id).inserted { ids[index] = nil }
        }
        var fresh = Set<Int>()
        if !ids.isEmpty, ids.allSatisfy({ $0 == nil }), entries.count == ids.count {
            ids = entries.map { Optional($0.id) }
        } else {
            for index in ids.indices where ids[index] == nil {
                ids[index] = newID()
                fresh.insert(index)
            }
        }
        let known = Dictionary(entries.map { ($0.id, $0.stamp) }, uniquingKeysWith: { first, _ in first })
        var adopted: [PlaylistStampEntry] = []
        for (index, step) in draft.steps.enumerated() {
            let id = ids[index]!
            if !fresh.contains(index), let stamp = known[id] {
                adopted.append(PlaylistStampEntry(id: id, stamp: stamp))
            } else {
                adopted.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: [.unknown],
                                                                           contentHash: hash(step, in: draft))))
            }
        }
        var identified = draft
        identified.setStepIDs(ids)
        return Result(draft: identified, entries: adopted, changed: identified.stepIDs != draft.stepIDs || adopted != entries)
    }

    /// 초안을 저장한다: 저장하는 초안(`incoming`)의 단계에 식별자를 맞추고 도장을 갱신한다.
    /// - 식별자가 있는 단계는 그대로 쓴다. 식별자가 없는 단계(앱이 메모리에 든 채 아직 파일에서 받지 않은 단계)는 지금 파일의 단계 가운데
    ///   다른 단계가 쓰지 않은 것과 내용 차례(최장 공통 부분 수열)로 맞춘다. 맞지 않으면 새 식별자를 받는다.
    /// - 내용이 그대로인 단계는 도장을 그대로 둔다. 내용이 바뀐 단계(합쳐진 편집)는 새 판을 받고 출처는 앞 출처에 이번 출처를 더한다.
    /// - 덮어쓰기 전에 지금 파일의 단계 해시가 도장의 해시와 다르면(바깥에서 고쳤다) 모름을 더한다.
    /// - 도장 없는 기존 단계는 모름을 유지한다. 새 단계는 이번 출처 하나다.
    /// - Parameters:
    ///   - previous: 저장 직전 파일의 초안
    ///   - entries: 저장 직전 도장 줄
    public static func save(_ incoming: PlaylistDraft, previous: PlaylistDraft, entries: [PlaylistStampEntry], origin: DraftOrigin,
                            newID: () -> UUID, newRevision: () throws -> DraftRevision) throws -> Result {
        let prior = try adopt(previous, entries: entries, newID: newID, newRevision: newRevision)
        var ids = incoming.stepIDs
        var seen = Set<UUID>()
        for index in ids.indices {
            if let id = ids[index], !seen.insert(id).inserted { ids[index] = nil }
        }
        // 식별자 없는 단계를 지금 파일의 단계와 맞춘다
        let claimed = Set(ids.compactMap { $0 })
        let pool = prior.draft.steps.indices.filter { !claimed.contains(prior.draft.steps[$0].id!) }
        let candidates = ids.indices.filter { ids[$0] == nil }
        let pairs = commonSubsequence(pool.map { hash(prior.draft.steps[$0], in: prior.draft) },
                                      candidates.map { hash(incoming.steps[$0], in: incoming) })
        for (poolIndex, candidateIndex) in pairs { ids[candidates[candidateIndex]] = prior.draft.steps[pool[poolIndex]].id }
        // 내용이 맞지 않는 나머지: 맞춘 단계 사이의 빈틈에서 단계 수가 같으면 차례대로 짝짓는다(합쳐져 내용이 바뀐 단계를 잇는다).
        // 잘못 짝지어도 앞 단계의 출처가 더해질 뿐이라 제안 쪽으로만 틀어진다
        let anchors = [(-1, -1)] + pairs + [(pool.count, candidates.count)]
        for (before, after) in zip(anchors, anchors.dropFirst()) {
            let left = Array((before.0 + 1)..<after.0), right = Array((before.1 + 1)..<after.1)
            guard !left.isEmpty, left.count == right.count else { continue }
            for (poolIndex, candidateIndex) in zip(left, right) { ids[candidates[candidateIndex]] = prior.draft.steps[pool[poolIndex]].id }
        }
        for index in ids.indices where ids[index] == nil { ids[index] = newID() }
        var saved = incoming
        saved.setStepIDs(ids)

        let before = Dictionary(uniqueKeysWithValues: zip(prior.draft.steps, prior.entries).map { ($0.id!, ($0, $1.stamp)) })
        var stamps: [PlaylistStampEntry] = []
        for (index, step) in saved.steps.enumerated() {
            let id = ids[index]!
            let current = hash(step, in: saved)
            guard let (previousStep, old) = before[id] else {
                stamps.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: [origin], contentHash: current)))
                continue
            }
            let outside = hash(previousStep, in: prior.draft) != old.contentHash
            if current == old.contentHash, !outside {
                stamps.append(PlaylistStampEntry(id: id, stamp: old))
                continue
            }
            var origins = old.origins.union([origin])
            if outside { origins.insert(.unknown) }
            stamps.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: origins, contentHash: current)))
        }
        return Result(draft: saved, entries: stamps, changed: true)
    }

    /// 두 해시 열의 최장 공통 부분 수열(차례를 지킨다). 짝 `(a 쪽 자리, b 쪽 자리)`
    static func commonSubsequence(_ a: [DraftContentHash], _ b: [DraftContentHash]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
