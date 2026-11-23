import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension DraftStore {
    /// 초안 폴더 하나(`home`, 앱은 DJCrate 데이터 폴더)의 초안 파일과 저장 큐 `writer`.
    /// 같은 파일(게인 초안 하나)을 쓰는 곳이 모두 같은 `writer`를 받아야 저장 순서가 지켜진다(조립 지점이 하나를 만들어 나눠 준다).
    /// 저장하는 초안에는 `origin`과 새 판·내용 해시를 도장으로 적는다(`StampedDrafts`, 초안 폴더 옆 `draft-stamps/`). 출처는 조립 지점이 정한다:
    /// 앱의 편집 포트는 사람 편집, CLI는 CLI. 정하지 않은 포트는 모름이라 그 초안은 제안이다(R5)
    public static func live(writer: DraftWriter, home: URL, origin: DraftOrigin = .unknown) -> DraftStore {
        let places = DraftLocations(home: home)
        var store = DraftStore(
            flush: { writer.flush() },
            saveRevision: { writer.saveRevision(in: places) },
            failures: { writer.failures(in: places) },
            unsavedUUIDs: { writer.unsavedUUIDs(in: places) },
            unsaved: {
                var unsaved = UnsavedDrafts()
                for uuid in writer.unsavedUUIDs(in: places) {
                    if let gain = writer.pendingGain(trackUUID: uuid, url: places.gain) { unsaved.gains[uuid] = gain }
                    if let draft = writer.pendingCue(trackUUID: uuid, directory: places.cue) { unsaved.cues[uuid] = draft }
                    if let draft = writer.pendingGrid(trackUUID: uuid, directory: places.grid) { unsaved.grids[uuid] = draft }
                }
                return unsaved
            },
            failedTagSaves: { writer.failedTagSaveUUIDs(in: places.tags) },
            retry: { kind, uuid, completion in writer.retry(kind, trackUUID: uuid, directory: places.url(kind), completion: completion) },
            isResolved: { failure in writer.isResolved(failure, directory: places.url(failure.kind)) },
            fileStamps: {
                var stamps: [String: Date] = [:]
                for directory in [places.cue, places.tags, places.grid, places.artwork] {
                    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    for file in files where file.pathExtension == "json" {
                        stamps[file.path] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    }
                }
                // 재생 목록 초안 파일도 CLI(`djc draft playlist`)가 바꾼다(#260).
                // 같은 URL 값은 Foundation이 처음 읽은 시각을 캐시해 두 번째 변경부터 놓친다. 매번 캐시를 비우고 읽는다.
                var playlist = places.playlist
                playlist.removeAllCachedResourceValues()
                if let date = (try? playlist.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    stamps[places.playlist.path] = date
                }
                return stamps
            },
            preserveDamaged: { writer.preserveDamagedDrafts(home: home) },
            takeMovedFiles: { DamagedDrafts.take(home: home) },
            cueDraftUUIDs: { CueDraftStore.uuids(directory: places.cue) },
            cueDraft: { CueDraftStore.load(trackUUID: $0, directory: places.cue) },
            pendingCue: { writer.pendingCue(trackUUID: $0, directory: places.cue) },
            saveCue: { draft, completion in
                writer.save(draft, directory: places.cue, write: { try StampedDrafts.saveCue($0, directory: $1, origin: origin) }, completion: completion)
            },
            gridDraftUUIDs: { GridDraftStore.uuids(directory: places.grid) },
            gridDraft: { GridDraftStore.load(trackUUID: $0, directory: places.grid) },
            pendingGrid: { writer.pendingGrid(trackUUID: $0, directory: places.grid) },
            saveGrid: { draft, completion in
                writer.save(draft, directory: places.grid, write: { try StampedDrafts.saveGrid($0, directory: $1, origin: origin) }, completion: completion)
            },
            gainDraftUUIDs: { GainDraftStore.uuids(url: places.gain) },
            gainDrafts: { try GainDraftStore.read(url: places.gain) },
            pendingGain: { writer.pendingGain(trackUUID: $0, url: places.gain) },
            saveGain: { gain, uuid, completion in
                writer.save(gain: gain, trackUUID: uuid, url: places.gain,
                            write: { try StampedDrafts.saveGain($0, trackUUID: $1, url: $2, origin: origin) }, completion: completion)
            },
            tagDraftUUIDs: { TagDraftStore.uuids(directory: places.tags) },
            tagDraft: { TagDraftStore.load(trackUUID: $0, directory: places.tags) },
            saveTags: { writer.save($0, directory: places.tags, write: { try StampedDrafts.saveTag($0, directory: $1, origin: origin) }) },
            artworkDraftUUIDs: { ArtworkDraftStore.uuids(directory: places.artwork) },
            artworkDrafts: { ArtworkDraftStore.all(directory: places.artwork) },
            artworkEdit: { try ArtworkDraftStore.load(trackUUID: $0, directory: places.artwork) },
            saveArtwork: { try StampedDrafts.saveArtwork($0, directory: places.artwork, origin: origin) },
            removeArtwork: { try StampedDrafts.removeArtwork(trackUUID: $0, directory: places.artwork) },
            // 읽을 때 단계 식별자를 채운다: 앱이 메모리에 받는 초안의 단계가 식별자를 가져야 저장이 새 단계로 보지 않는다(R5·R22).
            // 식별자를 적지 못하면 읽기는 던진다(`readPlaylistDraft`, 지금의 읽기 실패). 던지지 않는 읽기는 식별자 없는 초안 대신 메모리에서만
            // 식별자를 준 초안을 돌려준다
            playlistDraft: {
                (try? StampedDrafts.identifiedPlaylist(home: home))
                    ?? StampedDrafts.withEphemeralIdentifiers(PlaylistDraftStore.load(url: places.playlist))
            },
            readPlaylistDraft: { try StampedDrafts.identifiedPlaylist(home: home) },
            savePlaylistDraft: { try StampedDrafts.savePlaylist($0, url: places.playlist, origin: origin) },
            mergeDrafts: { DuplicateMergeDraftStore.load(url: places.merge) },
            saveMergeDrafts: { try StampedDrafts.saveMerges($0, url: places.merge, origin: origin) },
            newCueID: { UUID() })
        store.lockPlaylistDraft = { PlaylistDraftLock.acquire(PlaylistDraftLock.url(for: places.playlist), wait: $0) }
        // 출처·판(R5·R22): 도장은 사이드카에서 읽고, 판 지정 삭제는 저장 큐에서 앞서 걸린 저장 뒤에 초안 잠금 안에서 한다
        store.origin = origin
        store.originVariant = { live(writer: writer, home: home, origin: $0) }
        store.stamp = { DraftStampStore.stamp($0, home: home) }
        store.playlistStamps = { StampedDrafts.playlistStamps(home: home) }
        store.removeWritten = { written in
            let result = try writer.serialized { try StampedDrafts.removeWritten(written, home: home) }
            return DraftRemoval(removed: result.removed, suggested: result.suggested, kept: result.kept)
        }
        store.markSuggestions = { drafts, steps in
            try writer.serialized { try StampedDrafts.markSuggestions(drafts, playlistSteps: steps, home: home) }
        }
        store.removeWrittenSteps = { cleanup in
            let result = try writer.serialized {
                try StampedDrafts.removeWrittenSteps(cleanup.written.map { ($0.revision, $0.contentHash) }, newPlaylistIDs: cleanup.newPlaylistIDs,
                                                     copyFolder: cleanup.copyFolder, home: home)
            }
            return PlaylistStepRemoval(removed: result.removed, copied: result.copied, copyFailed: result.copyFailed, notFound: result.notFound)
        }
        return store
    }
}
