import DJCApplication
import DJCDomain
import Foundation

struct GridJob: Sendable {
    var done: Int
    var total: Int
}

/// 곡 추가(아직 rekordbox에 없는 곡) · 그리드 일괄 추정 · rekordbox XML 내보내기.
/// 넣기·넣기 결과 저장·재생 목록 연결·다시 읽을 때 가져온 뒤 확인·추정 규칙과 저장 순서는 유스케이스 `StageTracks`이고, 추가 목록 파일은
/// `StagingStore` 한 길로 쓴다. 여기서는 지금 목록(`staged`)을 들고 돌려받은 목록·결과를 목록·선택·진행 표시·안내에 맞춘다.
extension LibraryStore {
    // MARK: - 추가한 곡

    func loadStaged() {
        // 새 스냅샷에 추가한 곡과 같은 경로의 곡이 있으면(= rekordbox로 가져옴) 유스케이스가 그리드를 비교해 적어 저장한다.
        let reload = useCases.stage.reloadList(rows: rows, shareRoot: shareRoot, takingMovedFiles: location.movesDamagedDrafts)
        staged = reload.list
        if reload.saveError != nil { reportStagedSaveFailure(reload.saveError) } else { reportDraftFilesMovedBySave(reload.moved) }
        if let summary = reload.summary, stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(kind: summary.allMatched ? .success : .warning, text: summary.text)
        }
        resolvePlaylistImports()
        rebuildStagedRows()
        // 지난번에 추정을 마치지 못한 곡(그리드·키)을 이어서 한다.
        enqueueGrid(staged.filter { $0.bpm == nil || $0.needsKey }.map {
            GridJobItem(uuid: $0.uuid, path: $0.path, staged: true, grid: $0.bpm == nil)
        })
    }

    func rebuildStagedRows() {
        for row in stagedRows { rowsByID[row.id] = nil; rowsByUUID[row.track.uuid] = nil }
        stagedRows = staged.map {
            var row = TrackRow(track: $0.track, cues: [], playCount: 0, commentRule: commentPreset.rule)
            row.keyEstimated = $0.keyEstimated
            return row
        }
        for row in stagedRows { rowsByID[row.id] = row; rowsByUUID[row.track.uuid] = row }
        if case .staged = sidebar { refreshBase() }
    }

    /// 추가 목록 전체를 바꿔 저장한다(편집본 넣기가 `StagingStore`로 부른다: 화면이 든 목록과 디스크를 한 번에 맞춘다).
    /// 저장하지 못하면 목록은 그대로 두고 던진다. 저장이 손상된 옛 파일을 옮겼으면 넣은 뒤 `showStagedEdit`이 알린다.
    func saveStaged(_ tracks: [StagedTrack]) throws {
        _ = try useCases.stage.saveList(tracks, takingMovedFiles: false)
        staged = tracks
        rebuildStagedRows()
    }

    private func persistStaged() {
        do {
            reportDraftFilesMovedBySave(try useCases.stage.saveList(staged, takingMovedFiles: location.movesDamagedDrafts))
        } catch { reportStagedSaveFailure(error) }
    }

    private func reportStagedSaveFailure(_ error: (any Error)?) {
        guard let error else { return }
        stagingMessage = AppMessage(kind: .failure, text: String(ui: "추가한 곡 목록을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
    }

    /// 파일·폴더를 추가한다. 이미 rekordbox 컬렉션에 있는 파일은 건너뛴다
    /// (XML로 다시 가져오면 rekordbox의 기존 큐·그리드를 덮을 수 있다).
    func addFiles(_ urls: [URL], appleMusicOrigins: [String: [AppleMusicOrigin]] = [:],
                  createPlaylists: Bool = false, toPlaylist playlistID: String? = nil) async {
        guard writeLockPolicy.allowsLibraryInteraction,
              playlistID.map({ canEditTracks(of: $0) }) ?? true else { return }
        let stage = useCases.stage
        let files = stage.audioFiles(in: urls)
        guard !files.isEmpty else {
            stagingMessage = AppMessage(kind: .warning, text: String(ui: "추가할 음원이 없습니다. MP3·M4A·WAV·AIFF·FLAC 파일을 고르세요."))
            return
        }
        let addition = await stage.add(files, current: staged, library: rows, origins: appleMusicOrigins)
        // 태그를 읽는 동안 반영이 시작되면 추가 목록도 바꾸지 않는다.
        guard writeLockPolicy.allowsLibraryInteraction else { return }
        stagingMessage = nil
        // 읽는 동안 다른 곳(그리드 추정·편집본 넣기)이 고친 줄은 그대로 두고 결과만 얹어 저장하고, 재생 목록에 이으면 연결 기록을 더해 저장한다(유스케이스).
        let linksPlaylists = createPlaylists || playlistID != nil
        let commit = useCases.stage.commit(addition, onto: staged,
                                           link: linksPlaylists ? StageTracks.PlaylistLink(createPlaylists: createPlaylists, playlistID: playlistID,
                                                                                          origins: appleMusicOrigins) : nil,
                                           imports: playlistImports, importsLoadFailed: playlistImportsLoadFailed,
                                           takingMovedFiles: location.movesDamagedDrafts)
        if let list = commit.list {
            staged = list
            if commit.listSaveError != nil { reportStagedSaveFailure(commit.listSaveError) } else { reportDraftFilesMovedBySave(commit.moved) }
            rebuildStagedRows()
        }
        if let link = commit.link {
            if applyImportsChange(link) {
                resolvePlaylistImports()
            } else {
                stagingMessage = AppMessage(kind: .failure, text: playlistMessage?.text ?? String(ui: "재생 목록 연결을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요."))
            }
        }
        let summary = addition.summary(linksPlaylists: linksPlaylists)
        if stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(kind: summary.warning ? .warning : .success, text: summary.text)
        }
        // 넣은 곡은 목록에서 골라 보여 주기만 한다. 덱은 그대로 둔다(덱에 올리기는 더블클릭·⌘→, #93).
        if !addition.added.isEmpty || (!addition.stagedIDs.isEmpty && addition.libraryRows.isEmpty) {
            // 새 곡(또는 이미 추가한 곡)은 "추가한 곡"에서 고른다.
            sidebar = .staged
            selection = Set(addition.added.map(\.id) + addition.stagedIDs)
        } else if let first = addition.libraryRows.first {
            // rekordbox 곡: 지금 목록에 없으면 "전체"로 바꿔 고른다.
            if !displayRows.contains(where: { $0.id == first.id }) { sidebar = .filter(.all); search = "" }
            selection = Set(addition.libraryRows.map(\.id))
        }
        enqueueGrid(addition.added.map { GridJobItem(uuid: $0.uuid, path: $0.path, staged: true) })
    }

    func removeStaged(_ ids: Set<TrackRow.ID>) {
        let removing = staged.filter { ids.contains($0.id) }
        guard !removing.isEmpty else { return }
        var imports = playlistImports
        imports.removePending(paths: Set(removing.map(\.path)))
        guard savePlaylistImports(imports) else { return }
        let uuids = Set(removing.map(\.uuid))
        gridQueue.removeAll { uuids.contains($0.uuid) }
        stagingMessage = nil
        staged.removeAll { ids.contains($0.id) }
        persistStaged()
        selection.subtract(ids)
        rebuildStagedRows()
        refreshDeckTrack()
        if stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(text: String(ui: "\(removing.count)곡을 추가 목록에서 뺐습니다(파일은 그대로)."))
        }
    }

    /// rekordbox에 바로 넣은 곡을 추가 목록에서 뺀다(초안은 남긴다: 되돌리면 다시 붙는다). 뺀 곡을 돌려준다.
    func unstage(uuids: Set<String>) -> [StagedTrack] {
        let removing = staged.filter { uuids.contains($0.uuid) }
        guard !removing.isEmpty else { return [] }
        gridQueue.removeAll { uuids.contains($0.uuid) }
        staged.removeAll { uuids.contains($0.uuid) }
        persistStaged()
        selection.subtract(removing.map(\.id))
        rebuildStagedRows()
        return removing
    }

    /// 되돌린 곡을 추가 목록에 다시 넣는다(이미 있는 곡은 건너뜀). 넣은 곡 수.
    func restage(_ tracks: [StagedTrack]) -> Int {
        let known = Set(staged.map(\.uuid))
        let fresh = tracks.filter { !known.contains($0.uuid) }
        guard !fresh.isEmpty else { return 0 }
        staged += fresh
        persistStaged()
        rebuildStagedRows()
        return fresh.count
    }

    // MARK: - 가져오기 뒤 확인

    /// rekordbox로 가져온 게 확인된 곡을 추가 목록에서 뺀다(초안은 그대로 둔다).
    func removeImportedStaged() {
        let ids = Set(staged.filter { $0.importCheck != nil && $0.importCheck?.result != .pending }.map(\.id))
        removeStaged(ids)
    }

    // MARK: - 그리드 일괄 추정

    /// 초안이 없는 곡만 순서대로 추정해 그리드 초안으로 저장한다(rekordbox 시간축).
    func enqueueGrid(_ items: [GridJobItem]) {
        let queued = Set(gridQueue.map(\.uuid))
        let fresh = items.filter { !queued.contains($0.uuid) }
        guard !fresh.isEmpty else { return }
        gridQueue += fresh
        if gridJob == nil { gridJob = GridJob(done: 0, total: 0) }
        gridJob?.total += fresh.count
        if gridTask == nil {
            gridTask = Task { [weak self] in await self?.runGridQueue() }
        }
    }

    /// 지금 보이는 "BPM·그리드 없음" 곡을 모두 추정한다.
    func estimateGridsForDisplayedRows() {
        enqueueGrid(displayRows.filter { !$0.track.isStreaming }.map {
            GridJobItem(uuid: $0.track.uuid, path: $0.track.folderPath, staged: $0.isStaged)
        })
    }

    private func runGridQueue() async {
        while !gridQueue.isEmpty {
            let item = gridQueue.removeFirst()
            if item.grid { await estimateGrid(item) }
            // 키는 그리드 뒤에 본다(마디 창을 쓰려고).
            if item.staged { await findKey(item) }
            gridJob?.done += 1
        }
        gridJob = nil
        gridTask = nil
    }

    private func estimateGrid(_ item: GridJobItem) async {
        switch await useCases.stage.estimateGrid(item) {
        case let .existing(bpm):
            // 덱에서 이미 적용했거나 편집한 곡: 목록 BPM만 맞춘다.
            if item.staged { updateStaged(item.uuid, bpm: bpm, confident: nil) }
        case .skipped:
            break
        case let .saved(bpm, confident, failure):
            if let failure { reportLibraryError(failure.message) }
            draftChanged(trackUUID: item.uuid, kind: .grid, exists: true)
            if item.staged { updateStaged(item.uuid, bpm: bpm, confident: confident) }
            onGridDraftSaved?(item.uuid)
        }
    }

    private func updateStaged(_ uuid: String, bpm: Double?, confident: Bool?) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }) else { return }
        staged[index].bpm = bpm
        if let confident { staged[index].gridConfident = confident }
        persistStaged()
        rebuildStagedRows()
    }

    // MARK: - 추가한 곡 키

    /// 태그에 키가 없던 곡은 조성을 추정해 staged.json에 적어 둔다(다음 실행 때 다시 계산하지 않는다).
    private func findKey(_ item: GridJobItem) async {
        guard let track = staged.first(where: { $0.uuid == item.uuid }),
              let found = await useCases.stage.findKey(track) else { return }
        setStagedKey(uuid: item.uuid, key: found.key, source: found.source)
    }

    func setStagedKey(uuid: String, key: String?, source: StagedTrack.KeySource) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }) else { return }
        staged[index].key = key
        staged[index].keySource = source
        persistStaged()
        rebuildStagedRows()
    }

    /// 덱에서 추가한 곡의 그리드를 바꾸면 목록 BPM도 맞춘다.
    func stagedGridChanged(uuid: String, bpm: Double?) {
        guard let index = staged.firstIndex(where: { $0.uuid == uuid }), staged[index].bpm != bpm else { return }
        staged[index].bpm = bpm
        persistStaged()
        rebuildStagedRows()
    }

    // MARK: - 개발용 검증

    /// 개발용: `--add-files <경로,…>`로 곡을 추가하고, 그리드 추정이 끝나면 `--export-staged <파일>`로 내보낸다.
    /// `DJC_HOME`과 함께 써서 사용자 초안과 섞이지 않게 한다.
    func runLaunchStagingTest() {
        guard !launch.addFiles.isEmpty else { return }
        let urls = launch.addFiles, export = launch.exportStaged
        let useCases = useCases
        let log: @Sendable (String) -> Void = { useCases.log($0) }
        Task {
            await addFiles(urls)
            log("[staging] 추가: \(stagingMessage?.text ?? "")")
            while gridJob != nil { try? await Task.sleep(for: .milliseconds(300)) }
            for track in staged {
                let draft = useCases.stage.gridDraft(track.uuid)
                log("[staging] 추가한 곡 \(track.title) · BPM \(track.bpm.map { String(format: "%.2f", $0) } ?? "-") · 자신 \(track.gridConfident.map(String.init) ?? "-") · 키 \(track.key ?? "-")\(track.keySource.map { "(\($0.rawValue))" } ?? "") · 구간 \(draft?.segments.count ?? 0) · 첫 구간 \(draft?.segments.first.map { String(format: "%.3f초 %d박", $0.start, $0.firstBeatNumber) } ?? "-")")
            }
            if let export {
                do {
                    let result = try exportStaged(to: export)
                    log("[staging] 내보내기: \(result.count)곡 · 그리드 없음 \(result.withoutGrid) → \(export.path)")
                } catch {
                    log("[staging] 내보내기 실패: \(error)")
                }
            }
        }
    }

    // MARK: - rekordbox XML

    /// 키 초안이 있는 추가한 곡을 XML 내보내기에서 뺄 때 알리는 이유(유스케이스 `ExportXML`)
    static func stagedKeyDraftBlock(title: String) -> String { ExportXML.stagedKeyDraftBlock(title: title) }

    /// 추가한 곡을 rekordbox XML로 쓴다(유스케이스 `ExportXML.exportStaged`). 태그 초안과 그리드·큐 초안을 넣고, 키 초안이 있는 곡은 빼고 이유를 돌려준다.
    /// 반환: 내보낸 곡 수, 그리드가 없는 곡 수, 뺀 곡의 이유.
    func exportStaged(to url: URL, only ids: Set<TrackRow.ID>? = nil) throws -> (count: Int, withoutGrid: Int, skipped: [String]) {
        let exported = try useCases.exportXML.exportStaged(staged.filter { ids?.contains($0.id) ?? true }, tagDrafts: tagDrafts, to: url)
        return (exported.count, exported.withoutGrid, exported.skipped)
    }
}
