import DJCDomain
import Foundation

/// 이미 라이브러리가 있는 USB 수정. 편집(`UsbLibraryEdit`)을 계획하고 한 번에 쓴다.
/// 순서: 원본 확인 → 볼륨(정책·보호 경로·관문, 막히면 USB를 열거하지 않는다) → 저널 → USB DB 사본 → (곡 더하기·갱신·동기화면) 세션 전용 로컬 사본
/// → 계획(`UsbLibraryEngine.Edit`) → 확인 안 된 규칙 → `UsbWriter.write`. 사본·준비 폴더는 세션이 끝나면 지운다.
/// 입출력은 포트(`UsbLibraryEngine`·`UsbDevice`·`UsbDraftFiles`)로만 한다. 이 타입은 순서와 막힘 판정을 맡는다.
public final class UsbEditSession {
    let root: URL
    let database: URL?
    let share: URL?
    let writeGuard: UsbWriteGuard
    let paths: UsbWritePaths
    let engine: UsbLibraryEngine
    let device: UsbDevice
    let localCopies: URL
    let drafts: UsbDraftFiles
    /// 지금 시각(조립 지점이 준다)
    let now: @Sendable () -> Date

    /// 마지막 계획(막혀 던졌을 때도 CLI·앱이 요약을 읽는다)
    public private(set) var lastResult: UsbEditResult?
    /// 마지막 계획의 편집(초안이면 그때 읽은 초안, 결과 번호 1부터와 짝)
    public private(set) var lastEdits: [UsbLibraryEdit] = []

    /// - database: 로컬 스냅샷 사본(곡 더하기·갱신·목록 동기화·음원 지우기 확인에 쓴다. 라이브 master.db는 거부)
    /// - share: 로컬 rekordbox share(읽기만)
    /// - engine: USB 읽기·계획·준비·쓰기(시험은 마운트를 흉내 내는 파일 시스템을 묶은 엔진이나 가짜를 넘긴다)
    /// - device: 이 Mac의 일(rekordbox 버전, 라이브 master.db 판정, 세션 사본 뜨기 — 원본은 읽기만 — ·지우기, 경로 판정)
    /// - localCopies: 세션 사본(`local-<세션>/`)·USB DB 사본(`usb-<세션>/`)을 둘 곳
    /// - drafts: 이 USB의 초안 파일
    ///
    /// 가드(볼륨 정보·실물 쓰기 동의)·Mac 쪽 폴더·초안·엔진·이 Mac의 일은 기본값 없이 조립 지점이 넘긴다.
    public init(root: URL, database: URL?, share: URL?, guard writeGuard: UsbWriteGuard, paths: UsbWritePaths,
                engine: UsbLibraryEngine, device: UsbDevice, localCopies: URL, drafts: UsbDraftFiles, now: @escaping @Sendable () -> Date) {
        self.root = root
        self.database = database
        self.share = share
        self.writeGuard = writeGuard
        self.paths = paths
        self.engine = engine
        self.device = device
        self.localCopies = localCopies
        self.drafts = drafts
        self.now = now
    }

    /// 계획만(USB에 쓰지 않는다). 준비 폴더는 지운다
    public func preview(_ edits: [UsbLibraryEdit], options: UsbWriteOptions, snapshotTime: String? = nil) throws -> UsbEditResult {
        let prepared = try prepare(.edits(edits), options: options, snapshotTime: snapshotTime, progress: { _ in }, isCancelled: { false })
        if let staging = prepared.staging { device.remove(staging) }
        lastResult = prepared.result
        lastEdits = prepared.edits
        return prepared.result
    }

    /// 쓰기 대기 목록의 미리 보기: 이 볼륨 초안의 편집을 계획만 한다(초안이 없거나 비었으면 nil).
    /// 초안을 만든 뒤 USB가 바뀌었으면 쓸 때도 지금 상태로 다시 계획한다는 알림을 앞에 붙인다(막힌 볼륨은 USB를 더 읽지 않는다).
    /// - currentBase: 지금 USB DB 지문(앱은 그 자리의 볼륨을 다시 본 뒤 읽는다). 읽지 못하면 알림을 붙이지 않는다
    public func previewDraft(volume: UsbVolumeInfo, options: UsbWriteOptions, snapshotTime: String? = nil,
                             currentBase: () throws -> UsbFingerprint) throws -> (result: UsbEditResult, edits: [UsbLibraryEdit])? {
        guard let draft = try drafts.load(try Self.volumeKey(volume)), !draft.edits.isEmpty else { return nil }
        var result = try preview(draft.edits, options: options, snapshotTime: snapshotTime)
        if result.blocks.isEmpty, let now = try? currentBase(), !now.sameContent(as: draft.base) {
            result.notes.insert(Self.replannedNote, at: 0)
        }
        return (result, draft.edits)
    }

    /// 로컬 스냅샷 사본이 있어야 하는 편집(곡 더하기·갱신·동기화). CLI는 `--db`가 없을 때 이것으로 최근 스냅샷을 고른다
    public static func needsLocal(_ edits: [UsbLibraryEdit]) -> Bool {
        edits.contains {
            switch $0 {
            case .addTracks, .refreshTracks, .syncPlaylist, .syncSelection: true
            case .removeTracks, .playlist: false
            }
        }
    }

    /// 계획하고 쓴다(`options.dryRun`이면 준비·저널까지). 쓸 것이 없으면 보고서 nil. USB 전체가 막히면 `writeRefused`
    public func write(_ edits: [UsbLibraryEdit], options: UsbWriteOptions, snapshotTime: String? = nil,
                      progress: @escaping @Sendable (UsbProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        try run(.edits(edits), options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
    }

    /// 이 USB의 초안을 쓴다. 초안을 만든 뒤 USB가 바뀌었으면 지금 상태에 다시 계획한다.
    /// 쓴 뒤(또는 쓸 것이 없을 때) 초안에는 막힌 편집만 남기고(base는 그때 USB DB 지문), 막힌 것이 없으면 초안을 지운다
    public func writeDraft(options: UsbWriteOptions, snapshotTime: String? = nil, progress: @escaping @Sendable (UsbProgress) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        try run(.draft, options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
    }

    /// 편집 하나를 이 USB의 초안에 더한다(초안이 없으면 지금 USB DB 지문을 base로 만든다)
    public func addToDraft(_ edit: UsbLibraryEdit) throws {
        let volume = try writeGuard.volume(root)
        let blocks = environmentBlocks(volume, required: [], options: UsbWriteOptions())
        guard blocks.isEmpty else { throw UsbError.writeRefused(blocks) }
        try drafts.append(edit, try Self.volumeKey(volume), engine.writer.databaseFingerprint(root))
    }

    // MARK: - 순서

    enum Edits {
        case edits([UsbLibraryEdit])
        case draft
    }

    struct Prepared {
        var result: UsbEditResult
        var staging: URL?
        var draftKey: String?
        /// 계획한 편집(적힌 순서, 결과 번호 1부터와 짝)
        var edits: [UsbLibraryEdit] = []
    }

    func run(_ edits: Edits, options: UsbWriteOptions, snapshotTime: String?, progress: @escaping @Sendable (UsbProgress) -> Void,
             isCancelled: @escaping @Sendable () -> Bool) throws -> (UsbEditResult, UsbWriteReport?) {
        let prepared = try prepare(edits, options: options, snapshotTime: snapshotTime, progress: progress, isCancelled: isCancelled)
        lastResult = prepared.result
        lastEdits = prepared.edits
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging = prepared.staging { device.remove(staging) } }
        let result = prepared.result
        guard result.blocks.isEmpty else { throw UsbError.writeRefused(result.blocks) }
        guard let changes = result.changes else {
            if !options.dryRun, let key = prepared.draftKey { try keepBlockedEdits(prepared, volumeKey: key) }
            return (result, nil)
        }
        // 쓰기 직전 USB의 `._*`(사용자·macOS가 둔 것)는 검증이 이 쓰기가 남긴 것으로 세지 않게
        let preexisting = try engine.writer.preexistingAppleDoubles(root)
        do {
            var report = try engine.writer.write(UsbWriteRequest(changes: changes, verification: .edit(result), root: root, paths: paths,
                                                                 guard: writeGuard, options: options, preexistingAppleDoubles: preexisting,
                                                                 progress: progress, isCancelled: isCancelled))
            report.blocks += result.trackBlocks
            if report.outcome == .written, let key = prepared.draftKey { try keepBlockedEdits(prepared, volumeKey: key) }
            return (result, report)
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .volumeChanged, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    func prepare(_ edits: Edits, options: UsbWriteOptions, snapshotTime: String?, progress: @escaping @Sendable (UsbProgress) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> Prepared {
        // 1. 원본: 라이브 master.db면 열지 않고 거부
        if let database { try UsbExportSession.refuseLive(database, device: device) }
        progress(UsbProgress(phase: .planning, cancellable: true))
        // 2. 볼륨(정책·보호 경로·관문). 막히면 USB를 열거하지도 사본을 뜨지도 않는다
        let volume = try writeGuard.volume(root)
        let environment = environmentBlocks(volume, required: [], options: options)
        guard environment.isEmpty else { return Prepared(result: UsbEditResult(blocks: environment)) }
        let volumeKey = try Self.volumeKey(volume)

        // 3. 편집(초안이면 base와 지금 USB를 견준다)
        var notes: [String] = []
        let list: [UsbLibraryEdit]
        var draftKey: String?
        switch edits {
        case let .edits(given): list = given
        case .draft:
            guard let draft = try drafts.load(volumeKey) else {
                return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "noDraft", scope: .volume, message: String(ui: "이 USB에 쌓인 초안이 없습니다. 편집을 먼저 더하세요"))]))
            }
            list = draft.edits
            draftKey = volumeKey
            if !(try engine.writer.databaseFingerprint(root)).sameContent(as: draft.base) {
                notes.append(Self.replannedNote)
            }
        }

        // 4. 저널: 끝나지 않은 쓰기는 막고, 닫힌 저널의 ID highWater를 이어 쓴다. 기기가 바꿔 다시 계획하라고 닫힌 볼륨은 지금 상태로 계획한다
        var highWater: [String: Int] = [:]
        switch engine.writer.journalStatus(paths, volumeKey) {
        case .open:
            return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "recoveryNeeded", scope: .volume,
                                                                    message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))]))
        case .corrupt:
            return Prepared(result: UsbEditResult(blocks: [UsbBlock(code: "journalUnreadable", scope: .volume,
                                                                    message: String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요"))]))
        case let .closed(state, idHighWater):
            highWater = idHighWater
            if state == .needsReplan, !notes.contains(Self.replannedNote) { notes.append(Self.replannedNote) }
        case .missing: break
        }

        // 5. 스냅샷 시각은 세션 사본을 뜨기 전에 원본에서 푼다(곡 더하기·갱신·동기화가 쓰고, 요약 첫 줄에 출처를 적는다)
        let needsLocal = Self.needsLocal(list)
        var snapshot: (date: Date, source: UsbSnapshotTimeSource)?
        if let database { snapshot = try device.snapshotTime(snapshotTime, database) }

        // 6. USB DB 사본 → 읽기·합치기·전제
        let session = UsbLayout.newSessionID()
        let usbCopy = localCopies.appending(path: "usb-\(session)")
        defer { device.remove(usbCopy) }
        let source = try engine.edit.load(root, usbCopy)

        // 7. 세션 전용 로컬 사본(곡 더하기·갱신·동기화가 있을 때만). 끝나면(성공·실패·취소) 지운다
        let copyFolder = localCopies.appending(path: "local-\(session)")
        defer { device.remove(copyFolder) }
        var localDatabase: (any UsbOpenedLibrary)?
        defer { localDatabase?.close() }
        if needsLocal, let database, source.blocks.isEmpty {
            let copy = try device.copyLocalDatabase(database, copyFolder)
            localDatabase = try engine.openLocal(copy)
        }

        // 8. 계획·준비
        let staging = paths.staging.appending(path: session)
        var result: UsbEditResult
        do {
            result = try engine.edit.plan(UsbEditPlanInput(
                source: source, edits: list, local: localDatabase, share: share, volume: volume, root: root,
                staging: staging, session: session, highWater: highWater, snapshotTakenAt: snapshot?.date,
                appVersion: device.appVersion(),
                progress: { done, total in progress(UsbProgress(phase: .staging, completedItems: done, totalItems: total, cancellable: true)) },
                isCancelled: isCancelled))
        } catch {
            device.remove(staging)
            throw error
        }
        result.snapshotTakenAt = snapshot?.date
        result.snapshotSource = snapshot?.source
        result.notes = notes + result.notes
        // 9. 확인 안 된 규칙(실물 볼륨이면 관문이 막는다)
        if let changes = result.changes {
            let late = environmentBlocks(volume, required: changes.requiredRules, options: options)
            if !late.isEmpty {
                result.blocks += late
                result.changes = nil
            }
        }
        guard result.changes != nil else {
            device.remove(staging)
            return Prepared(result: result, draftKey: draftKey, edits: list)
        }
        return Prepared(result: result, staging: staging, draftKey: draftKey, edits: list)
    }

    static var replannedNote: String { String(ui: "USB가 그 사이 바뀌어 다시 계획했습니다") }

    /// 초안에 막힌 편집만 남긴다(적힌 순서). 막힌 편집은 새 스냅샷·기기 변경 가져오기 등으로 풀릴 수 있어 사용자가 다시 만들지 않게 두고,
    /// 쓴 편집·바꿀 것이 없던 편집은 뺀다. 새 base는 지금 USB DB 지문이다. 남는 것이 없으면 초안을 지운다
    func keepBlockedEdits(_ prepared: Prepared, volumeKey: String) throws {
        let blocked = prepared.result.outcomes.compactMap { entry -> UsbLibraryEdit? in
            guard case .blocked = entry.outcome, prepared.edits.indices.contains(entry.edit - 1) else { return nil }
            return Self.resolveCreatedPlaylists(in: prepared.edits[entry.edit - 1], ids: prepared.result.createdPlaylistIDs)
        }
        guard !blocked.isEmpty else {
            try drafts.discard(volumeKey)
            return
        }
        let createdAt = try drafts.load(volumeKey)?.createdAt ?? now()
        try drafts.save(UsbDraft(volumeKey: volumeKey, base: engine.writer.databaseFingerprint(root), edits: blocked, createdAt: createdAt))
    }

    /// 성공한 생성 편집은 초안에서 빠지므로 그 목록을 가리키는 참조는 실제 번호로 남긴다. 아직 만들지 못한 key는 그대로 둔다
    private static func resolveCreatedPlaylists(in edit: UsbLibraryEdit, ids: [String: Int]) -> UsbLibraryEdit {
        func ref(_ value: PlaylistRef) -> PlaylistRef {
            guard case let .new(key) = value, let id = ids[key] else { return value }
            return .id(String(id))
        }
        switch edit {
        case let .addTracks(localContentIDs, playlist):
            return .addTracks(localContentIDs: localContentIDs, playlist: playlist.map(ref))
        case let .syncPlaylist(playlist, localContentIDs):
            return .syncPlaylist(playlist: ref(playlist), localContentIDs: localContentIDs)
        case let .syncSelection(draft):
            let resolved = UsbSyncSelectionDraft(localDBID: draft.localDBID, sourceNodes: draft.sourceNodes, selection: draft.selection,
                                                 enabled: draft.enabled, playlistRefs: draft.playlistRefs.mapValues(ref), baseFiles: draft.baseFiles,
                                                 enabledOnly: draft.enabledOnly)
            return .syncSelection(draft: resolved)
        case .removeTracks, .refreshTracks: return edit
        case let .playlist(edit):
            let resolved: PlaylistEdit
            switch edit {
            case let .create(key, name, isFolder, parent):
                resolved = .create(key: key, name: name, isFolder: isFolder, parent: ref(parent))
            case let .rename(playlist, name): resolved = .rename(playlist: ref(playlist), name: name)
            case let .move(playlist, into): resolved = .move(playlist: ref(playlist), into: ref(into))
            case let .reorder(playlist, index): resolved = .reorder(playlist: ref(playlist), index: index)
            case let .delete(playlist): resolved = .delete(playlist: ref(playlist))
            case let .addTracks(playlist, contentIDs): resolved = .addTracks(playlist: ref(playlist), contentIDs: contentIDs)
            case let .removeTracks(playlist, entries): resolved = .removeTracks(playlist: ref(playlist), entries: entries)
            case let .moveTracks(playlist, entries, to): resolved = .moveTracks(playlist: ref(playlist), entries: entries, to: to)
            }
            return .playlist(edit: resolved)
        }
    }

    /// 볼륨 정책(수정)·보호 경로·실물 관문·확인 안 된 규칙(쓰기 절차의 A 단계와 같은 판정)
    func environmentBlocks(_ volume: UsbVolumeInfo, required: Set<UsbProvisionalRule>, options: UsbWriteOptions) -> [UsbBlock] {
        UsbExportSession.environmentBlocks(volume, root: root, required: required, confirmName: options.confirmName, purpose: .edit, guard: writeGuard,
                                           device: device)
    }

    /// 볼륨 UUID(대문자) — 저널·초안 파일 이름. 읽지 못하면 막는다
    public static func volumeKey(_ volume: UsbVolumeInfo) throws -> String {
        guard let uuid = volume.volumeUUID?.uppercased(), !uuid.isEmpty, uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw UsbError.writeRefused([UsbBlock(code: "noVolumeUUID", scope: .volume,
                                                  message: String(ui: "이 USB의 볼륨 번호를 읽지 못했습니다. 다시 연결한 뒤 시도하세요"))])
        }
        return uuid
    }
}
