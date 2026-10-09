import DJCDomain
import Foundation

/// 편집 한 건의 짧은 설명(대기 목록·알림). 목록 이름은 USB 라이브러리와 같은 초안에서 만든 목록에서 찾는다
public enum UsbEditText {
    public static func describe(_ edit: UsbLibraryEdit, library: UsbLibrary?, created: [String: String] = [:]) -> String {
        func name(_ ref: PlaylistRef) -> String {
            switch ref {
            case .root: String(ui: "맨 위")
            case let .id(text): library?.playlists.first { String($0.id) == text }?.name ?? String(ui: "재생 목록 \(text)")
            case let .new(key): created[key] ?? String(ui: "새 재생 목록")
            }
        }
        switch edit {
        case let .addTracks(ids, .none): return String(ui: "곡 \(ids.count)개 더하기")
        case let .addTracks(ids, .some(playlist)): return String(ui: "곡 \(ids.count)개 더하기 · ‘\(name(playlist))’에 넣기")
        case let .removeTracks(ids): return String(ui: "곡 \(ids.count)개 USB에서 빼기")
        case let .refreshTracks(ids, _): return String(ui: "곡 \(ids.count)개 로컬 변경 반영")
        case let .syncPlaylist(playlist, ids): return String(ui: "‘\(name(playlist))’ 동기화 · 곡 \(ids.count)개")
        case let .syncSelection(draft):
            return draft.enabledOnly ? String(ui: "USB 동기화 켜짐 저장") : String(ui: "USB 동기화 선택 저장")
        case let .playlist(edit):
            switch edit {
            case let .create(_, newName, isFolder, parent):
                let head = isFolder ? String(ui: "새 폴더 ‘\(newName)’") : String(ui: "새 재생 목록 ‘\(newName)’")
                return parent == .root ? head : String(ui: "\(head) · ‘\(name(parent))’ 안")
            case let .rename(ref, newName): return String(ui: "이름 바꾸기: ‘\(name(ref))’ → ‘\(newName)’")
            case let .move(ref, into): return String(ui: "옮기기: ‘\(name(ref))’ → ‘\(name(into))’")
            case let .reorder(ref, index): return String(ui: "순서 바꾸기: ‘\(name(ref))’ → \(index + 1)번째")
            case let .delete(ref): return String(ui: "지우기: ‘\(name(ref))’")
            case let .addTracks(ref, ids): return String(ui: "‘\(name(ref))’에 곡 \(ids.count)개 넣기")
            case let .removeTracks(ref, entries): return String(ui: "‘\(name(ref))’에서 곡 \(entries.count)개 빼기")
            case let .moveTracks(ref, _, _): return String(ui: "‘\(name(ref))’ 곡 순서 바꾸기")
            }
        }
    }

    /// 초안에서 만든 목록(key → 이름)
    public static func createdNames(_ edits: [UsbLibraryEdit]) -> [String: String] {
        var names: [String: String] = [:]
        for case let .playlist(edit: .create(key, name, _, _)) in edits where names[key] == nil { names[key] = name }
        return names
    }
}

/// USB 초안 편집의 순수 규칙: 초안에 더하기 전 막힘 판정, 목록 형제 순서, 한 칸 옮기기(앱 메뉴·쓰기 대기 목록이 부른다)
public enum UsbEditRules {
    /// 막힘 이유(화면 문구). 쓰기 때의 계획(`UsbEditSession`)과 같은 문구이고, 시험은 문장 대신 이 이름으로 비교한다
    public enum Reason {
        public static var missingTarget: String { String(ui: "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요") }
        public static var intoItself: String { String(ui: "재생 목록 폴더를 자기 안으로 옮길 수 없습니다. 다른 폴더를 고르세요") }
        public static var trackIDsDiffer: String { String(ui: "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요") }
        public static var parentMissing: String { String(ui: "부모 폴더를 찾을 수 없는 재생 목록이 있어 고칠 수 없습니다. rekordbox에서 USB를 다시 내보내세요") }
        public static var notFolder: String { String(ui: "재생 목록 안에는 넣을 수 없습니다. 폴더를 고르세요") }
        public static var notEntryList: String { String(ui: "폴더·인텔리전트 재생 목록에는 곡을 넣거나 뺄 수 없습니다. 일반 재생 목록을 고르세요") }
        public static var entriesDiffer: String { String(ui: "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다") }
        public static var historyTrack: String { String(ui: "재생 기록에 있는 곡이라 빼지 않았습니다. 먼저 기록을 가져오세요") }
        public static var noTracksLeft: String { String(ui: "USB에 곡이 하나도 남지 않습니다. 곡을 남기거나 USB를 새로 내보내세요") }
        public static func entryChanged(_ trackNo: Int) -> String {
            String(ui: "\(trackNo)번째 곡이 편집을 만들 때와 다릅니다. USB를 다시 읽은 뒤 고치세요")
        }
    }

    public static func blockReason(_ edits: [UsbLibraryEdit], volume: UsbVolumeInfo?, library: UsbLibrary?, info: UsbInfo?,
                                   isScratchMount: (String) -> Bool, physicalGate: UsbPhysicalWriteGate = .init(),
                                   syncGate: UsbSyncSelectionGate) -> String? {
        var projected = library
        var tree = library.map(UsbSyncPlan.usbLayout)
        for edit in edits {
            if let reason = blockReason(edit, volume: volume, library: projected, info: info,
                                        isScratchMount: isScratchMount, physicalGate: physicalGate, syncGate: syncGate) { return reason }
            guard case let .playlist(playlistEdit) = edit, var working = tree else { continue }
            switch playlistEdit {
            case .addTracks, .removeTracks, .moveTracks:
                // 새 곡의 USB 번호와 형식별 항목 변경은 최종 엔진이 확인한다.
                continue
            case .create, .rename, .move, .reorder, .delete:
                break
            }
            // 새 참조를 앞에서 만들지 못했는지는 최종 엔진이 확인한다.
            if case .create = playlistEdit {} else if working.item(playlistEdit.playlist.description) == nil { continue }
            if let destination = playlistEdit.destination, destination != .root,
               working.item(destination.description) == nil { continue }
            if case let .move(ref, into) = playlistEdit,
               working.subtree(of: ref.description).contains(into.description) {
                return Reason.intoItself
            }
            do { try working.apply(playlistEdit) }
            catch let failure as PlaylistLayout.Blocked { return failure.reason }
            catch { return Reason.missingTarget }
            tree = working
            // .new 부모의 실제 USB 번호는 아직 없다. 트리에는 기호 참조로 남기고 DB 모델은 기존 ID만 갱신한다.
            if var model = projected {
                model.playlists = model.playlists.compactMap { old in
                    guard let item = working.item(String(old.id)) else { return nil }
                    var playlist = old
                    playlist.name = item.name
                    playlist.parentID = Int(item.parentID) ?? 0
                    return playlist
                }
                projected = model
            }
        }
        return nil
    }

    /// 편집을 초안에 더하기 전의 가벼운 막힘 판정: 사본으로 읽은 라이브러리와 볼륨만 본다(USB·로컬 사본을 열지 않는다).
    /// 쓰기 때의 계획(`UsbEditSession`)과 같은 문구를 쓴다. 볼륨이 빠져 있으면 볼륨 판정은 쓸 때 한다.
    /// 메뉴가 목록마다 부르므로 곡 번호 집합은 곡을 가리키는 편집에서만 만든다
    /// - isScratchMount: 마운트 지점(realpath)이 임시 폴더 뿌리 아래인지(쓰기 세션의 실물 관문과 같은 판정, `UsbDevice.isScratchMount`)
    /// - physicalGate: 실물 쓰기 관문. 기본은 동의 없는 관문(실물은 막힘). 확인 안 된 규칙은 막지 않는다(확인 창이 알린다)
    /// - syncGate: 동기화 선택 파일의 쓰기 관문 규칙(엔진이 준다)
    public static func blockReason(_ edit: UsbLibraryEdit, volume: UsbVolumeInfo?, library: UsbLibrary?, info: UsbInfo?,
                                   isScratchMount: (String) -> Bool, physicalGate: UsbPhysicalWriteGate = .init(),
                                   syncGate: UsbSyncSelectionGate) -> String? {
        if case let .syncSelection(draft) = edit,
           let block = (library.map({ syncGate.gateBlock(draft.baseFiles, $0.formats) }) ?? syncGate.productionBlock())
               ?? syncGate.draftBlock(draft) {
            return block.message
        }
        if let volume {
            if let problem = UsbVolumePolicy.problems(volume, purpose: .edit).first { return problem.message }
            // 임시 폴더 뿌리 밖에 붙인 디스크 이미지도 실물로 판정한다(세션의 실물 관문과 같다)
            let judged = volume.judgedForWrite(underScratch: isScratchMount(volume.mountPoint))
            // 앱은 쓰기 확인 창이 볼륨 이름 확인을 대신한다
            if let block = physicalGate.blocks(judged, confirmName: volume.name).first { return block.message }
        }
        if let consistency = info?.consistency, consistency.editBlocked {
            return !consistency.trackIDsMatch || !consistency.pathsMatch
                ? Reason.trackIDsDiffer
                : Reason.parentMissing
        }
        guard let library else { return nil }
        let missing = Reason.missingTarget
        func trackIDs() -> Set<Int> { Set(library.tracks.map(\.id)) }
        /// 가리킨 목록. 맨 위·같은 초안에서 만든 목록은 쓸 때 계획이 본다
        enum Found { case unchecked, missing, found(UsbPlaylist) }
        func lookup(_ ref: PlaylistRef) -> Found {
            guard case let .id(text) = ref else { return .unchecked }
            guard let id = Int(text), let found = library.playlists.first(where: { $0.id == id }) else { return .missing }
            return .found(found)
        }
        /// 맨 위나 폴더여야 하는 자리
        func folderReason(_ ref: PlaylistRef) -> String? {
            switch lookup(ref) {
            case .unchecked: return nil
            case .missing: return missing
            case let .found(found):
                return found.attribute == 1 ? nil : Reason.notFolder
            }
        }
        /// 곡 항목을 고치는 목록: 일반 목록이고, 목록이 있는 형식의 항목이 모두 같고, 고를 때의 자리에 그 곡이 있어야 한다
        func entryReason(_ ref: PlaylistRef, entries picked: [PlaylistEntry] = []) -> String? {
            switch lookup(ref) {
            case .unchecked: return nil
            case .missing: return missing
            case let .found(found):
                guard found.attribute == 0 else {
                    return Reason.notEntryList
                }
                let lists = UsbFormat.allCases.filter(found.presentIn.contains).map { found.entries[$0] ?? [] }
                guard lists.allSatisfy({ $0 == lists.first }) else {
                    return Reason.entriesDiffer
                }
                let entries = lists.first ?? []
                for entry in picked where !(entries.indices.contains(entry.trackNo - 1) && String(entries[entry.trackNo - 1]) == entry.contentID) {
                    return Reason.entryChanged(entry.trackNo)
                }
                return nil
            }
        }
        func target(_ ref: PlaylistRef) -> String? {
            if case .missing = lookup(ref) { return missing }
            return nil
        }
        switch edit {
        case let .addTracks(_, playlist):
            return playlist.flatMap { entryReason($0) }
        case let .syncPlaylist(playlist, _):
            return entryReason(playlist)
        case .syncSelection:
            return nil
        case let .removeTracks(ids):
            let removing = Set(ids), all = trackIDs()
            if !removing.isSubset(of: all) { return missing }
            if library.histories.contains(where: { !removing.isDisjoint(with: $0.entries) }) {
                return Reason.historyTrack
            }
            if all.isSubset(of: removing) { return Reason.noTracksLeft }
            return nil
        case let .refreshTracks(ids, _):
            return Set(ids).isSubset(of: trackIDs()) ? nil : missing
        case let .playlist(edit):
            switch edit {
            case let .create(_, _, _, parent): return folderReason(parent)
            case let .rename(ref, _), let .reorder(ref, _), let .delete(ref): return target(ref)
            case let .move(ref, into):
                if let reason = target(ref) ?? folderReason(into) { return reason }
                if case let .id(text) = ref, ref == into || Self.descendants(of: Int(text) ?? -1, in: library).contains(where: { PlaylistRef.id(String($0)) == into }) {
                    return Reason.intoItself
                }
                return nil
            case let .addTracks(ref, ids):
                if let reason = entryReason(ref) { return reason }
                let all = trackIDs()
                return ids.allSatisfy { Int($0).map(all.contains) ?? false } ? nil : missing
            case let .removeTracks(ref, entries), let .moveTracks(ref, entries, _):
                return entryReason(ref, entries: entries)
            }
        }
    }

    public static func descendants(of id: Int, in library: UsbLibrary) -> [Int] {
        var result: [Int] = [], queue = [id]
        while let parent = queue.popLast() {
            let children = library.playlists.filter { $0.parentID == parent && $0.id != parent }.map(\.id).filter { !result.contains($0) }
            result += children
            queue += children
        }
        return result
    }

    /// 끈 USB 곡(content_id, 끈 차례) → 목록에 넣을 곡(같은 곡은 한 번)과 이미 든 곡 수(#240).
    /// 로컬 재생 목록에 넣기처럼 이미 든 곡은 넣지 않는다
    public static func tracksToAdd(_ dragged: [Int], current: [Int]) -> (ids: [Int], duplicates: Int) {
        let present = Set(current)
        var seen: Set<Int> = [], duplicates: Set<Int> = []
        var ids: [Int] = []
        for id in dragged where seen.insert(id).inserted {
            if present.contains(id) { duplicates.insert(id) } else { ids.append(id) }
        }
        return (ids, duplicates.count)
    }

    /// 옮길 항목(자리·곡)과 놓은 자리 아래에서 옮기지 않는 첫 항목의 자리(없으면 맨 끝) → 순서 바꾸기 편집. 그대로면 nil(#240).
    /// `to`는 로컬 재생 목록과 같게 옮기는 곡을 뺀 목록 기준의 자리다
    public static func moveEntriesEdit(_ moving: [PlaylistEntry], before: Int?, entries: [Int], playlist: Int) -> UsbLibraryEdit? {
        let positions = Set(moving.map(\.trackNo))
        guard !moving.isEmpty, moving.allSatisfy({ entries.indices.contains($0.trackNo - 1) && String(entries[$0.trackNo - 1]) == $0.contentID })
        else { return nil }
        let remaining = Array(1...entries.count).filter { !positions.contains($0) }
        let to = before.flatMap { remaining.firstIndex(of: $0) }.map { $0 + 1 } ?? remaining.count + 1
        var order = remaining
        order.insert(contentsOf: moving.map(\.trackNo).sorted(), at: to - 1)
        guard order != Array(1...entries.count) else { return nil }
        return .playlist(edit: .moveTracks(playlist: .id(String(playlist)), entries: moving.sorted { $0.trackNo < $1.trackNo }, to: to))
    }

    /// 초안의 목록 편집(만들기·옮기기·순서 바꾸기·지우기)을 읽은 라이브러리에 차례로 대 본 그 목록의 형제 순서(없거나 지웠으면 nil).
    /// 계획(`UsbEditPlanner`)과 같은 규칙: 순서 바꾸기는 나머지 사이 그 자리에 끼우고, 만들기·옮기기는 새 부모 끝에 붙인다.
    /// 읽은 순서는 사이드바와 같다(OneLibrary 순번 → Device Library 순번 → 번호)
    public static func siblingOrder(of target: PlaylistRef, library: UsbLibrary, edits: [UsbLibraryEdit]) -> [PlaylistRef]? {
        func order(_ item: UsbPlaylist) -> Int { item.sortOrder[.oneLibrary] ?? item.sortOrder[.deviceLibrary] ?? .max }
        var parents: [PlaylistRef: PlaylistRef] = [:], children: [PlaylistRef: [PlaylistRef]] = [:]
        for item in library.playlists.sorted(by: { (order($0), $0.id) < (order($1), $1.id) }) {
            let ref = PlaylistRef.id(String(item.id)), parent = item.parentID == 0 ? PlaylistRef.root : .id(String(item.parentID))
            parents[ref] = parent
            children[parent, default: []].append(ref)
        }
        /// 부모 목록에서 떼고 그 부모(없으면 nil)
        func detach(_ ref: PlaylistRef) -> PlaylistRef? {
            guard let parent = parents[ref] else { return nil }
            children[parent]?.removeAll { $0 == ref }
            return parent
        }
        func isInside(_ ref: PlaylistRef, _ folder: PlaylistRef) -> Bool {
            var cursor: PlaylistRef? = ref
            while let current = cursor {
                if current == folder { return true }
                cursor = parents[current]
            }
            return false
        }
        for case let .playlist(edit) in edits {
            switch edit {
            case let .create(key, _, _, parent):
                let ref = PlaylistRef.new(key)
                guard parents[ref] == nil else { continue }
                parents[ref] = parent
                children[parent, default: []].append(ref)
            case let .move(ref, into):
                // 자기 안으로 옮기기는 계획이 막는다
                guard parents[ref] != nil, !isInside(into, ref) else { continue }
                _ = detach(ref)
                parents[ref] = into
                children[into, default: []].append(ref)
            case let .reorder(ref, index):
                guard let parent = detach(ref) else { continue }
                var siblings = children[parent] ?? []
                siblings.insert(ref, at: min(max(index, 0), siblings.count))
                children[parent] = siblings
            case let .delete(ref):
                // 폴더를 지우면 그 아래도 없어진다
                var queue = [ref]
                while let next = queue.popLast() {
                    _ = detach(next)
                    parents[next] = nil
                    queue += children.removeValue(forKey: next) ?? []
                }
            case .rename, .addTracks, .removeTracks, .moveTracks:
                continue
            }
        }
        return parents[target].flatMap { children[$0] }
    }

    /// 초안에 한 칸 옮기기를 더한 편집(옮길 자리가 없으면 nil). 바로 앞 편집이 같은 목록의 순서 바꾸기면 새로 쌓지 않고 그것을 고치고,
    /// 그 편집 전 자리로 돌아오면 뺀다. 자리는 초안의 목록 편집을 적용한 순서에서 센다(계획이 편집을 차례로 적용하는 것과 같다)
    public static func movedDraft(_ edits: [UsbLibraryEdit], playlist id: Int, by step: Int, library: UsbLibrary) -> [UsbLibraryEdit]? {
        let ref = PlaylistRef.id(String(id))
        guard let siblings = siblingOrder(of: ref, library: library, edits: edits), let index = siblings.firstIndex(of: ref),
              siblings.indices.contains(index + step) else { return nil }
        let target = index + step, move = UsbLibraryEdit.playlist(edit: .reorder(playlist: ref, index: target))
        guard case let .playlist(.reorder(last, _))? = edits.last, last == ref else { return edits + [move] }
        let earlier = Array(edits.dropLast())
        let start = siblingOrder(of: ref, library: library, edits: earlier)?.firstIndex(of: ref)
        return start == target ? earlier : earlier + [move]
    }
}
