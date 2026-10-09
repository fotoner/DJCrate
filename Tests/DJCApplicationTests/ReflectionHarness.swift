import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization

/// 반영 세션 시험의 가짜 포트 묶음. 화면 상태(`state`)·초안(`drafts`, 메모리)·관문 결과(`gate`)를 정해 두고 세션을 만들면,
/// 세션이 부른 것(관문 호출·화면 변경·확인 창·잠금·다시 읽기·결과)을 남긴다. DB·디스크·앱 없이 흐름과 판정을 본다.
@MainActor
final class ReflectionHarness {
    let log = CallLog()
    let memory = MemoryDrafts()
    let previewHold = PreviewHold()
    let gateCalls = GateCalls()
    var script = GateScript()
    /// 라이브러리 화면 상태(세션이 읽는다). `apply`가 받은 변경 가운데 상태에 남는 것(태그·합치기·추가 목록 등)은 여기에도 반영한다.
    var state = ReflectionLibraryState()
    var changes: [ReflectionLibraryChange] = []
    var published: [ReflectionOutcome] = []
    var prompts: [ReflectionPrompt] = []
    /// 차례로 쓸 확인 답(비면 `answer`)
    var answers: [Bool] = []
    var answer = true
    var choice: ReflectionChoice = .confirm
    var locked = false
    /// (잠금, 덱도) 차례
    var locks: [String] = []
    var stages: [WriteStage?] = []
    var reloads: [(written: Set<String>, playlistEdits: [PlaylistEdit])] = []
    var reloadSucceeds = true
    /// 다시 읽기가 실패했을 때 목록 위에 남는 이유
    var reloadError: String?
    var running = false
    /// 쓰기 전 백업 폴더(메모리). 곡 넣기가 남긴 추가 목록·초안은 같은 백업에서 다시 읽힌다.
    lazy var backupsMemory = MemoryBackups { [log] in log.record($0) }
    var canBackUp: Bool { get { backupsMemory.canWrite } set { backupsMemory.canWrite = newValue } }
    /// 따로 남긴 것이 없는 백업에서 되살릴 초안·추가 목록
    var backupDrafts: RekordboxBackupDrafts { get { backupsMemory.drafts } set { backupsMemory.drafts = newValue } }
    var backupStaged: [StagedTrack]? { get { backupsMemory.staged } set { backupsMemory.staged = newValue } }
    /// 백업 폴더에 남기기가 실패할 종류("staged"·"cue"·"grid"·"tag")
    var failingBackupSaves: Set<String> { get { backupsMemory.failing } set { backupsMemory.failing = newValue } }
    var laterBackups: Int { get { backupsMemory.later } set { backupsMemory.later = newValue } }
    var pointRefusal: String? { get { backupsMemory.refusal } set { backupsMemory.refusal = newValue } }
    var updateCount: Int { get { backupsMemory.updateCount } set { backupsMemory.updateCount = newValue } }
    var preserved: [DamagedDraftFile] = []
    var playlistSaves = true
    var unsaved: Set<String> = []
    var saveFailures: [DraftSaveFailure] = []
    /// 관문이 쓴 뒤(초안을 정리할 때) 생기는 저장 실패
    var saveFailuresAfterWrite: [DraftSaveFailure] = []
    var failingArtworkRemovals: Set<String> = []
    /// 합치기 초안 저장이 실패한다
    var failingMergeSave = false
    /// 세션이 저장한 재생 목록 연결 기록(차례대로)
    var importsSaved: [PlaylistImports] = []
    var loudness: Loudness? = Loudness(integrated: -9, peak: -6, clippedRuns: 0)
    var unsupported: [String: String] = [:]
    var location = ReflectionHarness.location()
    var options = ReflectionSession.Options.app(attachesAnalysis: true, writesArtwork: true)

    static func location(explicitCopy: Bool = false, overridden: Bool = false) -> LibraryLocation {
        LibraryLocation(rekordboxDirectory: URL(filePath: "/lib"), rekordboxDirectoryOverridden: overridden,
                        snapshotDirectory: URL(filePath: "/snapshots"), opensExplicitCopy: explicitCopy,
                        explicitCopy: explicitCopy ? URL(filePath: "/opened/master.db") : nil, database: URL(filePath: "/lib/master.db"),
                        shareRoot: URL(filePath: "/lib/share"), backupDirectory: URL(filePath: "/backups"), draftHome: URL(filePath: "/drafts"),
                        movesDamagedDrafts: false)
    }

    var session: ReflectionSession {
        ReflectionSession(location: location, ports: ports, options: options)
    }

    var ports: ReflectionPorts {
        ReflectionPorts(gate: gate, backups: backups, drafts: drafts, snapshots: snapshots, audio: audio,
                        library: ReflectionLibrary(state: { self.libraryState }, apply: { self.apply($0) },
                                                   retryTagSaves: { self.log.record("retry tag saves") },
                                                   preserveDamagedDrafts: { self.log.record("preserve damaged"); return self.preserved },
                                                   savePlaylistDraft: { self.log.record("save playlist"); return self.playlistSaves }),
                        reload: LibraryReloader { written, edits in
                            self.log.record("reload")
                            self.reloads.append((written, edits))
                            return self.reloadSucceeds
                        },
                        lock: WriteLock(isLocked: { self.locked }, set: { locked, deck in
                            self.locked = locked
                            self.locks.append("\(locked)\(deck ? "" : " (덱 빼고)")")
                        }, stage: { self.stages.append($0) }),
                        confirmation: UserConfirmation(confirm: { prompt in
                            self.prompts.append(prompt)
                            return self.answers.isEmpty ? self.answer : self.answers.removeFirst()
                        }, choose: { prompt in
                            self.prompts.append(prompt)
                            return self.choice
                        }),
                        results: ReflectionResults { self.published.append($0) },
                        runningApps: RunningApps { [running] in running },
                        playlistImports: PlaylistImportsStore(load: { PlaylistImports() }, save: { imports in
                            MainActor.assumeIsolated { self.importsSaved.append(imports) }
                        }))
    }

    private var libraryState: ReflectionLibraryState {
        var current = state
        if !reloadSucceeds { current.lastError = reloadError }
        return current
    }

    /// 화면이 받은 변경. 상태에 남는 것은 상태에도 넣는다(앱 화면이 하는 일의 요지만).
    private func apply(_ change: ReflectionLibraryChange) {
        changes.append(change)
        switch change {
        case let .tagDrafts(drafts):
            for draft in drafts { state.tagDrafts[draft.trackUUID] = draft.hasChanges ? draft : nil }
        case let .mergeDrafts(drafts, _, _): state.mergeDrafts = drafts
        case let .playlistWritten(cleanup):
            if let draft = cleanup.draft { state.playlistDraft = draft }
            if let imports = cleanup.imports, imports.stored { state.playlistImports = imports.imports }
        case let .playlistImportsReset(reset):
            if let draft = reset.draft { state.playlistDraft = draft }
            if let imports = reset.imports, imports.stored { state.playlistImports = imports.imports }
        case let .unstaged(uuids): state.staged.removeAll { uuids.contains($0.uuid) }
        case let .restaged(tracks): state.staged += tracks
        case let .libraryError(text): state.lastError = text
        default: break
        }
    }

    private var drafts: DraftStore {
        var store = memory.store
        let unsaved = unsaved, failures = saveFailures, later = saveFailuresAfterWrite, failingRemovals = failingArtworkRemovals
        let failingMerge = failingMergeSave
        let calls = gateCalls
        store.unsavedUUIDs = { unsaved }
        store.failures = { calls.value.order.contains("write") ? failures + later : failures }
        let removeArtwork = store.removeArtwork
        store.removeArtwork = { uuid in
            if failingRemovals.contains(uuid) { throw FixtureFailure() }
            try removeArtwork(uuid)
        }
        let saveMerges = store.saveMergeDrafts
        store.saveMergeDrafts = { merges in
            if failingMerge { throw FixtureFailure() }
            try saveMerges(merges)
        }
        return store
    }

    private var gate: RekordboxWriteGate { .scripted(script, calls: gateCalls, hold: previewHold) }

    private var backups: RekordboxBackups { backupsMemory.port }

    private var snapshots: SnapshotTaker {
        let log = log
        return SnapshotTaker { _ in
            log.record("snapshot")
            return URL(filePath: "/snapshots/copy.db")
        }
    }

    private var audio: TrackAudioReader {
        let loudness = loudness, unsupported = unsupported, log = log
        return TrackAudioReader(
            needsAnalysis: { ($0 ?? "").isEmpty },
            tags: { url in
                log.record("tags \(url.lastPathComponent)")
                if url.lastPathComponent.hasPrefix("unreadable") { throw FixtureFailure() }
                return AudioTags(duration: 180, artwork: Data([1]))
            },
            loudness: { url in log.record("loudness \(url.lastPathComponent)"); return loudness },
            unsupported: { unsupported[$0.path] },
            addPlan: { url, tags in
                TrackAddPlan(path: url.path, fileName: url.lastPathComponent, title: tags.title ?? url.lastPathComponent, comment: "", year: 0,
                             trackNumber: 0, discNumber: 0, isrc: "", lyricist: "", fileType: 1, fileSize: 1, fileID: url.lastPathComponent,
                             length: 180, duration: 180, dateCreated: "", stockDate: "")
            })
    }

    // MARK: - 시험 재료

    static func row(_ id: String, path: String? = nil, analysis: String? = "/PIONEER/USBANLZ/x/ANLZ0000.DAT") -> TrackRow {
        TrackRow(track: Track(id: id, uuid: id, title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: path ?? "/music/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: analysis, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    static func outcome(_ uuid: String, _ status: RekordboxWriteOutcome.Status, reason: String? = nil, added: Int = 1) -> RekordboxWriteOutcome {
        .init(trackUUID: uuid, title: "곡 \(uuid)", status: status, reason: reason, removed: 0, added: added)
    }

    static func report(cues: [RekordboxWriteOutcome] = [], grids: [RekordboxWriteOutcome] = [], gains: [RekordboxWriteOutcome] = [],
                       analyses: [RekordboxWriteOutcome] = [], tags: [RekordboxWriteOutcome] = [], artworks: [RekordboxWriteOutcome] = [],
                       backup: String? = nil, dryRun: Bool = true) -> RekordboxWriteReport {
        var report = RekordboxWriteReport(outcomes: cues, backup: backup, dryRun: dryRun, createdAt: "", finalUpdateCount: 1)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.gainOutcomes = gains.isEmpty ? nil : gains
        report.analysisOutcomes = analyses.isEmpty ? nil : analyses
        report.tagOutcomes = tags.isEmpty ? nil : tags
        report.artworkOutcomes = artworks.isEmpty ? nil : artworks
        return report
    }

    static func cue(_ uuid: String, at time: Double = 12) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .hot(0), time: time))
        return draft
    }

    static func grid(_ uuid: String, bpm: Double = 128) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 0, bpm: bpm, firstBeatNumber: 1)])
    }

    static func tag(_ uuid: String, title: String = "새 제목") -> TagDraft {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        draft.fields.title = title
        return draft
    }

    static func staged(_ uuid: String) -> StagedTrack {
        StagedTrack(uuid: uuid, path: "/music/\(uuid).mp3", title: "곡 \(uuid)", duration: 180, addedOn: "2026-10-09")
    }

    static func track(_ path: String, written: Bool = true, uuid: String? = nil, reason: String? = nil) -> RekordboxTrackWriteOutcome {
        RekordboxTrackWriteOutcome(path: path, contentID: written ? "id-\(path)" : nil, title: "곡 \(path)", written: written, reason: reason,
                                   uuid: written ? uuid ?? "new-\(path)" : nil)
    }

    static func backup(_ name: String = "b", report: RekordboxWriteReport? = nil, tracks: RekordboxTrackWriteReport? = nil) -> RekordboxWriteBackup {
        RekordboxWriteBackup(url: URL(filePath: "/backups/\(name)"), createdAt: Date(timeIntervalSince1970: 0), isWrite: true, report: report,
                             trackReport: tracks)
    }

    /// 화면이 받은 변경의 짧은 이름(차례 비교용)
    var changeNames: [String] {
        changes.map { change in
            switch change {
            case let .draftsCleared(kind, uuids, counts): "cleared \(kind) \(uuids.sorted())\(counts ? " counts" : "")"
            case let .tagDrafts(drafts): "tags \(drafts.map(\.trackUUID).sorted())"
            case let .mergeDrafts(drafts, failure, _): "merges \(drafts.map(\.id))\(failure == nil ? "" : " failed")"
            case .playlistWritten: "playlist written"
            case let .artworkCleared(uuids, failed): "artwork cleared \(uuids) failed \(failed)"
            case let .artworkRestored(drafts, touched): "artwork restored \(drafts.keys.sorted()) touched \(touched)"
            case let .unstaged(uuids): "unstaged \(uuids.sorted())"
            case let .restaged(tracks): "restaged \(tracks.map(\.uuid))"
            case let .deckTrackMoved(id): "deck \(id)"
            case let .playlistImportsReset(reset): "imports reset \(reset.contentIDs.sorted())"
            case .unlinkedDraftsChanged: "unlinked"
            case let .libraryError(text): "error \(text)"
            case let .showAdded(id): "show \(id)"
            case let .deselected(ids): "deselect \(ids.sorted())"
            case let .lastWriteBackup(url): "last backup \(url?.lastPathComponent ?? "-")"
            case let .followUp(notes): "follow-up \(notes.count)"
            case .writeBackupsChanged: "backups changed"
            }
        }
    }

    /// 마지막으로 남긴 쓴 뒤 경고
    var followUp: [String]? {
        changes.reversed().lazy.compactMap { if case let .followUp(notes) = $0 { notes } else { nil } }.first
    }
}

struct FixtureFailure: Error, CustomStringConvertible { var description = "합성 실패" }
