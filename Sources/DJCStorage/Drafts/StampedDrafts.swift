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

    /// 파일이 있었는지 보고, 쓰고, 읽은 값의 해시로 도장을 적는다
    private static func stamped(_ key: DraftKey, home: URL, file: URL, origin: DraftOrigin, write: () throws -> Void,
                                hash: () -> DraftContentHash?) throws {
        try DraftStampStore.withLock(home: home) {
            let existed = FileManager.default.fileExists(atPath: file.path)
            try write()
            try DraftStampStore.restamp(key, home: home, existed: existed, origin: origin, hash: hash())
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

    /// 게인 초안(nil이면 지우기). 모든 곡이 한 파일이라 곡별 도장은 `gain.json` 사전에 적는다
    public static func saveGain(_ gain: Double?, trackUUID: String, url: URL, origin: DraftOrigin) throws {
        let home = url.deletingLastPathComponent()
        try DraftStampStore.withLock(home: home) {
            let existed = ((try? GainDraftStore.read(url: url)) ?? [:])[trackUUID] != nil
            try GainDraftStore.save(gain, trackUUID: trackUUID, url: url)
            let saved = (try? GainDraftStore.read(url: url))?[trackUUID]
            try DraftStampStore.restamp(DraftKey(.gain, trackUUID), home: home, existed: existed, origin: origin, hash: hash(saved))
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

    /// 합치기 초안 목록을 통째로 저장한다: 내용이 같은 초안은 도장을 그대로 두고, 바뀌거나 새로 든 초안만 새 판을 받는다
    public static func saveMerges(_ drafts: [DuplicateMergeDraft], url: URL, origin: DraftOrigin) throws {
        let home = url.deletingLastPathComponent()
        try DraftStampStore.withLock(home: home) {
            let before = Set(DuplicateMergeDraftStore.load(url: url).map(\.id))
            try DuplicateMergeDraftStore.save(drafts, url: url)
            let saved = DuplicateMergeDraftStore.load(url: url)
            let stampURL = DraftStampStore.folder(home: home).appending(path: "\(DraftKey.Kind.merge.rawValue).json")
            let old = (try? Data(contentsOf: stampURL)).flatMap { try? JSONDecoder().decode([String: DraftStamp].self, from: $0) } ?? [:]
            var stamps: [String: DraftStamp] = [:]
            var changed: [(draft: DuplicateMergeDraft, hash: DraftContentHash)] = []
            for draft in saved {
                guard let hash = try? DraftContentHash(of: draft) else { continue }
                if let stamp = old[draft.id], stamp.contentHash == hash { stamps[draft.id] = stamp } else { changed.append((draft, hash)) }
            }
            let revisions = try DraftStampStore.nextRevisions(changed.count, home: home)
            for (item, revision) in zip(changed, revisions) {
                var origins: Set<DraftOrigin> = [origin]
                if before.contains(item.draft.id) { origins.formUnion(old[item.draft.id]?.origins ?? [.unknown]) }
                stamps[item.draft.id] = DraftStamp(revision: revision, origins: origins, contentHash: item.hash)
            }
            try DraftStampStore.writeAggregate(stamps, to: stampURL)
        }
    }

    // MARK: 재생 목록 단계

    private static func stepHash(_ step: PlaylistDraft.Step, in draft: PlaylistDraft) -> DraftContentHash? { try? DraftContentHash(step: step, in: draft) }

    private static func playlistStampURL(home: URL) -> URL {
        DraftStampStore.folder(home: home).appending(path: "playlist.json")
    }

    private static func readPlaylistStamps(home: URL) -> [DraftStamp] {
        (try? Data(contentsOf: playlistStampURL(home: home))).flatMap { try? JSONDecoder().decode([DraftStamp].self, from: $0) } ?? []
    }

    private static func writePlaylistStamps(_ stamps: [DraftStamp], home: URL) throws {
        let url = playlistStampURL(home: home)
        guard !stamps.isEmpty else {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stamps).write(to: url, options: .atomic)
    }

    /// 단계 차례와 맞춘 도장. 단계 수가 사이드카와 같으면 차례대로 짝이다(바깥이 내용만 고쳐도 그 자리의 도장을 쓴다). 수가 다르면(도장을
    /// 모르는 쪽이 단계를 더하거나 뺐다) 해시가 같은 단계만 앞 도장을 잇고, 나머지 단계는 새 판과 모름 출처의 도장을 받는다.
    /// 잠금 안에서 부른다. `persist`면 바뀐 사이드카를 적는다
    private static func alignedPlaylistStamps(_ draft: PlaylistDraft, home: URL, persist: Bool) throws -> [DraftStamp] {
        let stamps = readPlaylistStamps(home: home)
        guard stamps.count != draft.steps.count else { return stamps }
        var pool = stamps
        var slots: [DraftStamp?] = []
        for step in draft.steps {
            if let hash = stepHash(step, in: draft), let index = pool.firstIndex(where: { $0.contentHash == hash }) {
                slots.append(pool.remove(at: index))
            } else {
                slots.append(nil)
            }
        }
        let missing = slots.filter { $0 == nil }.count
        var revisions = persist ? try DraftStampStore.nextRevisions(missing, home: home)[...] : []
        let aligned = zip(draft.steps, slots).map { step, slot -> DraftStamp in
            if let slot { return slot }
            let hash = stepHash(step, in: draft) ?? DraftContentHash(hex: "")
            // 저장하지 않는 읽기는 판을 받지 않는다(받아 적을 때까지 판 0으로 두고 쓰지 않는다)
            return DraftStamp(revision: revisions.popFirst() ?? DraftRevision(0), origins: [.unknown], contentHash: hash)
        }
        if persist { try writePlaylistStamps(aligned, home: home) }
        return aligned
    }

    /// 재생 목록 초안의 단계별 도장(`playlist-drafts.json`의 단계 차례와 같다). 도장이 없는 단계는 모름 출처로 새 판을 받아 사이드카에 적는다
    public static func playlistStamps(home: URL) -> [DraftStamp] {
        let draft = (try? PlaylistDraftStore.read(url: DraftLocations(home: home).playlist)) ?? PlaylistDraft()
        // 사이드카와 이미 맞으면 잠그지 않고 읽는다(자주 부르는 읽기)
        let stamps = readPlaylistStamps(home: home)
        if stamps.count == draft.steps.count { return stamps }
        return DraftStampStore.withLock(home: home) {
            let current = (try? PlaylistDraftStore.read(url: DraftLocations(home: home).playlist)) ?? PlaylistDraft()
            return (try? alignedPlaylistStamps(current, home: home, persist: true)) ?? []
        }
    }

    /// 재생 목록 초안을 통째로 저장한다: 앞 도장 가운데 내용이 같은 단계의 도장을 이어 쓰고, 나머지 단계만 새 판을 받는다
    public static func savePlaylist(_ draft: PlaylistDraft, url: URL, origin: DraftOrigin) throws {
        let home = url.deletingLastPathComponent()
        try DraftStampStore.withLock(home: home) {
            let previous = try alignedPlaylistStamps((try? PlaylistDraftStore.read(url: url)) ?? PlaylistDraft(), home: home, persist: false)
            try PlaylistDraftStore.save(draft, url: url)
            let saved = (try? PlaylistDraftStore.read(url: url)) ?? PlaylistDraft()
            var pool = previous.filter { $0.revision.value > 0 }
            var slots: [DraftStamp?] = []
            for step in saved.steps {
                if let hash = stepHash(step, in: saved), let index = pool.firstIndex(where: { $0.contentHash == hash }) {
                    slots.append(pool.remove(at: index))
                } else {
                    slots.append(nil)
                }
            }
            var revisions = try DraftStampStore.nextRevisions(slots.filter { $0 == nil }.count, home: home)[...]
            let stamps = zip(saved.steps, slots).map { step, slot -> DraftStamp in
                slot ?? DraftStamp(revision: revisions.popFirst()!, origins: [origin], contentHash: stepHash(step, in: saved) ?? DraftContentHash(hex: ""))
            }
            try writePlaylistStamps(stamps, home: home)
        }
    }

    /// 쓴 재생 목록 단계의 정리(R22): 판으로 찾아 뺀다. 지금 해시가 쓴 해시와 다르면(바깥에서 고침) 사본을 `copyFolder`에 남긴 뒤에만 빼고,
    /// 사본을 남기지 못하면 그 단계를 남긴다. 연결 ID 옮기기는 하지 않는다(규칙은 `PlaylistDraft`, #402)
    public static func removeWrittenSteps(_ written: [(revision: DraftRevision, contentHash: DraftContentHash)], newPlaylistIDs: [String: String],
                                          copyFolder: URL, home: URL) throws -> PlaylistStepRemovalResult {
        let url = DraftLocations(home: home).playlist
        return try DraftStampStore.withLock(home: home) {
            let draft = try PlaylistDraftStore.read(url: url)
            let stamps = try alignedPlaylistStamps(draft, home: home, persist: true)
            var result = PlaylistStepRemovalResult()
            var offsets: [Int] = []
            for item in written {
                guard let offset = stamps.firstIndex(where: { $0.revision == item.revision }) else {
                    result.notFound.insert(item.revision)
                    continue
                }
                let step = draft.steps[offset]
                let current = stepHash(step, in: draft) ?? DraftContentHash(hex: "")
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
            try writePlaylistStamps(stamps.enumerated().filter { !dropped.contains($0.offset) }.map(\.element), home: home)
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
            let draft = (try? PlaylistDraftStore.read(url: places.playlist)) ?? PlaylistDraft()
            var stamps = try alignedPlaylistStamps(draft, home: home, persist: true)
            let indices = stamps.indices.filter { playlistSteps.contains(stamps[$0].revision) }
            let revisions = try DraftStampStore.nextRevisions(indices.count, home: home)
            for (index, revision) in zip(indices, revisions) {
                let old = stamps[index]
                marked[old.revision] = revision
                stamps[index] = DraftStamp(revision: revision, origins: old.origins.union([.unknown]),
                                           contentHash: stepHash(draft.steps[index], in: draft) ?? old.contentHash)
            }
            if !indices.isEmpty { try writePlaylistStamps(stamps, home: home) }
            return marked
        }
    }
}
