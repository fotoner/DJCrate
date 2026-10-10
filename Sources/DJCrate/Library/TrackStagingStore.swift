import DJCApplication
import DJCDomain
import Foundation
import Observation

struct GridJob: Sendable {
    var done: Int
    var total: Int
}

/// 곡 추가(아직 rekordbox에 없는 곡) · 그리드 일괄 추정 · rekordbox XML 내보내기(기능 조각, #252).
/// 사이드바 줄·목록 아래 막대·저장 창·Apple Music 가져오기·곡 편집 창·덱(`onStagedGridChange`)이 쓴다.
/// 넣기·넣기 결과 저장·재생 목록 연결·다시 읽을 때 가져온 뒤 확인·추정 규칙과 저장 순서는 유스케이스 `StageTracks`이고, 추가 목록 파일은
/// `StagingStore` 한 길로 쓴다. 여기서는 지금 목록(`staged`)을 들고 돌려받은 목록·결과를 목록·선택·진행 표시·안내에 맞춘다.
/// 핵심 `LibraryStore`의 `staging` 속성이다. 곡·사이드바·선택·초안 표시·쓰기 잠금은 핵심 것을 읽고 고친다(`library`).
@MainActor
@Observable
final class TrackStagingStore {
    /// 이 조각을 든 핵심. 핵심이 조각을 들고 있어 약하게 잡지 않는다. 확장 파일(+XMLExport·+StagedEdit)도 써서 `private`이 아니다
    @ObservationIgnored unowned let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    var staged: [StagedTrack] = []
    var stagedRows: [TrackRow] = []
    /// 백그라운드 그리드 추정 진행(끝나면 nil)
    var gridJob: GridJob? {
        didSet { if (oldValue == nil) != (gridJob == nil) { hasGridJob = gridJob != nil } }
    }
    /// 추정이 도는 중인지. 진행(`done`)이 오를 때마다가 아니라 시작·끝에만 바뀌어, 사이드바 본문은 이것만 읽고 진행 줄을 넣고 뺀다(#141).
    private(set) var hasGridJob = false
    var gridQueue: [GridJobItem] = []
    var gridTask: Task<Void, Never>?
    /// 라이브러리 XML 내보내기 진행(끝나면 nil, `TrackStagingStore+XMLExport.swift`). 그리드 추정처럼 줄은 시작·끝에만 넣고 뺀다.
    var xmlExportJob: LibraryXMLExportJob? {
        didSet { if (oldValue == nil) != (xmlExportJob == nil) { hasXMLExportJob = xmlExportJob != nil } }
    }
    private(set) var hasXMLExportJob = false
    @ObservationIgnored var xmlExportTask: Task<Void, Never>?
    /// 곡 추가·내보내기 결과 안내
    var stagingMessage: AppMessage? {
        didSet { if let stagingMessage { library.feedback.announce(stagingMessage) } }
    }

    /// 곡을 추가해도 되는지(rekordbox에 쓰는 동안은 추가 목록을 바꾸지 않는다, `WriteLockPolicy`)
    var allowsLibraryInteraction: Bool { library.writeLockPolicy.allowsLibraryInteraction }

    // MARK: - 추가한 곡

    func loadStaged() {
        // 새 스냅샷에 추가한 곡과 같은 경로의 곡이 있으면(= rekordbox로 가져옴) 유스케이스가 그리드를 비교해 적어 저장한다.
        let reload = library.useCases.stage.reloadList(rows: library.rows, shareRoot: library.shareRoot,
                                                       takingMovedFiles: library.location.movesDamagedDrafts)
        staged = reload.list
        if reload.saveError != nil { reportStagedSaveFailure(reload.saveError) } else { library.reportDraftFilesMovedBySave(reload.moved) }
        if let summary = reload.summary, stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(kind: summary.allMatched ? .success : .warning, text: summary.text)
        }
        library.playlists.resolvePlaylistImports()
        rebuildStagedRows()
        // 지난번에 추정을 마치지 못한 곡(그리드·키)을 이어서 한다.
        enqueueGrid(staged.filter { $0.bpm == nil || $0.needsKey }.map {
            GridJobItem(uuid: $0.uuid, path: $0.path, staged: true, grid: $0.bpm == nil)
        })
    }

    func rebuildStagedRows() {
        for row in stagedRows { library.rowsByID[row.id] = nil; library.rowsByUUID[row.track.uuid] = nil }
        stagedRows = staged.map {
            var row = TrackRow(track: $0.track, cues: [], playCount: 0, commentRule: library.commentPreset.rule)
            row.keyEstimated = $0.keyEstimated
            return row
        }
        for row in stagedRows { library.rowsByID[row.id] = row; library.rowsByUUID[row.track.uuid] = row }
        if case .staged = library.sidebar { library.refreshBase() }
    }

    /// 추가 목록 전체를 바꿔 저장한다(편집본 넣기가 `StagingStore`로 부른다: 화면이 든 목록과 디스크를 한 번에 맞춘다).
    /// 저장하지 못하면 목록은 그대로 두고 던진다. 저장이 손상된 옛 파일을 옮겼으면 넣은 뒤 `showStagedEdit`이 알린다.
    func saveStaged(_ tracks: [StagedTrack]) throws {
        _ = try library.useCases.stage.saveList(tracks, takingMovedFiles: false)
        staged = tracks
        rebuildStagedRows()
    }

    private func persistStaged() {
        do {
            library.reportDraftFilesMovedBySave(try library.useCases.stage.saveList(staged, takingMovedFiles: library.location.movesDamagedDrafts))
        } catch { reportStagedSaveFailure(error) }
    }

    private func reportStagedSaveFailure(_ error: (any Error)?) {
        guard let error else { return }
        stagingMessage = AppMessage(kind: .failure, text: String(ui: "추가한 곡 목록을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
    }

    /// 파일 선택 창·메뉴가 고른 파일을 추가하기 시작한다(MVVM-4). 기다리지 않는다. 돌려주는 손잡이는 시험이 기다린다.
    /// 조각은 핵심을 붙들지 않으므로 일은 핵심을 거쳐 부른다(끝날 때까지 핵심을 붙든다)
    @discardableResult
    func startAddingFiles(_ urls: [URL]) -> Task<Void, Never> { Task { [library] in await library.staging.addFiles(urls) } }

    /// 파일·폴더를 추가한다. 이미 rekordbox 컬렉션에 있는 파일은 건너뛴다
    /// (XML로 다시 가져오면 rekordbox의 기존 큐·그리드를 덮을 수 있다).
    func addFiles(_ urls: [URL], appleMusicOrigins: [String: [AppleMusicOrigin]] = [:],
                  createPlaylists: Bool = false, toPlaylist playlistID: String? = nil) async {
        guard library.writeLockPolicy.allowsLibraryInteraction,
              playlistID.map({ library.playlists.canEditTracks(of: $0) }) ?? true else { return }
        let stage = library.useCases.stage
        let files = stage.audioFiles(in: urls)
        guard !files.isEmpty else {
            stagingMessage = AppMessage(kind: .warning, text: String(ui: "추가할 음원이 없습니다. MP3·M4A·WAV·AIFF·FLAC 파일을 고르세요."))
            return
        }
        let addition = await stage.add(files, current: staged, library: library.rows, origins: appleMusicOrigins)
        // 태그를 읽는 동안 반영이 시작되면 추가 목록도 바꾸지 않는다.
        guard library.writeLockPolicy.allowsLibraryInteraction else { return }
        stagingMessage = nil
        // 읽는 동안 다른 곳(그리드 추정·편집본 넣기)이 고친 줄은 그대로 두고 결과만 얹어 저장하고, 재생 목록에 이으면 연결 기록을 더해 저장한다(유스케이스).
        let linksPlaylists = createPlaylists || playlistID != nil
        let playlists = library.playlists
        let commit = library.useCases.stage.commit(addition, onto: staged,
                                                   link: linksPlaylists ? StageTracks.PlaylistLink(createPlaylists: createPlaylists, playlistID: playlistID,
                                                                                                  origins: appleMusicOrigins) : nil,
                                                   imports: playlists.playlistImports, importsLoadFailed: playlists.playlistImportsLoadFailed,
                                                   takingMovedFiles: library.location.movesDamagedDrafts)
        if let list = commit.list {
            staged = list
            if commit.listSaveError != nil { reportStagedSaveFailure(commit.listSaveError) } else { library.reportDraftFilesMovedBySave(commit.moved) }
            rebuildStagedRows()
        }
        if let link = commit.link {
            if playlists.applyImportsChange(link) {
                playlists.resolvePlaylistImports()
            } else {
                stagingMessage = AppMessage(kind: .failure, text: playlists.playlistMessage?.text ?? String(ui: "재생 목록 연결을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요."))
            }
        }
        let summary = addition.summary(linksPlaylists: linksPlaylists)
        if stagingMessage?.kind != .failure {
            stagingMessage = AppMessage(kind: summary.warning ? .warning : .success, text: summary.text)
        }
        // 넣은 곡은 목록에서 골라 보여 주기만 한다. 덱은 그대로 둔다(덱에 올리기는 더블클릭·⌘→, #93).
        if !addition.added.isEmpty || (!addition.stagedIDs.isEmpty && addition.libraryRows.isEmpty) {
            // 새 곡(또는 이미 추가한 곡)은 "추가한 곡"에서 고른다.
            library.sidebar = .staged
            library.selection = Set(addition.added.map(\.id) + addition.stagedIDs)
        } else if let first = addition.libraryRows.first {
            // rekordbox 곡: 지금 목록에 없으면 "전체"로 바꿔 고른다.
            if !library.displayRows.contains(where: { $0.id == first.id }) { library.sidebar = .filter(.all); library.search = "" }
            library.selection = Set(addition.libraryRows.map(\.id))
        }
        enqueueGrid(addition.added.map { GridJobItem(uuid: $0.uuid, path: $0.path, staged: true) })
    }

    func removeStaged(_ ids: Set<TrackRow.ID>) {
        let removing = staged.filter { ids.contains($0.id) }
        guard !removing.isEmpty else { return }
        var imports = library.playlists.playlistImports
        imports.removePending(paths: Set(removing.map(\.path)))
        guard library.playlists.savePlaylistImports(imports) else { return }
        let uuids = Set(removing.map(\.uuid))
        gridQueue.removeAll { uuids.contains($0.uuid) }
        stagingMessage = nil
        staged.removeAll { ids.contains($0.id) }
        persistStaged()
        library.selection.subtract(ids)
        rebuildStagedRows()
        library.refreshDeckTrack()
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
        library.selection.subtract(removing.map(\.id))
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
            // 도는 동안은 핵심을 붙든다(조각은 핵심을 unowned로만 본다. 옛 저장소의 일과 같은 수명)
            gridTask = Task { [weak library] in
                guard let library else { return }
                await library.staging.runGridQueue()
                withExtendedLifetime(library) {}
            }
        }
    }

    /// 지금 보이는 "BPM·그리드 없음" 곡을 모두 추정한다.
    func estimateGridsForDisplayedRows() {
        enqueueGrid(library.displayRows.filter { !$0.track.isStreaming }.map {
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
        switch await library.useCases.stage.estimateGrid(item) {
        case let .existing(bpm):
            // 덱에서 이미 적용했거나 편집한 곡: 목록 BPM만 맞춘다.
            if item.staged { updateStaged(item.uuid, bpm: bpm, confident: nil) }
        case .skipped:
            break
        case let .saved(bpm, confident, failure):
            if let failure { library.reportLibraryError(failure.message) }
            library.draftChanged(trackUUID: item.uuid, kind: .grid, exists: true)
            if item.staged { updateStaged(item.uuid, bpm: bpm, confident: confident) }
            library.onGridDraftSaved?(item.uuid)
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
              let found = await library.useCases.stage.findKey(track) else { return }
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
        guard !library.launch.addFiles.isEmpty else { return }
        let urls = library.launch.addFiles, export = library.launch.exportStaged
        let useCases = library.useCases
        let log: @Sendable (String) -> Void = { useCases.log($0) }
        Task { [library] in
            await library.staging.addFiles(urls)
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
        let exported = try library.useCases.exportXML.exportStaged(staged.filter { ids?.contains($0.id) ?? true }, tagDrafts: library.tagDrafts, to: url)
        return (exported.count, exported.withoutGrid, exported.skipped)
    }
}
