import Foundation

/// 재생 목록 초안(#39·#40): 저장(⌘S) 때 rekordbox에 쓸 편집을 적힌 순서대로 쌓는다.
///
/// 큐·그리드 초안처럼 편집이 기대는 rekordbox 목록의 처음 상태(`base`)를 들고 있어, 그 뒤 rekordbox에서 바뀐 목록의 편집은 쓰지 않는다.
/// - 곡 넣기·빼기·옮기기·이름 바꾸기·옮기기: 그 목록의 이름·부모·곡 항목
/// - 순서 바꾸기: 그 목록과 부모 안 순서(자리 번호가 거기에 기댄다)
/// - 지우기: 그 아래 모든 목록(지우면 함께 사라지므로 그 뒤 rekordbox에서 넣은 곡·목록이 있으면 막는다)
/// - 만들기·옮겨 넣을 폴더: 폴더가 있기만 하면 된다
/// 초안으로 만든 목록(`new:키`)은 rekordbox 상태가 없어 기댈 것이 없다.
public struct PlaylistDraft: Codable, Hashable, Sendable {
    /// 편집이 기대는 목록 하나의 rekordbox 상태
    public struct Base: Codable, Hashable, Sendable {
        public var name: String
        public var parentID: String
        public var isFolder: Bool
        public var entries: [PlaylistEntry]
        /// 부모 안 순서에 기대는 편집(순서 바꾸기의 부모, 폴더 지우기)이 있을 때만 적는다
        public var childIDs: [String]?

        public init(_ item: PlaylistLayout.Item, childIDs: [String]? = nil) {
            name = item.name
            parentID = item.parentID
            isFolder = item.isFolder
            entries = item.entries
            self.childIDs = childIDs
        }

        /// 부모 ID와 자식 순서에 든 새 목록 키(`new:키`)를 받은 rekordbox ID로 바꾼 기준
        func remapped(_ ids: [String: String]) -> Base {
            var base = self
            base.parentID = ids[parentID] ?? parentID
            base.childIDs = childIDs?.map { ids[$0] ?? $0 }
            return base
        }

        /// 맨 위(자식 순서만 본다)
        static func root(childIDs: [String]) -> Base {
            var base = Base(PlaylistLayout.Item(id: PlaylistLayout.root, name: "", parentID: "", isFolder: true))
            base.childIDs = childIDs
            return base
        }
    }

    public struct Step: Codable, Hashable, Sendable {
        public var edit: PlaylistEdit
        /// 이 편집이 기대는 rekordbox 목록(ID, 맨 위는 `root`). 하나라도 `base`와 달라졌으면 쓰지 않는다.
        public var depends: [String]
        /// 선택해 다시 적용한 편집의 기준. 같은 목록에 기대는 미선택 편집의 기준과 분리한다.
        public var recoveryBase: [String: Base]?
        /// 단계의 식별자(자동 저장 R5·R22). 한번 받으면 바뀌지 않는다: 편집이 합쳐져도(`fold`) 복사돼도 그대로다.
        /// 초안 저장소가 저장할 때 부여하고 초안 파일에 적는다(핵심부는 ID를 만들지 않는다). 도장(출처·판)은 이 식별자로 단계를 잇는다.
        /// 아직 저장하지 않은 단계와 옛 파일의 단계는 nil이고, 저장소가 저장하거나 읽을 때 새로 부여한다.
        /// 같음과 해시는 식별자를 보지 않는다(편집 내용이 같으면 같은 단계다)
        public var id: UUID?

        public init(edit: PlaylistEdit, depends: [String] = []) {
            self.edit = edit
            self.depends = depends
        }

        public static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.edit == rhs.edit && lhs.depends == rhs.depends && lhs.recoveryBase == rhs.recoveryBase
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(edit)
            hasher.combine(depends)
            hasher.combine(recoveryBase)
        }
    }

    public private(set) var steps: [Step] = []
    /// 목록 ID → 편집이 처음 기댄 때의 rekordbox 상태
    public private(set) var base: [String: Base] = [:]

    public init() {}

    public var edits: [PlaylistEdit] { steps.map(\.edit) }
    public var isEmpty: Bool { steps.isEmpty }

    /// 단계별 식별자(`Step.id`, 단계 차례)
    public var stepIDs: [UUID?] { steps.map(\.id) }

    /// 단계 식별자를 차례대로 적는다(초안 저장소가 부여한 값). 개수는 단계 수와 같아야 한다
    public mutating func setStepIDs(_ ids: [UUID?]) {
        precondition(ids.count == steps.count, "식별자 수가 단계 수와 다르다")
        for index in steps.indices { steps[index].id = ids[index] }
    }

    static var changedReason: String { String(ui: "편집을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 편집을 버리세요.") }

    // MARK: - 쌓기

    /// 편집을 더한다. 지금 rekordbox 상태에 초안을 얹은 모양에서 쓸 수 없는 편집이면 `PlaylistLayout.Blocked`를 던지고 그대로 둔다.
    /// 같은 목록의 이름은 마지막 것만 남기고, 초안으로 만든 목록을 지우면 만든 편집부터 없던 일로 한다.
    /// - Parameter frozen: 지금 rekordbox에 쓰고 있는 단계의 식별자(얼림, R21). 쓰고 있는 단계는 `fold`에서 빼서 합치지도 지우지도 않고,
    ///   새 편집은 뒤에 쌓는다. 쓰고 있는 단계가 바꾸는 목록에 기대는 새 단계는 쓰는 단계를 쓴 뒤의 모양을 기준(`recoveryBase`)으로 삼는다.
    ///   그래서 쓴 뒤 앞 단계를 빼도 새 단계는 낡은 것으로 막히지 않는다(앞 단계를 쓰지 못했으면 막힌다).
    ///   식별자가 없는 단계는 얼릴 수 없다(부르는 쪽이 식별자를 확인한 뒤 얼린다)
    /// - Returns: 더한 뒤 모양
    @discardableResult
    public mutating func append(_ edit: PlaylistEdit, rekordbox: PlaylistLayout, frozen: Set<UUID> = []) throws -> PlaylistLayout {
        let before = project(onto: rekordbox, frozen: frozen).layout
        var after = before
        try after.apply(edit)
        var draft = self
        // 쓰고 있는 단계를 쓴 뒤의 rekordbox 모양. 지우기는 이 모양에서 하위 목록을 구한다(쓰는 동안 폴더로 들어온 목록도 삭제 기준에 든다)
        let afterFrozen = frozen.isEmpty ? nil : frozenLayout(onto: rekordbox, frozen: frozen)
        let needs = Self.needs(edit, in: before, rekordbox: rekordbox, structure: afterFrozen)
        // 쓰고 있는 단계가 기대는 목록의 공유 기준은 바꾸지 않는다(그 단계의 해시·판이 바뀌어 쓴 뒤 정리가 찾지 못한다).
        // 그런 목록과 쓰고 있는 단계가 바꾸는 목록(쓴 뒤 모양이 지금 rekordbox와 다르다)에 새 단계가 기대는 기준은 그 단계 안에 둔다
        let writingDepends = Set(steps.filter { isFrozen($0, frozen) }.flatMap(\.depends))
        var own: [String: Base] = [:]
        for need in needs {
            let then = afterFrozen.flatMap { Self.makeBase(need.id, children: need.children, in: $0) }
            if writingDepends.contains(need.id) {
                own[need.id] = then ?? Self.makeBase(need.id, children: need.children, in: rekordbox)
                continue
            }
            draft.capture(need.id, children: need.children, from: rekordbox)
            if let then, let now = Self.makeBase(need.id, children: need.children, in: rekordbox), then != now { own[need.id] = then }
        }
        switch draft.fold(edit, before: before, rekordbox: rekordbox, frozen: frozen) {
        case .merged:
            break
        case let .separate(inheriting):
            var step = Step(edit: edit, depends: needs.map(\.id))
            step.id = inheriting
            if !own.isEmpty {
                // 기준을 단계 안에 둔다: 위에서 가린 목록만 그 기준이고 나머지는 공유 기준이다(단계 기준은 모든 `depends`를 덮어야 한다)
                step.recoveryBase = Dictionary(needs.compactMap { need in (own[need.id] ?? draft.base[need.id]).map { (need.id, $0) } },
                                               uniquingKeysWith: { first, _ in first })
            }
            draft.steps.append(step)
        }
        draft.pruneBase()
        self = draft
        return after
    }

    /// 쓰고 있는 단계(`frozen`)만 얹은 모양(그 단계들을 쓴 뒤의 rekordbox 모양)
    private func frozenLayout(onto rekordbox: PlaylistLayout, frozen: Set<UUID>) -> PlaylistLayout {
        var writing = self
        writing.steps = steps.filter { isFrozen($0, frozen) }
        return writing.project(onto: rekordbox).layout
    }

    private func isFrozen(_ step: Step, _ frozen: Set<UUID>) -> Bool { step.id.map(frozen.contains) ?? false }

    /// 편집이 기대는 rekordbox 목록(초안으로 만든 목록은 뺀다)
    /// - Parameter structure: 편집을 쓰는 때의 목록 구조(쓰고 있는 단계를 쓴 뒤 모양). 지우기는 이 구조에서 하위 목록을 구한다. 없으면 rekordbox 구조다
    static func needs(_ edit: PlaylistEdit, in layout: PlaylistLayout, rekordbox: PlaylistLayout,
                      structure: PlaylistLayout? = nil) -> [(id: String, children: Bool)] {
        func existing(_ ref: PlaylistRef) -> String? {
            if case let .id(id) = ref, rekordbox.item(id) != nil { id } else { nil }
        }
        switch edit {
        case .create: return []
        case let .rename(ref, _), let .move(ref, _), let .addTracks(ref, _), let .removeTracks(ref, _), let .moveTracks(ref, _, _):
            return existing(ref).map { [($0, false)] } ?? []
        case let .reorder(ref, _):
            var needs = existing(ref).map { [($0, false)] } ?? []
            if let parent = layout.item(ref.layoutID)?.parentID, parent == PlaylistLayout.root || rekordbox.item(parent) != nil {
                needs.append((parent, true))
            }
            return needs
        case let .delete(ref):
            guard let id = existing(ref) else { return [] }
            let shape = structure ?? rekordbox
            return shape.subtree(of: id).filter { rekordbox.item($0) != nil }.map { ($0, shape.item($0)?.isFolder == true) }
        }
    }

    mutating func capture(_ id: String, children: Bool, from rekordbox: PlaylistLayout) {
        if base[id] == nil { base[id] = Self.makeBase(id, children: false, in: rekordbox) }
        if children, base[id] != nil, base[id]?.childIDs == nil { base[id]?.childIDs = rekordbox.childIDs(of: id) }
    }

    /// 그 목록의 기준(맨 위는 자식 순서만). 목록이 없으면 nil. `children`이면 자식 순서도 적는다
    static func makeBase(_ id: String, children: Bool, in layout: PlaylistLayout) -> Base? {
        if id == PlaylistLayout.root { return .root(childIDs: layout.childIDs(of: id)) }
        guard let item = layout.item(id) else { return nil }
        return Base(item, childIDs: children ? layout.childIDs(of: id) : nil)
    }

    /// 편집을 쌓은 결과: 앞 단계에 합쳐졌거나(새 단계 없음), 새 단계로 붙는다. 지운 단계를 대신해 붙는 새 단계는 지운 단계의 식별자를 잇는다
    /// (같은 대상의 마지막 편집만 쓰는 이름 바꾸기: 앞 출처가 새 단계 도장에 합쳐진다, R5)
    enum Fold {
        case merged
        case separate(inheriting: UUID?)
    }

    /// 앞 편집과 합칠 수 있으면 합친다. 쓰고 있는 단계(`frozen`)는 합치지도 지우지도 않는다
    mutating func fold(_ edit: PlaylistEdit, before: PlaylistLayout, rekordbox: PlaylistLayout, frozen: Set<UUID> = []) -> Fold {
        switch edit {
        case let .rename(ref, name):
            if case let .new(key) = ref, let index = createIndex(key), !isFrozen(steps[index], frozen),
               case let .create(_, _, isFolder, parent) = steps[index].edit {
                steps[index].edit = .create(key: key, name: name, isFolder: isFolder, parent: parent)
                return .merged
            }
            // 이름은 마지막 것만 쓴다. rekordbox 이름으로 되돌리면 편집이 없다.
            // 다만 쓰고 있는 이름 바꾸기가 있으면 쓴 뒤 이름이 달라지므로 rekordbox 이름으로 되돌리는 것도 편집이다.
            let writingRename = steps.contains { step in
                if isFrozen(step, frozen), case .rename(ref, _) = step.edit { true } else { false }
            }
            var replaced: [UUID] = [], kept: [Step] = []
            for step in steps {
                if !isFrozen(step, frozen), case .rename(ref, _) = step.edit {
                    if let id = step.id { replaced.append(id) }
                } else {
                    kept.append(step)
                }
            }
            steps = kept
            return !writingRename && rekordbox.item(ref.layoutID)?.name == name ? .merged : .separate(inheriting: replaced.first)
        case let .delete(.new(key)):
            let subtree = Set(before.subtree(of: PlaylistRef.new(key).layoutID))
            guard let start = createIndex(key), !isFrozen(steps[start], frozen), subtree.allSatisfy({ $0.hasPrefix("new:") })
            else { return .separate(inheriting: nil) }
            // 쓰고 있는 단계가 그 아래 목록을 만들었거나 거쳐 갔으면 없던 일로 할 수 없다(쓰고 있는 단계를 지우지 않는다)
            guard !steps.contains(where: { step in
                isFrozen(step, frozen)
                    && (subtree.contains(step.edit.playlist.layoutID) || step.edit.destination.map { subtree.contains($0.layoutID) } == true)
            }) else { return .separate(inheriting: nil) }
            let outside = steps.filter { !subtree.contains($0.edit.playlist.layoutID) }
            // 다른 목록이 이 폴더를 거쳐 갔거나(만든 뒤 밖으로 옮김), 뒤에 부모 안 자리에 기대는 순서 바꾸기가 있으면 그대로 지운다.
            guard !outside.contains(where: { $0.edit.destination.map { subtree.contains($0.layoutID) } == true }),
                  !steps[start...].contains(where: { step in
                      if case let .reorder(ref, _) = step.edit { !subtree.contains(ref.layoutID) } else { false }
                  })
            else { return .separate(inheriting: nil) }
            steps = outside
            return .merged
        default:
            return .separate(inheriting: nil)
        }
    }

    func createIndex(_ key: String) -> Int? {
        steps.firstIndex { if case .create(key, _, _, _) = $0.edit { true } else { false } }
    }

    mutating func pruneBase() {
        let used = Set(steps.flatMap(\.depends))
        base = base.filter { used.contains($0.key) }
    }

    // MARK: - 버리기

    /// 이 목록(폴더면 그 아래까지, 초안을 얹은 모양 기준)을 건드린 편집을 버린다.
    /// 버린 새 목록을 가리키던 편집(그 안에 만든 목록, 그리로 옮긴 목록 등)도 함께 버린다.
    /// - Parameter frozen: 지금 rekordbox에 쓰고 있는 단계의 식별자. 쓰고 있는 단계는 버리지 않는다(R21)
    public mutating func discard(playlist id: String, rekordbox: PlaylistLayout, frozen: Set<UUID> = []) {
        let layout = project(onto: rekordbox, frozen: frozen).layout
        let ids = Set(layout.item(id) != nil ? layout.subtree(of: id) : [id])
        steps = steps.filter { isFrozen($0, frozen) || !ids.contains($0.edit.playlist.layoutID) }
        dropOrphans(frozen: frozen)
        pruneBase()
    }

    /// 지금 rekordbox 상태에서 쓸 수 없는 편집을 모두 버린다(그 편집에 기대던 편집도). 쓰고 있는 단계(`frozen`)는 버리지 않는다.
    public mutating func discardBlocked(rekordbox: PlaylistLayout, contentIDs: Set<String>? = nil, frozen: Set<UUID> = []) {
        while true {
            let blocked = project(onto: rekordbox, contentIDs: contentIDs, frozen: frozen).blocked
            guard zip(steps, blocked).contains(where: { !isFrozen($0.0, frozen) && $0.1 != nil }) else { break }
            steps = zip(steps, blocked).filter { isFrozen($0.0, frozen) || $0.1 == nil }.map(\.0)
            dropOrphans(frozen: frozen)
        }
        pruneBase()
    }

    /// 쓴 편집을 뺀다(쓰기 모듈 결과가 편집 순서와 같다). 남은 편집은 그대로 두어 다음 반영에서 다시 본다.
    public mutating func removeSteps(at offsets: some Sequence<Int>) {
        let drop = Set(offsets)
        steps = steps.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        pruneBase()
    }

    /// 쓴 뒤 새 목록의 연결 ID를 남은 단계에 옮긴다(R22): 남은 단계의 대상과 목적지(만들기의 부모, 옮기기의 폴더)가 가리키던 `new:키`를
    /// 받은 rekordbox ID로 바꾼다. 단계 기준(`base`·`recoveryBase`)의 부모 ID와 자식 순서에 든 `new:키`도 옮긴다(쓰는 동안 쌓은 순서 편집의 기준이
    /// 쓴 뒤 모양을 담는다). 만든 단계가 남아 있는 키는 `ids`에서 빼서 부른다(그 키는 아직 `new:키`다). 단계 식별자는 그대로다.
    /// 다시 해도 결과가 같다(옮길 `new:키`가 이미 없으면 바뀌는 것이 없다)
    public func remapped(_ ids: [String: String]) -> PlaylistDraft {
        guard !ids.isEmpty else { return self }
        var draft = self
        draft.steps = steps.map { step in
            var step = step
            step.edit = step.edit.remapped(ids)
            step.recoveryBase = step.recoveryBase?.mapValues { $0.remapped(ids) }
            return step
        }
        draft.base = base.mapValues { $0.remapped(ids) }
        return draft
    }

    /// 곡 추가를 되돌리면 사라진 ContentID를 초안에서도 뺀다. 다른 목록의 base는 그대로 둔다.
    public mutating func forgetContentIDs(_ ids: Set<String>, rekordbox: PlaylistLayout) {
        var originalLayout = rekordbox
        steps = steps.compactMap { step in
            let original = step.edit
            let before = originalLayout.item(original.playlist.layoutID)?.entries ?? []
            defer { try? originalLayout.apply(original) }
            // 앞의 추가 편집에서 빠진 곡만큼 뒤의 자리 번호도 당긴다.
            func remaining(_ entries: [PlaylistEntry]) -> [PlaylistEntry] {
                entries.filter { !ids.contains($0.contentID) }.map { entry in
                    PlaylistEntry(trackNo: entry.trackNo - before.filter { $0.trackNo < entry.trackNo && ids.contains($0.contentID) }.count,
                                  contentID: entry.contentID)
                }
            }
            var step = step
            switch step.edit {
            case let .addTracks(ref, tracks):
                let kept = tracks.filter { !ids.contains($0) }
                guard !kept.isEmpty else { return nil }
                step.edit = .addTracks(playlist: ref, contentIDs: kept)
            case let .removeTracks(ref, entries):
                let kept = remaining(entries)
                guard !kept.isEmpty else { return nil }
                step.edit = .removeTracks(playlist: ref, entries: kept)
            case let .moveTracks(ref, entries, to):
                let kept = remaining(entries)
                guard !kept.isEmpty else { return nil }
                let removedBefore = before.filter { !entries.contains($0) }.prefix(max(0, to - 1)).filter { ids.contains($0.contentID) }.count
                step.edit = .moveTracks(playlist: ref, entries: kept, to: to - removedBefore)
            default: break
            }
            return step
        }
        pruneBase()
    }

    /// 만든 편집이 없어진 새 목록을 가리키는 편집을 버린다(없어질 때까지 되풀이). 쓰고 있는 단계(`frozen`)는 늘 남긴다
    mutating func dropOrphans(frozen: Set<UUID> = []) {
        while true {
            var created = Set<String>()
            var kept: [Step] = []
            for step in steps {
                let refs = [step.edit.playlist, step.edit.destination].compactMap { $0 }
                if case let .create(key, _, _, _) = step.edit {
                    if isFrozen(step, frozen) || refs.dropFirst().allSatisfy({ ref in if case .new = ref { created.contains(ref.layoutID) } else { true } }) {
                        created.insert(PlaylistRef.new(key).layoutID)
                        kept.append(step)
                    }
                    continue
                }
                if isFrozen(step, frozen) || refs.allSatisfy({ ref in if case .new = ref { created.contains(ref.layoutID) } else { true } }) { kept.append(step) }
            }
            guard kept.count != steps.count else { return }
            steps = kept
        }
    }

    /// 되돌린 뒤: 되살린 편집을 지금 rekordbox 상태에 차례로 다시 쌓는다(쌓을 수 없는 편집은 `failed`).
    public static func rebuilt(_ edits: [PlaylistEdit], rekordbox: PlaylistLayout) -> (draft: PlaylistDraft, failed: [PlaylistEdit], reasons: [String]) {
        var draft = PlaylistDraft(), failed: [PlaylistEdit] = [], reasons: [String] = []
        for edit in edits {
            do { try draft.append(edit, rekordbox: rekordbox) }
            catch {
                failed.append(edit)
                reasons.append((error as? PlaylistLayout.Blocked)?.reason ?? String(describing: error))
            }
        }
        return (draft, failed, reasons)
    }

    // MARK: - 얹어 보기

    public struct Projection: Hashable, Sendable {
        /// 초안을 얹은 모양(막힌 편집은 빼고)
        public var layout: PlaylistLayout
        public var edits: [PlaylistEdit]
        /// 편집마다 쓸 수 없는 이유(쓸 수 있으면 nil). `edits`와 같은 순서.
        public var blocked: [String?]
        /// 초안으로 바뀌는 목록(새로 만든 것·이름·자리·곡이 바뀐 것, 안의 목록을 지운 폴더)
        public var changed: Set<String>
        /// 막힌 편집이 가리키는 목록 → 처음 이유
        public var blockedTargets: [String: String]

        public var ready: [PlaylistEdit] { zip(edits, blocked).filter { $0.1 == nil }.map(\.0) }
        public var blockedEdits: [(edit: PlaylistEdit, reason: String)] {
            zip(edits, blocked).compactMap { edit, reason in reason.map { (edit, $0) } }
        }
    }

    /// 지금 rekordbox 상태가 base와 다르면 그 이유
    public func staleReason(_ id: String, rekordbox: PlaylistLayout) -> String? {
        staleReason(id, base: base, rekordbox: rekordbox)
    }

    /// 화면과 쓰기 관문이 같은 편집별 기준을 검사한다.
    public func staleReason(for step: Step, rekordbox: PlaylistLayout) -> String? {
        step.depends.lazy.compactMap { staleReason($0, base: step.recoveryBase ?? base, rekordbox: rekordbox) }.first
    }

    private func staleReason(_ id: String, base bases: [String: Base], rekordbox: PlaylistLayout) -> String? {
        guard let base = bases[id] else { return nil }
        let children = base.childIDs.map { _ in rekordbox.childIDs(of: id) }
        if id == PlaylistLayout.root { return children == base.childIDs ? nil : Self.changedReason }
        guard let now = rekordbox.item(id) else { return String(ui: "rekordbox에서 지운 목록입니다") }
        return Base(now, childIDs: children) == base ? nil : Self.changedReason
    }

    /// 지금 rekordbox 상태에 편집을 차례로 얹는다. base와 달라진 목록에 기대는 편집, 얹을 수 없는 편집은 막힌 것으로 두고 건너뛴다.
    /// - Parameter frozen: 지금 rekordbox에 쓰고 있는 단계의 식별자. 쓰고 있지 않은 단계는 쓰고 있는 단계를 쓴 뒤의 모양을 기준으로 낡음을 본다
    ///   (쓰는 동안 옛 사본 위에 보여 주려고. 쓰기가 끝나 쓴 단계를 빼고 새 사본을 읽으면 `frozen` 없이 같은 기준으로 맞는다)
    public func project(onto rekordbox: PlaylistLayout, contentIDs: Set<String>? = nil, frozen: Set<UUID> = []) -> Projection {
        var layout = rekordbox
        let written = frozen.isEmpty ? rekordbox : frozenLayout(onto: rekordbox, frozen: frozen)
        var blocked: [String?] = [], changed = Set<String>(), targets: [String: String] = [:]
        for step in steps {
            let target = step.edit.playlist.layoutID
            let parent = layout.item(target)?.parentID
            var reason = staleReason(for: step, rekordbox: frozen.isEmpty || isFrozen(step, frozen) ? rekordbox : written)
            if reason == nil, let contentIDs, case let .addTracks(_, ids) = step.edit,
               !ids.allSatisfy({ contentIDs.contains($0) }) {
                reason = String(ui: "넣을 곡이 rekordbox 컬렉션에서 사라졌으니 이 편집을 버리고 곡을 다시 선택하세요.")
            }
            if reason == nil {
                do { try layout.apply(step.edit) } catch let error as PlaylistLayout.Blocked { reason = error.reason } catch { reason = "\(error)" }
            }
            blocked.append(reason)
            if let reason {
                if targets[target] == nil { targets[target] = reason }
                continue
            }
            if case .delete = step.edit {
                if let parent, parent != PlaylistLayout.root { changed.insert(parent) }
            } else {
                changed.insert(target)
            }
        }
        return Projection(layout: layout, edits: edits, blocked: blocked, changed: changed.filter { layout.item($0) != nil },
                          blockedTargets: targets)
    }
}

extension PlaylistDraft {
    public struct Recovery: Hashable, Sendable {
        public var draft: PlaylistDraft
        /// 원래 초안의 편집 번호(0부터)
        public var reapplied: [Int]
        public var refused: [Int: String]
    }

    /// 선택한 목록의 막힌 편집만 현재 상태에 차례로 다시 쌓는다. 실패와 미선택 편집은 원래 기준으로 남긴다.
    public func recovering(playlist id: String, rekordbox: PlaylistLayout, contentIDs: Set<String>) -> Recovery {
        let blocked = project(onto: rekordbox, contentIDs: contentIDs).blocked
        var draft = self, layout = rekordbox
        var reapplied: [Int] = [], refused: [Int: String] = [:]
        var captured: [Int: [String: Base]] = [:], alreadyCurrent = Set<Int>()
        for (index, step) in steps.enumerated() {
            guard blocked[index] != nil, step.edit.playlist.layoutID == id else {
                if blocked[index] == nil { try? layout.apply(step.edit) }
                continue
            }
            do {
                let edit = try recoveryEdit(at: index, onto: layout, contentIDs: contentIDs)
                let needs = Self.needs(edit, in: layout, rekordbox: rekordbox)
                var current = PlaylistDraft()
                for need in needs { current.capture(need.id, children: need.children, from: rekordbox) }
                let rebuilt = Self.rebuilt([edit], rekordbox: layout)
                if let reason = rebuilt.reasons.first { throw PlaylistLayout.Blocked(reason) }
                layout = rebuilt.draft.project(onto: layout).layout
                if rebuilt.draft.isEmpty { alreadyCurrent.insert(index) }
                var replacement = Step(edit: edit, depends: needs.map(\.id))
                replacement.recoveryBase = current.base
                draft.steps[index] = replacement
                captured[index] = current.base
                reapplied.append(index)
            } catch let error as PlaylistLayout.Blocked { refused[index] = error.reason }
            catch { refused[index] = String(describing: error) }
        }
        // 공유 기준을 바꾸면 고르지 않은 편집까지 풀리므로 그 기준은 편집 안에만 둔다.
        let untouched = Set(steps.enumerated().filter { !reapplied.contains($0.offset) }.flatMap { $0.element.depends })
        for index in reapplied {
            for (id, base) in captured[index] ?? [:] where !untouched.contains(id) { draft.base[id] = base }
        }
        draft.removeSteps(at: alreadyCurrent)
        return Recovery(draft: draft, reapplied: reapplied, refused: refused)
    }

    private func recoveryEdit(at index: Int, onto layout: PlaylistLayout, contentIDs: Set<String>) throws -> PlaylistEdit {
        let edit = steps[index].edit
        switch edit {
        case let .addTracks(ref, ids):
            guard ids.allSatisfy({ contentIDs.contains($0) }) else {
                throw PlaylistLayout.Blocked(String(ui: "넣을 곡이 rekordbox 컬렉션에서 사라졌으니 이 편집을 버리고 곡을 다시 선택하세요."))
            }
            return .addTracks(playlist: ref, contentIDs: ids)
        case let .removeTracks(ref, entries):
            try requireRecoveryTracks(entries, contentIDs: contentIDs)
            return .removeTracks(playlist: ref, entries: try recoveryEntries(entries, at: index, onto: layout))
        case let .moveTracks(ref, entries, to):
            try requireRecoveryTracks(entries, contentIDs: contentIDs)
            return .moveTracks(playlist: ref, entries: try recoveryEntries(entries, at: index, onto: layout), to: to)
        default: return edit
        }
    }

    private func requireRecoveryTracks(_ entries: [PlaylistEntry], contentIDs: Set<String>) throws {
        guard entries.allSatisfy({ contentIDs.contains($0.contentID) }) else {
            throw PlaylistLayout.Blocked(String(ui: "대상 곡이 rekordbox 컬렉션에서 사라졌으니 이 편집을 버리고 곡을 다시 선택하세요."))
        }
    }

    private func recoveryEntries(_ entries: [PlaylistEntry], at index: Int, onto layout: PlaylistLayout) throws -> [PlaylistEntry] {
        let step = steps[index], id = step.edit.playlist.layoutID
        guard let now = layout.item(id) else {
            throw PlaylistLayout.Blocked(String(ui: "대상 목록이 사라졌으니 이 편집을 버리고 목록을 다시 선택하세요."))
        }
        let originalBase = (step.recoveryBase ?? base)[id]
        var original = PlaylistLayout([(PlaylistLayout.Item(id: id, name: "", parentID: PlaylistLayout.root, isFolder: false,
                                                           entries: originalBase?.entries ?? []), 1)])
        // 자리 번호는 앞 편집의 결과에 기대므로 처음 기준에서 앞의 곡 편집을 재생한다.
        for earlier in steps.prefix(index) where earlier.edit.playlist.layoutID == id {
            switch earlier.edit {
            case .addTracks, .removeTracks, .moveTracks: try original.apply(earlier.edit)
            default: break
            }
        }
        let before = original.item(id)?.entries ?? []
        if before == now.entries { return entries }
        return try entries.map { entry in
            let oldMatches = before.filter { $0.contentID == entry.contentID }
            let matches = now.entries.filter { $0.contentID == entry.contentID }
            guard oldMatches.count == 1, matches.count == 1, let match = matches.first else {
                throw PlaylistLayout.Blocked(String(ui: "곡이 목록에서 사라졌거나 같은 곡의 대응이 모호하니 이 편집을 버리고 목록을 다시 편집하세요."))
            }
            return match
        }
    }
}
