import DJCDomain
import Foundation

/// 묶음 편집이 가리키는 목록·폴더(#260). 글자 하나로도 쓴다: `root`, rekordbox ID, `new:키`(초안으로 이미 만든 목록),
/// `@이름`(같은 묶음에서 앞서 만든 목록), `name:이름`(그 차례 모양에서 이름이 하나인 목록).
public enum PlaylistTarget: Hashable, Sendable, CustomStringConvertible {
    case ref(PlaylistRef)
    case alias(String)
    case name(String)

    public init(_ text: String) {
        if text.hasPrefix("@") { self = .alias(String(text.dropFirst())) }
        else if text.hasPrefix("name:") { self = .name(String(text.dropFirst(5))) }
        else { self = .ref(PlaylistRef(text)) }
    }

    public var description: String {
        switch self {
        case let .ref(ref): ref.description
        case let .alias(alias): "@\(alias)"
        case let .name(name): "name:\(name)"
        }
    }
}

/// 부모 안 자리
public enum PlaylistPosition: Hashable, Sendable {
    /// 0부터. 형제 수보다 크면 맨 끝
    case index(Int)
    /// 이 항목 바로 앞
    case before(PlaylistTarget)
}

/// 재생 목록 편집 요청 하나(사이드바 조작 하나와 같은 단위). 요청 하나가 편집 여러 개가 되면 모두 쌓거나 하나도 쌓지 않는다.
public enum PlaylistEditRequest: Hashable, Sendable {
    /// 새 목록·폴더. 자리를 주지 않으면 부모 맨 위다(rekordbox와 같다). `alias`를 주면 뒤 요청이 `@alias`로 가리킨다.
    /// `tracks`는 만든 목록에 넣을 곡(ContentID)이다.
    case create(name: String, isFolder: Bool, parent: PlaylistTarget, position: PlaylistPosition?, alias: String?, tracks: [String])
    case rename(PlaylistTarget, name: String)
    /// `into`가 nil이면 지금 부모 안에서 자리만 바꾼다. 자리를 주지 않으면 그 부모의 맨 끝이다(rekordbox와 같다).
    case move(PlaylistTarget, into: PlaylistTarget?, position: PlaylistPosition?)
    /// 폴더면 안의 목록까지 지운다
    case delete(PlaylistTarget)
    /// 목록 끝에 넣는다. 이미 든 곡은 넣지 않는다(앱과 같다).
    case addTracks(PlaylistTarget, contentIDs: [String])
    /// 그 곡의 모든 자리를 뺀다
    case removeTracks(PlaylistTarget, contentIDs: [String])
    /// 곡을 준 순서대로 `before` 곡 앞에(nil이면 맨 끝) 놓는다
    case moveTracks(PlaylistTarget, contentIDs: [String], before: String?)
}

extension EditPlaylists {
    /// 요청 하나의 결과
    public struct BatchOutcome: Hashable, Sendable {
        public enum Status: String, Hashable, Sendable {
            /// 초안에 쌓았다
            case stacked
            /// 이미 그 모양이라 쌓을 편집이 없다
            case unchanged
            /// 막혀 건너뛰었다(`reason`)
            case skipped
        }

        public var status: Status
        public var reason: String?
        /// 편집한 목록(초안을 얹은 모양의 ID: rekordbox ID 또는 `new:키`). 찾지 못했으면 nil
        public var playlistID: String?
        /// 그 목록의 이름(편집하기 전, 만들기면 새 이름)
        public var name: String?
        /// 초안에 더한 편집
        public var edits: [PlaylistEdit] = []
        /// 넣거나 빼지 않은 곡(이미 든 곡, 목록에 없는 곡)
        public var ignored: [String] = []
    }

    /// 묶음 편집 계획
    public struct Batch: Sendable {
        /// 쌓은 뒤 초안(`refused`면 받은 초안 그대로)
        public var draft: PlaylistDraft
        /// 요청마다 결과(요청 순서)
        public var outcomes: [BatchOutcome]
        /// 임시 이름 → 만든 목록 ID(`new:키`)
        public var aliases: [String: String]
        /// 쌓은 뒤 모양(rekordbox 상태에 초안을 얹은 것)
        public var layout: PlaylistLayout
        /// 하나라도 막히면 쌓지 않기로 했고 막힌 요청이 있어 아무것도 쌓지 않았다
        public var refused: Bool

        public var stackedCount: Int { refused ? 0 : outcomes.filter { $0.status == .stacked }.count }
        public var skippedCount: Int { outcomes.filter { $0.status == .skipped }.count }
        public var hasChanges: Bool { stackedCount > 0 }
        /// 처음 막힌 요청의 이유
        public var firstSkipReason: String? { outcomes.first { $0.status == .skipped }?.reason }
    }

    /// 요청을 차례로 지금 rekordbox 상태 + 초안에 얹어 계획한다. 막힌 요청은 이유와 함께 건너뛰고 나머지를 쌓는다(`allOrNothing`이면 하나도 쌓지 않는다).
    /// 막힘 판정은 앱 초안과 같다(`PlaylistDraft.append`): 인텔리전트·쓰기 규칙을 확인하지 않은 목록, 폴더가 아닌 부모, 제 안으로 옮기기 등.
    /// 이름(`name:`)은 그 차례 모양에서 찾는다. 편집이 기대는 rekordbox 목록 상태는 초안이 `base`로 적는다.
    /// - Parameters:
    ///   - contentIDs: rekordbox 컬렉션의 곡. 주면 그 밖의 곡을 넣는 요청을 막는다
    ///   - newKey: 새 목록 열쇠(`new:키`)
    public static func planning(_ requests: [PlaylistEditRequest], onto draft: PlaylistDraft, rekordbox: PlaylistLayout,
                                contentIDs: Set<String>? = nil, allOrNothing: Bool = false, newKey: () -> String) -> Batch {
        var current = draft
        var layout = draft.project(onto: rekordbox).layout
        var aliases: [String: String] = [:]
        var outcomes: [BatchOutcome] = []
        for request in requests {
            var planner = RequestPlanner(layout: layout, aliases: aliases, contentIDs: contentIDs)
            do {
                var outcome = try planner.plan(request, newKey: newKey)
                if !outcome.edits.isEmpty {
                    // 요청 하나의 편집은 모두 쌓거나 하나도 쌓지 않는다
                    var next = current
                    for edit in outcome.edits { try next.append(edit, rekordbox: rekordbox) }
                    current = next
                    layout = current.project(onto: rekordbox).layout
                    if case let .create(_, _, _, _, alias?, _) = request, let id = outcome.playlistID { aliases[alias] = id }
                }
                outcome.status = outcome.edits.isEmpty ? .unchanged : .stacked
                outcomes.append(outcome)
            } catch {
                let reason = (error as? PlaylistLayout.Blocked)?.reason ?? DJCError.reason(of: error)
                // 만들지 못한 목록의 `new:키`는 내지 않는다(그 ID로 이어 편집하면 찾지 못한 목록이 된다)
                let made: String? = if case .create = request { nil } else { planner.resolvedID }
                outcomes.append(BatchOutcome(status: .skipped, reason: reason, playlistID: made, name: planner.resolvedName))
            }
        }
        let refused = allOrNothing && outcomes.contains { $0.status == .skipped }
        return Batch(draft: refused ? draft : current, outcomes: outcomes, aliases: aliases,
                     layout: refused ? draft.project(onto: rekordbox).layout : layout, refused: refused)
    }
}

/// 요청 하나를 그 차례 모양에서 편집으로 바꾼다(쌓지는 않는다)
private struct RequestPlanner {
    let layout: PlaylistLayout
    let aliases: [String: String]
    let contentIDs: Set<String>?
    /// 막혀도 결과에 남길 대상 목록과 그 이름
    var resolvedID: String?
    var resolvedName: String?

    init(layout: PlaylistLayout, aliases: [String: String], contentIDs: Set<String>?) {
        self.layout = layout
        self.aliases = aliases
        self.contentIDs = contentIDs
    }

    mutating func plan(_ request: PlaylistEditRequest, newKey: () -> String) throws -> EditPlaylists.BatchOutcome {
        switch request {
        case let .create(name, isFolder, parent, position, alias, tracks):
            if let alias, aliases[alias] != nil {
                throw PlaylistLayout.Blocked(String(ui: "같은 묶음에 같은 임시 이름(@\(alias))으로 만든 목록이 있습니다"))
            }
            let parentID = try resolve(parent)
            try requireKnown(tracks)
            let key = newKey()
            let ref = PlaylistRef.new(key)
            resolvedID = ref.layoutID
            resolvedName = name
            var edits: [PlaylistEdit] = [.create(key: key, name: name, isFolder: isFolder, parent: PlaylistRef(parentID))]
            if let position {
                // 새 항목은 부모 맨 위에 생긴다. 다른 자리면 순서 바꾸기를 잇는다
                let index = try self.index(position, in: parentID, moving: nil)
                if index != 0 { edits.append(.reorder(playlist: ref, index: index)) }
            }
            var ignored: [String] = []
            if !tracks.isEmpty {
                let split = PlaylistLayout.Item(id: ref.layoutID, name: name).split(adding: tracks)
                ignored = split.duplicates
                edits.append(.addTracks(playlist: ref, contentIDs: split.new))
            }
            return outcome(edits, ignored: ignored)

        case let .rename(target, name):
            let item = try item(target)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return outcome(name == item.name ? [] : [.rename(playlist: PlaylistRef(item.id), name: name)])

        case let .move(target, into, position):
            let item = try item(target)
            let parent = try into.map(resolve) ?? item.parentID
            let others = layout.childIDs(of: parent).filter { $0 != item.id }
            // 같은 부모 안에서 자기 앞이면 그대로다(다른 폴더면 아래에서 그 폴더 안 자리가 아니라고 막는다)
            if parent == item.parentID, case let .before(sibling) = position, try resolve(sibling) == item.id { return outcome([]) }
            let index = try position.map { try self.index($0, in: parent, moving: item.id) } ?? others.count
            let ref = PlaylistRef(item.id)
            if item.parentID != parent {
                // 옮기기는 새 부모 맨 끝에 놓는다. 다른 자리면 순서 바꾸기를 잇는다
                return outcome([.move(playlist: ref, into: PlaylistRef(parent))] + (index != others.count ? [.reorder(playlist: ref, index: index)] : []))
            }
            return outcome(index == layout.childIDs(of: parent).firstIndex(of: item.id) ? [] : [.reorder(playlist: ref, index: index)])

        case let .delete(target):
            let item = try item(target)
            return outcome([.delete(playlist: PlaylistRef(item.id))])

        case let .addTracks(target, contentIDs):
            let item = try trackList(target)
            try requireKnown(contentIDs)
            let split = item.split(adding: contentIDs)
            return outcome(split.new.isEmpty ? [] : [.addTracks(playlist: PlaylistRef(item.id), contentIDs: split.new)], ignored: split.duplicates)

        case let .removeTracks(target, contentIDs):
            let item = try trackList(target)
            let entries = item.entries(of: Set(contentIDs))
            guard !entries.isEmpty else { throw Self.absent }
            let present = Set(item.trackIDs)
            return outcome([.removeTracks(playlist: PlaylistRef(item.id), entries: entries)], ignored: contentIDs.filter { !present.contains($0) })

        case let .moveTracks(target, contentIDs, before):
            let item = try trackList(target)
            let present = Set(item.trackIDs)
            let wanted = contentIDs.filter(present.contains)
            guard !wanted.isEmpty else { throw Self.absent }
            if let before, !present.contains(before) {
                throw PlaylistLayout.Blocked(String(ui: "앞에 둘 곡(ContentID \(before))이 그 목록에 없습니다"))
            }
            let moving = item.firstEntries(of: Set(wanted))
            var edits: [PlaylistEdit] = []
            if moving.map(\.contentID) == Self.unique(wanted) {
                // 목록 순서 그대로면 앱의 끌어 옮기기와 같은 편집 하나
                if let edit = Self.moveEdit(item, moving: moving, before: before) { edits.append(edit) }
            } else {
                // 준 순서가 목록 순서와 다르면 곡마다 차례로 같은 자리 앞에 놓는다
                var local = layout
                for id in Self.unique(wanted) {
                    guard let now = local.item(item.id), let edit = Self.moveEdit(now, moving: now.firstEntries(of: [id]), before: before) else { continue }
                    try local.apply(edit)
                    edits.append(edit)
                }
            }
            return outcome(edits, ignored: contentIDs.filter { !present.contains($0) })
        }
    }

    private func outcome(_ edits: [PlaylistEdit], ignored: [String] = []) -> EditPlaylists.BatchOutcome {
        EditPlaylists.BatchOutcome(status: .stacked, playlistID: resolvedID, name: resolvedName, edits: edits, ignored: ignored)
    }

    static var absent: PlaylistLayout.Blocked { PlaylistLayout.Blocked(String(ui: "그 목록에 든 곡이 아닙니다. djc playlist로 곡을 확인하세요")) }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 곡들을 `before` 앞(nil이면 맨 끝)으로 옮기는 편집. 이미 그 자리면 nil
    static func moveEdit(_ item: PlaylistLayout.Item, moving: [PlaylistEntry], before: String?) -> PlaylistEdit? {
        guard !moving.isEmpty else { return nil }
        let to = item.insertionPoint(before: before, moving: moving)
        var after = item.entries.filter { !moving.contains($0) }
        after.insert(contentsOf: moving, at: min(max(to - 1, 0), after.count))
        return after == item.entries ? nil : .moveTracks(playlist: PlaylistRef(item.id), entries: moving, to: to)
    }

    private func requireKnown(_ ids: [String]) throws {
        guard let contentIDs else { return }
        if let missing = ids.first(where: { !contentIDs.contains($0) }) {
            throw PlaylistLayout.Blocked(String(ui: "rekordbox 컬렉션에 없는 곡입니다(ContentID \(missing))"))
        }
    }

    /// 자리(부모 안 번호, 0부터). `moving`은 옮기는 항목(형제에서 뺀다)
    private func index(_ position: PlaylistPosition, in parent: String, moving: String?) throws -> Int {
        let others = layout.childIDs(of: parent).filter { $0 != moving }
        switch position {
        case let .index(index): return min(max(index, 0), others.count)
        case let .before(target):
            let id = try resolve(target)
            guard let index = others.firstIndex(of: id) else {
                throw PlaylistLayout.Blocked(String(ui: "자리로 준 항목이 그 폴더 안에 없습니다"))
            }
            return index
        }
    }

    /// 편집할 목록(인텔리전트 목록 등 막힌 목록은 앱 초안과 같은 이유로 막는다)
    private mutating func item(_ target: PlaylistTarget) throws -> PlaylistLayout.Item {
        let id = try resolve(target)
        resolvedID = id
        resolvedName = layout.item(id)?.name
        return try layout.target(PlaylistRef(id))
    }

    private mutating func trackList(_ target: PlaylistTarget) throws -> PlaylistLayout.Item {
        let id = try resolve(target)
        resolvedID = id
        resolvedName = layout.item(id)?.name
        return try layout.trackList(PlaylistRef(id))
    }

    /// 모양 안 ID(`root`, rekordbox ID, `new:키`). 없는 목록은 그 편집을 쌓을 때 막힌다
    private func resolve(_ target: PlaylistTarget) throws -> String {
        switch target {
        case let .ref(ref): return ref.layoutID
        case let .alias(alias):
            guard let id = aliases[alias] else {
                throw PlaylistLayout.Blocked(String(ui: "앞에서 만들지 못한 목록입니다(@\(alias))"))
            }
            return id
        case let .name(name):
            let matches = layout.outline.filter { $0.name == name }
            guard !matches.isEmpty else { throw PlaylistLayout.Blocked(String(ui: "‘\(name)’ 이름의 재생 목록이 없습니다. djc playlists로 이름을 확인하세요")) }
            guard matches.count == 1 else {
                throw PlaylistLayout.Blocked(String(ui: "‘\(name)’ 이름의 목록이 \(matches.count)개라 고를 수 없습니다. ID로 가리키세요"))
            }
            return matches[0].id
        }
    }
}
