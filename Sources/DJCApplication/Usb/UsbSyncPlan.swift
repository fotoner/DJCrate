import DJCDomain
import Foundation

/// 동기화 뒤 USB 목록 미리 보기의 표시
public enum UsbSyncPreviewMark: Hashable, Sendable {
    /// 새로 만든다(이름을 바꾼 원본도 새 목록이 된다)
    case created
    /// 이은 USB 목록을 새 자리로 옮긴다
    case moved
    /// 어느 원본에도 잇지 않고 그대로 남는다(rekordbox 장치 트리에서 회색)
    case unlinked
}

/// 재생 목록 편집만 계획한 결과(곡 편집 없이 미리 보기에도 쓴다)
public struct UsbSyncPlaylistPlan: Sendable {
    public var edits: [PlaylistEdit]
    /// 원본 목록 ID → 기존 USB 목록 또는 같은 묶음에서 만든 목록
    public var refs: [String: PlaylistRef]
    /// 편집을 얹은 USB 목록 트리
    public var result: PlaylistLayout
    /// 지우는 USB 목록(폴더면 안에 든 것까지 함께 지운다). 편집 전 트리의 항목
    public var deleted: [PlaylistLayout.Item]
    public var marks: [String: UsbSyncPreviewMark]
}

/// 선택한 로컬 트리를 USB 편집으로 만든다. rekordbox처럼(2026-10-08 정상 USB 실험) 지난 선택 파일 행으로 이어졌던 USB 목록은
/// 원본을 선택에서 빼거나 로컬에서 지우면 지우고, 이름을 바꾼 원본은 새 목록을 만들어 옛 목록을 연결 없이 남긴다.
/// 이름을 바꾼 폴더는 하위 목록까지 새로 만들고 옛 폴더와 그 안의 목록을 남긴다(2026-10-08 실험 G3).
public struct UsbSyncPlan: Sendable {
    public var edits: [UsbLibraryEdit]
    public var layout: PlaylistLayout
    public var trackIDs: [String]
    /// 동기화에 잇지 않고 USB에 그대로 남는 목록·폴더 수(rekordbox 장치 트리에서 회색)
    public var unlinkedPlaylistCount: Int
    /// 지우는 USB 목록(폴더면 안에 든 것까지)
    public var deletedPlaylists: [PlaylistLayout.Item] = []
    /// 동기화 뒤 USB의 어느 목록에도 없는 곡. rekordbox처럼 확인을 받은 뒤에만 USB에서 뺀다.
    public var orphanTrackIDs: [Int] = []
    /// 어느 목록에도 없지만 빼면 USB(어느 형식이든)에 곡이 하나도 남지 않아 빼지 않는 곡. 곡 0개 라이브러리는 쓰지 않는다
    /// (`lastTrack`, 곡 빼기가 막히면 목록 지우기·선택 파일까지 묶음 전체가 쓰이지 않는다)
    public var keptOrphanTrackIDs: [Int] = []
    /// 원본 목록 ID → 기존 USB 목록 또는 같은 묶음에서 만든 목록
    public var playlistRefs: [String: PlaylistRef] = [:]

    /// 원본별 전체 선택도 새 하위 목록을 따라가게 한다. 선택용 부모(`UsbSyncSourceNode`의 두 머리)는 실제 USB 폴더에 들어가지 않는다.
    public static func nodes(_ layout: PlaylistLayout) -> [ITunesSyncSelection.Node] {
        let rekordbox = UsbSyncSourceNode.rekordboxSelectionID, iTunes = UsbSyncSourceNode.iTunesSelectionID
        let groups: [ITunesSyncSelection.Node] = [
            .init(id: rekordbox, parentID: "0", isFolder: true),
            .init(id: iTunes, parentID: "0", isFolder: true),
        ]
        return groups + layout.outline.map { item in
            let root = item.id.hasPrefix("itunes:") ? iTunes : rekordbox
            return .init(id: item.id, parentID: item.parentID == PlaylistLayout.root ? root : item.parentID,
                         isFolder: item.isFolder)
        }
    }

    /// 미반영 목록과 인텔리전트 목록은 기존 USB 내보내기와 같은 범위로 뺀다.
    public static func source(_ layout: PlaylistLayout) -> PlaylistLayout {
        let items = layout.outline.filter { !$0.isNew && !$0.isSmart }
        let ids = Set(items.map(\.id))
        return PlaylistLayout(items.filter { $0.parentID == PlaylistLayout.root || ids.contains($0.parentID) }.map { item in
            (item: item, seq: layout.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0)
        })
    }

    public static func selectedLayout(_ source: PlaylistLayout, selection: ITunesSyncSelection) -> PlaylistLayout {
        let selected = selection.expandedIDs(in: nodes(source))
        var included = selected
        for id in selected { included.formUnion(source.ancestors(of: id).map(\.id)) }
        return PlaylistLayout(source.outline.filter { included.contains($0.id) }.map { item in
            (item: item, seq: source.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0)
        })
    }

    /// 목록 항목에서 그 곡들만 뺀다(목록·폴더와 남은 곡의 순서는 그대로)
    public static func removing(_ trackIDs: Set<String>, from layout: PlaylistLayout) -> PlaylistLayout {
        guard !trackIDs.isEmpty else { return layout }
        return PlaylistLayout(layout.outline.map { item in
            var item = item
            item.entries.removeAll { trackIDs.contains($0.contentID) }
            return (item: item, seq: layout.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0)
        })
    }

    /// 보일 항목: OneLibrary에 있으면 그 순서(합친 모델이 앞세우는 쪽), 없으면 Device Library
    public static func entries(of playlist: UsbPlaylist) -> [Int] {
        playlist.presentIn.contains(.oneLibrary) ? playlist.entries[.oneLibrary] ?? [] : playlist.entries[.deviceLibrary] ?? []
    }

    public static func usbLayout(_ library: UsbLibrary) -> PlaylistLayout {
        PlaylistLayout(library.playlists.map { playlist in
            let entries = entries(of: playlist).enumerated().map {
                PlaylistEntry(trackNo: $0.offset + 1, contentID: String($0.element))
            }
            let item = PlaylistLayout.Item(id: String(playlist.id), name: playlist.name,
                                           parentID: playlist.parentID == 0 ? PlaylistLayout.root : String(playlist.parentID),
                                           isFolder: playlist.attribute == 1, isSmart: playlist.attribute == 4, entries: entries)
            return (item: item, seq: playlist.sortOrder[.oneLibrary] ?? playlist.sortOrder[.deviceLibrary] ?? 0)
        })
    }

    /// 목록이 있는 형식마다의 항목. 두 형식의 항목이 다를 수 있어 `usbLayout`(보이는 형식 하나)만으로는 곡이 남는지 알 수 없다
    public static func entriesByFormat(_ playlist: UsbPlaylist) -> [[Int]] {
        let lists = UsbFormat.allCases.filter(playlist.presentIn.contains).map { playlist.entries[$0] ?? [] }
        return lists.isEmpty ? [entries(of: playlist)] : lists
    }

    public static func path(_ item: PlaylistLayout.Item, in layout: PlaylistLayout) -> [String] {
        (layout.ancestors(of: item.id).map(\.name) + [item.name]).map(UsbLayout.nfc)
    }

    public static func initialSelection(source: PlaylistLayout, library: UsbLibrary) -> ITunesSyncSelection {
        let usb = usbLayout(library)
        let paths = Set(usb.outline.filter { !$0.isFolder && !$0.isSmart }.map { path($0, in: usb) })
        return ITunesSyncSelection(selectedIDs: Set(source.outline.filter { !$0.isFolder && paths.contains(path($0, in: source)) }.map(\.id)))
    }

    /// 쓴 뒤 새 목록 ID도 경로로 찾는다. 같은 경로가 여럿이면 짝을 저장하지 않는다.
    public static func bindings(source: PlaylistLayout, target: PlaylistLayout, library: UsbLibrary) -> [String: UsbSyncPlaylistBinding] {
        let usb = usbLayout(library)
        let byPath = Dictionary(grouping: usb.outline, by: { path($0, in: usb) })
        var result: [String: UsbSyncPlaylistBinding] = [:]
        for item in target.outline {
            let components = path(item, in: source)
            guard let candidates = byPath[components], candidates.count == 1,
                  let match = candidates.first, match.isFolder == item.isFolder, !match.isSmart, let id = Int(match.id) else { continue }
            result[item.id] = UsbSyncPlaylistBinding(usbID: id, path: components, isFolder: item.isFolder)
        }
        return result
    }

    /// - linkedPlaylistIDs: 지난 선택 파일 행이 이은 원본 ID → USB 목록 번호(두 형식이 같은 번호인 것만)
    /// - removedPlaylistIDs: 로컬에서 지운 원본의 행이 가리키던 USB 목록 번호
    /// - excluding: USB에 넣을 수 없어 목록에서 빼는 로컬 곡(`UsbSyncSource.skippedLocalTracks`). 남은 곡의 순서·반복은 그대로다
    public static func build(source: PlaylistLayout, selection: ITunesSyncSelection, library: UsbLibrary,
                      matches: [Int: String], badges: [Int: UsbSyncStatus], bindings: [String: UsbSyncPlaylistBinding],
                      linkedPlaylistIDs: [String: Int] = [:], removedPlaylistIDs: Set<Int> = [], excluding: Set<String> = [],
                      newKey: () -> String) throws -> UsbSyncPlan {
        let desired = removing(excluding, from: selectedLayout(source, selection: selection))
        let playlists = try playlistPlan(desired: desired, library: library, bindings: bindings, linkedPlaylistIDs: linkedPlaylistIDs,
                                         removedPlaylistIDs: removedPlaylistIDs, newKey: newKey)
        let refs = playlists.refs, working = playlists.result
        let edits: [UsbLibraryEdit] = playlists.edits.map { .playlist(edit: $0) }
        let keep = Set(refs.values.map(\.description))
        let unlinked = working.outline.filter { !keep.contains($0.id) }
        return try tracks(desired: desired, library: library, matches: matches, badges: badges, refs: refs, working: working,
                          unlinked: unlinked, edits: edits, deleted: playlists.deleted)
    }

    /// 재생 목록 편집만 계획한다. 미리 보기와 쓰기가 같은 규칙을 쓴다.
    public static func playlistPlan(desired: PlaylistLayout, library: UsbLibrary, bindings: [String: UsbSyncPlaylistBinding],
                             linkedPlaylistIDs: [String: Int] = [:], removedPlaylistIDs: Set<Int> = [],
                             newKey: () -> String) throws -> UsbSyncPlaylistPlan {
        let desiredPaths = Dictionary(grouping: desired.outline, by: { path($0, in: desired) })
        guard !desiredPaths.values.contains(where: { $0.count > 1 }) else {
            throw PlaylistLayout.Blocked(String(ui: "같은 폴더에 이름이 같은 재생 목록이 있습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
        }
        var working = usbLayout(library)
        // USB 목록 번호 → 그 목록이 있는 형식(이름 철자 비교용)
        let playlistFormats = Dictionary(library.playlists.map { (String($0.id), $0.presentIn) }) { first, _ in first }
        guard working.outline.count == working.items.count else {
            throw PlaylistLayout.Blocked(String(ui: "USB 재생 목록의 부모 관계가 맞지 않습니다. rekordbox에서 USB를 확인한 뒤 다시 동기화하세요"))
        }
        let before = working
        // 이름을 바꾼 원본의 옛 목록처럼 연결 없이 남은 목록이 있어 USB에는 이름이 같은 목록이 있을 수 있다.
        // 이름으로 이어야 할 때만 모호함을 막는다.
        let byPath = Dictionary(grouping: working.outline, by: { path($0, in: working) })
        var refs: [String: PlaylistRef] = [:], retained = Set<String>()
        // 다른 원본에 이어진(지운 원본 포함) USB 목록은 이름이 같아도 이 원본에 잇지 않는다.
        let linked = Set(bindings.map { String($0.value.usbID) } + linkedPlaylistIDs.values.map(String.init)
            + removedPlaylistIDs.map(String.init))
        /// 이름을 바꿔 새로 만드는 폴더 안의 원본이 옛 폴더 안의 이은 목록을 가리키는지. rekordbox는 이름을 바꾼 폴더 아래
        /// 하위 목록도 새로 만들고(새 Dev_ID) 옛 폴더와 그 안의 목록을 연결 없이 남겼다(2026-10-08 실험 G3, 두 형식 모두).
        func leavesRenamedFolder(_ item: PlaylistLayout.Item, old: PlaylistLayout.Item) -> Bool {
            guard item.parentID != PlaylistLayout.root, case .new? = refs[item.parentID],
                  let oldParent = linkedPlaylistIDs[item.parentID] ?? bindings[item.parentID]?.usbID else { return false }
            return old.parentID == String(oldParent)
        }
        for item in desired.outline {
            var match: PlaylistLayout.Item?
            let wanted = path(item, in: desired)
            if let bound = bindings[item.id], let old = working.item(String(bound.usbID)),
               old.isFolder == bound.isFolder, !old.isSmart, UsbLayout.nfc(old.name) == UsbLayout.nfc(item.name),
               !leavesRenamedFolder(item, old: old) {
                // 이름이 같으면 위치가 바뀌어도 이은 목록을 새 자리로 옮긴다(항목 유지). rekordbox도 옮긴 원본은
                // 새 자리에만 보이고 옛 자리에 남기지 않았다(2026-10-08 정상 USB 실험).
                match = old
            } else if let candidates = byPath[wanted]?.filter({
                bindings[item.id]?.usbID == Int($0.id) || linkedPlaylistIDs[item.id] == Int($0.id) || !linked.contains($0.id)
            }),
                      !candidates.isEmpty {
                // 이름이 바뀐 원본은 rekordbox처럼 새 USB 목록으로 만든다(옛 목록은 연결 없이 남는다, 2026-10-08 실험).
                // 바뀐 자리에 잇지 않은 USB 목록이 이미 있을 때만 그 목록에 잇는다(rekordbox 동작은 확인하지 않음).
                guard candidates.count == 1 else {
                    throw PlaylistLayout.Blocked(String(ui: "USB의 같은 폴더에 이름이 같은 재생 목록이 있습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
                }
                match = candidates.first
            }
            if let match {
                guard match.isFolder == item.isFolder, !match.isSmart, retained.insert(match.id).inserted else {
                    throw PlaylistLayout.Blocked(String(ui: "USB에서 같은 이름의 폴더와 재생 목록을 구분할 수 없습니다. 이름을 다르게 바꾼 뒤 동기화하세요"))
                }
                refs[item.id] = .id(match.id)
            } else {
                refs[item.id] = .new(newKey())
            }
        }
        var edits: [PlaylistEdit] = []
        func append(_ edit: PlaylistEdit) throws {
            let previousCount = edit.destination.map { working.childIDs(of: $0 == .root ? PlaylistLayout.root : $0.description).count }
            try working.apply(edit)
            // USB는 새 목록을 부모의 맨 끝에 만든다. 로컬 초안 트리의 맨 위 규칙과 다르다.
            if case let .create(key, _, _, _) = edit, let previousCount {
                try working.apply(.reorder(playlist: .new(key), index: previousCount))
            }
            edits.append(edit)
        }
        // 옮길 항목을 먼저 맨 위로 꺼내 두면 폴더의 부모·자식을 바꾸어도 순환하지 않는다.
        for item in desired.outline {
            guard let ref = refs[item.id], case .id = ref, let old = working.item(ref.description) else { continue }
            let parent = item.parentID == PlaylistLayout.root ? PlaylistRef.root : refs[item.parentID] ?? .root
            let parentID = parent == .root ? PlaylistLayout.root : parent.description
            if old.parentID != parentID, old.parentID != PlaylistLayout.root { try append(.move(playlist: ref, into: .root)) }
        }
        for item in desired.outline {
            guard let ref = refs[item.id] else { continue }
            let parent = item.parentID == PlaylistLayout.root ? PlaylistRef.root : refs[item.parentID] ?? .root
            switch ref {
            case let .new(key): try append(.create(key: key, name: item.name, isFolder: item.isFolder, parent: parent))
            case .id:
                // 철자(NFC·NFD)만 다른 이름도 OneLibrary에 있는 목록이면 바꾼다(#233, `UsbNameSpelling.playlistNeedsRename`)
                if let current = working.item(ref.description)?.name,
                   UsbNameSpelling.playlistNeedsRename(from: current, to: item.name, formats: playlistFormats[ref.description] ?? library.formats) {
                    try append(.rename(playlist: ref, name: item.name))
                }
                let parentID = parent == .root ? PlaylistLayout.root : parent.description
                if working.item(ref.description)?.parentID != parentID { try append(.move(playlist: ref, into: parent)) }
            case .root: break
            }
        }
        // 지난 선택 파일 행으로 이었던 USB 목록 중 원본을 선택에서 빼거나 로컬에서 지운 것은 지운다(rekordbox와 같다,
        // 2026-10-08 정상 USB 실험). 행으로 이은 적 없는 USB 목록과 이름을 바꾼 원본의 옛 목록은 지우지 않는다.
        // 폴더는 남는 목록이 안에 없을 때만 지운다(연결 없는 목록이 든 폴더는 rekordbox도 남겼다).
        let keep = Set(refs.values.map(\.description))
        let desiredIDs = Set(desired.outline.map(\.id))
        let doomed = Set((linkedPlaylistIDs.filter { !desiredIDs.contains($0.key) }.map(\.value) + removedPlaylistIDs).map(String.init))
            .filter { working.item($0) != nil }.subtracting(keep)
        var removable: [String: Bool] = [:]
        func isRemovable(_ id: String) -> Bool {
            if let known = removable[id] { return known }
            let children = working.childIDs(of: id)
            let value = doomed.contains(id) && children.allSatisfy(isRemovable)
            removable[id] = value
            return value
        }
        var deleted: [PlaylistLayout.Item] = []
        for item in working.outline where isRemovable(item.id) && !working.ancestors(of: item.id).contains(where: { isRemovable($0.id) }) {
            deleted.append(item)
        }
        for item in deleted { try append(.delete(playlist: .id(item.id))) }
        // 이은 목록끼리만 원본 순서로 맞추고, 남은 목록은 그 자리에 둔다.
        let parents = [PlaylistLayout.root] + desired.outline.filter(\.isFolder).map(\.id)
        for parent in parents {
            let usbParent = parent == PlaylistLayout.root ? PlaylistLayout.root : refs[parent]?.description ?? PlaylistLayout.root
            let ordered = desired.childIDs(of: parent).compactMap { refs[$0]?.description }
            let current = working.childIDs(of: usbParent)
            let slots = current.indices.filter { ordered.contains(current[$0]) }
            guard slots.count == ordered.count else { continue }
            var target = current
            for (slot, id) in zip(slots, ordered) { target[slot] = id }
            for (index, id) in target.enumerated() where working.childIDs(of: usbParent).firstIndex(of: id) != index {
                let ref: PlaylistRef = refs.values.first { $0.description == id } ?? .id(id)
                try append(.reorder(playlist: ref, index: index))
            }
        }
        var marks: [String: UsbSyncPreviewMark] = [:]
        for item in working.outline {
            if !keep.contains(item.id) { marks[item.id] = .unlinked }
            else if item.id.hasPrefix(PlaylistRef.new("").description) { marks[item.id] = .created }
            else if let old = before.item(item.id), old.parentID != item.parentID { marks[item.id] = .moved }
        }
        return UsbSyncPlaylistPlan(edits: edits, refs: refs, result: working, deleted: deleted, marks: marks)
    }

    public static func tracks(desired: PlaylistLayout, library: UsbLibrary, matches: [Int: String], badges: [Int: UsbSyncStatus],
                       refs: [String: PlaylistRef], working: PlaylistLayout, unlinked: [PlaylistLayout.Item],
                       edits playlistEdits: [UsbLibraryEdit], deleted: [PlaylistLayout.Item]) throws -> UsbSyncPlan {
        var edits = playlistEdits
        var seen = Set<String>()
        let trackIDs = desired.outline.filter(\.holdsTracks).flatMap(\.trackIDs).filter { seen.insert($0).inserted }
        let usbByLocal = Dictionary(grouping: matches.keys, by: { matches[$0]! })
        guard !trackIDs.contains(where: { (usbByLocal[$0]?.count ?? 0) > 1 }) else {
            throw PlaylistLayout.Blocked(String(ui: "같은 로컬 곡의 USB 사본이 여러 개라 동기화할 수 없습니다. USB의 중복 곡을 정리한 뒤 다시 시도하세요"))
        }
        let missing = trackIDs.filter { usbByLocal[$0] == nil }
        if !missing.isEmpty { edits.append(.addTracks(localContentIDs: missing, playlist: nil)) }
        var refresh: [(parts: Set<UsbRefreshPart>, ids: [Int])] = []
        for id in trackIDs {
            guard let usbID = usbByLocal[id]?.first, case let .localNewer(fields)? = badges[usbID] else { continue }
            var parts = Set<UsbRefreshPart>()
            if fields.contains(.information) { parts.formUnion([.info, .artwork]) }
            if fields.contains(.analysis) { parts.insert(.grid) }
            if fields.contains(.cue) { parts.insert(.cues) }
            guard !parts.isEmpty else { continue }
            if let index = refresh.firstIndex(where: { $0.parts == parts }) { refresh[index].ids.append(usbID) }
            else { refresh.append((parts: parts, ids: [usbID])) }
        }
        edits += refresh.map { .refreshTracks(usbContentIDs: $0.ids, parts: $0.parts) }
        // 동기화 뒤에도 곡을 가리키는 USB 목록: 이은 목록은 원본 곡, 남은 목록은 지금 곡. 곡 빼기는 모든 형식에서 빼므로
        // 지금 곡은 목록이 있는 모든 형식의 항목을 합친다(한 형식의 항목에만 든 곡도 남는다).
        let usbEntries = Dictionary(library.playlists.map { (String($0.id), entriesByFormat($0)) }, uniquingKeysWith: { first, _ in first })
        var referenced = Set<String>()
        for item in desired.outline where item.holdsTracks {
            guard let ref = refs[item.id] else { continue }
            let expected = item.trackIDs.compactMap { usbByLocal[$0]?.first }.map(String.init)
            referenced.formUnion(expected)
            let current: [[String]]
            if case .id = ref, let lists = usbEntries[ref.description] { current = lists.map { $0.map(String.init) } }
            else { current = [working.item(ref.description)?.trackIDs ?? []] }
            // 형식마다 항목이 다른 목록은 곡 맞추기가 막힐 수 있다(`playlistEntriesDiffer`). 그때 남을 곡을 빼지 않게 지금 곡도 남긴다.
            if current.contains(where: { $0 != current.first }) { referenced.formUnion(current.joined()) }
            if expected.count != item.trackIDs.count || current.contains(where: { $0 != expected }) {
                edits.append(.syncPlaylist(playlist: ref, localContentIDs: item.trackIDs))
            }
        }
        for item in unlinked {
            referenced.formUnion(usbEntries[item.id].map { $0.joined().map(String.init) } ?? item.trackIDs)
        }
        // 재생 기록에 남은 곡은 곡 빼기가 막으므로 지울 곡에 넣지 않는다.
        let history = Set(library.histories.flatMap(\.entries))
        var orphans = library.tracks.map(\.id).filter { !referenced.contains(String($0)) && !history.contains($0) }.sorted()
        var kept: [Int] = []
        // 빼면 곡이 하나도 남지 않는 형식이 있으면 곡 빼기만 하지 않는다. 목록 지우기·선택 파일은 쓴다.
        let removing = Set(orphans)
        let empties = library.formats.contains { format in
            let present = library.tracks.filter { $0.presentIn.contains(format) }
            return !present.isEmpty && present.allSatisfy { removing.contains($0.id) }
        }
        if !orphans.isEmpty, empties { swap(&orphans, &kept) }
        return UsbSyncPlan(edits: edits, layout: desired, trackIDs: trackIDs, unlinkedPlaylistCount: unlinked.count,
                           deletedPlaylists: deleted, orphanTrackIDs: orphans, keptOrphanTrackIDs: kept, playlistRefs: refs)
    }
}
