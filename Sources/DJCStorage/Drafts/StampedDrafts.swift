import DJCDomain
import Foundation

/// 곡 초안 판 지정 삭제의 결과(R22). `DraftStore.removeWritten`의 결과 `DraftRemoval`이 이것을 옮긴다
public struct DraftRemovalResult: Equatable, Sendable {
    /// 판과 해시가 같아 지운 초안
    public var removed: [WrittenDraft]
    /// 판은 같은데 지금 해시가 달라(바깥에서 고침) 지우지 않고 제안으로 남긴 초안
    public var suggested: [WrittenDraft]
    /// 판이 달라(쓰는 동안 새로 저장했거나 이미 없음) 또는 읽지 못해 그대로 둔 초안
    public var kept: [WrittenDraft]

    public init(removed: [WrittenDraft] = [], suggested: [WrittenDraft] = [], kept: [WrittenDraft] = []) {
        self.removed = removed
        self.suggested = suggested
        self.kept = kept
    }
}

/// 쓴 재생 목록 단계 정리의 결과(R22). `PlaylistStepRemoval`이 이것을 옮긴다
public struct PlaylistStepRemovalResult: Equatable, Sendable {
    public var removed: Set<DraftRevision> = []
    /// 해시가 달라 사본을 남기고 뺀 단계 → 사본 파일
    public var copied: [DraftRevision: URL] = [:]
    /// 해시가 달랐는데 사본을 남기지 못해 남긴 단계
    public var copyFailed: Set<DraftRevision> = []
    /// 판을 찾지 못한 단계
    public var notFound: Set<DraftRevision> = []

    public init() {}
}

/// 초안을 저장하면서 도장(출처·새 판·해시)을 적고, 쓴 판만 지운다(자동 저장 R5·R22). 앱의 저장 큐·CLI 초안 파일·시험이 같은 함수를 쓴다.
/// 초안 파일을 쓴 뒤 도장을 적고(`DraftStampStore` 설명), 모두 초안 잠금 안에서 한다. 해시는 디스크에서 다시 읽은 값의 해시다:
/// 쓰기 묶음이 읽어 넣는 값과 같은 함수·같은 내용이라야 정리가 판과 해시를 견줄 수 있다.
public enum StampedDrafts {
    // MARK: 곡 초안 저장

    /// 파일이 있었는지 보고, 쓰고, 읽은 값의 해시로 도장을 적는다. 덮어쓰기 전에 지금 파일 내용의 해시를 저장된 도장의 해시와 견준다:
    /// 다르면(바깥에서 고쳤다) 새 도장의 출처에 모름을 더한다. 읽지 못해도 같다. 파일은 없는데 도장이 남아 있어도 같다
    private static func stamped(_ key: DraftKey, home: URL, file: URL, origin: DraftOrigin, write: () throws -> Void,
                                hash: () -> DraftContentHash?) throws {
        try DraftStampStore.withLock(home: home) {
            let present = FileManager.default.fileExists(atPath: file.path)
            let old = DraftStampStore.read(key, home: home)
            // 파일은 없는데 그 키의 도장이 남아 있다(손상 파일을 복구가 옮겼거나 바깥이 지웠다): 기존 출처를 잇고 모름을 더한다
            let stale = !present && old != nil
            let outside = stale || (present ? old.map { hash() != $0.contentHash } ?? false : false)
            try write()
            try DraftStampStore.restamp(key, home: home, existed: present || stale, origin: origin, hash: hash(), outside: outside)
        }
    }

    private static func hash(_ value: (some Encodable)?) -> DraftContentHash? { value.flatMap { try? DraftContentHash(of: $0) } }

    public static func saveCue(_ draft: CueDraft, directory: URL, origin: DraftOrigin) throws {
        try stamped(DraftKey(.cue, draft.trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(draft.trackUUID).json"), origin: origin,
                    write: { try CueDraftStore.save(draft, directory: directory) },
                    hash: { hash(CueDraftStore.load(trackUUID: draft.trackUUID, directory: directory)) })
    }

    public static func saveGrid(_ draft: GridDraft, directory: URL, origin: DraftOrigin) throws {
        try stamped(DraftKey(.grid, draft.trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(draft.trackUUID).json"), origin: origin,
                    write: { try GridDraftStore.save(draft, directory: directory) },
                    hash: { hash(GridDraftStore.load(trackUUID: draft.trackUUID, directory: directory)) })
    }

    public static func saveTag(_ draft: TagDraft, directory: URL, origin: DraftOrigin) throws {
        try stamped(DraftKey(.tag, draft.trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(draft.trackUUID).json"), origin: origin,
                    write: { try TagDraftStore.save(draft, directory: directory) },
                    hash: { hash(TagDraftStore.load(trackUUID: draft.trackUUID, directory: directory)) })
    }

    /// CLI·초안 파일 포트의 큐 초안 지우기(손상된 파일은 옮겨 보관한다)
    public static func removeCue(trackUUID: String, directory: URL) throws {
        try stamped(DraftKey(.cue, trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(trackUUID).json"), origin: .unknown,
                    write: { try CueDraftStore.remove(trackUUID: trackUUID, directory: directory) }, hash: { nil })
    }

    public static func removeTag(trackUUID: String, directory: URL) throws {
        try stamped(DraftKey(.tag, trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(trackUUID).json"), origin: .unknown,
                    write: { try TagDraftStore.remove(trackUUID: trackUUID, directory: directory) }, hash: { nil })
    }

    /// 게인 초안(nil이면 지우기). 모든 곡이 한 파일이라 곡별 도장은 `gain.json` 사전에 적는다.
    /// 지금 파일을 읽지 못하면(손상) 빈 파일과 다르다: 그 곡의 기존 도장의 출처를 잇고 모름을 더한다
    public static func saveGain(_ gain: Double?, trackUUID: String, url: URL, origin: DraftOrigin) throws {
        let home = url.deletingLastPathComponent()
        try DraftStampStore.withLock(home: home) {
            let key = DraftKey(.gain, trackUUID)
            let readable = try? GainDraftStore.read(url: url)
            let unreadable = readable == nil
            let current = readable?[trackUUID]
            let old = DraftStampStore.read(key, home: home)
            // 그 곡의 도장이 남아 있는데 곡이 파일에 없다(손상 파일을 복구가 옮겼거나 바깥이 지웠다)도 기존 출처를 잇고 모름을 더한다
            let stale = current == nil && old != nil
            let existed = current != nil || stale
            let outside = unreadable || stale || (current != nil && old.map { hash(current) != $0.contentHash } ?? false)
            try GainDraftStore.save(gain, trackUUID: trackUUID, url: url)
            let saved = (try? GainDraftStore.read(url: url))?[trackUUID]
            try DraftStampStore.restamp(key, home: home, existed: existed, origin: origin, hash: hash(saved), outside: outside)
        }
    }

    /// 그림 초안과 사본
    public static func saveArtwork(_ edit: ArtworkEdit, directory: URL, origin: DraftOrigin) throws {
        try stamped(DraftKey(.artwork, edit.trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(edit.trackUUID).json"), origin: origin,
                    write: { try ArtworkDraftStore.save(edit, directory: directory) },
                    hash: { (try? ArtworkDraftStore.load(trackUUID: edit.trackUUID, directory: directory)).flatMap { try? DraftContentHash(artwork: $0) } })
    }

    public static func removeArtwork(trackUUID: String, directory: URL) throws {
        try stamped(DraftKey(.artwork, trackUUID), home: directory.deletingLastPathComponent(),
                    file: directory.appending(path: "\(trackUUID).json"), origin: .unknown,
                    write: { try ArtworkDraftStore.remove(trackUUID: trackUUID, directory: directory) }, hash: { nil })
    }

    /// 합치기 초안 목록을 통째로 저장한다: 내용이 같은 초안은 도장을 그대로 두고, 바뀌거나 새로 든 초안만 새 판을 받는다.
    /// 덮어쓰기 전 파일의 초안 해시가 도장의 해시와 다르면(바깥에서 고쳤다) 그 초안의 출처에 모름을 더한다
    public static func saveMerges(_ drafts: [DuplicateMergeDraft], url: URL, origin: DraftOrigin) throws {
        let home = url.deletingLastPathComponent()
        try DraftStampStore.withLock(home: home) {
            // 지금 파일을 읽지 못하면(손상) 빈 파일과 다르다: 기존 도장의 출처를 잇고 모름을 더한다
            var existing: [String: DuplicateMergeDraft] = [:]
            var unreadable = false
            do {
                existing = Dictionary((try DamagedDrafts.read([DuplicateMergeDraft].self, at: url) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                unreadable = true
            }
            try DuplicateMergeDraftStore.save(drafts, url: url)
            let saved = DuplicateMergeDraftStore.load(url: url)
            let stampURL = DraftStampStore.folder(home: home).appending(path: "\(DraftKey.Kind.merge.rawValue).json")
            let old = (try? Data(contentsOf: stampURL)).flatMap { try? JSONDecoder().decode([String: DraftStamp].self, from: $0) } ?? [:]
            var stamps: [String: DraftStamp] = [:]
            var changed: [(draft: DuplicateMergeDraft, hash: DraftContentHash, outside: Bool)] = []
            for draft in saved {
                guard let hash = try? DraftContentHash(of: draft) else { continue }
                // 덮어쓰기 전 파일의 초안 해시가 도장의 해시와 다르면(바깥에서 고쳤다) 내용이 같아도 새 도장이다
                let stale = existing[draft.id] == nil && old[draft.id] != nil
                let outside = unreadable || stale || (existing[draft.id].flatMap { before in old[draft.id].map { self.hash(before) != $0.contentHash } } ?? false)
                if let stamp = old[draft.id], stamp.contentHash == hash, !outside { stamps[draft.id] = stamp } else { changed.append((draft, hash, outside)) }
            }
            let revisions = try DraftStampStore.nextRevisions(changed.count, home: home)
            for (item, revision) in zip(changed, revisions) {
                var origins: Set<DraftOrigin> = [origin]
                if existing[item.draft.id] != nil || old[item.draft.id] != nil { origins.formUnion(old[item.draft.id]?.origins ?? [.unknown]) }
                if item.outside { origins.insert(.unknown) }
                stamps[item.draft.id] = DraftStamp(revision: revision, origins: origins, contentHash: item.hash)
            }
            try DraftStampStore.writeAggregate(stamps, to: stampURL)
        }
    }

    // MARK: 재생 목록 단계

    // 단계의 도장은 단계 식별자(`PlaylistDraft.Step.id`, 초안 파일 안)로 잇는다. 사이드카 `playlist.json`은 단계 차례의 `PlaylistStampEntry` 배열이다.
    // 식별자·도장 규칙은 `PlaylistStepStamping`(DJCDomain)이다. 메모리 구현과 같은 함수를 쓴다

    private static func playlistStampURL(home: URL) -> URL {
        DraftStampStore.folder(home: home).appending(path: "playlist.json")
    }

    private static func readPlaylistEntries(home: URL) -> [PlaylistStampEntry] {
        (try? Data(contentsOf: playlistStampURL(home: home))).flatMap { try? JSONDecoder().decode([PlaylistStampEntry].self, from: $0) } ?? []
    }

    private static func writePlaylistEntries(_ entries: [PlaylistStampEntry], home: URL) throws {
        let url = playlistStampURL(home: home)
        guard !entries.isEmpty else {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// 지금 파일의 초안에 식별자·도장을 맞춘다(없는 것은 모름으로 받는다). 바뀌었으면 초안 파일과 사이드카를 다시 적는다. 잠금 안에서 부른다.
    /// 초안 파일을 읽지 못하면 던진다(손상된 파일 때문에 도장을 지우지 않게)
    private static func adoptedPlaylist(home: URL) throws -> PlaylistStepStamping.Result {
        let url = DraftLocations(home: home).playlist
        let draft = try PlaylistDraftStore.read(url: url)
        let result = try PlaylistStepStamping.adopt(draft, entries: readPlaylistEntries(home: home), newID: { UUID() },
                                                    newRevision: { try DraftStampStore.nextRevisions(1, home: home)[0] })
        if result.changed {
            // 도장 사이드카를 먼저 적는다: 사이드카 쓰기에 실패하면 초안 파일은 바뀌지 않는다(식별자만 적히고 도장이 없는 상태를 만들지 않는다).
            // 파일 쓰기에 실패하면 사이드카에는 파일에 없는 식별자의 줄이 남지만, 다음에 읽을 때 걸러진다
            try writePlaylistEntries(result.entries, home: home)
            if result.draft.stepIDs != draft.stepIDs { try PlaylistDraftStore.save(result.draft, url: url) }
        }
        return result
    }

    /// 재생 목록 초안의 단계별 도장(`playlist-drafts.json`의 단계 차례와 같다). 식별자나 도장이 없는 단계는 모름 출처로 새 판을 받아
    /// 적는다(그래서 읽기가 초안 파일과 사이드카를 쓸 수 있다). 읽지 못하거나 잠금을 잡지 못하면 빈 배열(모름)이다
    public static func playlistStamps(home: URL) -> [DraftStamp] {
        guard let draft = try? PlaylistDraftStore.read(url: DraftLocations(home: home).playlist) else { return [] }
        // 식별자와 도장이 이미 맞으면 잠그지 않고 읽는다(자주 부르는 읽기)
        let entries = readPlaylistEntries(home: home)
        let ids = draft.stepIDs
        if ids.allSatisfy({ $0 != nil }), ids.compactMap({ $0 }) == entries.map(\.id) { return entries.map(\.stamp) }
        return (try? DraftStampStore.withLock(home: home) { try adoptedPlaylist(home: home).entries.map(\.stamp) }) ?? []
    }

    /// 재생 목록 초안을 식별자를 채워 읽는다(CLI가 쌓기 전, 앱이 메모리에 받을 때). 식별자가 이미 다 있으면 잠그지 않는다. 없는 단계는
    /// 새 식별자와 모름 도장을 받고 도장 사이드카와 초안 파일에 적는다(식별자 없는 초안으로 이어 저장하면 기존 단계가 새 단계로 보여
    /// 이번 출처 하나로 적히기 때문이다). 식별자나 도장을 적지 못하면(잠금·판 번호·저장 오류) 식별자 없는 초안을 돌려주지 않고 던진다.
    /// 파일을 읽지 못하면 `DraftFileDamaged`를 던진다
    public static func identifiedPlaylist(home: URL) throws -> PlaylistDraft {
        let draft = try PlaylistDraftStore.read(url: DraftLocations(home: home).playlist)
        let ids = draft.stepIDs
        if ids.allSatisfy({ $0 != nil }), Set(ids.compactMap { $0 }).count == ids.count { return draft }
        return try DraftStampStore.withLock(home: home) { try adoptedPlaylist(home: home).draft }
    }

    /// 식별자를 파일에 적지 못할 때(`identifiedPlaylist`가 던질 때) 앱이 던지지 않는 읽기(`playlistDraft()`)에 주는 초안: 식별자 없는 단계에
    /// 메모리에서만 새 식별자를 부여한다(파일에는 적지 않는다). 그 초안을 저장하면 그 식별자들은 지금 파일에 없는 단계라 `[이번 출처, 모름]`으로
    /// 적히고, 식별자 없는 초안처럼 기존 단계가 이번 출처 하나로 적히지 않는다
    public static func withEphemeralIdentifiers(_ draft: PlaylistDraft) -> PlaylistDraft {
        var seen = Set<UUID>()
        var identified = draft
        identified.setStepIDs(draft.stepIDs.map { id in
            if let id, seen.insert(id).inserted { return id }
            let fresh = UUID()
            seen.insert(fresh)
            return fresh
        })
        return identified
    }

    /// 재생 목록 초안을 통째로 저장한다: 단계 식별자를 맞추고(`PlaylistStepStamping.save`) 도장을 갱신한다. 초안 잠금 안에서 한다.
    /// - Parameter expecting: 주면 지금 파일의 초안이 이것과 같을 때만 저장한다(CLI가 계획한 원본의 재확인과 저장을 한 잠금에서 한다).
    ///   다르면 저장하지 않고 false
    @discardableResult
    public static func savePlaylist(_ draft: PlaylistDraft, url: URL, origin: DraftOrigin, expecting: PlaylistDraft? = nil) throws -> Bool {
        let home = url.deletingLastPathComponent()
        return try DraftStampStore.withLock(home: home) {
            // 저장만 하면 읽지 못하는 파일은 저장소가 옮겨 보관하고 새로 쓴다. 이때 빈 파일과 다르다(`previousUnreadable`): 기존 도장의 출처를 잇고
            // 모름을 더한다. 원본을 견주면 읽지 못할 때 던진다
            var current = PlaylistDraft()
            var unreadable = false
            if let expecting {
                current = try PlaylistDraftStore.read(url: url)
                // 단계 식별자도 견준다: 같은 내용으로 다시 만든 단계는 다른 단계다
                if current != expecting || current.stepIDs != expecting.stepIDs { return false }
            } else if let read = try? PlaylistDraftStore.read(url: url) {
                current = read
            } else {
                unreadable = true
            }
            let result = try PlaylistStepStamping.save(draft, previous: current, entries: readPlaylistEntries(home: home), origin: origin,
                                                       previousUnreadable: unreadable, newID: { UUID() },
                                                       newRevision: { try DraftStampStore.nextRevisions(1, home: home)[0] })
            try PlaylistDraftStore.save(result.draft, url: url)
            // 도장의 해시는 파일에서 다시 읽은 단계의 해시다(쓰기 묶음이 읽어 넣는 값과 같다)
            let saved = try PlaylistDraftStore.read(url: url)
            let entries = zip(saved.steps, result.entries).map { step, entry -> PlaylistStampEntry in
                var entry = entry
                entry.stamp.contentHash = PlaylistStepStamping.hash(step, in: saved)
                return entry
            }
            try writePlaylistEntries(saved.steps.count == entries.count ? entries : result.entries, home: home)
            return true
        }
    }

    /// 쓴 재생 목록 단계의 정리(R22): 판으로 찾아 뺀다. 지금 해시가 쓴 해시와 다르면(바깥에서 고침) 사본을 `copyFolder`에 남긴 뒤에만 빼고,
    /// 사본을 남기지 못하면 그 단계를 남긴다. 연결 ID 옮기기는 하지 않는다(규칙은 `PlaylistDraft`, #402)
    public static func removeWrittenSteps(_ written: [(revision: DraftRevision, contentHash: DraftContentHash)], newPlaylistIDs: [String: String],
                                          copyFolder: URL, home: URL) throws -> PlaylistStepRemovalResult {
        let url = DraftLocations(home: home).playlist
        return try DraftStampStore.withLock(home: home) {
            let adopted = try adoptedPlaylist(home: home)
            let draft = adopted.draft
            var result = PlaylistStepRemovalResult()
            var offsets: [Int] = []
            for item in written {
                guard let offset = adopted.entries.firstIndex(where: { $0.stamp.revision == item.revision }) else {
                    result.notFound.insert(item.revision)
                    continue
                }
                let step = draft.steps[offset]
                let current = PlaylistStepStamping.hash(step, in: draft)
                if current != item.contentHash {
                    // 바깥에서 고친 단계: 사본을 디스크에 남긴 뒤에만 뺀다
                    let playlistID: String? = switch step.edit.playlist {
                    case let .id(id): id
                    case .new: newPlaylistIDs[step.edit.playlist.description]
                    case .root: nil
                    }
                    let depends = Set(step.depends)
                    let copy = PlaylistStepCopy(revision: item.revision, playlistID: playlistID, step: step,
                                                base: draft.base.filter { depends.contains($0.key) },
                                                writtenHash: item.contentHash, currentHash: current)
                    let copyURL = PlaylistStepCopy.url(folder: copyFolder, revision: item.revision)
                    do {
                        try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(copy).write(to: copyURL, options: .atomic)
                    } catch {
                        result.copyFailed.insert(item.revision)
                        continue
                    }
                    result.copied[item.revision] = copyURL
                }
                offsets.append(offset)
                result.removed.insert(item.revision)
            }
            guard !offsets.isEmpty else { return result }
            var remaining = draft
            remaining.removeSteps(at: offsets)
            try PlaylistDraftStore.save(remaining, url: url)
            let dropped = Set(offsets)
            try writePlaylistEntries(adopted.entries.enumerated().filter { !dropped.contains($0.offset) }.map(\.element), home: home)
            return result
        }
    }

    // MARK: 판 지정 삭제·제안 전환

    /// 지금 내용의 해시(디스크). 초안이 없거나 읽지 못하면 nil
    static func currentHash(_ key: DraftKey, places: DraftLocations) -> DraftContentHash? {
        if [.cue, .grid, .tag, .artwork].contains(key.kind), !DraftStampStore.isSafeName(key.id) { return nil }
        switch key.kind {
        case .cue: return hash(CueDraftStore.load(trackUUID: key.id, directory: places.cue))
        case .grid: return hash(GridDraftStore.load(trackUUID: key.id, directory: places.grid))
        case .tag: return hash(TagDraftStore.load(trackUUID: key.id, directory: places.tags))
        case .gain: return hash((try? GainDraftStore.read(url: places.gain))?[key.id])
        case .artwork:
            return (try? ArtworkDraftStore.load(trackUUID: key.id, directory: places.artwork)).flatMap { try? DraftContentHash(artwork: $0) }
        case .merge: return hash(DuplicateMergeDraftStore.load(url: places.merge).first { $0.id == key.id })
        }
    }

    private static func removeDraft(_ key: DraftKey, places: DraftLocations) throws {
        func removeFile(_ directory: URL) throws {
            do { try FileManager.default.removeItem(at: directory.appending(path: "\(key.id).json")) } catch CocoaError.fileNoSuchFile {}
        }
        switch key.kind {
        case .cue: try removeFile(places.cue)
        case .grid: try removeFile(places.grid)
        case .tag: try removeFile(places.tags)
        case .gain: try GainDraftStore.save(nil, trackUUID: key.id, url: places.gain)
        case .artwork: try ArtworkDraftStore.remove(trackUUID: key.id, directory: places.artwork)
        case .merge: try DuplicateMergeDraftStore.save(DuplicateMergeDraftStore.load(url: places.merge).filter { $0.id != key.id }, url: places.merge)
        }
    }

    /// 곡 초안의 판 지정 삭제(쓴 뒤 정리, R22). 판과 지금 내용의 해시가 모두 쓴 것과 같으면 지운다. 판이 같고 해시가 다르면(바깥에서 고침)
    /// 지우지 않고 새 판과 모름 출처를 적어 제안으로 남긴다. 판이 다르거나 초안이 없거나 읽지 못하면 그대로 둔다
    public static func removeWritten(_ written: [WrittenDraft], home: URL) throws -> DraftRemovalResult {
        let places = DraftLocations(home: home)
        return try DraftStampStore.withLock(home: home) {
            var result = DraftRemovalResult()
            for item in written {
                guard let stamp = DraftStampStore.read(item.key, home: home), stamp.revision == item.revision,
                      let current = currentHash(item.key, places: places) else {
                    result.kept.append(item)
                    continue
                }
                if current == item.contentHash {
                    try removeDraft(item.key, places: places)
                    try DraftStampStore.write(nil, for: item.key, home: home)
                    result.removed.append(item)
                } else {
                    try markSuggestion(item.key, old: stamp, current: current, home: home)
                    result.suggested.append(item)
                }
            }
            return result
        }
    }

    /// 그 초안을 제안으로 바꾼다: 출처에 모름을 더하고 지금 내용의 해시로 새 판을 준다. 새 판
    @discardableResult
    private static func markSuggestion(_ key: DraftKey, old: DraftStamp, current: DraftContentHash?, home: URL) throws -> DraftRevision {
        let revision = try DraftStampStore.nextRevisions(1, home: home)[0]
        try DraftStampStore.write(DraftStamp(revision: revision, origins: old.origins.union([.unknown]), contentHash: current ?? old.contentHash),
                                  for: key, home: home)
        return revision
    }

    /// "이대로 둔다"(R11): 판이 같은 곡 초안과 재생 목록 단계를 지우지 않고 제안으로 바꾼다. 옛 판 → 새 판
    public static func markSuggestions(_ drafts: [WrittenDraft], playlistSteps: Set<DraftRevision>, home: URL) throws -> [DraftRevision: DraftRevision] {
        let places = DraftLocations(home: home)
        return try DraftStampStore.withLock(home: home) {
            var marked: [DraftRevision: DraftRevision] = [:]
            for item in drafts {
                guard let stamp = DraftStampStore.read(item.key, home: home), stamp.revision == item.revision else { continue }
                marked[stamp.revision] = try markSuggestion(item.key, old: stamp, current: currentHash(item.key, places: places), home: home)
            }
            guard !playlistSteps.isEmpty else { return marked }
            let adopted = try adoptedPlaylist(home: home)
            var entries = adopted.entries
            let indices = entries.indices.filter { playlistSteps.contains(entries[$0].stamp.revision) }
            let revisions = try DraftStampStore.nextRevisions(indices.count, home: home)
            for (index, revision) in zip(indices, revisions) {
                let old = entries[index].stamp
                marked[old.revision] = revision
                entries[index].stamp = DraftStamp(revision: revision, origins: old.origins.union([.unknown]),
                                                  contentHash: PlaylistStepStamping.hash(adopted.draft.steps[index], in: adopted.draft))
            }
            if !indices.isEmpty { try writePlaylistEntries(entries, home: home) }
            return marked
        }
    }
}
