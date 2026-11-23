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

/// 재생 목록 단계의 식별자·도장 규칙(자동 저장 R5·R22). 도장은 단계에 저장한 식별자로 단계를 잇는다.
/// 원칙: 단계의 동일성을 확인할 수 없으면 기존 판을 어떤 단계에도 다시 붙이지 않는다. 해시나 단계 차례로 짐작해 잇지 않는다
/// (같은 내용의 단계가 둘이면 해시로는 가를 수 없고, 같은 자리의 단계가 같은 단계라는 보장도 없다). 확인할 수 없는 단계는 새 판과 모름
/// 출처를 받는다. 그러면 옛 판으로 하는 정리는 그 단계를 지우지 못한다(쓰지 않은 편집을 지우는 일이 없다). 이미 쓴 단계가 제안으로 남는 것은
/// 받아들인다(⌘S로 사용자가 고른다).
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

    /// 단계 식별자. 같은 식별자를 가진 단계가 둘 이상이면 어느 단계가 그 식별자의 단계인지 확인할 수 없으므로 모두 nil로 만든다
    /// (첫 단계에 옛 판을 붙이지 않는다). `duplicated`는 그렇게 비운 자리다
    private static func uniqueIDs(_ draft: PlaylistDraft) -> (ids: [UUID?], duplicated: Set<Int>) {
        let all = draft.stepIDs
        let counts = Dictionary(all.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        var ids = all
        var duplicated = Set<Int>()
        for index in ids.indices {
            if let id = ids[index], counts[id, default: 0] > 1 {
                ids[index] = nil
                duplicated.insert(index)
            }
        }
        return (ids, duplicated)
    }

    /// 파일에 있는 초안의 단계에 식별자를 맞추고 도장 줄을 맞춘다.
    /// - 식별자가 있고 겹치지 않는 단계는 그 식별자로 도장을 잇는다.
    /// - 식별자가 없는 단계(옛 파일, 식별자를 모르는 쪽이 다시 쓴 파일)는 새 식별자를 받고, 도장이 없는 단계(초안 저장과 도장 갱신 사이에
    ///   멈춘 단계, 도장을 모르는 쪽이 더한 단계)는 새 판과 모름 출처의 도장을 받는다. 단계 수가 같아도 같은 자리의 도장을 잇지 않는다.
    public static func adopt(_ draft: PlaylistDraft, entries: [PlaylistStampEntry], newID: () -> UUID,
                             newRevision: () throws -> DraftRevision) throws -> Result {
        var ids = uniqueIDs(draft).ids
        var fresh = Set<Int>()
        for index in ids.indices where ids[index] == nil {
            ids[index] = newID()
            fresh.insert(index)
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
    /// - 식별자가 있는 단계는 그 식별자로 지금 파일의 단계를 잇는다. 식별자가 없는 단계는 이번 출처가 새로 만든 단계다: 새 식별자와 새 판,
    ///   출처는 이번 출처 하나다. 지금 파일의 단계와 내용으로 맞춰 보지 않는다(그래서 앱은 저장한 뒤 디스크에서 다시 읽어 식별자를 받는다).
    /// - 식별자가 있는데 지금 파일에 없는 단계(이미 정리로 빠진 단계를 낡은 메모리가 되살림)는 새 판에 이번 출처와 모름을 둔다.
    /// - 내용이 그대로인 단계는 도장을 그대로 둔다. 내용이 바뀐 단계(합쳐진 편집)는 새 판을 받고 출처는 앞 출처에 이번 출처를 더한다.
    /// - 덮어쓰기 전에 지금 파일의 단계 해시가 도장의 해시와 다르면(바깥에서 고쳤다) 모름을 더한다.
    /// - 도장 없는 기존 단계는 모름을 유지한다.
    /// - 지금 파일을 읽지 못했으면(`previousUnreadable`) 빈 파일과 다르다: 저장하는 모든 단계는 새 판을 받고 출처는 기존 도장의 출처에
    ///   이번 출처와 모름을 더한다(새 출처 하나만 받지 않는다).
    /// - Parameters:
    ///   - previous: 저장 직전 파일의 초안(읽지 못했으면 빈 초안)
    ///   - entries: 저장 직전 도장 줄
    public static func save(_ incoming: PlaylistDraft, previous: PlaylistDraft, entries: [PlaylistStampEntry], origin: DraftOrigin,
                            previousUnreadable: Bool = false, newID: () -> UUID,
                            newRevision: () throws -> DraftRevision) throws -> Result {
        let unique = uniqueIDs(incoming)
        var ids = unique.ids
        let given = ids
        for index in ids.indices where ids[index] == nil { ids[index] = newID() }
        var saved = incoming
        saved.setStepIDs(ids)

        if previousUnreadable {
            let remembered = Dictionary(entries.map { ($0.id, $0.stamp) }, uniquingKeysWith: { first, _ in first })
            var stamps: [PlaylistStampEntry] = []
            for (index, step) in saved.steps.enumerated() {
                let id = ids[index]!
                let origins = (given[index] == nil ? [] : remembered[id]?.origins ?? []).union([origin, .unknown])
                stamps.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: origins,
                                                                          contentHash: hash(step, in: saved))))
            }
            return Result(draft: saved, entries: stamps, changed: true)
        }

        let known = Dictionary(entries.map { ($0.id, $0.stamp) }, uniquingKeysWith: { first, _ in first })
        let prior = try adopt(previous, entries: entries, newID: newID, newRevision: newRevision)
        let before = Dictionary(uniqueKeysWithValues: zip(prior.draft.steps, prior.entries).map { ($0.id!, ($0, $1.stamp)) })
        var stamps: [PlaylistStampEntry] = []
        for (index, step) in saved.steps.enumerated() {
            let id = ids[index]!
            let current = hash(step, in: saved)
            guard given[index] != nil else {
                // 식별자가 없는 단계는 이번 출처가 새로 만든 단계다. 식별자가 겹쳐 비운 단계는 확인할 수 없으니 모름도 더한다
                let origins: Set<DraftOrigin> = unique.duplicated.contains(index) ? [origin, .unknown] : [origin]
                stamps.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: origins, contentHash: current)))
                continue
            }
            guard let (previousStep, old) = before[id] else {
                // 식별자는 있는데 지금 파일에 단계가 없다(정리·복구로 파일에서 빠졌다). 사이드카에 도장이 남아 있으면 그 출처를 잇고 모름을 더한다
                let remembered = known[id]?.origins ?? []
                stamps.append(PlaylistStampEntry(id: id, stamp: DraftStamp(revision: try newRevision(), origins: remembered.union([origin, .unknown]),
                                                                          contentHash: current)))
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
}
