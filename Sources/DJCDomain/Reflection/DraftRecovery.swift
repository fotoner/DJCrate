import Foundation

/// 종류 전체의 차이를 본 뒤 사용자가 고르는 동작이다. 가져오기 자체는 초안을 바꾸지 않는다.
public enum DraftRecoveryChoice: Sendable { case keepEditing, useCurrent }
public enum DraftRecoveryError: Error { case ambiguousIdentity }

public struct TagDraftRecovery: Sendable {
    public let draft: TagDraft
    public let current: TagFields
    public init(draft: TagDraft, current: TagFields) { self.draft = draft; self.current = current }
    public var conflictingKeys: [TagFields.Key] { draft.conflictingKeys(with: current) }
    public func resolve(_ choice: DraftRecoveryChoice) -> TagDraft {
        var result = TagDraft(trackUUID: draft.trackUUID, base: current)
        if case .keepEditing = choice {
            for key in draft.changedKeys { result.fields[key] = draft.fields[key] }
        }
        return result
    }
}

public struct CueDraftRecovery: Sendable {
    public let draft: CueDraft
    public let current: [EditableCue]
    public let sourceMappings: [String: String]
    public init(draft: CueDraft, current: [EditableCue], sourceMappings: [String: String] = [:]) {
        self.draft = draft; self.current = current; self.sourceMappings = sourceMappings
    }

    public func resolve(_ choice: DraftRecoveryChoice) throws -> CueDraft {
        if case .keepEditing = choice, !sourceMappings.isEmpty {
            let oldSources = Set(draft.base.compactMap(\.sourceID))
            let latestSources = current.compactMap(\.sourceID)
            guard Set(sourceMappings.values).count == sourceMappings.count,
                  sourceMappings.allSatisfy({ oldSources.contains($0.key) && !latestSources.contains($0.key)
                      && !oldSources.contains($0.value) }) else {
                throw DraftRecoveryError.ambiguousIdentity
            }
            for target in sourceMappings.values where latestSources.filter({ $0 == target }).count != 1 {
                throw DraftRecoveryError.ambiguousIdentity
            }
            var mapped = draft
            for index in mapped.base.indices {
                if let old = mapped.base[index].sourceID, let selected = sourceMappings[old] { mapped.base[index].sourceID = selected }
            }
            for index in mapped.cues.indices {
                if let old = mapped.cues[index].sourceID, let selected = sourceMappings[old] { mapped.cues[index].sourceID = selected }
            }
            return try CueDraftRecovery(draft: mapped, current: current).resolve(choice)
        }
        var result = CueDraft(trackUUID: draft.trackUUID)
        result.base = current.map { cue in
            var cue = cue
            if let source = cue.sourceID, let old = draft.base.first(where: { $0.sourceID == source }) { cue.id = old.id }
            return cue
        }.sorted { $0.time < $1.time }
        result.cues = result.base
        if case .useCurrent = choice { return result }
        let sources = draft.base.compactMap(\.sourceID), latest = current.compactMap(\.sourceID)
        guard sources.count == draft.base.count, Set(sources).count == sources.count,
              latest.count == current.count, Set(latest).count == latest.count,
              Set(draft.cues.map(\.id)).count == draft.cues.count,
              Set(draft.base.map(\.id)).count == draft.base.count else { throw DraftRecoveryError.ambiguousIdentity }
        for change in draft.changes {
            switch change {
            case let .removed(old):
                // 외부에서 이미 지운 큐는 같은 결과다. 수정한 큐가 사라진 경우와 구분한다.
                result.cues.removeAll { $0.sourceID == old.sourceID }
            case let .modified(old, desired):
                guard let index = result.cues.firstIndex(where: { $0.sourceID == old.sourceID }) else {
                    throw DraftRecoveryError.ambiguousIdentity
                }
                var merged = result.cues[index]
                if old.kind != desired.kind { merged.kind = desired.kind }
                if old.time != desired.time { merged.time = desired.time }
                if old.name != desired.name { merged.name = desired.name }
                if old.loop == nil || desired.loop == nil {
                    if old.loop != desired.loop { merged.loop = desired.loop }
                } else if old.loop != desired.loop {
                    // 루프를 고친 경우에만 외부에서 없어진 루프를 명시 재적용한다.
                    if merged.loop == nil { merged.loop = desired.loop }
                    if old.loop?.end != desired.loop?.end { merged.loop?.end = desired.loop!.end }
                    if old.loop?.active != desired.loop?.active { merged.loop?.active = desired.loop!.active }
                    if old.loop?.beats != desired.loop?.beats { merged.loop?.beats = desired.loop!.beats }
                }
                result.cues[index] = merged
            case let .added(cue):
                let candidates = result.base.filter {
                    !sources.contains($0.sourceID ?? "") && $0.kind == cue.kind && $0.time == cue.time
                        && $0.name == cue.name && $0.loop == cue.loop
                }
                guard candidates.count <= 1 else { throw DraftRecoveryError.ambiguousIdentity }
                if candidates.isEmpty { result.cues.append(cue) }
            }
        }
        // 내 편집의 슬롯 선택만 재적용한다. 다른 슬롯·메모리 큐·자동 큐는 최신 그대로다.
        let editedIDs = Set(draft.changes.compactMap { change -> UUID? in
            switch change { case let .added(cue): cue.id; case let .modified(_, cue): cue.id; case .removed: nil }
        })
        let editedHot = result.cues.filter { editedIDs.contains($0.id) && $0.kind.slotLetter != nil }
        for cue in editedHot { result.cues.removeAll { $0.kind == cue.kind && $0.id != cue.id } }
        result.cues.sort { $0.time < $1.time }
        return result
    }
}

public struct GridDraftRecovery: Sendable {
    public let draft: GridDraft
    public let current: [GridSegment]
    public init(draft: GridDraft, current: [GridSegment]) { self.draft = draft; self.current = current }
    public func resolve(_ choice: DraftRecoveryChoice) throws -> GridDraft {
        var result = GridDraft(trackUUID: draft.trackUUID, base: current, segments: current)
        if case .useCurrent = choice { return result }
        if current == draft.base { result.segments = draft.segments; return result }
        if current == draft.segments { return result }
        // 변속 지점의 추가·삭제·순서가 바뀌면 위치로 추측해 다른 구간에 편집을 붙이지 않는다.
        guard current.count == draft.base.count, draft.segments.count == draft.base.count,
              (current.count == 1 || (zip(current, draft.base).allSatisfy({ $0.start == $1.start })
                && zip(draft.segments, draft.base).allSatisfy({ $0.start == $1.start }))) else {
            throw DraftRecoveryError.ambiguousIdentity
        }
        for index in current.indices {
            let old = draft.base[index], desired = draft.segments[index]
            if old.start != desired.start { result.segments[index].start = desired.start }
            if old.bpm != desired.bpm { result.segments[index].bpm = desired.bpm }
            if old.firstBeatNumber != desired.firstBeatNumber { result.segments[index].firstBeatNumber = desired.firstBeatNumber }
        }
        return result
    }
}
