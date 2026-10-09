import DJCApplication
import DJCDomain
import Foundation

/// 읽지 못한 초안 파일과 재생 목록 초안 저장 실패(#174).
/// 손상된 파일은 지우지 않고 `damaged-drafts`에 옮겨 알리고, 메모리에 남은 입력은 다시 저장한다.
extension LibraryStore {
    /// 옮긴 초안 파일을 알린다(닫을 때까지 남고, 그사이 더 옮기면 수를 더한다).
    /// 추가 목록(`staged.json`)은 초안이 아니라 곡 파일 경로의 목록이라 파일 수에 세지 않고 다시 추가할 일을 따로 안내한다(#178).
    func reportDamagedDrafts(_ entries: [DamagedDraftFile]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            guard let uuid = entry.trackUUID else { continue }
            let kind: WritePart?
            switch entry.kind {
            case .cue: kind = .cue
            case .grid: kind = .grid
            case .tag: kind = .tag
            case .artwork: kind = .artwork
            default: kind = nil
            }
            if let kind { unreadableDraftKinds[uuid, default: []].insert(kind) }
        }
        let fresh = draftFileMessage == nil
        let drafts = entries.filter { $0.kind != .staged }
        damagedDraftCount = (fresh ? 0 : damagedDraftCount) + drafts.count
        damagedStagedList = (fresh ? false : damagedStagedList) || drafts.count < entries.count
        useCases.log("[초안 파일] 읽지 못해 옮긴 파일 \(entries.count)개: \(entries.map(\.name).joined(separator: ", "))")
        draftFileMessage = AppMessage(kind: .warning, text: Self.damagedDraftText(damagedDraftCount, stagedList: damagedStagedList))
    }

    static func damagedDraftText(_ count: Int, stagedList: Bool = false) -> String {
        var sentences: [String] = []
        if count > 0 {
            sentences.append(String(ui: "초안 파일 \(count)개를 읽지 못해 DJCrate 데이터 폴더의 damaged-drafts에 옮겨 두었으니 필요한 곡의 초안을 다시 만드세요."))
        }
        if stagedList {
            sentences.append(String(ui: "추가한 곡 목록 파일을 읽지 못해 DJCrate 데이터 폴더의 damaged-drafts에 옮겨 두었으니 추가했던 곡 파일을 다시 추가하세요."))
        }
        return sentences.joined(separator: " ")
    }

    /// 합치기 초안·추가 목록 저장이 손상된 기존 파일을 옮겼으면(`moved`, 저장한 유스케이스가 가져왔다) 알린다.
    /// 메모리 값으로 새 파일을 썼으니 그 목록이 비어 있지 않으면 잃은 것이 없어 알리지 않는다.
    func reportDraftFilesMovedBySave(_ moved: [DamagedDraftFile]) {
        applyMovedDrafts(moved.filter {
            switch $0.kind {
            case .staged: staged.isEmpty
            case .merge: mergeDrafts.isEmpty
            default: true
            }
        })
    }

    /// 데이터 폴더의 손상된 초안 파일을 옮기고 알린다. 메모리에 남은 태그·재생 목록 초안은 다시 저장하고, 옮긴 초안의 표시를 거둔다.
    /// - Returns: 옮긴 파일
    @discardableResult
    func preserveDamagedDraftFiles(previousTags: [String: TagDraft]? = nil,
                                   previousPlaylist: PlaylistDraft? = nil) -> [DamagedDraftFile] {
        guard location.movesDamagedDrafts else { return [] }
        let moved = useCases.watch.preserveDamaged()
        applyMovedDrafts(moved, previousTags: previousTags, previousPlaylist: previousPlaylist)
        return moved
    }

    /// 옮긴 파일을 화면 상태에 반영한다. 메모리 입력(태그·재생 목록)은 유스케이스가 다시 저장해 잃지 않고(`WatchDrafts.recoverMoved`),
    /// 여기서는 메모리 초안과 표시를 맞춘다.
    func applyMovedDrafts(_ moved: [DamagedDraftFile], previousTags: [String: TagDraft]? = nil,
                          previousPlaylist: PlaylistDraft? = nil, reporting: Bool = true) {
        guard !moved.isEmpty else { return }
        if reporting { reportDamagedDrafts(moved) }
        let recovery = useCases.watch.recoverMoved(moved, memoryTags: previousTags ?? tagDrafts, memoryPlaylist: previousPlaylist ?? playlistDraft)
        for step in recovery.steps {
            switch step {
            case let .keepTag(draft): tagDrafts[draft.trackUUID] = draft
            case let .clearCue(uuid):
                draftCueCounts[uuid] = nil
                draftChanged(trackUUID: uuid, kind: .cue, exists: false)
            case let .clearGrid(uuid): draftChanged(trackUUID: uuid, kind: .grid, exists: false)
            case let .clearArtwork(uuid):
                artworkDrafts[uuid] = nil
                updateEdited(uuid)
            }
        }
        if !recovery.resavedTags.isEmpty {
            rememberTagSaves(recovery.resavedTags)
            tagRevision += 1
        }
        if let gains = recovery.gainDraftUUIDs { applyGainDraftUUIDs(gains) }
        if let playlist = recovery.playlist {
            playlistDraft = playlist.draft
            applyPlaylistSave(playlist.error)
            refreshPlaylists()
        }
    }

    /// 디스크와 저장하지 못한 입력을 합친 게인 초안 곡(유스케이스가 센다)
    func refreshGainDraftUUIDs() { applyGainDraftUUIDs(useCases.watch.gainDraftUUIDs()) }

    private func applyGainDraftUUIDs(_ uuids: Set<String>) {
        for uuid in uuids.symmetricDifference(gainDraftUUIDs) {
            draftChanged(trackUUID: uuid, kind: .gain, exists: uuids.contains(uuid))
        }
    }

    // MARK: - 재생 목록 초안 저장

    static var playlistSaveFailureText: String { ReflectionSession.playlistSaveFailureText }

    /// 메모리 초안을 저장한다. 실패하면 메모리 초안을 그대로 두고 기록해, 쓰기 전에 다시 저장한다.
    @discardableResult
    func savePlaylistDraft() -> Bool {
        do {
            try useCases.playlists.saveDraft(playlistDraft)
            applyPlaylistSave(nil)
            return true
        } catch {
            applyPlaylistSave(error)
            return false
        }
    }

    /// 메모리 초안을 저장한 결과(`error`가 nil이면 저장했다)를 표시에 맞춘다. 실패면 쓰기 전에 다시 저장하도록 기록한다(#174)
    func applyPlaylistSave(_ error: (any Error)?) {
        if let error {
            playlistDraftUnsaved = true
            AppErrorMessage.log(error)
            playlistMessage = AppMessage(kind: .warning, text: Self.playlistSaveFailureText)
        } else {
            playlistDraftUnsaved = false
            if playlistMessage?.text == Self.playlistSaveFailureText { playlistMessage = nil }
        }
    }

    /// 쓰기 전에: 저장하지 못한 재생 목록 초안은 다시 저장해 본다. 저장했거나 저장할 것이 없으면 true(아니면 쓰기가 막는다).
    func ensurePlaylistDraftSaved() -> Bool {
        guard playlistDraftUnsaved else { return true }
        return savePlaylistDraft()
    }
}
