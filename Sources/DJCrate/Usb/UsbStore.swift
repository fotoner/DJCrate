import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 사이드바 USB 절 상태: 연결된 볼륨마다 모양(빈 FAT32·rekordbox USB·쓸 수 없는 모양)과 사본으로 읽은 라이브러리.
/// 여기서는 USB에 쓰지 않는다. 읽기는 호스트가 메인 액터 밖에서 사본으로 하고, 여기서는 결과만 받는다.
/// 쓰기(`UsbWriteCoordinator`)가 쥐는 볼륨별 잠금·진행·지난 쓰기는 핵심부 쓰기 세션(`UsbWriteSession`)이 들고, 그 관찰 상태는
/// 쓰기 화면 모델(`write`, `UsbWriteModel`)에 따로 둔다. 여기서는 같은 이름으로 이어 보인다.
/// 끝나지 않은 쓰기가 있는 볼륨이 나타났다는 알림은 여기 둔다.
/// USB 초안(편집·빠진 볼륨의 초안)도 여기서 본다. 초안 파일은 `UsbEditActions`·초안 쓰기가 볼륨마다 한 줄(`draftQueue`)로 고친다.
@MainActor @Observable final class UsbStore {
    enum Shape: Equatable {
        /// 내보낼 수 있는 빈 FAT32·MBR(rekordbox 라이브러리 없음)
        case emptyExportable
        case rekordbox(formats: Set<UsbFormat>)
        /// 읽지 않았다(볼륨 모양). 이유와 할 일
        case unsupported(reason: String)
        case reading
        case failed(String)

        /// 다시 읽을 필요가 없는 결과
        var isSettled: Bool {
            switch self {
            case .emptyExportable, .rekordbox: true
            case .unsupported, .reading, .failed: false
            }
        }
    }

    private(set) var volumes: [UsbVolumeInfo] = []
    /// 볼륨키 → 모양
    private(set) var shapes: [String: Shape] = [:]
    private(set) var libraries: [String: UsbLibrary] = [:]
    /// 볼륨키 → 라이브러리를 읽은 판. 읽을 때마다 오른다(곡 줄의 썸네일이 같은 자리에 덮어쓴 그림도 새로 읽게)
    private(set) var libraryRevisions: [String: Int] = [:]
    private(set) var infos: [String: UsbInfo] = [:]
    /// 볼륨키 → content_id → 상태
    private(set) var syncBadges: [String: [Int: UsbSyncStatus]] = [:]
    /// 볼륨키 → USB content_id → 로컬 ContentID(짝이 하나인 곡만, 배지와 함께 계산)
    private(set) var localMatches: [String: [Int: String]] = [:]
    /// 쓰기 세션의 화면 모델(잠금·진행·옮기기 상태). 사이드바 상태와 따로 관찰한다
    let write = UsbWriteModel()
    /// 핵심부 쓰기 세션(쓰기 흐름 `UsbWriteFlow`가 쥔다)
    var session: UsbWriteSession { write.session }
    /// 볼륨별 잠금(쓰기 중 표시). 잠긴 볼륨은 다시 읽거나 꺼내지 않는다. `beginWrite`·`endWrite`로만 바꾼다
    var busyVolumes: Set<String> { write.busyVolumes }
    private(set) var ejecting: Set<String> = []
    /// 마지막 꺼내기 단추가 실패한 이유와 할 일(성공하면 지운다)
    private(set) var ejectMessage: String?
    /// 지금 쓰는 볼륨과 진행(덮개가 읽는다). 앱은 한 번에 한 볼륨에만 쓴다
    var activeWrite: UsbActiveWrite? { write.activeWrite }
    /// 열 내보내기 시트(볼륨·다시 미리 보기 결과)
    var exportSheet: UsbExportSheetRequest?
    /// 볼륨 이름 옆에서 연 동기화 시트
    var syncSheet: UsbSyncSheetRequest?
    /// 볼륨별 동기화 선택. 시험에서는 폴더를 주입할 때만 저장한다.
    @ObservationIgnored var syncSelectionDirectory: URL?
    /// 동기화 창이 읽는 파일(선택 파일·masterPlaylists6.xml·설정 파일)과 로컬 짝짓기 키. 앱은 조립 지점이 실제 구현을 붙인다.
    /// nil이면 동기화 창이 선택·라이브러리를 읽지 못한 것으로 알린다(시험·캡처의 기본)
    @ObservationIgnored var syncFiles: UsbSyncFiles?
    @ObservationIgnored var localKeys: LocalLibraryKeysSource?
    let readPolicy: UsbReadPolicy
    /// 볼륨키 → 초안 편집 수(없으면 nil)
    private(set) var draftCounts: [String: Int] = [:]
    /// 볼륨키 → 초안이 바뀐 횟수(쓰기 대기 목록이 초안을 다시 읽는다)
    private(set) var draftRevisions: [String: Int] = [:]
    /// 초안이 남은 채 빠진 볼륨(이번 실행에서 읽은 것만): 그때 볼륨 정보와 라이브러리. 다시 붙으면 뺀다
    private(set) var absentDrafts: [String: UsbAbsentVolume] = [:]
    /// USB 초안 파일(앱은 DJC_HOME 아래 `usb-drafts`). nil이면 초안을 다루지 않는다(시험·캡처의 기본 — 사용자 폴더를 읽지 않게)
    @ObservationIgnored var drafts: UsbDraftFiles?
    /// 볼륨키 → 초안 편집(파일에서 읽은 그대로). 순서 옮기기처럼 초안 위에서 판정하는 메뉴가 읽는다
    private(set) var draftEdits: [String: [UsbLibraryEdit]] = [:]
    /// 같은 실행의 유효한 native 초안은 창을 닫아도 사본을 소유한다. 디스크에서 문맥을 재구성하지 않는다.
    struct SyncDraftSource: Sendable {
        var job: UsbEditJob
        var edits: [UsbLibraryEdit]
        let snapshotLease: UsbSyncSnapshotLease
        let id = UUID()
        let sourceIsCurrent: @MainActor @Sendable () -> Bool
    }
    @ObservationIgnored private(set) var syncDraftSources: [String: SyncDraftSource] = [:]

    func rememberSyncDraft(_ job: UsbEditJob, edits: [UsbLibraryEdit],
                           sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool) {
        let key = job.volumeKey
        guard let lease = job.syncSourceContext?.snapshot?.lease, job.database == lease.database,
              draftEdits[key] == edits, volume(key)?.matchesSyncWriteVolume(job.volume) == true, sourceIsCurrent() else {
            invalidateSyncDraft(key)
            return
        }
        syncDraftSources[key] = SyncDraftSource(job: job, edits: edits, snapshotLease: lease, sourceIsCurrent: sourceIsCurrent)
        observeSyncDraftSource(key)
    }

    /// 초안 파일·원래 스냅샷은 남기고, 이 실행이 만든 사본의 소유권만 해제한다.
    func invalidateSyncDraft(_ key: String) { syncDraftSources[key] = nil }

    private func observeSyncDraftSource(_ key: String) {
        guard let saved = syncDraftSources[key] else { return }
        let id = saved.id
        let current = withObservationTracking {
            saved.sourceIsCurrent()
        } onChange: { [weak self] in
            // Observation 알림은 변경 직전이다. 새 값으로 판정하고 같은 초안일 때만 다시 관찰한다.
            Task { @MainActor [weak self] in
                guard let self, self.syncDraftSources[key]?.id == id else { return }
                self.observeSyncDraftSource(key)
            }
        }
        if !current { invalidateSyncDraft(key) }
    }
    /// 새 USB 읽기를 채택했을 때 원문이 달라졌으면 초안은 남기고 사본만 해제한다.
    private func validateSyncDraftAfterRead(_ key: String) async {
        guard let saved = syncDraftSources[key] else { return }
        let bases = saved.edits.compactMap { edit -> [UsbFormat: Data]? in
            if case let .syncSelection(draft) = edit { return draft.baseFiles }
            return nil
        }
        guard let expected = bases.first, bases.allSatisfy({ $0 == expected }),
              saved.sourceIsCurrent(), volume(key)?.matchesSyncWriteVolume(saved.job.volume) == true else {
            invalidateSyncDraft(key)
            return
        }
        let service = writeService, volume = saved.job.volume
        let formats = libraries[key]?.formats ?? UsbFormat.defaultSet
        let matches = await BlockingWork.run(qos: .utility) {
            guard let actual = try? service.currentVolume(volume), actual.matchesSyncWriteVolume(volume),
                  let files = try? service.syncSelectionBaseFiles(actual, formats: formats) else { return false }
            return files == expected
        }
        guard syncDraftSources[key]?.id == saved.id else { return }
        if !matches || !saved.sourceIsCurrent() || self.volume(key)?.matchesSyncWriteVolume(volume) != true || draftEdits[key] != saved.edits {
            invalidateSyncDraft(key)
        }
    }

    /// 마운트 지점이 임시 폴더 뿌리 아래인지(realpath). 그 밖의 디스크 이미지는 쓰기 때 실물로 본다(편집 막힘 미리 판정).
    /// 기본은 쓰기 창구의 판정(쓰기 세션과 같다). 시험은 지어낸 마운트 지점을 넘긴다
    @ObservationIgnored var isScratchMount: (String) -> Bool
    /// 볼륨키 → 초안 고치기 줄(읽고-고치고-쓰기가 겹쳐 편집을 잃지 않게, 누른 차례대로)
    @ObservationIgnored private var draftChains: [String: Task<Void, Never>] = [:]
    /// 볼륨키 → 그 줄에 선 일 수(돌고 있는 일 포함)
    @ObservationIgnored private var draftQueueLengths: [String: Int] = [:]

    /// 볼륨키 → 마지막 내보내기(`session`)
    var lastExports: [String: UsbExportJob] {
        get { session.lastExports }
        set { session.lastExports = newValue }
    }
    var lastMigrations: Set<String> {
        get { session.lastMigrations }
        set { session.lastMigrations = newValue }
    }
    /// 관찰은 화면 모델에서, 바꾸기는 세션으로 한다(세션이 내보내면 화면 모델이 곧바로 따라온다)
    var migrationBackups: [String: URL] {
        get { write.migrationBackups }
        set { session.migrationBackups = newValue }
    }
    var migrationBlockReasons: [String: String] {
        get { write.migrationBlockReasons }
        set { session.migrationBlockReasons = newValue }
    }
    /// 앱의 USB 쓰기 창구(유스케이스 `UsbWriting`, `LibraryStore.usbCoordinator`가 쓴다. 저널 알림과 같은 창구를 붙인다).
    /// 만들 때 정하고 바꾸지 않는다(붙인 쓰기 흐름과 미리 보기·확인이 같은 창구를 보게)
    @ObservationIgnored let writeService: any UsbWriting
    /// 끝나지 않은 쓰기가 있는 볼륨이 나타났을 때. 알림만 띄운다 — 회복은 사용자가 누를 때만 한다
    @ObservationIgnored var onPendingJournal: ((UsbVolumeInfo) -> Void)?
    @ObservationIgnored private let host: any UsbHost
    @ObservationIgnored private let localLibrary: @Sendable () -> LocalLibraryKeys?
    @ObservationIgnored private let journal: @Sendable (String) -> UsbJournalInfo
    /// 이번에 붙어 있는 동안 저널을 본 볼륨(떨어지면 지운다: 다시 나타나면 또 본다)
    @ObservationIgnored private var journalChecked: Set<String> = []
    /// 목록·라이브러리·배지가 바뀐 뒤(보고 있는 USB 목록을 다시 만든다)
    @ObservationIgnored var onChange: (() -> Void)?
    /// 라이브러리를 읽었거나 로컬 짝을 다시 계산한 뒤(볼륨, 그 라이브러리, USB content_id → 로컬 ContentID). 기기 재생 기록을 보존한다(#43).
    /// 읽기 성공 즉시 짝 없이도 먼저 보존하고, 로컬 키가 준비되면 짝을 다시 계산해 알린다.
    @ObservationIgnored var onLibraryEvaluated: ((UsbVolumeInfo, UsbLibrary, [Int: String]) -> Void)?
    /// 다 읽은 볼륨의 그때 정보(같으면 알림 때 다시 읽지 않는다)
    @ObservationIgnored private var readVolumes: [String: UsbVolumeInfo] = [:]
    /// 새로 읽기를 한 줄로 세운다(알림과 새로고침이 겹쳐도 차례로)
    @ObservationIgnored private var chain: Task<Void, Never>?

    /// - writeService: USB 쓰기 창구(앱은 조립 지점이 만든 `UsbWriteService`, 시험은 가짜). 기본값이 없다
    /// - localLibrary: 로컬 짝짓기 키(앱이 연 스냅샷에서 미리 읽어 둔 값). 메인 액터 밖에서 부른다
    /// - journal: 볼륨키 → 그 볼륨의 쓰기 저널 상태(앱은 `UsbWriting.journal`, 기본은 저널을 보지 않는다). 메인 액터 밖에서 부른다
    init(host: any UsbHost, readPolicy: UsbReadPolicy = .current(), writeService: any UsbWriting,
         localLibrary: @escaping @Sendable () -> LocalLibraryKeys?,
         journal: @escaping @Sendable (String) -> UsbJournalInfo = { _ in .none }) {
        self.host = host
        self.readPolicy = readPolicy
        self.writeService = writeService
        self.localLibrary = localLibrary
        self.journal = journal
        isScratchMount = { [writeService] in writeService.isScratchMount($0) }
    }

    /// 동기화 선택 파일의 쓰기 관문(편집 막힘 미리 판정·동기화 창). 쓰기 창구와 같은 규칙
    var syncGate: UsbSyncSelectionGate { writeService.syncGate }

    /// 초안 고치기(초안 파일 + 처음 base는 그 자리 USB DB 지문). 초안을 다루지 않으면 nil
    var draftEditing: UsbDraftEditing? {
        let service = writeService
        return drafts.map { UsbDraftEditing(files: $0, base: { try service.draftBase($0) }, now: { Date() }) }
    }

    // MARK: - 읽기

    /// 볼륨을 모두 다시 본다(이미 읽은 USB도 다시 사본을 떠서 읽는다)
    func refresh() async {
        await enqueue(force: true)
    }

    /// 사이드바 "USB 다시 읽기" 단추. 뷰는 기다리지 않는다
    @discardableResult
    func refreshTapped() -> Task<Void, Never> { Task { await refresh() } }

    /// 볼륨 이벤트의 목록을 채택한다. 중간 분리 알림이 합쳐져도 같은 정보의 재연결 USB를 다시 읽는다.
    func watch() async {
        await enqueue(force: false)
        for await volumes in host.volumeEvents {
            await enqueue(force: true, listedVolumes: volumes)
        }
    }

    private func enqueue(force: Bool, listedVolumes: [UsbVolumeInfo]? = nil) async {
        let listed = listedVolumes ?? host.volumes()
        let previous = chain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.update(force: force, all: listed)
        }
        chain = task
        await task.value
    }

    private func update(force: Bool, all: [UsbVolumeInfo]) async {
        // 시험 실행은 실물 볼륨을 이름도 보이지 않게 뺀다(화면 캡처에 남지 않게)
        let visible = (readPolicy == .diskImagesOnly ? all.filter(\.isDiskImage) : all).sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.mountPoint < rhs.mountPoint : order == .orderedAscending
        }
        let previous = volumes
        volumes = visible
        // 부재 초안은 표시하되, 분리·같은 UUID의 장치 변경 뒤 사본을 이어 쓰지는 않는다.
        for (key, saved) in syncDraftSources where visible.first(where: { $0.usbKey == key })?.matchesSyncWriteVolume(saved.job.volume) != true {
            invalidateSyncDraft(key)
        }
        let keys = Set(visible.map(\.usbKey))
        // 초안이 있는 볼륨은 빠져도 쓰기 대기 목록을 남긴다(다시 붙으면 그 볼륨 아래로 돌아간다)
        for volume in previous where !keys.contains(volume.usbKey) { rememberDraft(volume) }
        for key in keys { absentDrafts[key] = nil }
        for key in Set(shapes.keys).subtracting(keys) {
            forget(key)
            shapes[key] = nil
        }
        journalChecked.formIntersection(keys)
        // 연 내보내기 시트의 볼륨이 빠지면 닫는다(닫을 단추 없는 빈 창으로 남지 않게)
        if let sheet = exportSheet, !keys.contains(sheet.volumeKey) { exportSheet = nil }
        if let sheet = syncSheet, !keys.contains(sheet.volumeKey), activeWrite == nil { syncSheet = nil }
        defer { onChange?() }
        guard !visible.isEmpty else { return }
        for volume in visible {
            let key = volume.usbKey
            guard !busyVolumes.contains(key) else { continue }
            await checkJournal(volume)
            if let problem = UsbVolumePolicy.problems(volume, purpose: .export).first {
                forget(key)
                shapes[key] = .unsupported(reason: problem.message)
                continue
            }
            if !force, readVolumes[key] == volume, shapes[key]?.isSettled == true { continue }
            await read(volume)
        }
    }

    private func read(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey
        // 다시 읽는 동안에도 앞서 읽은 라이브러리는 보여 두고, 새 결과가 오면 한 번에 바꾼다
        migrationBlockReasons[key] = nil
        shapes[key] = .reading
        do {
            let info = try await host.info(for: volume)
            let formats = Set(info.formats.compactMap(UsbFormat.init(rawValue:)))
            if formats.isEmpty {
                forget(key)
                infos[key] = info
                shapes[key] = .emptyExportable
            } else {
                let library = try await host.library(for: volume)
                // 로컬 키 계산을 기다리다 USB가 빠져도 읽은 기기 기록은 잃지 않는다.
                onLibraryEvaluated?(volume, library, [:])
                let evaluated = await badges(for: library)
                infos[key] = info
                libraries[key] = library
                libraryRevisions[key, default: 0] += 1
                syncBadges[key] = evaluated.badges
                localMatches[key] = evaluated.matches
                shapes[key] = .rekordbox(formats: formats)
                // 아래 기다림 전에 알린다(그 사이 볼륨이 빠지면 이 라이브러리로 부르지 않게)
                onLibraryEvaluated?(volume, library, evaluated.matches)
                await reloadDraft(key)
                await validateSyncDraftAfterRead(key)
            }
            readVolumes[key] = volume
        } catch {
            forget(key)
            shapes[key] = .failed(Self.message(for: error))
        }
    }

    /// 읽는 볼륨이 나타나면 한 번 저널을 본다. 끝나지 않은 쓰기(닫힌 상태가 아닌 저널)만 알린다 — 드라이 런·다시 계획은 닫힌 상태다
    private func checkJournal(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey
        guard journalChecked.insert(key).inserted else { return }
        let journal = journal
        let info = await BlockingWork.run(qos: .utility) { journal(key) }
        // 기다리는 동안 떨어졌거나 쓰기가 시작됐으면 알리지 않는다
        guard info.isPending, journalChecked.contains(key), !busyVolumes.contains(key), self.volume(key) != nil else { return }
        onPendingJournal?(volume)
    }

    private func forget(_ key: String) {
        invalidateSyncDraft(key)
        libraries[key] = nil
        infos[key] = nil
        syncBadges[key] = nil
        localMatches[key] = nil
        readVolumes[key] = nil
    }

    /// 로컬 스냅샷을 새로 읽었을 때 배지만 다시 계산한다
    func localLibraryChanged() async {
        for (key, library) in libraries {
            let evaluated = await badges(for: library)
            // 기다리는 동안 볼륨이 빠졌거나 다시 읽혔으면 버린다
            if libraries[key] == library {
                syncBadges[key] = evaluated.badges
                localMatches[key] = evaluated.matches
                if let mounted = self.volume(key) { onLibraryEvaluated?(mounted, library, evaluated.matches) }
            }
        }
        onChange?()
    }

    private func badges(for library: UsbLibrary) async -> UsbLocalEvaluation {
        let localLibrary = localLibrary
        return await BlockingWork.run(qos: .utility) { () -> UsbLocalEvaluation in
            let local = localLibrary()
            let evaluated = UsbSyncBadges.evaluate(library: library, local: local)
            return UsbLocalEvaluation(badges: evaluated.badges, matches: evaluated.matches)
        }
    }

    static func message(for error: any Error) -> String {
        AppErrorMessage.log(error)
        if let error = error as? UsbError, let description = error.errorDescription { return description }
        return String(ui: "USB 라이브러리를 읽지 못했습니다. USB를 다시 연결한 뒤 다시 시도하세요")
    }

    // MARK: - 꺼내기

    /// 사이드바 꺼내기 단추. 실패하면 이유를 `ejectMessage`에 남긴다(성공하면 지운다)
    @discardableResult
    func ejectTapped(_ volumeKey: String) -> Task<Void, Never> {
        Task { ejectMessage = await eject(volumeKey) }
    }

    /// 볼륨을 꺼낸다. 실패하면 이유와 할 일(nil = 성공)
    func eject(_ volumeKey: String) async -> String? {
        guard let volume = volumes.first(where: { $0.usbKey == volumeKey }) else { return nil }
        guard !busyVolumes.contains(volumeKey) else { return String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 꺼내세요") }
        guard !ejecting.contains(volumeKey) else { return nil }
        ejecting.insert(volumeKey)
        defer { ejecting.remove(volumeKey) }
        do {
            try await host.eject(volume)
        } catch {
            AppErrorMessage.log(error)
            return String(ui: "USB를 꺼내지 못했습니다. 사용 중인 앱을 닫고 Finder에서 꺼내세요")
        }
        // 떨어짐 알림을 기다리지 않고 바로 뺀다
        rememberDraft(volume)
        volumes.removeAll { $0.usbKey == volumeKey }
        journalChecked.remove(volumeKey)
        forget(volumeKey)
        shapes[volumeKey] = nil
        if exportSheet?.volumeKey == volumeKey { exportSheet = nil }
        if syncSheet?.volumeKey == volumeKey { syncSheet = nil }
        onChange?()
        return nil
    }

    // MARK: - 초안

    /// 초안 편집을 받는 볼륨: 읽은 rekordbox USB(다시 읽는 중 포함, 볼륨 번호가 있어야 한다)와 초안이 남은 채 빠진 볼륨.
    /// 읽지 못한 볼륨은 받지 않는다(초안 메뉴 자체를 보이지 않는다)
    func acceptsEdits(_ key: String) -> Bool {
        guard drafts != nil else { return false }
        if let volume = volume(key) {
            return libraries[key] != nil && (try? UsbEditSession.volumeKey(volume)) == key
        }
        return absentDrafts[key] != nil
    }

    func presentSync(_ key: String) {
        guard volume(key) != nil, activeWrite == nil, !busyVolumes.contains(key), !ejecting.contains(key) else { return }
        switch shapes[key] {
        case .emptyExportable?, .rekordbox?: syncSheet = UsbSyncSheetRequest(volumeKey: key)
        default: break
        }
    }

    /// 편집 대상 볼륨 이름(빠진 볼륨도)
    func editName(_ key: String) -> String? { volume(key)?.name ?? absentDrafts[key]?.volume.name }

    /// 편집 대상 라이브러리(빠진 볼륨은 마지막으로 읽은 것)
    func editLibrary(_ key: String) -> UsbLibrary? { libraries[key] ?? absentDrafts[key]?.library }

    /// 편집 대상 라이브러리에 쓰기 전 초안의 목록 항목 편집을 얹은 것(#240). 목록 줄·끌어 놓을 자리·막힘 판정이 이 순서를 본다
    func projectedLibrary(_ key: String) -> UsbLibrary? {
        editLibrary(key).map { UsbDraftProjection.library($0, edits: draftEdits[key] ?? []) }
    }

    /// 그 볼륨의 초안 고치기를 한 줄로 세운다: 앞서 넣은 일이 끝난 뒤에 body를 돌린다(볼륨마다 따로).
    /// 초안 파일을 읽고 고쳐 쓰는 일(편집 더하기·빼기·버리기, 초안 쓰기)과 편집 수 다시 읽기는 모두 이 줄로 한다.
    /// body 안에서 같은 볼륨의 줄을 다시 기다리지 않는다(스스로를 기다려 멈춘다)
    func draftQueue<T: Sendable>(_ key: String, _ body: @escaping @MainActor () async -> T) async -> T {
        let previous = draftChains[key]
        draftQueueLengths[key, default: 0] += 1
        let task = Task { @MainActor () -> T in
            await previous?.value
            let value = await body()
            let left = (draftQueueLengths[key] ?? 1) - 1
            draftQueueLengths[key] = left > 0 ? left : nil
            return value
        }
        draftChains[key] = Task { _ = await task.value }
        return await task.value
    }

    /// 그 볼륨의 초안 줄에 선 일 수(돌고 있는 일 포함). 시험이 뒤 일이 줄에 선 것을 시간 대신 이것으로 기다린다
    func draftQueueLength(_ key: String) -> Int { draftQueueLengths[key] ?? 0 }

    /// 그 볼륨의 초안을 다시 읽는다(메인 액터 밖에서 파일을 읽는다)
    func reloadDraft(_ key: String) async {
        guard let editing = draftEditing else { return }
        await draftQueue(key) { [weak self] in
            let edits = await BlockingWork.run(qos: .utility) { () -> [UsbLibraryEdit] in editing.edits(key) }
            self?.setDraft(edits, for: key)
        }
    }

    /// 초안이 바뀌었다(편집 동작·쓰기 뒤). 빠진 볼륨의 초안이 비면 사이드바에서 뺀다
    func setDraft(_ edits: [UsbLibraryEdit], for key: String) {
        let count = edits.count
        if let saved = syncDraftSources[key], saved.edits != edits { invalidateSyncDraft(key) }
        draftEdits[key] = edits.isEmpty ? nil : edits
        draftCounts[key] = count > 0 ? count : nil
        draftRevisions[key, default: 0] += 1
        if count == 0, absentDrafts[key] != nil {
            absentDrafts[key] = nil
        }
        // 목록은 초안을 얹은 순서로 보인다. 빠진 볼륨의 쓰기 대기 목록을 보던 중에 초안이 비면 라이브러리로 돌아간다
        onChange?()
    }

    /// 빠지는 볼륨에 초안이 있으면 기억한다(읽은 볼륨만)
    private func rememberDraft(_ volume: UsbVolumeInfo) {
        let key = volume.usbKey
        guard drafts != nil, (draftCounts[key] ?? 0) > 0, libraries[key] != nil,
              (try? UsbEditSession.volumeKey(volume)) == key else { return }
        absentDrafts[key] = UsbAbsentVolume(volume: volume, library: libraries[key])
    }

    // MARK: - 쓰기 잠금·진행

    /// 볼륨을 잠그고 쓰기를 시작한다(`UsbWriteSession.begin`). 그 볼륨이 이미 잠겼거나 다른 볼륨에 쓰는 중이면 nil.
    /// 잠근 볼륨은 다시 읽기·꺼내기·끝나지 않은 쓰기 알림에서 빠진다
    /// - cancellable: 취소를 받는 일인지(회복·되돌리기는 받지 않는다)
    func beginWrite(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        guard let flag = session.begin(volume, title: title, cancellable: cancellable) else { return nil }
        // 이 쓰기가 연 저널을 "나타난 볼륨의 끝나지 않은 쓰기"로 다시 알리지 않는다(다시 붙이면 본다)
        journalChecked.insert(volume.usbKey)
        return flag
    }

    func setWriteTitle(_ title: String, for key: String) { session.setTitle(title, for: key) }
    func report(_ progress: UsbProgress, for key: String) { session.report(progress, for: key) }
    func endWrite(_ key: String) { session.end(key) }
    func cancelWrite() { write.cancel() }

    // MARK: - 목록 줄

    func volume(_ key: String) -> UsbVolumeInfo? { volumes.first { $0.usbKey == key } }

    // MARK: - 실물 쓰기

    /// 미리 판정용 실물 쓰기 관문. 앱은 내보내기 시트·쓰기 확인 창이 동의를 받으므로 동의한 관문으로 본다.
    /// 디스크 이미지만 읽는 실행(시험)은 동의 없음(실물은 막힘)
    var physicalGate: UsbPhysicalWriteGate {
        UsbPhysicalWriteGate(consented: readPolicy == .all)
    }

    /// 이 볼륨에 쓰기가 막히는 까닭(실물 관문만, 쓰기 세션과 같은 판정·문구). 쓸 수 있으면 nil.
    /// 앱은 쓰기 확인 창이 볼륨 이름 확인을 대신한다
    func physicalWriteBlock(_ volume: UsbVolumeInfo) -> String? {
        let judged = volume.judgedForWrite(underScratch: isScratchMount(volume.mountPoint))
        return physicalGate.blocks(judged, confirmName: volume.name).first?.message
    }

    /// 사이드바 대상의 곡 줄(읽기 전용). 재생 목록은 쓰기 전 초안을 얹은 차례다(`UsbDraftProjection`)
    func rows(for target: UsbSidebarTarget) -> [TrackRow] {
        guard let volume = volume(target.volumeKey), let read = libraries[target.volumeKey] else { return [] }
        let library = UsbDraftProjection.library(read, edits: draftEdits[target.volumeKey] ?? [])
        let badges = syncBadges[target.volumeKey] ?? [:]
        let revision = libraryRevisions[target.volumeKey] ?? 0
        switch target {
        case .collection:
            return UsbLibraryRows.collection(library: library, volumeKey: target.volumeKey, mountPoint: volume.mountPoint, badges: badges,
                                             revision: revision)
        case let .playlist(_, id):
            return UsbLibraryRows.playlist(id, library: library, volumeKey: target.volumeKey, mountPoint: volume.mountPoint, badges: badges,
                                           revision: revision)
        case .pending:
            return []
        }
    }

    /// 대상이 아직 보이는지(볼륨이 빠지거나 목록이 없어지면 거짓). 쓰기 대기 목록은 초안이 남은 채 빠진 볼륨에도 있다
    func contains(_ target: UsbSidebarTarget) -> Bool {
        if case let .pending(key) = target { return acceptsEdits(key) }
        guard volume(target.volumeKey) != nil else { return false }
        switch target {
        case .collection: return libraries[target.volumeKey] != nil || shapes[target.volumeKey] == .reading
        case let .playlist(key, id): return libraries[key]?.playlists.contains { $0.id == id } ?? (shapes[key] == .reading)
        case .pending: return false
        }
    }

    /// 목록 제목
    func title(for target: UsbSidebarTarget) -> String {
        let name = editName(target.volumeKey) ?? "USB"
        switch target {
        case .collection: return String(ui: "\(name) · 컬렉션")
        case let .playlist(key, id): return libraries[key]?.playlists.first { $0.id == id }?.name ?? name
        case .pending: return String(ui: "\(name) · USB 쓰기 대기")
        }
    }
}

/// 사이드바 USB 절에서 고르는 대상
public enum UsbSidebarTarget: Hashable, Sendable {
    case collection(volumeKey: String)
    case playlist(volumeKey: String, id: Int)
    /// USB 쓰기 대기(그 볼륨의 초안)
    case pending(volumeKey: String)

    var volumeKey: String {
        switch self {
        case let .collection(key), let .playlist(key, _), let .pending(key): key
        }
    }
}

/// 초안이 남은 채 빠진 볼륨: 빠질 때의 정보와 마지막으로 읽은 라이브러리
struct UsbAbsentVolume: Equatable {
    var volume: UsbVolumeInfo
    var library: UsbLibrary?
}

struct UsbSyncSheetRequest: Equatable, Identifiable {
    var volumeKey: String
    var id: String { volumeKey }
}

/// 로컬 곡과 견준 결과. 로컬 키를 몰랐으면(스냅샷을 아직 읽지 않음) 배지·짝이 비어 있다.
private struct UsbLocalEvaluation: Sendable {
    var badges: [Int: UsbSyncStatus]
    var matches: [Int: String]
}
