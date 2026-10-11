import DJCDomain
import Foundation

/// 빈 USB 내보내기 선택
public struct UsbExportOptions: Sendable {
    public var formats: Set<UsbFormat> = UsbFormat.defaultSet
    public var naming: any UsbAnalysisNaming = RekordboxAnalysisNaming()
    /// 기기 설정 파일을 옮길 로컬 rekordbox 설정 폴더(MYSETTING 등, 확인 안 된 규칙 `settingFiles`). nil이면 옮기지 않는다(기본)
    public var settingsFolder: URL? = nil
    public var verifyAudio = false
    public var confirmName: String? = nil
    /// 사용자가 확인한 볼륨의 UUID(앱). 쓰기 절차가 열 때 지금 볼륨과 비교한다
    public var expectedVolumeUUID: String? = nil
    public var dryRun = false
    /// `--snapshot-time`(ISO 8601). nil이면 사본 이름 → mtime(`UsbSnapshotTime`)
    public var snapshotTime: String? = nil
    /// 선택한 로컬·iTunes 목록 모델. nil이면 기존처럼 스냅샷 DB의 재생 목록을 읽는다.
    public var playlistLayout: PlaylistLayout? = nil
    /// USB 동기화에서 내보내면 rekordbox 선택 파일도 같은 쓰기 묶음으로 만든다.
    public var syncSelection: UsbSyncSelectionDraft? = nil

    public init() {}

    /// 앱·CLI가 같은 칸을 같은 이름으로 채운다(넘기지 않은 칸은 기본값)
    public init(formats: Set<UsbFormat> = UsbFormat.defaultSet, dryRun: Bool = false, confirmName: String? = nil,
                expectedVolumeUUID: String? = nil, verifyAudio: Bool = false, settingsFolder: URL? = nil, snapshotTime: String? = nil,
                playlistLayout: PlaylistLayout? = nil, syncSelection: UsbSyncSelectionDraft? = nil) {
        self.formats = formats
        self.dryRun = dryRun
        self.confirmName = confirmName
        self.expectedVolumeUUID = expectedVolumeUUID
        self.verifyAudio = verifyAudio
        self.settingsFolder = settingsFolder
        self.snapshotTime = snapshotTime
        self.playlistLayout = playlistLayout
        self.syncSelection = syncSelection
    }

    /// 기기 설정 파일을 옮기는지
    public var settings: Bool { settingsFolder != nil }
}

/// 무엇을 내보낼지. 목록이 폴더면 그 안까지 간다
public enum UsbSelection: Sendable, Hashable {
    case playlists([String])
    case tracks([String])
    case both(playlists: [String], tracks: [String])

    public var playlistIDs: [String] {
        switch self {
        case let .playlists(ids), let .both(ids, _): ids
        case .tracks: []
        }
    }

    public var trackIDs: [String] {
        switch self {
        case let .tracks(ids), let .both(_, ids): ids
        case .playlists: []
        }
    }
}

/// 미리 보기(드라이 런·앱 미리 보기도 이것)
public struct UsbExportPreview: Sendable {
    public var plan: UsbExportPlan
    /// 막는 것이 없을 때만 있다. 준비 폴더는 세션이 끝나면 지운다
    public var changes: UsbChangeSet?
    /// 막힘 전부. 곡·목록 단위는 그 곡·목록만 빼고 쓰고, 그 밖(`stopping`)이 하나라도 있으면 쓰지 않는다
    public var blocks: [UsbBlock]
    /// 막지 않는 알림(그림 없음·빼고 쓰는 큐 등)
    public var warnings: [UsbBlock]
    /// 확인 안 된 규칙별 곡 수(계획 규칙 + Device Library 문자열 규칙, 같은 곡은 한 번)
    public var ruleCounts: [UsbProvisionalRule: Int]
    public var requiredRules: Set<UsbProvisionalRule>
    public var requiredBytes: Int64
    public var availableBytes: Int64
    public var snapshotTakenAt: Date
    public var snapshotSource: UsbSnapshotTimeSource

    public init(plan: UsbExportPlan, changes: UsbChangeSet?, blocks: [UsbBlock], warnings: [UsbBlock], ruleCounts: [UsbProvisionalRule: Int],
                requiredRules: Set<UsbProvisionalRule>, requiredBytes: Int64, availableBytes: Int64, snapshotTakenAt: Date,
                snapshotSource: UsbSnapshotTimeSource) {
        self.plan = plan
        self.changes = changes
        self.blocks = blocks
        self.warnings = warnings
        self.ruleCounts = ruleCounts
        self.requiredRules = requiredRules
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.snapshotTakenAt = snapshotTakenAt
        self.snapshotSource = snapshotSource
    }

    /// 쓰기를 멈추는 막힘(볼륨·형식·파일 단위)
    public var stopping: [UsbBlock] {
        blocks.filter {
            switch $0.scope {
            case .track, .playlist: false
            case .volume, .format, .file: true
            }
        }
    }

    /// 막힌 곡 수(같은 곡은 한 번)
    public var blockedTrackCount: Int {
        Set(blocks.compactMap { block -> String? in if case let .track(id) = block.scope { id } else { nil } }).count
    }
}

/// 로컬 스냅샷 사본의 곡·목록을 빈 FAT32·MBR USB에 OneLibrary + Device Library로 내보낸다.
/// 순서: 원본 확인 → 로컬 rekordbox 버전·볼륨 → 세션 전용 로컬 사본 → 후보·계획 → 빌더(행 크기 막힘) → 준비 → `UsbWriter.write`.
/// 로컬 사본은 넘겨받은 `database`에서만 뜨고(사용자 스냅샷 폴더는 읽지도 쓰지도 않는다) 세션이 끝나면 지운다.
/// 입출력은 포트(`UsbLibraryEngine`·`UsbDevice`)로만 한다. 이 타입은 순서와 막힘 판정을 맡는다.
public final class UsbExportSession {
    let database: URL
    let share: URL
    let root: URL
    let writeGuard: UsbWriteGuard
    let paths: UsbWritePaths
    let engine: UsbLibraryEngine
    let device: UsbDevice
    let localCopies: URL
    /// 지금 시각(조립 지점이 준다)
    let now: @Sendable () -> Date

    /// 마지막 미리 보기·쓰기의 계획(앱·CLI 요약이 읽는다)
    public private(set) var lastPreview: UsbExportPreview?

    /// - database: 로컬 스냅샷 사본(라이브 master.db는 거부)
    /// - share: 로컬 rekordbox share(읽기만)
    /// - root: USB 마운트 지점
    /// - engine: USB 읽기·계획·조립·쓰기(시험은 마운트를 흉내 내는 파일 시스템을 묶은 엔진이나 가짜를 넘긴다)
    /// - device: 이 Mac의 일(rekordbox 버전, 라이브 master.db 판정, 세션 사본 뜨기·지우기, 경로 판정)
    /// - localCopies: 세션 사본 폴더(`local-<세션>/`)를 둘 곳
    ///
    /// 가드(볼륨 정보·실물 쓰기 동의)·Mac 쪽 폴더·엔진·이 Mac의 일은 기본값 없이 조립 지점(앱·CLI의 `UsbWriteService`)이 넘긴다.
    public init(database: URL, share: URL, root: URL, guard writeGuard: UsbWriteGuard, paths: UsbWritePaths,
                engine: UsbLibraryEngine, device: UsbDevice, localCopies: URL, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.share = share
        self.root = root
        self.writeGuard = writeGuard
        self.paths = paths
        self.engine = engine
        self.device = device
        self.localCopies = localCopies
        self.now = now
    }

    /// 계획·막힘·준비까지(USB에 쓰지 않는다). 막는 것이 없으면 준비한 변경 묶음을 담고 준비 폴더는 지운다
    public func preview(selection: UsbSelection, options: UsbExportOptions) throws -> UsbExportPreview {
        let prepared = try prepare(selection: selection, options: options, progress: { _ in }, isCancelled: { false })
        if let staging = prepared.staging { device.remove(staging) }
        lastPreview = prepared.preview
        return prepared.preview
    }

    /// 미리 보기와 같은 계획으로 쓴다(`options.dryRun`이면 준비·저널까지만). 막는 것이 있으면 `writeRefused`
    public func write(selection: UsbSelection, options: UsbExportOptions, progress: @escaping @Sendable (UsbProgress) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        let prepared = try prepare(selection: selection, options: options, progress: progress, isCancelled: isCancelled)
        lastPreview = prepared.preview
        // 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패)는 회복이 준비 폴더를 쓸 수 있어 남긴다
        var keepStaging = false
        defer { if !keepStaging, let staging = prepared.staging { device.remove(staging) } }
        let stopping = prepared.preview.stopping
        guard stopping.isEmpty, let changes = prepared.preview.changes, let assembled = prepared.assembled else {
            throw UsbError.writeRefused(stopping.isEmpty ? prepared.preview.blocks : stopping)
        }
        let writeOptions = UsbWriteOptions(dryRun: options.dryRun, confirmName: options.confirmName,
                                           verifyAudio: options.verifyAudio, expectedVolumeUUID: options.expectedVolumeUUID)
        // 쓰기 직전 USB의 `._*`(루트 `._.Trashes`, 사용자 음원 옆 등): 쓰기 전 확인이 막지 않는 것이라 검증이 이 쓰기가 남긴 것으로 세지 않게
        let preexisting = try engine.writer.preexistingAppleDoubles(root)
        do {
            var report = try engine.writer.write(UsbWriteRequest(changes: changes, verification: .export(assembled), root: root, paths: paths,
                                                                 guard: writeGuard, options: writeOptions, preexistingAppleDoubles: preexisting,
                                                                 progress: progress, isCancelled: isCancelled))
            report.blocks += prepared.preview.blocks
            return report
        } catch let error as UsbError {
            switch error {
            case .volumeLost, .volumeChanged, .restoreFailed, .restorePending: keepStaging = true
            default: break
            }
            throw error
        }
    }

    // MARK: - 순서

    struct Prepared {
        var preview: UsbExportPreview
        var assembled: UsbExportAssembled?
        /// 만든 준비 폴더(없으면 nil)
        var staging: URL?
    }

    func prepare(selection: UsbSelection, options: UsbExportOptions, progress: @escaping @Sendable (UsbProgress) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> Prepared {
        // 1. 원본: 라이브 master.db면 열지 않고 거부. 스냅샷 시각은 세션 사본을 뜨기 전에 원본에서 푼다(사본은 이름·시각이 바뀐다)
        try refuseLive()
        let snapshot = try device.snapshotTime(options.snapshotTime, database)
        progress(UsbProgress(phase: .planning, cancellable: true))
        var preview = UsbExportPreview(plan: UsbExportPlanner.plan(UsbExportRequest(candidates: [], snapshotTakenAt: snapshot.date)),
                                       changes: nil, blocks: [], warnings: [], ruleCounts: [:], requiredRules: [], requiredBytes: 0,
                                       availableBytes: 0, snapshotTakenAt: snapshot.date, snapshotSource: snapshot.source)

        // 2·3. 로컬 rekordbox 버전, 볼륨(정책·빈 USB·관문). 여기서 막히면 로컬 사본도 뜨지 않는다
        let volume = try writeGuard.volume(root)
        preview.availableBytes = volume.available
        preview.blocks = try volumeBlocks(volume, options: options)
        let syncProductionBlock = options.syncSelection.flatMap { engine.syncGate.gateBlock($0.baseFiles, options.formats) }
        guard preview.blocks.isEmpty else { return Prepared(preview: preview) }
        let existing = try engine.export.existingContents(root)

        // 세션 사본: 넘겨받은 사본 → 세션 전용 폴더. 끝나면(성공·실패·취소) 지운다(클라우드 토큰이 든 사본을 남기지 않게)
        let session = UsbLayout.newSessionID()
        let copyFolder = localCopies.appending(path: "local-\(session)")
        defer { device.remove(copyFolder) }
        let copy = try device.copyLocalDatabase(database, copyFolder)
        let db = try engine.openLocal(copy)
        defer { db.close() }

        // 4. 후보 → 목록 트리 → 계획, 5·6. 빌더(행 크기 막힘으로 뺀 곡은 다시 계획)
        let tree: [UsbPlaylistInput]
        do {
            if let layout = options.playlistLayout {
                tree = try engine.export.layoutTree(layout, selection.playlistIDs)
            } else {
                tree = selection.playlistIDs.isEmpty ? [] : try engine.export.playlistTree(db, selection.playlistIDs)
            }
        } catch let UsbError.writeRefused(blocks) {
            preview.blocks = blocks
            return Prepared(preview: preview)
        }
        var seen: Set<String> = []
        let ids = (tree.flatMap(\.trackLocalIDs) + selection.trackIDs).filter { seen.insert($0).inserted }
        let candidates = try engine.export.candidates(db, share, ids)
        let loadedIDs = Set(candidates.map(\.localContentID))
        // 후보 로더는 없는 행·삭제된 행을 돌려주지 않는다. 요청과 견줘 조용한 누락을 막는다.
        let missingBlocks = ids.filter { !loadedIDs.contains($0) }.map {
            UsbBlock(code: "localTrackMissing", scope: .track($0),
                     message: String(ui: "내보낼 곡이 로컬 스냅샷에 없습니다. 새 스냅샷을 뜬 뒤 다시 내보내세요"))
        }
        preview.blocks = missingBlocks
        if let syncProductionBlock {
            preview.blocks.append(syncProductionBlock)
            if !missingBlocks.isEmpty {
                preview.blocks.append(UsbBlock(code: "syncSelectionIncomplete", scope: .volume,
                    message: String(ui: "동기화할 목록이나 곡을 모두 쓸 수 없어 동기화 선택도 갱신하지 않았습니다. 막힌 항목의 이유를 해결한 뒤 다시 시도하세요")))
            }
            return Prepared(preview: preview)
        }
        let sources = Dictionary(candidates.map { ($0.localContentID, $0.sourcePath ?? "") }) { first, _ in first }
        let rootURL = root, sameContent = engine.export.sameContent
        let request = UsbExportRequest(
            candidates: candidates, playlists: tree, existing: existing, formats: options.formats, naming: options.naming,
            snapshotTakenAt: snapshot.date, clusterSize: volume.clusterSize ?? 32_768,
            sameContent: { id, relative in
                // 이름이 겹칠 때만 USB 쪽 파일을 읽어 해시한다
                sameContent(sources[id] ?? "", rootURL.appending(path: relative))
            })
        let build = try engine.export.build(request, db, share, Self.today(now()))
        preview.plan = build.plan
        // 동기화 계획이 건너뛴 곡(iTunes 목록의 연결되지 않은 곡 등)도 넣지 못한 곡으로 함께 알린다
        preview.blocks = missingBlocks + build.blocks + (options.syncSelection?.skippedTracks.filter(\.isSkippableInSync) ?? [])
        preview.warnings = build.plan.warnings
        preview.requiredRules = build.plan.requiredRules
        preview.ruleCounts = build.plan.ruleCounts
        // 동기화는 넣지 못한 곡만 빼고 쓴다(rekordbox와 같다). 스냅샷에 없는 곡·볼륨 막힘이 있으면 선택을 쓰지 않는다
        if options.syncSelection != nil, preview.blocks.contains(where: { !$0.isSkippableInSync }) {
            preview.blocks.append(UsbBlock(code: "syncSelectionIncomplete", scope: .volume,
                                           message: String(ui: "동기화할 목록이나 곡을 모두 쓸 수 없어 동기화 선택도 갱신하지 않았습니다. 막힌 항목의 이유를 해결한 뒤 다시 시도하세요")))
            return Prepared(preview: preview)
        }
        if !build.volumeBlocks.isEmpty { return Prepared(preview: preview) }
        if build.plan.tracks.isEmpty {
            preview.blocks.append(UsbBlock(code: "noTracks", scope: .volume,
                                           message: String(ui: "내보낼 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요")))
            return Prepared(preview: preview)
        }

        // 7. 준비 폴더에 DB 셋·분석 파일·아트워크를 만들고 변경 묶음을 얻는다
        let staging = paths.staging.appending(path: session)
        let assembled: UsbExportAssembled
        do {
            assembled = try engine.export.assemble(UsbExportAssembleInput(
                built: build, local: db, share: share, staging: staging, formats: options.formats,
                session: session, settingsFolder: options.settingsFolder, syncSelection: options.syncSelection,
                progress: { done, total in progress(UsbProgress(phase: .staging, completedItems: done, totalItems: total, cancellable: true)) },
                isCancelled: isCancelled))
        } catch {
            device.remove(staging)
            throw error
        }
        preview.changes = assembled.changes
        preview.warnings = assembled.warnings
        preview.requiredRules = assembled.changes.requiredRules
        preview.ruleCounts = assembled.ruleCounts
        preview.requiredBytes = Self.requiredBytes(assembled.changes, volume: volume)
        // 확인 안 된 규칙(Device Library 작성기 규칙까지 합친 뒤)과 용량
        var late = Self.environmentBlocks(volume, root: root, required: assembled.changes.requiredRules, options: options, guard: writeGuard,
                                          device: device)
        if preview.requiredBytes > volume.available { late.append(Self.spaceBlock(needed: preview.requiredBytes, available: volume.available)) }
        preview.blocks += late
        if !late.isEmpty {
            preview.changes = nil
            device.remove(staging)
            return Prepared(preview: preview)
        }
        return Prepared(preview: preview, assembled: assembled, staging: staging)
    }

    // MARK: - 막힘

    /// 라이브 master.db(링크·같은 inode 포함)면 거부한다. 파일은 열지 않는다(경로·stat만)
    func refuseLive() throws {
        try Self.refuseLive(database, device: device)
    }

    /// USB 수정 세션도 같은 판정을 쓴다
    static func refuseLive(_ database: URL, device: UsbDevice) throws {
        guard device.isLiveDatabase(database) else { return }
        throw UsbError.writeRefused([UsbBlock(code: "liveDatabase", scope: .volume,
                                              message: String(ui: "라이브 master.db는 열 수 없습니다. djc snapshot으로 사본을 만든 뒤 읽으세요"))])
    }

    /// 로컬 rekordbox 버전, 볼륨 정책·보호 경로·실물 관문, 이미 라이브러리가 있는 USB, `PIONEER/`에 남은 것
    func volumeBlocks(_ volume: UsbVolumeInfo, options: UsbExportOptions) throws -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        let version = device.appVersion()
        if !device.isVerified(version) {
            let shown = version ?? String(ui: "찾지 못함")
            blocks.append(UsbBlock(code: "localVersionUnverified", scope: .volume,
                                   message: String(ui: "로컬 rekordbox 버전(\(shown))은 USB 내보내기를 확인하지 않았습니다. 확인한 버전(7.2.x)의 rekordbox에서 분석한 라이브러리로 내보내세요")))
        }
        let environment = Self.environmentBlocks(volume, root: root, required: [], options: options, guard: writeGuard, device: device)
        blocks += environment
        // 관문·정책·보호 경로에 막힌 볼륨(동의 없는 실물 등)은 이름도 열거하지 않는다(쓰기 절차 A 단계와 같은 순서)
        guard environment.isEmpty else { return blocks }
        if try engine.export.hasLibrary(root) {
            blocks.append(UsbBlock(code: "libraryExists", scope: .volume,
                                   message: String(ui: "이 USB에는 이미 rekordbox 라이브러리가 있습니다. USB 수정(`djc usb-edit`)으로 곡을 더하세요")))
        } else if let leftover = engine.export.leftoverBlock(root) {
            blocks.append(leftover)
        }
        return blocks
    }

    /// 볼륨 정책·보호 경로·실물 관문·확인 안 된 규칙(쓰기 절차의 A 단계와 같은 판정, rekordbox 실행은 쓰기 때 본다).
    /// 실물 쓰기가 닫혀 있는 동안은 가드 값과 무관하게 임시 폴더 아래 루트만 받는다(쓰기 절차와 같다)
    static func environmentBlocks(_ volume: UsbVolumeInfo, root: URL, required: Set<UsbProvisionalRule>, options: UsbExportOptions,
                                  guard writeGuard: UsbWriteGuard, device: UsbDevice) -> [UsbBlock] {
        environmentBlocks(volume, root: root, required: required, confirmName: options.confirmName, purpose: .export, guard: writeGuard,
                          device: device)
    }

    /// 내보내기·수정 공통(볼륨 정책 목적만 다르다)
    static func environmentBlocks(_ volume: UsbVolumeInfo, root: URL, required: Set<UsbProvisionalRule>, confirmName: String?,
                                  purpose: UsbVolumePurpose, guard writeGuard: UsbWriteGuard, device: UsbDevice) -> [UsbBlock] {
        var blocks = UsbVolumePolicy.blocks(volume, purpose: purpose)
        let real = device.realPath(root.path)
        if isProtected(real ?? root.path, protectedRoots: writeGuard.protectedRoots, realPath: device.realPath) {
            blocks.append(UsbBlock(code: "protectedPath", scope: .volume,
                                   message: String(ui: "rekordbox 라이브러리나 DJCrate 데이터 폴더에는 USB처럼 쓸 수 없습니다. USB 볼륨을 고르세요")))
        }
        // 임시 폴더 밖이면 디스크 이미지라고 나와도 실물로 판정한다(쓰기 절차와 같다)
        let judged = volume.judgedForWrite(underScratch: real.map(device.isUnderScratch) ?? false)
        // 시험 프로세스가 임시 폴더 밖에 쓰지 않는 것은 쓰기 절차의 첫 확인(경로)이 지킨다
        blocks += UsbRuleCheck.blocks(required: required, volume: judged, gate: writeGuard.gate, confirmName: confirmName)
        return blocks
    }

    /// 루트(realpath)가 보호 폴더와 같거나 그 안이거나 그것을 품는지(쓰기 절차와 같은 판정)
    static func isProtected(_ root: String, protectedRoots: [URL], realPath: (String) -> String?) -> Bool {
        protectedRoots.contains { protected in
            let path = realPath(protected.path) ?? protected.path
            return root == path || root.hasPrefix(path + "/") || path.hasPrefix(root + "/")
        }
    }

    /// 쓰기 절차의 용량 확인과 같은 셈: 새로 쓸 크기(클러스터 올림) + 가장 큰 DB × 2 + 여유
    static func requiredBytes(_ changes: UsbChangeSet, volume: UsbVolumeInfo) -> Int64 {
        let cluster = volume.clusterSize ?? 32_768
        func rounded(_ size: Int64) -> Int64 { UsbSpaceEstimate.roundUp(max(size, 0), cluster: max(cluster, 512)) }
        var needed = changes.copies.filter { $0.disposition == .create }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.writes.filter { $0.disposition != .reuse }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.databases.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += 2 * (changes.databases.map(\.size).max() ?? 0)
        return needed + UsbSpaceEstimate.margin(available: volume.available)
    }

    static func spaceBlock(needed: Int64, available: Int64) -> UsbBlock {
        let megabyte: Int64 = 1024 * 1024
        let need = (needed + megabyte - 1) / megabyte, free = available / megabyte
        return UsbBlock(code: "insufficientSpace", scope: .volume,
                        message: String(ui: "USB 여유 공간이 모자랍니다(필요 \(need)MB, 여유 \(free)MB). 곡을 줄이거나 공간이 더 있는 USB를 쓰세요"))
    }

    /// 그날(이 Mac의 시간대) "YYYY-MM-DD"
    static func today(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
