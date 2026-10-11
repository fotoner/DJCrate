import DJCDomain
import Foundation

/// 편집 하나의 계획(모델 적용 방법·준비한 파일·규칙·알림)
struct UsbPlannedEdit {
    var index: Int
    var outcome: UsbOutcome = .unchanged
    var op: UsbResolvedEdit?
    var rules: Set<UsbProvisionalRule> = []
    var files: UsbExportAssembly.Context
    var notes: [String] = []
    var warnings: [UsbBlock] = []
    var trackBlocks: [UsbBlock] = []
    var isRemoval = false
    /// 적용이 성공한 뒤 다음 목록 동기화가 참조할 로컬 ID → 새 USB ID
    var addedLocalTracks: [String: Int] = [:]
    /// 더한 곡 중 파일 크기 칸(로컬 FileSize)이 복사한 음원과 다른 곡(USB content id, `audioChangedSinceAnalysis`)
    var audioSizeFromDatabase: Set<Int> = []
}

/// 편집 하나를 막는 이유(그 편집만 빼고 나머지를 쓴다)
struct UsbEditBlocked: Error {
    let block: UsbBlock
}

/// 편집을 차례로 계획한다. 앞 편집을 적용한 모델(`working`) 위에서 다음 편집을 본다
struct UsbEditPlanner {
    let source: UsbEditSource
    let writable: Set<UsbFormat>
    let root: UsbRoot
    let fileSystem: any UsbFileSystem
    let staging: URL
    let localDatabase: CipherDatabase?
    let share: URL?
    let snapshotTakenAt: Date?
    let localAppVersion: String?
    let clusterSize: Int
    var working: UsbLibrary
    var ids: UsbIDAllocator
    /// 이번 묶음에서 만든 목록(만들 때 준 key → id)
    var newPlaylists: [String: Int] = [:]
    /// 이번 묶음에서 이미 갱신한 곡
    var refreshed: Set<Int> = []
    /// 같은 묶음에서 더한 곡은 내보내며 바뀐 파일 이름과 무관하게 정확한 번호로 연결한다
    var addedLocalTracks: [String: Int] = [:]
    /// 짝짓기는 삭제되지 않은 로컬 곡 전체를 보고, 같은 DB·곡 ID끼리 묶어 이름의 모호함도 확인한다
    struct LocalIdentity: Hashable {
        var database: Int64
        var song: Int64
    }
    var localTrackKeys: [LocalIdentity: [UsbLocalTrackKey]]?
    /// 곡 더하기가 볼 USB 상태(처음 쓸 때 USB를 훑어 만든다)
    var existing: UsbExistingState?
    var artwork: UsbArtworkLayout?
    /// OneLibrary 사본의 기기 큐 행 수(곡 id → 수)
    var deviceCueRows: [Int: Int]?
    /// 동기화 묶음(선택 파일을 함께 쓴다)이면 더할 곡이 모두 막혀도 곡 더하기 편집을 막지 않고 건너뛴다.
    /// rekordbox처럼 넣지 못한 곡만 알리고 목록은 넣은 곡으로 맞춘다
    var skipsUnaddableTracks = false
    /// 앞 편집에서 이미 곡 단위 막힘으로 알린 로컬 곡(목록 동기화가 같은 곡을 다른 이유로 다시 세지 않게)
    var reportedLocalTracks: Set<String> = []

    init(source: UsbEditSource, root: UsbRoot, fileSystem: any UsbFileSystem, staging: URL, localDatabase: CipherDatabase?, share: URL?,
         snapshotTakenAt: Date?, localAppVersion: String?, clusterSize: Int, highWater: [String: Int]) {
        self.source = source
        writable = source.writable
        self.root = root
        self.fileSystem = fileSystem
        self.staging = staging
        self.localDatabase = localDatabase
        self.share = share
        self.snapshotTakenAt = snapshotTakenAt
        self.localAppVersion = localAppVersion
        self.clusterSize = clusterSize
        working = source.current
        ids = Self.allocator(source.current, highWater: highWater)
    }

    /// 산 행·지운 행·기기 기록이 가리키는 ID·지난 쓰기의 highWater를 모두 본 번호 배정기
    static func allocator(_ model: UsbLibrary, highWater: [String: Int]) -> UsbIDAllocator {
        var ids = UsbIDAllocator()
        observe(model, into: &ids)
        for (kind, set) in model.deadIDs { if let kind = UsbIDKind(rawValue: kind), let max = set.max() { ids.observe(kind, max) } }
        for history in model.histories { if let max = history.entries.max() { ids.observe(.content, max) } }
        for (kind, value) in highWater { if let kind = UsbIDKind(rawValue: kind) { ids.observe(kind, value) } }
        return ids
    }

    static func observe(_ model: UsbLibrary, into ids: inout UsbIDAllocator) {
        func each(_ kind: UsbIDKind, _ values: [Int]) { if let max = values.max() { ids.observe(kind, max) } }
        each(.content, model.tracks.map(\.id))
        each(.artist, model.artists.map(\.id))
        each(.album, model.albums.map(\.id))
        each(.genre, model.genres.map(\.id))
        each(.key, model.keys.map(\.id))
        each(.label, model.labels.map(\.id))
        each(.image, model.images.map(\.id))
        // 두 형식의 번호를 모두 본다(대표 번호만 보면 한 형식에서 쓰는 번호를 새 목록에 줄 수 있다, #233). 음수 대표 번호는 형식 번호가 아니다
        each(.playlist, model.playlists.flatMap { [$0.id] + $0.formatIDs.values }.filter { $0 > 0 })
    }

    // MARK: - 편집 하나

    mutating func plan(_ edit: UsbLibraryEdit, index: Int, progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> UsbPlannedEdit {
        var planned = UsbPlannedEdit(index: index, files: UsbExportAssembly.Context(staging: staging.appending(path: "edit-\(index)")))
        do {
            switch edit {
            case let .removeTracks(usbContentIDs): try planRemove(usbContentIDs, into: &planned)
            case let .playlist(edit): try planPlaylist(edit, into: &planned)
            case let .refreshTracks(usbContentIDs, parts): try planRefresh(usbContentIDs, parts: parts, into: &planned)
            case let .addTracks(localContentIDs, playlist):
                try planAdd(localContentIDs, playlist: playlist, into: &planned, progress: progress, isCancelled: isCancelled)
            case let .syncPlaylist(playlist, localContentIDs):
                try planSyncPlaylist(playlist, localIDs: localContentIDs, into: &planned)
            case .syncSelection:
                // ID는 모든 목록 편집을 실제 적용한 뒤 정한다(계획 중에 미리 성공으로 기록하지 않는다).
                break
            }
        } catch let blocked as UsbEditBlocked {
            planned.op = nil
            planned.outcome = .blocked(blocked.block)
            planned.files = UsbExportAssembly.Context(staging: planned.files.staging)
        } catch let UsbError.writeRefused(blocks) where !blocks.isEmpty {
            // 로컬 곡을 찾지 못함 등 곡·편집 하나의 막힘
            planned.op = nil
            planned.outcome = .blocked(blocks[0])
            planned.files = UsbExportAssembly.Context(staging: planned.files.staging)
        }
        for block in planned.trackBlocks { if case let .track(id) = block.scope { reportedLocalTracks.insert(id) } }
        if let op = planned.op {
            do {
                let next = try UsbEditModel.apply(op, to: working, writable: writable)
                working = OneLibraryWriter.normalized(next, from: working)
                Self.observe(working, into: &ids)
                addedLocalTracks.merge(planned.addedLocalTracks) { _, new in new }
                planned.outcome = .written
            } catch {
                planned.op = nil
                planned.outcome = .blocked(Self.applyFailed(String(describing: error)))
            }
        }
        return planned
    }

    static func applyFailed(_ reason: String) -> UsbBlock {
        UsbBlock(code: "applyFailed", scope: .volume, message: String(ui: "이 편집을 USB 라이브러리에 적용하지 못했습니다(\(reason))"))
    }

    // MARK: - 곡 빼기

    mutating func planRemove(_ ids: [Int], into planned: inout UsbPlannedEdit) throws {
        let ids = Self.unique(ids)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let track = working.tracks.first(where: { $0.id == id }), !track.presentIn.isDisjoint(with: writable) else {
                throw Self.vanished(.track("usb:\(id)"))
            }
            if working.histories.contains(where: { $0.entries.contains(id) }) {
                throw UsbEditBlocked(block: UsbBlock(code: "historyReferenced", scope: .track("usb:\(id)"),
                                                     message: String(ui: "재생 기록에 있는 곡이라 빼지 않았습니다. 먼저 기록을 가져오세요")))
            }
        }
        let removing = Set(ids)
        for format in writable where !working.tracks.contains(where: { $0.presentIn.contains(format) && !removing.contains($0.id) }) {
            throw UsbEditBlocked(block: UsbBlock(code: "lastTrack", scope: .format(format),
                                                 message: String(ui: "USB에 곡이 하나도 남지 않습니다. 곡을 남기거나 USB를 새로 내보내세요")))
        }
        planned.op = .removeTracks(ids)
        planned.rules = [.editRemoveTracks]
        planned.isRemoval = true
    }

    // MARK: - 재생 목록

    mutating func planPlaylist(_ edit: PlaylistEdit, into planned: inout UsbPlannedEdit) throws {
        planned.rules = [.editPlaylists]
        switch edit {
        case let .create(key, name, isFolder, parent):
            guard newPlaylists[key] == nil else {
                throw UsbEditBlocked(block: UsbBlock(code: "duplicateKey", scope: .playlist("new:\(key)"),
                                                     message: String(ui: "같은 key로 재생 목록을 두 번 만들 수 없습니다. 편집 파일의 key를 고치세요")))
            }
            let parentID = try folder(parent)
            let parentFormats = parentID == 0 ? writable : (working.playlists.first { $0.id == parentID }?.presentIn ?? [])
            let formats = writable.intersection(parentFormats)
            guard !formats.isEmpty else { throw Self.vanished(.playlist(parent.description)) }
            let id = ids.next(.playlist)
            let sortOrder = Dictionary(uniqueKeysWithValues: formats.map { ($0, nextSortOrder(parent: parentID, format: $0, excluding: nil)) })
            newPlaylists[key] = id
            planned.op = .playlist(.create(UsbPlaylist(id: id, name: name, parentID: parentID, attribute: isFolder ? 1 : 0, imageID: nil,
                                                       presentIn: formats, sortOrder: sortOrder,
                                                       entries: Dictionary(uniqueKeysWithValues: formats.map { ($0, []) }))))
            planned.rules.insert(.playlistSiblingBase)
            if isFolder { planned.rules.insert(.playlistFolderRow) }
            // pdb 문자열 규칙은 Device Library에 쓸 때만
            if formats.contains(.deviceLibrary) { planned.rules.formUnion(UsbTrackRules.pdbStringRules([name])) }
        case let .rename(ref, name):
            let playlist = try target(ref)
            // 철자(NFC·NFD)만 다른 이름도 OneLibrary에는 바꿔 쓴다. Device Library는 늘 NFC로 쓰므로 그것만으로는 바꾸지 않는다(#233)
            guard UsbNameSpelling.playlistNeedsRename(from: playlist.name, to: name, formats: playlist.presentIn.intersection(writable)) else {
                return
            }
            try requireWritableEverywhere(playlist, ref: ref)
            if playlist.presentIn.contains(.deviceLibrary) { planned.rules.formUnion(UsbTrackRules.pdbStringRules([name])) }
            planned.op = .playlist(.rename(id: playlist.id, name: name))
        case let .move(ref, into):
            let playlist = try target(ref)
            let parentID = try folder(into)
            if parentID != playlist.parentID { try requireWritableEverywhere(playlist, ref: ref) }
            if parentID != 0 {
                guard parentID != playlist.id, !descendants(of: playlist.id).contains(parentID) else {
                    throw UsbEditBlocked(block: UsbBlock(code: "moveIntoSelf", scope: .playlist(ref.description),
                                                         message: String(ui: "재생 목록 폴더를 자기 안으로 옮길 수 없습니다. 다른 폴더를 고르세요")))
                }
                let parentFormats = working.playlists.first { $0.id == parentID }?.presentIn ?? []
                guard playlist.presentIn.isSubset(of: parentFormats) else {
                    throw UsbEditBlocked(block: UsbBlock(code: "parentFormatMissing", scope: .playlist(ref.description),
                                                         message: String(ui: "옮길 폴더가 이 목록이 있는 형식에 모두 있지 않아 옮길 수 없습니다. 다른 폴더를 고르세요")))
                }
            }
            let formats = playlist.presentIn.intersection(writable)
            let sortOrder = Dictionary(uniqueKeysWithValues: formats.map {
                ($0, nextSortOrder(parent: parentID, format: $0, excluding: playlist.id))
            })
            planned.op = .playlist(.move(id: playlist.id, parentID: parentID, sortOrder: sortOrder))
            planned.rules.insert(.playlistSiblingBase)
        case let .reorder(ref, index):
            let playlist = try target(ref)
            var orders: [Int: [UsbFormat: Int]] = [:]
            for format in UsbFormat.allCases where playlist.presentIn.contains(format) && writable.contains(format) {
                let siblings = working.playlists.filter { $0.parentID == playlist.parentID && $0.presentIn.contains(format) }
                    .sorted { ($0.sortOrder[format] ?? 0, $0.id) < ($1.sortOrder[format] ?? 0, $1.id) }
                // 형제 순번의 시작값(0 또는 1)을 그대로 따른다
                let base = siblings.compactMap { $0.sortOrder[format] }.min() ?? 0
                var order = siblings.map(\.id).filter { $0 != playlist.id }
                order.insert(playlist.id, at: min(max(index, 0), order.count))
                for (position, id) in order.enumerated() where siblings.first(where: { $0.id == id })?.sortOrder[format] != base + position {
                    orders[id, default: [:]][format] = base + position
                }
            }
            if !orders.isEmpty { planned.op = .playlist(.reorder(orders)) }
            planned.rules.insert(.playlistSiblingBase)
        case let .delete(ref):
            let playlist = try target(ref)
            planned.op = .playlist(.delete([playlist.id] + descendants(of: playlist.id)))
        case let .addTracks(ref, contentIDs):
            let (playlist, formats, entries) = try entryTarget(ref)
            let added = try contentIDs.map { try trackID($0, formats: formats) }
            guard !added.isEmpty else { return }
            planned.op = .playlist(.entries(change(playlist.id, formats: formats, before: entries, after: entries + added)))
        case let .removeTracks(ref, picked):
            let (playlist, formats, entries) = try entryTarget(ref)
            let positions = try matching(picked, in: entries, ref: ref)
            guard !positions.isEmpty else { return }
            let after = entries.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
            planned.op = .playlist(.entries(change(playlist.id, formats: formats, before: entries, after: after)))
        case let .moveTracks(ref, picked, to):
            let (playlist, formats, entries) = try entryTarget(ref)
            let positions = try matching(picked, in: entries, ref: ref)
            var order = entries.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
            let moving = positions.sorted().map { entries[$0] }
            order.insert(contentsOf: moving, at: min(max(to - 1, 0), order.count))
            if order != entries { planned.op = .playlist(.entries(change(playlist.id, formats: formats, before: entries, after: order))) }
        }
    }

    /// 편집 대상 목록(지금 USB에 있고 고칠 수 있는 형식에 있어야 한다)
    func target(_ ref: PlaylistRef) throws -> UsbPlaylist {
        guard let id = playlistID(ref), let playlist = working.playlists.first(where: { $0.id == id }),
              !playlist.presentIn.isDisjoint(with: writable) else { throw Self.vanished(.playlist(ref.description)) }
        return playlist
    }

    func playlistID(_ ref: PlaylistRef) -> Int? {
        switch ref {
        case .root: 0
        case let .id(text): Int(text)
        case let .new(key): newPlaylists[key]
        }
    }

    /// 목록 이름·부모는 형식마다 따로 두지 않는다(합친 모델에 한 값). 고칠 수 없는 형식에도 있는 목록을 바꾸면 두 형식이 어긋나
    /// 다음 읽기부터 짝을 잃고 두 목록으로 보이므로(`UsbPlaylistPairing`) 그런 목록의 이름·부모는 바꾸지 않는다
    func requireWritableEverywhere(_ playlist: UsbPlaylist, ref: PlaylistRef) throws {
        guard playlist.presentIn.isSubset(of: writable) else {
            throw UsbEditBlocked(block: UsbBlock(code: "playlistInBlockedFormat", scope: .playlist(ref.description),
                                                 message: String(ui: "Device Library를 지금 고칠 수 없어, 두 형식에 함께 있는 재생 목록의 이름과 폴더는 바꾸지 않았습니다. Device Library가 막힌 이유를 먼저 푼 뒤 다시 시도하세요")))
        }
    }

    /// 맨 위(0) 또는 폴더
    func folder(_ ref: PlaylistRef) throws -> Int {
        if ref == .root { return 0 }
        let playlist = try target(ref)
        guard playlist.attribute == 1 else {
            throw UsbEditBlocked(block: UsbBlock(code: "notFolder", scope: .playlist(ref.description),
                                                 message: String(ui: "재생 목록 안에는 넣을 수 없습니다. 폴더를 고르세요")))
        }
        return playlist.id
    }

    /// 부모 안 형제의 가장 큰 순번 + 1(형제가 없으면 0)
    func nextSortOrder(parent: Int, format: UsbFormat, excluding: Int?) -> Int {
        working.playlists.filter { $0.parentID == parent && $0.id != excluding && $0.presentIn.contains(format) }
            .compactMap { $0.sortOrder[format] }.max().map { $0 + 1 } ?? 0
    }

    func descendants(of id: Int) -> [Int] {
        var result: [Int] = [], queue = [id]
        while let parent = queue.popLast() {
            let children = working.playlists.filter { $0.parentID == parent && $0.id != parent }.map(\.id).filter { !result.contains($0) }
            result += children
            queue += children
        }
        return result
    }

    /// 항목 편집 대상: 폴더가 아니고, 목록이 있는 모든 형식에서 항목이 같아야 한다
    func entryTarget(_ ref: PlaylistRef) throws -> (UsbPlaylist, [UsbFormat], [Int]) {
        let playlist = try target(ref)
        guard playlist.attribute == 0 else {
            throw UsbEditBlocked(block: UsbBlock(code: "notTrackList", scope: .playlist(ref.description),
                                                 message: String(ui: "폴더·인텔리전트 재생 목록에는 곡을 넣거나 뺄 수 없습니다. 일반 재생 목록을 고르세요")))
        }
        let present = UsbFormat.allCases.filter(playlist.presentIn.contains)
        let lists = present.map { playlist.entries[$0] ?? [] }
        guard lists.allSatisfy({ $0 == lists.first }) else {
            throw UsbEditBlocked(block: UsbBlock(code: "playlistEntriesDiffer", scope: .playlist(ref.description),
                                                 message: String(ui: "이 재생 목록은 두 형식의 곡 목록이 달라 곡을 고칠 수 없습니다. 이름·위치만 바꿀 수 있습니다")))
        }
        return (playlist, present.filter(writable.contains), lists.first ?? [])
    }

    func change(_ id: Int, formats: [UsbFormat], before: [Int], after: [Int]) -> UsbEntriesChange {
        UsbEntriesChange(playlistID: id, before: Dictionary(uniqueKeysWithValues: formats.map { ($0, before) }),
                         after: Dictionary(uniqueKeysWithValues: formats.map { ($0, after) }))
    }

    /// USB content_id 글자 → 곡(목록이 있는 형식에 모두 있어야 한다)
    func trackID(_ text: String, formats: [UsbFormat]) throws -> Int {
        guard let id = Int(text), let track = working.tracks.first(where: { $0.id == id }),
              Set(formats).isSubset(of: track.presentIn) else { throw Self.vanished(.track("usb:\(text)")) }
        return id
    }

    /// 항목 자리(1부터)마다 그 자리의 곡이 편집을 만들 때와 같은지. 0부터의 자리 번호를 돌려준다
    func matching(_ picked: [PlaylistEntry], in entries: [Int], ref: PlaylistRef) throws -> Set<Int> {
        var positions: Set<Int> = []
        for entry in picked {
            guard entry.trackNo >= 1, entry.trackNo <= entries.count, String(entries[entry.trackNo - 1]) == entry.contentID,
                  positions.insert(entry.trackNo - 1).inserted else {
                throw UsbEditBlocked(block: UsbBlock(code: "entryMismatch", scope: .playlist(ref.description),
                                                     message: String(ui: "\(entry.trackNo)번째 곡이 편집을 만들 때와 다릅니다. USB를 다시 읽은 뒤 고치세요")))
            }
        }
        return positions
    }

    // MARK: - 도움

    static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func vanished(_ scope: UsbBlock.Scope) -> UsbEditBlocked {
        UsbEditBlocked(block: UsbBlock(code: "targetMissing", scope: scope, message: String(ui: "대상이 USB에서 사라졌습니다. USB를 다시 읽은 뒤 고치세요")))
    }

    /// USB 상대 경로("/" 뗌)
    static func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    /// USB DB의 그림 경로(상대)가 아트워크 파일 모양(`PIONEER/Artwork/nnnnn/[ab]n(_m).jpg`, `..`·`._` 없음)인지.
    /// 아니면 그 자리를 덮어쓰거나 지우지 않는다(손상됐거나 꾸민 USB가 USB·Mac의 다른 파일을 가리키지 못하게)
    static func isArtworkFile(_ relative: String) -> Bool {
        UsbRemovalPolicy.allows(relative) && UsbWriter.isSafeRelativePath(relative)
            && UsbLayout.collisionKey(relative).hasPrefix(UsbLayout.collisionKey(UsbLayout.artworkRoot + "/"))
            && !UsbLayout.isAppleDouble((relative as NSString).lastPathComponent)
    }
}
