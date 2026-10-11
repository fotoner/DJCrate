import DJCApplication
import DJCDomain
import Foundation

/// 복구 시트(#232)의 줄에 보이는 글: 한 줄 차이 요약, 경고, 접어 둔 자세히 보기(기준·현재·내 편집).
/// 판정·적용 규칙(`DraftRecoveryReview`·`PlaylistRecoveryReview`)은 그대로 쓰고 여기서는 보여 줄 글만 만든다.
enum RecoverySummary {
    // MARK: - 곡 초안

    /// 초안의 기준이 지금 rekordbox와 달라졌는지. 같으면 rekordbox가 바뀌어서가 아니라 다른 이유(반쪽 분석 등)로 쓰지 못하는 초안이다.
    static func isStale(_ review: DraftRecoveryReview) -> Bool { !changeClauses(review).isEmpty }

    /// 무엇이 rekordbox에서 바뀌었는지(곡·종류 하나) 한 줄. 바뀐 것이 없으면 그렇게 알린다.
    static func summary(_ review: DraftRecoveryReview) -> String {
        let changes = changeClauses(review)
        guard !changes.isEmpty else { return String(ui: "rekordbox의 현재 값이 초안의 기준과 같아 바뀐 것이 없습니다") }
        var clauses = changes
        if case let (.tags(draft), .tags(current)) = (review.original, review.current) {
            // 태그는 내가 고친 칸과 같은 칸을 둘 다 바꾼 칸도 함께 보인다.
            let conflicts = TagDraftRecovery(draft: draft, current: current.base).conflictingKeys
            if !draft.changedKeys.isEmpty { clauses.append(String(ui: "내 편집: \(labels(draft.changedKeys))")) }
            if !conflicts.isEmpty { clauses.append(String(ui: "같은 칸을 둘 다 바꿈: \(labels(conflicts))")) }
        }
        return clauses.joined(separator: " · ")
    }

    /// rekordbox에서 바뀐 것의 요약 조각. 비어 있으면 바뀐 것이 없다.
    private static func changeClauses(_ review: DraftRecoveryReview) -> [String] {
        switch (review.original, review.current) {
        case let (.tags(draft), .tags(current)): tagClauses(draft: draft, current: current)
        case let (.cues(draft), .cues(current)): cueClauses(draft: draft, current: current)
        case let (.grid(draft), .grid(current)): gridClauses(draft: draft, current: current)
        default: []
        }
    }

    private static func tagClauses(draft: TagDraft, current: TagDraft) -> [String] {
        // 키·평점·곡 색은 고친 초안만 비교한다(그 칸이 없던 옛 초안의 빈 기준이 현재 값과 달라 보이는 것은 차이가 아니다).
        let external = TagFields.Key.allCases.filter {
            draft.base[$0] != current.base[$0] && (!TagFields.Key.independent.contains($0) || draft.base[$0] != draft.fields[$0])
        }
        return external.isEmpty ? [] : [String(ui: "rekordbox에서 바뀐 칸: \(labels(external))")]
    }

    private static func labels(_ keys: [TagFields.Key]) -> String { keys.map(\.label).joined(separator: "·") }

    private static func cueClauses(draft: CueDraft, current: CueDraft) -> [String] {
        let before = Dictionary(draft.base.compactMap { cue in cue.sourceID.map { ($0, cue) } }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.base.compactMap { cue in cue.sourceID.map { ($0, cue) } }, uniquingKeysWith: { first, _ in first })
        let added = after.keys.filter { before[$0] == nil }.count
        let removed = before.keys.filter { after[$0] == nil }.count
        let changed = after.filter { id, cue in before[id].map { !sameCue($0, cue) } ?? false }.count
        var parts: [String] = []
        if added > 0 { parts.append(String(ui: "추가 \(added)")) }
        if changed > 0 { parts.append(String(ui: "변경 \(changed)")) }
        if removed > 0 { parts.append(String(ui: "삭제 \(removed)")) }
        return parts.isEmpty ? [] : [String(ui: "rekordbox에서 바뀐 큐: \(parts.joined(separator: " · "))")]
    }

    private static func sameCue(_ a: EditableCue, _ b: EditableCue) -> Bool {
        a.kind == b.kind && abs(a.time - b.time) < 0.001 && a.name == b.name && a.loop == b.loop
    }

    private static func gridClauses(draft: GridDraft, current: GridDraft) -> [String] {
        func bpms(_ segments: [GridSegment]) -> String {
            var seen: [Double] = []
            for segment in segments where !seen.contains(segment.bpm) { seen.append(segment.bpm) }
            return seen.map { String(format: "%.2f", $0) }.joined(separator: "·")
        }
        if draft.base.map(\.bpm) != current.base.map(\.bpm) {
            return [String(ui: "rekordbox에서 바뀐 그리드: \(bpms(draft.base)) → \(bpms(current.base)) BPM")]
        }
        if draft.base != current.base { return [String(ui: "rekordbox에서 바뀐 그리드: 첫 박·구간 위치")] }
        // 대체 그리드는 구간으로 줄이기 전의 모든 박이 승인한 원본과 같아야 하므로 구간이 같아도 다시 확인한다.
        return draft.replacementSource == nil ? [] : [String(ui: "rekordbox에서 바뀐 그리드: 대체 승인한 원본의 박")]
    }

    /// 고르기 전에 알아 둘 것: 내 편집을 유지하면 달라지는 점
    static func notes(_ review: DraftRecoveryReview) -> [String] {
        var notes: [String] = []
        switch (review.original, review.current) {
        case let (.tags(draft), .tags(current)):
            let conflicts = TagDraftRecovery(draft: draft, current: current.base).conflictingKeys
            if !conflicts.isEmpty { notes.append(String(ui: "내 편집 유지를 고르면 같은 칸의 현재값을 내 값으로 덮습니다: \(labels(conflicts))")) }
        case let (.cues, .cues(current)):
            if case let .cues(merged)? = try? review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: review.cueSourceMappings),
               current.base.contains(where: { old in !merged.cues.contains { $0.sourceID == old.sourceID } }) {
                notes.append(String(ui: "내 편집 유지를 고르면 rekordbox의 현재 큐 일부가 없어집니다. 자세히 보기에서 확인하세요."))
            }
        case let (.grid(draft), _):
            if draft.replacementSource != nil {
                notes.append(String(ui: "내 편집 유지를 고르면 표시한 현재 원본의 전체 박을 기준으로 단일 템포 대체 그리드를 새로 승인합니다."))
            }
        default: break
        }
        return notes
    }

    /// 접어 둔 자세히 보기: 기준(초안을 만들 때) · 현재 · 내 편집
    static func details(_ review: DraftRecoveryReview) -> [String] {
        switch (review.original, review.current) {
        case let (.tags(d), .tags(c)):
            let recovery = TagDraftRecovery(draft: d, current: c.base)
            // 독립 칸(키·평점·곡 색)은 고친 초안만 비교에 올린다(그 칸이 없던 옛 초안의 빈 기준이 현재 값과 달라 보이는 것은 차이가 아니다)
            return TagFields.Key.allCases.filter {
                (!TagFields.Key.independent.contains($0) && d.base[$0] != c.base[$0]) || d.base[$0] != d.fields[$0]
            }.flatMap { key in
                [key.label + (recovery.conflictingKeys.contains(key) ? " ⚠︎" : ""),
                 String(ui: "기준: \(d.base[key])"), String(ui: "현재: \(c.base[key])"), String(ui: "내 편집: \(d.fields[key])")]
            }
        case let (.cues(d), .cues(c)):
            var lines = [String(ui: "기준:")] + d.base.map(cueDescription)
                + [String(ui: "현재:")] + c.base.map(cueDescription)
                + [String(ui: "내 편집:")] + d.cues.map(cueDescription)
            if case let .cues(merged)? = try? review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: review.cueSourceMappings) {
                let removed = c.base.filter { old in !merged.cues.contains { $0.sourceID == old.sourceID } }
                if !removed.isEmpty { lines += [String(ui: "내 편집 유지 때 없어질 현재 큐:")] + removed.map(cueDescription) }
            }
            for (oldSource, currentSource) in review.cueSourceMappings.sorted(by: { $0.key < $1.key }) {
                if let old = d.base.first(where: { $0.sourceID == oldSource }), let current = c.base.first(where: { $0.sourceID == currentSource }) {
                    lines += [String(ui: "직접 지정한 큐 대응:"), cueDescription(old), "→ " + cueDescription(current)]
                }
            }
            return lines
        case let (.grid(d), .grid(c)):
            return [String(ui: "기준:")] + d.base.map(gridDescription)
                + [String(ui: "현재:")] + c.base.map(gridDescription)
                + [String(ui: "내 편집:")] + d.segments.map(gridDescription)
        default: return []
        }
    }

    /// 내가 고친 큐 가운데 지금 rekordbox에 같은 ID가 없는 것(사람이 대응하는 현재 큐를 이어야 한다)
    static func missingCueMappings(_ review: DraftRecoveryReview) -> [EditableCue] {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return [] }
        let sources = Set(current.base.compactMap(\.sourceID))
        return draft.changes.compactMap {
            if case let .modified(old, _) = $0, let source = old.sourceID, !sources.contains(source) { return old }
            return nil
        }
    }

    /// 내 큐에 이을 수 있는 현재 큐(초안이 아는 ID가 아닌 것)
    static func cueMappingCandidates(_ review: DraftRecoveryReview) -> [EditableCue] {
        guard case let .cues(draft) = review.original, case let .cues(current) = review.current else { return [] }
        let known = Set(draft.base.compactMap(\.sourceID))
        return current.base.filter { cue in cue.sourceID.map { !known.contains($0) } ?? false }
    }

    static func cueDescription(_ cue: EditableCue) -> String {
        var parts = [cue.kind.slotLetter.map { String(ui: "핫큐 \($0)") } ?? String(ui: "메모리 큐"), String(ui: "\(cue.time, specifier: "%.3f")초")]
        if !cue.name.isEmpty { parts.append(cue.name) }
        if let loop = cue.loop { parts.append(String(ui: "루프 끝 \(loop.end, specifier: "%.3f")초 · 활성 \(loop.active ? 1 : 0) · 박 \(loop.beats ?? 0)")) }
        return parts.joined(separator: " · ")
    }

    private static func gridDescription(_ segment: GridSegment) -> String {
        String(ui: "\(segment.start, specifier: "%.3f")초 · \(segment.bpm, specifier: "%.4f") BPM · 박 \(segment.firstBeatNumber)")
    }

    // MARK: - 재생 목록

    static func playlistTitle(_ review: PlaylistRecoveryReview) -> String {
        review.current.layout.item(review.playlistID)?.name ?? review.original.base[review.playlistID]?.name ?? String(ui: "사라진 목록")
    }

    /// 편집이 기댄 목록 가운데 막힌 편집들이 기대는 처음 상태(ID별)
    private static func bases(_ review: PlaylistRecoveryReview) -> [String: PlaylistDraft.Base] {
        var bases: [String: PlaylistDraft.Base] = [:]
        for index in review.blockedOffsets {
            let step = review.original.steps[index]
            for dependency in step.depends where bases[dependency] == nil {
                bases[dependency] = (step.recoveryBase ?? review.original.base)[dependency]
            }
        }
        return bases
    }

    /// 무엇이 rekordbox에서 바뀌었는지(목록 하나) 한 줄
    static func playlistSummary(_ review: PlaylistRecoveryReview) -> String {
        let id = review.playlistID, layout = review.current.layout
        guard let base = bases(review)[id] else { return String(ui: "초안을 만든 뒤 rekordbox의 이 목록이 바뀌었습니다") }
        var clauses: [String] = []
        if id == PlaylistLayout.root {
            if base.childIDs != layout.childIDs(of: id) { clauses.append(String(ui: "맨 위 항목 순서가 바뀜")) }
        } else if let item = layout.item(id) {
            if item.name != base.name { clauses.append(String(ui: "이름: ‘\(base.name)’ → ‘\(item.name)’")) }
            if item.parentID != base.parentID { clauses.append(String(ui: "다른 폴더로 옮겨짐")) }
            if !base.isFolder, item.entries != base.entries { clauses.append(String(ui: "곡 목록이 바뀜")) }
            if let children = base.childIDs, children != layout.childIDs(of: id) { clauses.append(String(ui: "폴더 안 항목이 바뀜")) }
        } else {
            clauses.append(String(ui: "목록이 사라짐"))
        }
        if clauses.isEmpty, let reason = review.recovery.refused.values.sorted().first { return reason }
        return clauses.isEmpty ? String(ui: "초안을 만든 뒤 rekordbox의 이 목록이 바뀌었습니다") : String(ui: "rekordbox에서 바뀐 것: \(clauses.joined(separator: " · "))")
    }

    /// 다시 적용하지 못하는 편집의 이유
    static func playlistNotes(_ review: PlaylistRecoveryReview) -> [String] {
        review.blockedOffsets.compactMap { index in
            review.recovery.refused[index].map { String(ui: "이 편집은 다시 적용하지 못했으니 그대로 남기거나 버리고 다시 편집하세요: \($0)") }
        }
    }

    /// 접어 둔 자세히 보기: 기준 · 현재 · 내 편집 · 다시 적용한 뒤
    static func playlistDetails(_ review: PlaylistRecoveryReview) -> [String] {
        let id = review.playlistID, current = review.current.layout
        func name(_ id: String, layout: PlaylistLayout) -> String {
            if id == PlaylistLayout.root { return String(ui: "맨 위") }
            return layout.item(id)?.name ?? review.original.base[id]?.name ?? String(ui: "사라진 목록")
        }
        func tracks(_ entries: [PlaylistEntry]) -> [String] {
            entries.map { String(ui: "\($0.trackNo)번째 · \(review.current.titles[$0.contentID] ?? String(ui: "사라진 곡"))") }
        }
        func baseDescription(_ base: PlaylistDraft.Base?, id: String) -> [String] {
            guard let base else { return [String(ui: "사라진 목록")] }
            if id == PlaylistLayout.root {
                return [String(ui: "맨 위")] + (base.childIDs ?? []).map { name($0, layout: current) }
            }
            var lines = [base.name, String(ui: "폴더: \(name(base.parentID, layout: current))")]
            if let children = base.childIDs { lines += children.map { name($0, layout: current) } }
            if !base.isFolder { lines += tracks(base.entries) }
            return lines
        }
        func itemDescription(_ id: String, layout: PlaylistLayout) -> [String] {
            if id == PlaylistLayout.root { return layout.children(of: id).map(\.name) }
            guard let item = layout.item(id) else { return [String(ui: "사라진 목록")] }
            var lines = [item.name, String(ui: "폴더: \(name(item.parentID, layout: layout))")]
            if item.isFolder {
                for child in layout.childIDs(of: id) {
                    lines += itemDescription(child, layout: layout)
                }
            } else { lines += tracks(item.entries) }
            return lines
        }
        let bases = bases(review)
        var details = [String(ui: "기준:")] + baseDescription(bases[id], id: id)
            + [String(ui: "현재:")] + itemDescription(id, layout: current)
        for dependency in bases.keys.sorted() where dependency != id {
            details += [String(ui: "함께 확인할 목록: \(name(dependency, layout: current))"), String(ui: "기준:")]
                + baseDescription(bases[dependency], id: dependency) + [String(ui: "현재:")] + itemDescription(dependency, layout: current)
        }
        details += [String(ui: "내 편집:")]
        for index in review.blockedOffsets {
            details.append(playlistEditDescription(review.original.steps[index].edit, current: review.current))
        }
        if !review.recovery.reapplied.isEmpty {
            details += [String(ui: "다시 적용한 뒤:")] + itemDescription(id, layout: review.recovery.draft.project(onto: current).layout)
        }
        return details
    }

    private static func playlistEditDescription(_ edit: PlaylistEdit, current: PlaylistRecoveryCurrent) -> String {
        func target(_ ref: PlaylistRef) -> String {
            ref == .root ? String(ui: "맨 위") : current.layout.item(ref.layoutID)?.name ?? String(ui: "사라진 목록")
        }
        func titles(_ ids: [String]) -> String { ids.map { current.titles[$0] ?? String(ui: "사라진 곡") }.joined(separator: ", ") }
        switch edit {
        case let .create(_, name, _, parent): return String(ui: "‘\(target(parent))’ 안에 ‘\(name)’ 만들기")
        case let .rename(_, name): return String(ui: "이름을 ‘\(name)’으로 바꾸기")
        case let .move(_, into): return String(ui: "‘\(target(into))’ 안으로 옮기기")
        case let .reorder(_, index): return String(ui: "폴더 안 \(index + 1)번째로 옮기기")
        case .delete: return String(ui: "목록과 그 안의 항목 지우기")
        case let .addTracks(_, ids): return String(ui: "끝에 곡 넣기: \(titles(ids))")
        case let .removeTracks(_, entries): return String(ui: "목록에서 곡 빼기: \(titles(entries.map(\.contentID)))")
        case let .moveTracks(_, entries, to): return String(ui: "\(to)번째로 곡 옮기기: \(titles(entries.map(\.contentID)))")
        }
    }
}
