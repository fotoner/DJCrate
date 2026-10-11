import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension DraftStore {
    /// 초안 폴더 하나(`home`, 앱은 DJCrate 데이터 폴더)의 초안 파일과 저장 큐 `writer`.
    /// 같은 파일(게인 초안 하나)을 쓰는 곳이 모두 같은 `writer`를 받아야 저장 순서가 지켜진다(조립 지점이 하나를 만들어 나눠 준다).
    public static func live(writer: DraftWriter, home: URL) -> DraftStore {
        let places = DraftLocations(home: home)
        return DraftStore(
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
                return stamps
            },
            preserveDamaged: { writer.preserveDamagedDrafts(home: home) },
            takeMovedFiles: { DamagedDrafts.take(home: home) },
            cueDraftUUIDs: { CueDraftStore.uuids(directory: places.cue) },
            cueDraft: { CueDraftStore.load(trackUUID: $0, directory: places.cue) },
            pendingCue: { writer.pendingCue(trackUUID: $0, directory: places.cue) },
            saveCue: { draft, completion in writer.save(draft, directory: places.cue, completion: completion) },
            gridDraftUUIDs: { GridDraftStore.uuids(directory: places.grid) },
            gridDraft: { GridDraftStore.load(trackUUID: $0, directory: places.grid) },
            pendingGrid: { writer.pendingGrid(trackUUID: $0, directory: places.grid) },
            saveGrid: { draft, completion in writer.save(draft, directory: places.grid, completion: completion) },
            gainDraftUUIDs: { GainDraftStore.uuids(url: places.gain) },
            gainDrafts: { try GainDraftStore.read(url: places.gain) },
            pendingGain: { writer.pendingGain(trackUUID: $0, url: places.gain) },
            saveGain: { gain, uuid, completion in writer.save(gain: gain, trackUUID: uuid, url: places.gain, completion: completion) },
            tagDraftUUIDs: { TagDraftStore.uuids(directory: places.tags) },
            tagDraft: { TagDraftStore.load(trackUUID: $0, directory: places.tags) },
            saveTags: { writer.save($0, directory: places.tags) },
            artworkDraftUUIDs: { ArtworkDraftStore.uuids(directory: places.artwork) },
            artworkDrafts: { ArtworkDraftStore.all(directory: places.artwork) },
            artworkEdit: { try ArtworkDraftStore.load(trackUUID: $0, directory: places.artwork) },
            saveArtwork: { try ArtworkDraftStore.save($0, directory: places.artwork) },
            removeArtwork: { try ArtworkDraftStore.remove(trackUUID: $0, directory: places.artwork) },
            playlistDraft: { PlaylistDraftStore.load(url: places.playlist) },
            savePlaylistDraft: { try PlaylistDraftStore.save($0, url: places.playlist) },
            mergeDrafts: { DuplicateMergeDraftStore.load(url: places.merge) },
            saveMergeDrafts: { try DuplicateMergeDraftStore.save($0, url: places.merge) },
            newCueID: { UUID() })
    }
}
