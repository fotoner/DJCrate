import DJCAdapters
import DJCApplication
import RekordboxKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import Foundation

// 개발용 자가 시험은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 디버그 앱에서만 받는 자가 시험 인자를 연결한다.
@MainActor
enum DevSelfTests {
    static func runIfRequested(store: LibraryStore, deck: DeckModel, windows: AppWindows, reflection: ReflectionCoordinator,
                               playlistSidebar: PlaylistSidebarModel, libraryWindow: LibraryWindowModel, statusBar: StatusBarModel,
                               rekordboxRun: RekordboxRunModel) {
        if DiagnosticRun.isCopySelfTest() { AutoReflectAppSelfTest.stopSplitViewAutosave() }
        runITunesSelfTestIfRequested(store: store, deck: deck)
        runSearchLayoutIfRequested(store: store, libraryWindow: libraryWindow)
        runReflectionLayoutIfRequested(store: store, libraryWindow: libraryWindow, statusBar: statusBar, rekordboxRun: rekordboxRun)
        Issue237Capture.runIfRequested(store: store)
        ColumnHeaderCapture.runIfRequested(store: store)
        UsbDragCapture.runIfRequested(store: store)
        UsbDeckCapture.runIfRequested(store: store)
        runDuplicateLayoutIfRequested(store: store)
        runDraftNoticeCaptureIfRequested(store: store, libraryWindow: libraryWindow)
        runXMLExportCaptureIfRequested(store: store)
        runXMLImportCaptureIfRequested(store: store, libraryWindow: libraryWindow)
        runPlaylistRecoveryIfRequested(store: store, reflection: reflection)
        runWriteSelfTestIfRequested(store: store, deck: deck, reflection: reflection, playlistSidebar: playlistSidebar)
        QuitWaitSelfTest.runIfRequested(store: store, reflection: reflection)
        AutoReflectAppSelfTest.runIfRequested(store: store, deck: deck, reflection: reflection)
        SidebarMultiCapture.runIfRequested(store: store, sidebar: playlistSidebar, reflection: reflection)
        HistorySelfTest.runIfRequested(store: store, reflection: reflection)
        runTrackSelfTestIfRequested(store: store)
        runLoopSelfTestIfRequested(deck: deck)
        runScrollPerfIfRequested(deck: deck)
        UIPerfSelfTest.runIfRequested(store: store, deck: deck, windows: windows, reflection: reflection, playlistSidebar: playlistSidebar)
        ResizePerfSelfTest.runIfRequested(store: store, deck: deck)
        runLoopAudioSelfTestIfRequested()
        runHotCueClickSelfTestIfRequested(store: store, deck: deck)
        runPausedHotCueSelfTestIfRequested(store: store, deck: deck)
        runScrubHotCueSelfTestIfRequested(store: store, deck: deck)
        runJumpAudioSelfTestIfRequested()
        runFlipSelfTestIfRequested()
        runMetronomeSelfTestIfRequested()
        UsbSelfTest.runIfRequested(store: store)
        if ProcessInfo.processInfo.arguments.contains("--switch-selftest") {
            Task {
                guard await loadSelfTestLibrary(store) else { exit(1) }
                exit(await switchSelfTestExitCode(store: store, deck: deck))
            }
        }
    }

    /// 쓰기 시험 전에 CLI가 쌓아 둔 재생 목록 초안(시험과 같은 모양: 맨 위 새 폴더 안 새 목록, 있던 목록에 곡 하나). 초안이 없으면 nil
    static func externalSelfTestPlaylists(_ store: LibraryStore) -> (list: String?, extended: (id: String, before: [String], added: String)?)? {
        let draft = store.playlists.playlistDraft
        guard !draft.isEmpty else { return nil }
        let layout = store.playlists.playlistProjection.layout
        let list = layout.outline.first { $0.name == "DJC 시험 목록" && $0.isNew }?.id
        let extended = draft.edits.lazy.compactMap { edit -> (id: String, before: [String], added: String)? in
            guard case let .addTracks(.id(id), ids) = edit, let first = ids.first, let item = store.playlists.rekordboxPlaylists.item(id) else { return nil }
            return (id, item.trackIDs, first)
        }.first
        return (list, extended)
    }

    /// 개발용: 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)와 사본 초안(`DJC_HOME`)으로
    /// 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기 → 초안 복구를 앱 흐름 그대로 해 본다(`--write-selftest`).
    /// 재생 목록 초안도 만들어(맨 위에 폴더 → 그 안에 목록 + 곡, 있던 목록에 곡 하나) 함께 쓰고 되돌린다.
    /// `DJC_HOME`에 재생 목록 초안이 이미 있으면(CLI `djc draft playlist`로 같은 모양을 쌓음) 만들지 않고 그것을 쓴다.
    static func runWriteSelfTestIfRequested(store: LibraryStore, deck: DeckModel, reflection: ReflectionCoordinator,
                                            playlistSidebar: PlaylistSidebarModel) {
        guard ProcessInfo.processInfo.arguments.contains("--write-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[쓰기 시험] \(text)\n".utf8)) }
        Task {
            guard await loadSelfTestLibrary(store) else { log("사본을 읽지 못했습니다"); exit(1) }
            let code = await selfTestExitCode(passLine: "쓰기·되돌림 시험 통과", log: log) {
                try await runWriteSelfTest(store: store, deck: deck, session: reflection.session, playlistSidebar: playlistSidebar, log: log)
            }
            exit(code)
        }
    }

    static func runWriteSelfTest(store: LibraryStore, deck: DeckModel, session: ReflectionSession, playlistSidebar: PlaylistSidebarModel,
                                 log: (String) -> Void) async throws {
        func check(_ ok: Bool, _ text: String) throws {
            log(text)
            if !ok { throw SelfTestMismatch(text) }
        }
        let locations = DraftLocations(home: store.draftFolder)
        let before = store.rowsByUUID
        let playlistsBefore = store.playlists.rekordboxPlaylists
        // CLI가 준비한 편집이 없으면 분석 파일이 있는 합성 곡에 큐와 그리드 초안을 만든다.
        if let row = store.rows.first(where: { RekordboxShare.hasWaveformAnalysis($0.track.analysisDataPath, root: store.shareRoot) }),
           let url = RekordboxShare.analysisURL(row.track.analysisDataPath, root: store.shareRoot) {
            if store.cueDraftUUIDs.isEmpty {
                var cue = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues)
                cue.place(EditableCue(id: UUID(), kind: .memory, time: 1.25))
                try CueDraftStore.save(cue, directory: locations.cue)
                store.draftChanged(trackUUID: row.track.uuid, kind: .cue, exists: true)
            }
            if store.gridDraftUUIDs.isEmpty {
                var grid = GridDraft(trackUUID: row.track.uuid, grid: try BeatGrid.load(anlz: url))
                grid.shift(by: 0.02)
                try GridDraftStore.save(grid, directory: locations.grid)
                store.draftChanged(trackUUID: row.track.uuid, kind: .grid, exists: true)
            }
        }
        // 그림 초안(#66): 그림 없는 분석한 곡에 넣기, 그림 있는 곡에 지우기(지울 옛 그림 바이트는 되돌린 뒤 비교한다)
        let analysed = store.rows.filter { EditArtwork.canEdit($0) && !($0.track.analysisDataPath ?? "").isEmpty }
        let artworkAdd = analysed.first { !store.artworkBase(for: $0).hasArtwork }
        let artworkDelete = analysed.first { store.artworkBase(for: $0).hasArtwork }
        let artworkNames = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]
        func artworkFiles(_ row: TrackRow) -> [URL] {
            let folder = store.shareRoot.appending(path: String(TrackArtwork.folder(uuid: row.track.uuid).dropFirst()))
            return artworkNames.map { folder.appending(path: $0) }
        }
        let deletedOriginals = try artworkDelete.map { try artworkFiles($0).map { try Data(contentsOf: $0) } } ?? []
        // 인스펙터 그림 칸과 같은 화면 모델로 만든다(안내는 쓰지 않는다)
        let artwork = ArtworkInspectorModel(store: store)
        if let row = artworkAdd { artwork.setArtwork(Self.selfTestArtwork(), name: "DJC 시험 그림.jpg", rows: [row]) }
        if let row = artworkDelete { artwork.deleteArtwork(rows: [row]) }
        log("그림 초안: 넣기 \(artworkAdd.map { _ in "1곡" } ?? "없음") · 지우기 \(artworkDelete.map { _ in "1곡" } ?? "없음") · 초안 \(store.artworkDrafts.count)곡")
        // 평점·곡 색 초안(#65): 쓰기를 확인한 곡(상태 0·256·257, 재생 목록에 든 곡도 R65로 열림) 하나에 별 4개·두 번째 색(rekordbox Red)
        let rated = store.rows.first { !$0.isStaged && !$0.track.isStreaming && TrackListTagEditing.unavailableReason($0, key: .rating) == nil }
        let ratedBefore = rated.map { ($0.track.rating, $0.track.colorID) }
        // 지금 값과 다른 값을 고른다(같으면 초안이 생기지 않는다)
        let ratingValue = rated?.track.rating == 4 ? "5" : "4", colorValue = rated?.track.colorID == "2" ? "7" : "2"
        if let rated {
            store.tags.setTag(.rating, ratingValue, rows: [rated])
            store.tags.setTag(.color, colorValue, rows: [rated])
        }
        log("평점·곡 색 초안: \(rated.map { _ in "1곡(별 \(ratingValue)개·색 \(colorValue))" } ?? "쓸 수 있는 곡 없음")")
        let targets = store.writeTargets(store.rows)
        log("반영 대기 \(store.pendingLibraryCount)곡 · 대상 \(targets.count)곡")
        // 재생 목록 초안: 새 폴더 안에 새 목록(곡 셋), 있던 목록 하나에 곡 하나
        let playable = store.rows.filter { !$0.isStaged && !$0.track.isStreaming }
        var list: String?
        var extended: (id: String, before: [String], added: String)?
        if let external = Self.externalSelfTestPlaylists(store) {
            // CLI(`djc draft playlist`)로 같은 편집을 미리 쌓았으면 그 초안을 그대로 쓴다(#260: 앱 편집과 같게 쓰이는지 본다)
            (list, extended) = (external.list, external.extended)
            log("재생 목록 초안: 바깥(CLI) 초안을 씀")
        } else {
            let folder = store.playlists.createPlaylist(isFolder: true, in: PlaylistLayout.root, name: "DJC 시험 폴더")
            list = folder.flatMap { store.playlists.createPlaylist(isFolder: false, in: $0, name: "DJC 시험 목록", tracks: Array(playable.prefix(3))) }
            if let existing = store.playlists.rekordboxPlaylists.outline.first(where: { $0.holdsTracks }),
               let track = playable.first(where: { !existing.trackIDs.contains($0.track.id) }) {
                store.playlists.addTracks([track], toPlaylist: existing.id)
                extended = (existing.id, existing.trackIDs, track.track.id)
            }
        }
        playlistSidebar.cancelRenaming()
        let playlistEdits = store.playlists.playlistDraft.edits.count
        log("재생 목록 초안: 편집 \(playlistEdits)건 · 새 목록 \(list ?? "-") · 있던 목록에 넣기 \(extended == nil ? "없음" : "있음")")
        // 큐를 쓰는 곡을 올려 둬야 쓴 뒤 덱이 새 큐를 읽었는지 확인할 수 있다.
        guard let cueTarget = targets.first(where: { store.cueDraftUUIDs.contains($0.track.uuid) }) else {
            throw SelfTestMismatch("덱에 올릴 큐 대상 곡이 없습니다")
        }
        store.selection = [cueTarget.id]
        store.loadToDeck(cueTarget)
        try check(deck.row?.id == cueTarget.id, "덱에 큐 대상 곡 올리기")
        let playlistDraft = store.playlists.playlistDraft
        let projectedTracks = list.flatMap { store.playlists.playlistProjection.layout.item($0)?.trackIDs }
        defer { store.setWriteLock(false) }
        store.setWriteLock(true)
        let preview = try await session.previewWrite(rows: targets, playlists: true)
        log("미리 보기 재생 목록: 씀 \(preview.report.playlistWritten.count)건 · 막힘 \(preview.report.playlistBlocked.count)건")
        for o in preview.report.playlistBlocked { log("  막힘 \(o.name): \(o.reason ?? "")") }
        log("미리 보기: 큐 \(preview.report.written.count)곡 · 그리드 \(preview.report.gridWritten.count)곡 · 막힘 큐 \(preview.report.blocked.count) · 그리드 \(preview.report.gridBlocked.count)")
        for o in preview.report.blocked + preview.report.gridBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
        log("미리 보기 분석 붙이기: \(preview.report.analysisWritten.count)곡 · 막힘 \(preview.report.analysisBlocked.count)")
        for o in preview.report.analysisBlocked { log("  막힘 \(o.title): \(o.reason ?? "")") }
        guard let batch = preview.writeRequest, !batch.drafts.isEmpty, !batch.grids.isEmpty, !batch.tags.isEmpty,
              batch.drafts.contains(where: { $0.trackUUID == cueTarget.track.uuid }),
              let artworkAdd, let artworkDelete, let extended, let projectedTracks, !projectedTracks.isEmpty,
              batch.artworks.count == 2, batch.playlists == playlistDraft, rated != nil,
              preview.exclusions.isEmpty, batch.draftKeys == preview.batch.draftKeys else {
            throw SelfTestMismatch("큐·그리드·태그·그림·재생 목록의 쓰기 대상이 부족하거나 막혔습니다")
        }
        let gridPlans = try batch.grids.map { draft in
            guard let row = before[draft.trackUUID] else { throw SelfTestMismatch("그리드 대상이 없습니다") }
            let file = try AVAudioFile(forReading: URL(filePath: row.track.folderPath))
            let duration = Double(file.length) / file.processingFormat.sampleRate + RekordboxTimeline.predictedOffset(url: file.url)
            return (draft, draft.grid(duration: duration))
        }
        var analysisBefore: [URL: Data] = [:]
        for draft in batch.grids {
            if let url = before[draft.trackUUID].flatMap({ RekordboxShare.analysisURL($0.track.analysisDataPath, root: store.shareRoot) }) {
                for file in [url, url.deletingPathExtension().appendingPathExtension("EXT")] { analysisBefore[file] = try Data(contentsOf: file) }
            }
        }
        let report = try await session.writeDrafts(batch, to: session.target)
        store.setWriteLock(false)
        let rekordbox = store.playlists.rekordboxPlaylists
        let newFolder = rekordbox.outline.first { $0.name == "DJC 시험 폴더" && $0.isFolder && $0.parentID == PlaylistLayout.root }
        let newList = newFolder.flatMap { record in rekordbox.children(of: record.id).first { $0.name == "DJC 시험 목록" } }
        try check(report.playlistWritten.count == playlistEdits && newList?.trackIDs == projectedTracks
            && rekordbox.item(extended.id)?.trackIDs == extended.before + [extended.added] && store.playlists.playlistDraft.isEmpty,
            "재생 목록 쓰기 · 편집 \(report.playlistWritten.count)/\(playlistEdits)건")
        for draft in batch.drafts {
            guard let row = store.rowsByUUID[draft.trackUUID] else { throw SelfTestMismatch("큐 대상이 없습니다") }
            let now = CueDraft(trackUUID: draft.trackUUID, rekordboxCues: row.cues)
            try check(RekordboxWriter.key(now.cues, withSource: false) == RekordboxWriter.key(RekordboxWriter.expectedCues(after: draft), withSource: false),
                      "큐 쓰기 · 다시 읽은 큐 \(now.cues.count)개")
        }
        await deck.softReloadTask?.value
        guard let cueRow = store.rowsByUUID[cueTarget.track.uuid], let deckDraft = deck.draft else {
            throw SelfTestMismatch("덱 큐 갱신 · 다시 읽은 큐가 없습니다")
        }
        let reread = CueDraft(trackUUID: cueRow.track.uuid, rekordboxCues: cueRow.cues)
        try check(deck.row?.id == cueRow.id && deckDraft.trackUUID == cueRow.track.uuid && !deckDraft.hasChanges
            && RekordboxWriter.key(deckDraft.base, withSource: true) == RekordboxWriter.key(reread.base, withSource: true),
            "덱 큐 갱신 · 다시 읽은 기준 큐 \(deckDraft.base.count)개")
        for (draft, expected) in gridPlans {
            guard let row = store.rowsByUUID[draft.trackUUID], let url = RekordboxShare.analysisURL(row.track.analysisDataPath, root: store.shareRoot),
                  RekordboxShare.hasWaveformAnalysis(row.track.analysisDataPath, root: store.shareRoot) else {
                throw SelfTestMismatch("그리드 분석 파일이 없습니다")
            }
            let actual = try BeatGrid.load(anlz: url)
            try check(!expected.beats.isEmpty && actual.beats.count == expected.beats.count
                && zip(actual.beats, expected.beats).allSatisfy { a, b in a.number == b.number && abs(a.bpm - b.bpm) < 0.011 && abs(a.time - b.time) <= 0.0015 },
                "그리드 쓰기 · 다시 읽은 박 \(actual.beats.count)/\(expected.beats.count)개")
        }
        for draft in batch.tags {
            guard let row = store.rowsByUUID[draft.trackUUID] else { throw SelfTestMismatch("태그 대상이 없습니다") }
            try check(draft.changedKeys.allSatisfy { row.tagFields[$0] == draft.fields[$0] }, "태그 쓰기 · 바뀐 칸 \(draft.changedKeys.count)개")
        }
        for (uuid, gain) in batch.gains {
            try check(store.rowsByUUID[uuid]?.autoGain.map { abs($0.gainDB - gain) <= 0.01 } == true, "게인 쓰기 · 초안 \(gain)dB")
        }
        guard let rated, let ratedBefore, let ratedNow = store.rowsByUUID[rated.track.uuid],
              let added = store.rowsByUUID[artworkAdd.track.uuid], let deleted = store.rowsByUUID[artworkDelete.track.uuid],
              let input = batch.artworks.first(where: { $0.trackUUID == added.track.uuid })?.image,
              let expectedArt = TrackArtwork.make(input), let record = store.artworkBase(for: added).files.first else {
            throw SelfTestMismatch("다시 읽은 곡이나 앨범아트 행이 없습니다")
        }
        try check(String(ratedNow.track.rating) == ratingValue && ratedNow.track.colorID == colorValue
            && report.tagWritten.contains { $0.trackUUID == rated.track.uuid && Set($0.fields ?? []).isSuperset(of: ["rating", "color"]) }, "평점·곡 색 쓰기")
        let sizes = try artworkFiles(added).map { try Data(contentsOf: $0) }
        try check(sizes == [expectedArt.full, expectedArt.medium, expectedArt.small] && record.hash == md5(expectedArt.full)
            && record.size == expectedArt.full.count && added.track.imagePath == TrackArtwork.imagePath(uuid: added.track.uuid)
            && !store.artworkBase(for: deleted).hasArtwork && store.artworkBase(for: deleted).files.isEmpty
            && artworkFiles(deleted).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
            && FileManager.default.fileExists(atPath: artworkFiles(deleted)[0].deletingLastPathComponent().path), "그림 쓰기 · 세 크기와 파일 행 확인")
        let backups = session.writeBackups()
        guard let path = report.backup, let backup = backups.first(where: {
            $0.isWrite && $0.url.resolvingSymlinksInPath().isSameDirectory(as: URL(filePath: path).resolvingSymlinksInPath())
        }) else {
            throw SelfTestMismatch("이번 쓰기의 백업이 없습니다")
        }
        try await session.restoreBackup(backup, to: session.target)
        for draft in batch.drafts {
            try check(store.rowsByUUID[draft.trackUUID]?.cues == before[draft.trackUUID]?.cues
                && CueDraftStore.load(trackUUID: draft.trackUUID, directory: locations.cue) == draft, "큐 되돌림")
        }
        for (url, data) in analysisBefore { try check(try Data(contentsOf: url) == data, "분석 파일 되돌림 · \(url.pathExtension)") }
        for draft in batch.grids {
            try check(store.rowsByUUID[draft.trackUUID]?.track.analysisDataPath == before[draft.trackUUID]?.track.analysisDataPath
                && GridDraftStore.load(trackUUID: draft.trackUUID, directory: locations.grid) == draft, "그리드 되돌림")
        }
        for draft in batch.tags {
            try check(store.rowsByUUID[draft.trackUUID]?.tagFields == before[draft.trackUUID]?.tagFields
                && store.tagDrafts[draft.trackUUID] == draft, "태그 되돌림")
        }
        let back = store.rowsByUUID[rated.track.uuid]
        try check(back?.track.rating == ratedBefore.0 && back?.track.colorID == ratedBefore.1, "평점·곡 색 시험 통과")
        let restoredArt = try artworkFiles(artworkDelete).map { try Data(contentsOf: $0) }
        for edit in batch.artworks {
            guard let row = store.rowsByUUID[edit.trackUUID] else { throw SelfTestMismatch("복원한 그림 대상이 없습니다") }
            try check(store.artworkBase(for: row) == edit.draft.base && store.artworkDrafts[edit.trackUUID] == edit.draft, "그림 행과 초안 되돌림")
        }
        try check(artworkFiles(artworkAdd).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && restoredArt == deletedOriginals,
                  "그림 파일 되돌림 · 세 크기 원본 확인")
        try check((report.createdFiles ?? []).allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "만든 분석 파일 정리")
        try check(store.playlists.rekordboxPlaylists == playlistsBefore && store.playlists.playlistDraft == playlistDraft, "재생 목록 되돌림")
        try check(try await addKeySelfTest(store: store, session: session, log: log), "곡 넣기·키 되돌림")
    }

    /// 곡 넣기 + 키(#5): 라이브러리 곡의 음원 사본(`DJC_HOME` 아래)을 추가 목록에 넣고 키 8A를 골라 미리 보기 → 넣기 → 다시 읽은 곡의 키를 보고,
    /// 그 넣기를 쓰기 전으로 복원해 곡이 빠지고 추가 목록·키 초안이 돌아오는지 본다. 뒤에서 도는 그리드·키 추정을 기다리지 않고 결과가 늘 같게
    /// 추가 목록에 바로 넣는다(분석 없이 넣기, 분석까지 넣는 경우는 `RekordboxTrackAddKeyTests`). 통과하면 "넣기+키 시험 통과" 줄을 남긴다.
    static func addKeySelfTest(store: LibraryStore, session: ReflectionSession, log: (String) -> Void) async throws -> Bool {
        let key = "8A"
        guard let source = store.rows.first(where: { !$0.isStaged && !$0.track.isStreaming && FileManager.default.fileExists(atPath: $0.track.folderPath) }) else {
            log("넣기+키: 음원이 있는 라이브러리 곡이 없습니다"); return false
        }
        let folder = store.draftFolder.appending(path: "selftest-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "DJC 키 시험.\(URL(filePath: source.track.folderPath).pathExtension)")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: URL(filePath: source.track.folderPath), to: url)
        let staged = try await StagedTrack.make(fileAt: url, addedOn: String(ISO8601DateFormatter().string(from: .now).prefix(10)))
        _ = store.staging.restage([staged])
        guard let row = store.rowsByID[staged.id] else { log("넣기+키: 추가한 곡을 목록에서 찾지 못했습니다"); return false }
        store.tags.setTag(.musicalKey, key, rows: [row])
        let picked = store.tags.confirmedStagedKey(uuid: staged.uuid)
        store.setWriteLock(true)
        let preview = try await session.previewAdd(rows: [row])
        let previewKey = preview.report.added.first?.keyWritten
        let report = try await session.add(preview, to: session.target)
        store.setWriteLock(false)
        guard let outcome = report.added.first, outcome.written, let uuid = outcome.uuid else {
            log("넣기+키: 넣지 못했습니다 \(report.added.first?.reason ?? preview.unreadable.joined(separator: " / "))"); return false
        }
        let reread = store.rowsByUUID[uuid]?.track.key
        log("넣기+키: 고른 키 \(picked ?? "-") · 미리 보기 키 \(previewKey ?? "-") · 넣음 \(report.added.filter(\.written).count)곡(\(preview.withoutAnalysis.isEmpty ? "분석 포함" : "분석 없이")) · 쓴 키 \(outcome.keyWritten ?? "-")\(outcome.keyReason.map { " 막힘 \($0)" } ?? "") · 다시 읽은 키 \(reread ?? "-") · 남은 추가 곡 \(store.staging.staged.count)")
        guard let backup = RekordboxWriter.backups(in: store.backupDirectory).first(where: { $0.trackReport?.added.contains { $0.uuid == uuid } == true }) else {
            log("넣기+키: 넣기 백업이 없습니다"); return false
        }
        _ = try await session.restoreBackup(backup, to: session.target)
        let gone = store.rowsByUUID[uuid] == nil
        let restaged = store.staging.staged.contains { $0.uuid == staged.uuid }
        let kept = store.tags.confirmedStagedKey(uuid: staged.uuid)
        log("넣기+키 되돌림: 넣은 곡 빠짐 \(gone) · 추가 목록에 돌아옴 \(restaged) · 키 초안 \(kept ?? "없음") · 새 곡 키 초안 남음 \(store.tagDrafts[uuid] != nil)")
        let passed = picked == key && previewKey == key && outcome.keyWritten == key && reread == key && gone && restaged && kept == key
            && store.tagDrafts[uuid] == nil
        log(passed ? "넣기+키 시험 통과" : "넣기+키 시험 실패")
        return passed
    }

    /// 쓰기 시험이 넣을 합성 그림(600×600 그러데이션 JPEG)
    static func selfTestArtwork() -> Data {
        let side = 600
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                rgba[i] = UInt8(60 + 190 * x / side); rgba[i + 1] = UInt8(60 + 190 * y / side); rgba[i + 2] = 120
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 개발용: 활성 루프가 있는 곡에서 루프 앞부터 재생해 반복되는지 본다(`--loop-selftest`, 음량 −70dB).
    static func runLoopSelfTestIfRequested(deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--loop-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[루프 시험] \(text)\n".utf8)) }
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<100 where !deck.canPlay || deck.draft == nil { await wait(0.1) }
            deck.volume = 0.0003
            deck.metronome = true   // 루프 중 클릭 예약도 함께 돈다
            guard let active = deck.draft?.cues.first(where: { $0.loop?.active == true }), let loop = active.loop else {
                log("활성 루프 없음"); exit(1)
            }
            log(String(format: "활성 루프 %.3f~%.3f초", active.time, loop.end))
            deck.seek(active.time - 1)
            deck.togglePlay()
            var samples: [Double] = []
            for _ in 0..<35 { await wait(0.2); samples.append(deck.currentTime) }
            deck.togglePlay()
            let inside = samples.dropFirst(8).allSatisfy { $0 >= active.time - 0.05 && $0 <= loop.end + 0.08 }
            log("위치: " + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            log(inside ? "루프 안에서 반복됨" : "루프를 벗어남!")
            guard inside else { exit(1) }

            // 즉석 루프: 루프 없는 자리에서 L(4박) → ½ → 빈 핫큐 칸에 저장 → 나가기
            deck.exitLoop()
            let cues = deck.draft?.cues ?? []
            let spot = stride(from: 20.0, to: deck.duration - 20, by: 5).first { t in
                !cues.contains { cue in cue.loop.map { t > cue.time - 3 && t < $0.end + 3 } ?? false }
            } ?? 30
            deck.seek(spot)
            deck.togglePlay()
            await wait(0.5)
            deck.toggleLoop()
            guard let instant = deck.instantLoop else { log("즉석 루프가 안 걸림"); exit(1) }
            let beat = 60 / (deck.gridBPM ?? 120)
            log(String(format: "즉석 루프 %@박 %.3f~%.3f초 (%.2f박)", deck.loopSizeText, instant.start, instant.end, (instant.end - instant.start) / beat))
            samples = []
            for _ in 0..<15 { await wait(0.2); samples.append(deck.currentTime) }
            let instantInside = samples.dropFirst(2).allSatisfy { $0 >= instant.start - 0.05 && $0 <= instant.end + 0.08 }
            log("위치: " + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            deck.resizeLoop(-1)
            let halved = deck.instantLoop.map { ($0.end - $0.start) / beat } ?? 0
            log(String(format: "½ 뒤 %@박 (%.2f박)", deck.loopSizeText, halved))
            let before = deck.draft?.cues.count ?? 0
            guard let slot = (0..<8).first(where: { deck.hotCue(slot: $0) == nil }) else { log("빈 핫큐 칸 없음"); exit(1) }
            deck.pressHotCue(slot: slot)
            let stored = deck.hotCue(slot: slot)
            let storedOK = stored?.loop != nil && deck.engagedLoopID == stored?.id && deck.instantLoop == nil
            log("핫큐 \(slot + 1)에 저장: \(storedOK ? "루프 핫큐로 저장·계속 반복" : "실패")")
            samples = []
            for _ in 0..<8 { await wait(0.2); samples.append(deck.currentTime) }
            let storedInside = stored.flatMap { cue in cue.loop.map { loop in samples.allSatisfy { $0 >= cue.time - 0.05 && $0 <= loop.end + 0.08 } } } ?? false
            log(String(format: "저장한 루프 %.3f~%.3f초 · 위치: ", stored?.time ?? 0, stored?.loop?.end ?? 0)
                + samples.map { String(format: "%.2f", $0) }.joined(separator: " "))
            deck.toggleLoop()
            let exited = !deck.isLooping
            if let id = stored?.id { deck.delete(id) }
            deck.togglePlay()
            let restored = (deck.draft?.cues.count ?? -1) == before
            log("즉석 루프 반복 \(instantInside) · ½ \(abs(halved - 2) < 0.1) · 저장 뒤 반복 \(storedInside) · 나가기 \(exited) · 시험 큐 지움 \(restored)")
            let ok = instantInside && abs(halved - 2) < 0.1 && storedOK && storedInside && exited && restored
            log(ok ? "통과" : "실패")
            exit(ok ? 0 : 1)
        }
    }

    /// 개발용: 재생 중에 곡 목록을 스크롤할 때 파형 갱신이 끊기는지 잰다(`--scroll-perf`).
    static func runScrollPerfIfRequested(deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--scroll-perf") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[스크롤 성능] \(text)\n".utf8)) }
        Task {
            let args = ProcessInfo.processInfo.arguments
            if let value = args.first(where: { $0.hasPrefix("--perf-waveform=") })?.split(separator: "=").last,
               let mode = WaveformColorMode(rawValue: String(value)) { deck.waveformColorMode = mode }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<200 where !deck.canPlay || deck.waveform == nil
                || (deck.waveformColorMode != .threeBand && deck.colorWaveform == nil) { await wait(0.1) }
            guard deck.canPlay else { log("재생 불가"); exit(1) }
            @MainActor func findTable(_ view: NSView?) -> NSTableView? {
                guard let view else { return nil }
                if let table = view as? NSTableView, table.identifier == KeyRouter.trackListID { return table }
                for sub in view.subviews { if let found = findTable(sub) { return found } }
                return nil
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let table = findTable(window.contentView),
                  let clip = table.enclosingScrollView?.contentView else { log("목록을 찾지 못함"); exit(1) }
            log("파형 모드: \(deck.waveformColorMode.title)")
            if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "preview" }) {
                log("미리 보기 컬럼: " + (column.isHidden ? "끔" : "켬"))
            }
            // 시험 음량은 오디오에만 주고 저장된 덱 음량은 바꾸지 않는다.
            deck.audio.volume = 0.0003
            PerfProbe.startRunLoopProbe()
            // 첫 메모리 큐가 곡 끝에 있어도 측정 도중 재생이 끝나지 않게 한다.
            deck.seek(0)
            deck.togglePlay()
            await wait(1.5)
            if let arg = args.first(where: { $0.hasPrefix("--perf-capture=") }) {
                let path = String(arg.dropFirst("--perf-capture=".count))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                await wait(0.3)
                let capture = Process()
                capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), path]
                var saved = false
                do {
                    try capture.run()
                    capture.waitUntilExit()
                    saved = capture.terminationStatus == 0
                } catch {}
                // 화면 기록 권한이 없으면 창 뷰(제목 막대 포함)를 직접 그린다(`--ui-perf-capture`와 같은 방식).
                if !saved, let frame = window.contentView?.superview,
                   let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    saved = (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))) != nil
                }
                log("화면 저장: \(saved ? "통과" : "실패")")
            }
            if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }),
               !table.tableColumns[column].isHidden {
                let visible = table.rows(in: table.visibleRect)
                let hasImage = (visible.location..<NSMaxRange(visible)).contains { row in
                    let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
                    // 앱 언어와 관계없이 통과하게 PreviewWaveform과 같은 키로 비교한다.
                    return cell?.accessibilityValue() as? String == String(ui: "곡 전체 미리 보기")
                }
                log("미리 보기 비트맵: " + (hasImage ? "표시됨" : "없음"))
            }
            PerfProbe.reset()
            await wait(3)
            log("가만히: " + PerfProbe.summary())
            PerfProbe.reset()
            // 3초씩: 천천히(8ms마다 14px), 빠르게 훑기(8ms마다 70px)
            var stepCosts: [Double] = []
            for (name, step) in [("천천히 스크롤", 14.0), ("빠르게 스크롤", 70.0)] {
                PerfProbe.reset()
                let started = ProcessInfo.processInfo.systemUptime
                var y = clip.bounds.origin.y
                var down = true
                while ProcessInfo.processInfo.systemUptime - started < 3 {
                    y += down ? step : -step
                    let maxY = table.bounds.height - clip.bounds.height
                    if y >= maxY { down = false } else if y <= 0 { down = true }
                    let t0 = CACurrentMediaTime()
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    stepCosts.append((CACurrentMediaTime() - t0) * 1000)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                let sorted = stepCosts.sorted()
                guard deck.isPlaying else { log("측정 중 재생 종료: 더 긴 곡을 선택하세요"); exit(1) }
                log("\(name): " + PerfProbe.summary()
                    + String(format: " · 스크롤 한 번 처리 평균 %.2fms · 상위 10%% %.2fms · 최대 %.2fms",
                             stepCosts.reduce(0, +) / Double(max(stepCosts.count, 1)), sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0))
                stepCosts = []
            }
            deck.togglePlay()
            exit(0)
        }
    }

    /// 개발용: 루프 이음새가 샘플 단위로 맞는지 실제 재생 경로로 확인한다(`--loop-audio-selftest`, 스피커 음소거).
    /// 값이 곧 프레임 번호인 램프 WAV를 틀고, 곡 믹서 출력에서 "프레임이 +1이 아닌 곳"을 모두 찾는다.
    static func runLoopAudioSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--loop-audio-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[루프 소리 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let rate = 44_100.0, seconds = 30
            let url = FileManager.default.temporaryDirectory.appending(path: "djc-ramp.wav")
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let count = Int(rate) * seconds
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = Float(i) / 1_000_000 }
                try file.write(from: buffer)
            } catch { log("램프 파일을 만들지 못함: \(error)"); exit(1) }

            let audio = DeckAudio()
            audio.volume = 1   // 값이 곧 프레임 번호여야 한다(볼륨을 곱하지 않게)
            try? audio.load(url: url)
            for _ in 0..<100 where !audio.canLoopSampleAccurately || !audio.isOutputReady { await wait(0.05) }
            guard audio.canLoopSampleAccurately else { log("메모리 디코딩 안 됨"); exit(1) }
            guard audio.isOutputReady else { log("오디오 출력을 준비하지 못함(장치 응답 없음)"); exit(1) }
            let captured = Captured()
            audio.debugCaptureTrack { buffer in
                guard case let .float(data) = buffer.channelData(0) else { return }
                captured.append((0..<Int(buffer.frameLength)).map { Int((Double(data[$0]) * 1_000_000).rounded()) })
            }
            func frame(_ t: Double) -> Int { Int((t * rate).rounded()) }
            // 루프(2.0~2.5초) 안에서 지금 몇 초째인지 보고 누른다(½이 새 끝 전·후 두 경우를 모두 지나게).
            @MainActor func waitPhase(_ range: ClosedRange<Double>) async {
                for _ in 0..<500 {
                    if range.contains((audio.position - 2.0).truncatingRemainder(dividingBy: 0.5)) { return }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            // 1) 1초부터 재생 → 2) 2.0~2.5초 루프 걸기 → 3) 바퀴 앞쪽에서 ½(새 끝에서 바로 줄어듦) → 4) ×2
            // → 5) 바퀴 뒤쪽에서 ½(새 길이만큼 뒤로 뜀) → 6) ×2 두 번(2.0~3.0) → 7) 나가기(바퀴 끝에서 이어 감)
            audio.play(from: 1.0)
            await wait(0.4)
            audio.setLoop(2.0...2.5)
            await wait(1.2)
            await waitPhase(0.0...0.08)
            audio.setLoop(2.0...2.25)
            await wait(0.8)
            audio.setLoop(2.0...2.5)
            await wait(0.8)
            await waitPhase(0.20...0.28)
            audio.setLoop(2.0...2.25)
            await wait(0.8)
            audio.setLoop(2.0...2.5)
            await wait(0.6)
            audio.setLoop(2.0...3.0)
            await wait(2.2)
            audio.setLoop(nil)
            await wait(2.0)
            audio.stop()
            await wait(0.2)
            // 재생 전·멈춘 뒤의 0은 뺀다.
            var frames = Array(captured.values.drop { $0 == 0 })
            while frames.last == 0 { frames.removeLast() }
            var jumps: [(Int, Int)] = []
            var previous: Int?
            for value in frames {
                if let p = previous, value != p + 1 { jumps.append((p, value)) }
                previous = value
            }
            let expected: Set<String> = ["\(frame(2.5) - 1)→\(frame(2.0))", "\(frame(2.25) - 1)→\(frame(2.0))", "\(frame(3.0) - 1)→\(frame(2.0))"]
            // 새 끝을 지나 ½하면 정확히 새 길이(0.25초)만큼 뒤로 뛴다
            let halfLength = frame(2.25) - frame(2.0)
            let backJumps = jumps.filter { $0.1 == $0.0 + 1 - halfLength && $0.0 >= frame(2.25) && $0.0 < frame(2.5) }
            let described = jumps.map { "\($0.0)→\($0.1)" }
            let unexpected = jumps.filter { jump in
                !expected.contains("\(jump.0)→\(jump.1)") && !backJumps.contains { $0 == jump }
            }.map { "\($0.0)→\($0.1)" }
            log("받은 프레임 \(frames.count) · 이음새 \(jumps.count)곳: " + Dictionary(grouping: described, by: { $0 }).map { "\($0.key) ×\($0.value.count)" }.sorted().prefix(12).joined(separator: ", "))
            // 순서대로(연속 0은 한 덩어리로)
            var ordered: [String] = []
            for (a, b) in jumps where !(a == 0 && b == 0) { ordered.append("\(a)→\(b)") }
            log("순서: " + ordered.prefix(40).joined(separator: " "))
            let exitedAt = frames.last.map { Double($0) / rate } ?? 0
            log(String(format: "마지막 프레임 %.3f초(나간 뒤 3.0초를 지나 이어졌는지)", exitedAt))
            log("½ 뒤로 뛰기 \(backJumps.count)번(새 끝을 지나 누른 경우)")
            let ok = unexpected.isEmpty && !jumps.isEmpty && backJumps.count == 1 && exitedAt > 3.2
            log(ok ? "통과: 루프 이음새가 모두 샘플 단위로 맞음" : "실패: 예상 밖 이음새 \(unexpected.prefix(5))")
            exit(ok ? 0 : 1)
        }
    }
}

extension DevSelfTests {
    /// 개발용: 재생 퀀타이즈 핫큐 점프가 박 경계에서 샘플 단위로 넘어가는지 실제 재생 경로로 확인한다(`--jump-audio-selftest`, 스피커 음소거).
    /// 값이 곧 프레임 번호인 램프 WAV(120BPM 그리드, 0.5초부터 박)를 틀고, 곡 믹서 출력에서 "프레임이 +1이 아닌 곳"을 모두 찾아
    /// 예약한 점프(경계 직전 프레임 → 착지 프레임)·루프 되풀이 말고는 이음새가 없는지, 경계가 실제 비트그리드 선이고 저장 큐의 첫 샘플에 착지하는지 본다.
    static func runJumpAudioSelfTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--jump-audio-selftest") else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[점프 소리 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let rate = 44_100.0, seconds = 40
            let url = FileManager.default.temporaryDirectory.appending(path: "djc-jump-ramp.wav")
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let count = Int(rate) * seconds
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = Float(i) / 1_000_000 }
                try file.write(from: buffer)
            } catch { log("램프 파일을 만들지 못함: \(error)"); exit(1) }
            let bpm = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--jump-bpm=") })
                .flatMap { Double($0.dropFirst("--jump-bpm=".count)) } ?? 120
            guard [120.0, 180.0].contains(bpm) else { log("BPM은 120 또는 180으로 지정하세요"); exit(1) }
            let grid = BeatGrid(beats: (0..<Int(Double(seconds) * bpm / 60)).map {
                BeatGrid.Beat(number: $0 % 4 + 1, bpm: bpm, time: 0.5 + Double($0) * 60 / bpm)
            })
            log("그리드 \(Int(bpm)) BPM")
            func quantize(_ beats: Double) -> PlayQuantize { PlayQuantize(grid: grid, beats: beats)! }

            let audio = DeckAudio()
            audio.volume = 1   // 값이 곧 프레임 번호여야 한다(볼륨을 곱하지 않게)
            try? audio.load(url: url)
            for _ in 0..<100 where !audio.canLoopSampleAccurately || !audio.isOutputReady { await wait(0.05) }
            guard audio.canLoopSampleAccurately else { log("메모리 디코딩 안 됨"); exit(1) }
            guard audio.isOutputReady else { log("오디오 출력을 준비하지 못함(장치 응답 없음)"); exit(1) }
            let captured = Captured()
            audio.debugCaptureTrack { buffer in
                guard case let .float(data) = buffer.channelData(0) else { return }
                captured.append((0..<Int(buffer.frameLength)).map { Int((Double(data[$0]) * 1_000_000).rounded()) })
            }
            func frame(_ t: Double) -> Int { Int((t * rate).rounded()) }
            var expected: [String: String] = [:]
            var failures: [String] = []
            /// 점프 하나: 경계는 실제 그리드 선이며 착지는 저장 큐다(제품의 분할/착지 함수를 정답으로 쓰지 않는다).
            /// `flowLoop`: 누를 때 되풀이 중이던 루프. 경계가 그 시작이면 되풀이 순간(루프 끝 직전 프레임)에서 넘어간다.
            @MainActor func expect(_ jump: PlayQuantize.Jump?, _ name: String, cue: Double, flowLoop: ClosedRange<Double>? = nil) {
                guard let jump else { failures.append("\(name): 예약 못 함"); return }
                if let timing = audio.debugJumpTiming {
                    log(String(format: "%@ 계측: 입력host %.6f 청취 %.6f rendered %lld ahead %lld 예약직전 %lld 준비ms %.3f 선택node %lld target %lld",
                               name, timing.requestedHost, timing.audiblePosition, timing.renderedNode, timing.ahead,
                               timing.beforeScheduleNode, (timing.beforeScheduleHost - timing.requestedHost) * 1000,
                               timing.selectedNode, timing.targetFrame))
                    // 제품의 boundary 함수가 아닌 실제 그리드 목록에서 예약 가능한 첫 큰 박을 찾는다.
                    if flowLoop == nil, let first = grid.beats.first(where: { $0.time >= timing.earliestPosition - 1e-9 }),
                       abs(jump.at - first.time) > 1e-6 {
                        failures.append(String(format: "%@: 첫 큰 박 %.4f초 대신 %.4f초 예약", name, first.time, jump.at))
                    }
                    if timing.selectedNode < timing.ahead { failures.append("\(name): 렌더 여유보다 앞에 예약함") }
                }
                let at = grid.beatCoordinate(at: jump.at)
                if !grid.beats.contains(where: { abs($0.time - jump.at) < 1e-6 }) { failures.append("\(name): 큰 박선 전에 점프함") }
                if abs(jump.to - cue) > 1e-9 { failures.append("\(name): 저장 큐의 앞부분을 생략함") }
                let before = flowLoop.map { abs($0.lowerBound - jump.at) < 1e-6 ? frame($0.upperBound) - 1 : frame(jump.at) - 1 } ?? frame(jump.at) - 1
                expected["\(before)→\(frame(cue))"] = name
                log(String(format: "%@ 예약: %.4f초(%.2f박째) → %.4f초", name, jump.at, at, jump.to))
            }

            // 1) 이전 단위값 ¼·1·½ 각각 큰 박선에서 10초·20초·5~6초 루프 핫큐로 진입
            // → 루프 안에서 12초 핫큐를 누르고 바로 15초 핫큐(나중 것만 넘어가야 한다)
            audio.play(from: 1.0)
            await wait(0.5)
            expect(audio.scheduleJump(to: 10, loop: nil, quantize: quantize(0.25)), "이전 ¼ 값", cue: 10)
            await wait(1.0)
            expect(audio.scheduleJump(to: 20, loop: nil, quantize: quantize(1)), "이전 1 값", cue: 20)
            await wait(1.2)
            expect(audio.scheduleJump(to: 5, loop: 5...6, quantize: quantize(0.5)), "이전 ½ 값 루프", cue: 5)
            await wait(2.6)
            let overridden = audio.scheduleJump(to: 12, loop: nil, quantize: quantize(1))
            expect(audio.scheduleJump(to: 15, loop: nil, quantize: quantize(1)), "다시 누름", cue: 15, flowLoop: 5...6)
            let positionCheck = audio.position
            await wait(1.2)
            let after = audio.position
            audio.stop()
            await wait(0.2)

            var frames = Array(captured.values.drop { $0 == 0 })
            while frames.last == 0 { frames.removeLast() }
            var jumps: [String] = []
            var previous: Int?
            for value in frames {
                if let p = previous, value != p + 1 { jumps.append("\(p)→\(value)") }
                previous = value
            }
            let wrap = "\(frame(6) - 1)→\(frame(5))"
            let seen = Dictionary(grouping: jumps, by: { $0 }).mapValues(\.count)
            for (pair, name) in expected where seen[pair] != 1 { failures.append("\(name): 이음새 \(pair)가 \(seen[pair] ?? 0)번") }
            if let overridden, jumps.contains(where: { $0.hasSuffix("→\(frame(overridden.to))") }) { failures.append("먼저 누른 12초 핫큐로 넘어감") }
            let wraps = seen[wrap] ?? 0
            if wraps < 2 { failures.append("루프 되풀이 \(wraps)번(2번 넘어야 함)") }
            let unexpected = jumps.filter { expected[$0] == nil && $0 != wrap }
            if !unexpected.isEmpty { failures.append("예상 밖 이음새 \(unexpected.prefix(5))") }
            log("받은 프레임 \(frames.count) · 이음새 \(jumps.count)곳(루프 되풀이 \(wraps)번) · 순서: " + jumps.prefix(20).joined(separator: " "))
            log(String(format: "다시 누른 뒤 위치 %.3f초 → 1.2초 뒤 %.3f초(15초 근처여야 함)", positionCheck, after))
            if !(15...16.5).contains(after) { failures.append(String(format: "화면 위치가 착지를 따라가지 않음(%.3f초)", after)) }
            log(failures.isEmpty ? "통과: 핫큐 점프가 박 경계에서 샘플 단위로 넘어감" : "실패: \(failures)")
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}

/// 개발용: 메트로놈이 박마다 한 번씩 빠짐없이 치는지 실제 재생 경로로 센다(`--metronome-selftest`, 스피커 음소거).
/// 무음 WAV + 120BPM 그리드로 12초 재생(그중 루프 구간 포함), 클릭 노드 출력에서 클릭 시작을 찾아 박 수와 비교한다.
@MainActor
func runMetronomeSelfTestIfRequested() {
    let testsJump = ProcessInfo.processInfo.arguments.contains("--metronome-jump-selftest")
    guard testsJump || ProcessInfo.processInfo.arguments.contains("--metronome-selftest") else { return }
    func log(_ text: String) { FileHandle.standardError.write(Data("[메트로놈 시험] \(text)\n".utf8)) }
    Task { @MainActor in
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let rate = 44_100.0, seconds = 40
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-silence.wav")
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Int(rate) * seconds))!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        } catch { log("무음 파일을 만들지 못함: \(error)"); exit(1) }
        var beats: [BeatGrid.Beat] = []
        for k in 0..<80 { beats.append(BeatGrid.Beat(number: k % 4 + 1, bpm: 120, time: 0.25 + Double(k) * 0.5)) }
        if testsJump {
            beats = (0..<8).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 60, time: 0.25 + Double($0)) }
                + (0..<90).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 180, time: 8.1 + Double($0) / 3) }
        }
        let grid = BeatGrid(beats: beats)
        let audio = DeckAudio()
        try? audio.load(url: url)
        for _ in 0..<100 where !audio.canLoopSampleAccurately || !audio.isOutputReady { await wait(0.05) }
        guard audio.isOutputReady else { log("오디오 출력을 준비하지 못함(장치 응답 없음)"); exit(1) }
        let captured = Captured()
        audio.debugCaptureClicks { buffer in
            guard case let .float(data) = buffer.channelData(0) else { return }
            // 부호까지 보존해 클릭 간격과 강박(1760Hz)/일반 박(1175Hz)을 함께 검사한다.
            captured.append((0..<Int(buffer.frameLength)).map { Int(data[$0] * 1_000_000) })
        }
        audio.metronome = true
        audio.play(from: 1.0)
        // 화면 틱처럼 약 14ms마다 예약한다(창 경계가 박 가까이에 자주 걸리게 조금씩 흔든다).
        let started = ProcessInfo.processInfo.systemUptime
        var i = 0
        let played = testsJump ? 3.0 : 12.0
        var jump: PlayQuantize.Jump?
        while ProcessInfo.processInfo.systemUptime - started < played {
            audio.scheduleClicks(grid)
            i += 1
            if testsJump, jump == nil, audio.position >= 1.5 {
                // 첫 클릭(1.25초) 뒤에 요청해 시작 시계와 점프 시계 사이의 한 박 간격도 반드시 검사한다.
                jump = audio.scheduleJump(to: 8.1, loop: nil, quantize: PlayQuantize(grid: grid, beats: 1)!)
            }
            try? await Task.sleep(for: .milliseconds(13 + i % 3))
        }
        audio.stop()
        await wait(0.2)
        // 소리 덩어리(클릭) 수: 0→1로 바뀌는 곳. 클릭 30ms 안의 작은 끊김은 합친다.
        let values = captured.values
        var onsetFrames: [Int] = [], silentRun = 10_000
        for (frame, value) in values.enumerated() {
            if abs(value) > 10_000 {
                if silentRun > 400 { onsetFrames.append(frame) }
                silentRun = 0
            } else { silentRun += 1 }
        }
        let onsets = onsetFrames.count
        if testsJump {
            let intervals = zip(onsetFrames, onsetFrames.dropFirst()).map { Double($1 - $0) / 48_000 }
            let downbeats = onsetFrames.map { onset in
                let end = min(values.count - 1, onset + 960)
                let crossings = (onset..<end).filter { values[$0] <= 0 && values[$0 + 1] > 0 }.count
                return crossings > 29
            }
            guard let jump else { log("실패: 점프를 예약하지 못함"); exit(1) }
            // 앱 첫 화면을 그리는 동안 요청이 늦어질 수 있어 실제 예약 경계 앞의 원래 박도 포함한다.
            let prefix = grid.beats.filter { $0.time >= 1 && $0.time < jump.at - 0.0001 }
            let expected = prefix.map { (time: $0.time, downbeat: $0.isDownbeat) }
                + grid.beats.filter { $0.time >= jump.to - 0.0001 }.map { (time: jump.at + $0.time - jump.to, downbeat: $0.isDownbeat) }
            let spacingOK = intervals.enumerated().allSatisfy { index, interval in
                index + 1 < expected.count && abs(interval - (expected[index + 1].time - expected[index].time)) < 0.002
            }
            let accentsOK = downbeats.enumerated().allSatisfy { index, downbeat in
                index < expected.count && downbeat == expected[index].downbeat
            }
            let ok = onsets >= prefix.count + 4 && spacingOK && accentsOK
            log(String(format: "점프 %.4f → %.4f초 · 경계 전 원래 박 %d개", jump.at, jump.to, prefix.count))
            log("점프 뒤 클릭 \(onsets)개 · 간격 \(intervals.map { String(format: "%.4f", $0) }.joined(separator: ",")) · 강박 \(downbeats)")
            log(ok ? "통과: 점프 직후부터 새 그리드의 박과 강박으로 클릭함" : "실패: 점프 전 그리드의 클릭이 남거나 새 박이 빠짐")
            exit(ok ? 0 : 1)
        }
        let expected = grid.beats.filter { $0.time >= 1.0 && $0.time < 1.0 + played - 0.3 }.count
        log("예상 박 약 \(expected)개(마지막 0.3초 제외) · 들린 클릭 \(onsets)개")
        let ok = onsets >= expected && onsets <= expected + 1
        log(ok ? "통과: 클릭이 빠지지 않음" : "실패: 클릭 수가 다름")
        exit(ok ? 0 : 1)
    }
}

/// 오디오 탭 스레드에서 모은 값(잠금으로 보호)
final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ values: [Int]) { lock.lock(); storage += values; lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
#endif
