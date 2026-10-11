@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

@MainActor
private final class SyncSourceWriteHost: UsbWriteHost {
    var toast: AppToast?
    var source: UsbSyncSource
    var revision = 1
    var database = URL(filePath: "/tmp/djc-synthetic/snapshot.db")
    let share = URL(filePath: "/tmp/djc-synthetic/share")
    var checks = 0
    var readEpoch = 1
    let root: URL
    var lease: UsbSyncSnapshotLease?
    var usbHost: FakeUsbHost?
    var liveVolume: FakeUsbLiveVolumeReader?

    init() throws {
        source = UsbSyncSource.make(rekordbox: PlaylistLayout([(.init(id: "10", name: "목록"), 0)]),
                                   iTunes: SyncedITunesLibrary(snapshot: .init(status: .ready), tracks: []))
        root = FileManager.default.temporaryDirectory.appending(path: "djc-source-host-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appending(path: "snapshot.db")
        try Data("합성 원본 A".utf8).write(to: database)
        lease = try UsbSyncSnapshotLease.capture(.capture(database), directory: root.appending(path: "copies"))
    }
    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool {
        checks += 1
        return context.source == source && context.catalogRevision == revision && context.readEpoch == readEpoch
            && context.snapshot?.provenance.sourceURL == self.database
            && context.snapshot?.database == database && share == self.share
    }
    func change(_ field: String) {
        switch field {
        case "source": source.layout = PlaylistLayout([(.init(id: "10", name: "바뀐 목록"), 0)])
        case "revision": revision += 1
        case "epoch": readEpoch += 1
        default: database = URL(filePath: "/tmp/djc-synthetic/new-snapshot.db")
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class SyncSourceChangingPrompter: HeadlessReflectionPrompter {
    var onConfirm: () -> Void = {}
    var confirmations = 0
    func show(_ prompt: ReflectionPrompt) -> Bool {
        if prompt.confirm == String(ui: "USB에 쓰기") { confirmations += 1; onConfirm() }
        return true
    }
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { .cancel }
}

@MainActor
@Suite("USB native 쓰기 직전 원본 검사")
struct UsbSyncSourceWriteGuardTests {
    private func setup() async throws -> (UsbStore, SyncSourceWriteHost, FakeUsbWriteService, UsbExportJob) {
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 USB")
        let usbHost = FakeUsbHost([volume])
        usbHost.serveEmpty(volume)
        let service = FakeUsbWriteService()
        let usb = UsbStore(host: usbHost, readPolicy: .all, writeService: service, localLibrary: { nil })
        await usb.refresh()
        let host = try SyncSourceWriteHost()
        host.usbHost = usbHost
        let live = FakeUsbLiveVolumeReader(volume)
        host.liveVolume = live
        service.update {
            $0.liveVolumeReader = { try live.read($0) }
            $0.liveSyncFilesReader = { _, _ in [:] }
        }
        let draft = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: host.source.nativeNodes,
                                         selection: .init(selectedIDs: ["10"]), enabled: true,
                                         playlistRefs: ["10": .id("10")], baseFiles: [:])
        let job = UsbExportJob(database: try #require(host.lease).database, share: host.share, volume: volume, selection: .playlists(["10"]),
                               formats: [.oneLibrary], snapshotTime: nil, syncSelection: draft,
                               syncSourceContext: .init(source: host.source, catalogRevision: host.revision,
                                                        readEpoch: host.readEpoch, snapshot: host.lease?.reference))
        return (usb, host, service, job)
    }

    @Test func export의_preview_await_중_원본_revision_스냅샷이_바뀌면_false이며_쓰기_호출은_0이다() async throws {
        for field in ["source", "revision", "snapshot", "epoch"] {
            let (usb, host, service, job) = try await setup()
            let gate = TestGate()
            defer { gate.open() }
            service.update { $0.onPreview = { gate.pass() } }
            let prompter = SyncSourceChangingPrompter()
            let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
            let task = Task { await coordinator.export(job) }
            try #require(await waitUntil { gate.arrivals == 1 })
            host.change(field)
            gate.open()
            #expect(await task.value == false)
            #expect(service.current.calls.filter { $0 == "write" }.isEmpty && service.current.fileOperations == 0)
            #expect(prompter.confirmations == 0)
        }
    }

    @Test func export의_확인창과_재사용_summary_뒤에도_새_원본으로_쓰지_않는다() async throws {
        for field in ["source", "revision", "snapshot", "epoch"] {
            let (usb, host, service, job) = try await setup()
            let prompter = SyncSourceChangingPrompter()
            prompter.onConfirm = { host.change(field) }
            let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
            #expect(await coordinator.export(job, reusing: UsbTestData.summary()) == false)
            #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
            #expect(prompter.confirmations == 1)
        }
    }

    @Test func 시트가_동의한_재사용_export도_바뀐_원본을_거부한다() async throws {
        let (usb, host, service, job) = try await setup()
        host.change("revision")
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        #expect(await coordinator.export(job, reusing: UsbTestData.summary(), consented: true) == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
    }

    @Test func nil_context_일반_export는_기본거부_host에서도_그대로_쓴다() async throws {
        let (usb, _, service, native) = try await setup()
        var job = native
        job.syncSelection = nil
        job.syncSourceContext = nil
        let coordinator = UsbWriteCoordinator(usb: usb, host: FakeUsbWriteHost(), service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        #expect(await coordinator.export(job) == true)
        #expect(service.current.calls == ["preview", "write"] && service.current.fileOperations == 1)
    }

    @Test func native_context를_검사하지_않는_fakehost는_기본_거부한다() async throws {
        let (usb, _, service, job) = try await setup()
        let coordinator = UsbWriteCoordinator(usb: usb, host: FakeUsbWriteHost(), service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        #expect(await coordinator.export(job) == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
    }

    private func rememberDraft(_ usb: UsbStore, job: UsbExportJob) -> [UsbLibraryEdit] {
        let edits: [UsbLibraryEdit] = [.syncSelection(draft: job.syncSelection!)]
        usb.setDraft(edits, for: job.volumeKey)
        usb.rememberSyncDraft(Self.rememberedJob(job), edits: edits, sourceIsCurrent: { true })
        return edits
    }

    /// 동기화 초안을 만들 때 보관한 수정 작업(쓰기 창구에는 이 작업의 사본 DB·원본 시각이 그대로 가야 한다)
    private static func rememberedJob(_ job: UsbExportJob) -> UsbEditJob {
        UsbEditJob(database: job.database, share: job.share, volume: job.volume, snapshotTime: nil, syncSourceContext: job.syncSourceContext)
    }

    @Test func 일반_writeDraft의_native_문맥은_preview부터_끝까지_고정되어_원본_변경을_막는다() async throws {
        for field in ["source", "revision", "snapshot", "epoch"] {
            let (usb, host, service, job) = try await setup()
            let edits = rememberDraft(usb, job: job), gate = TestGate()
            defer { gate.open() }
            service.update { $0.editSummary.edits = edits; $0.onPreviewEdit = { gate.pass() } }
            let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
            let task = Task { await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share) }
            try #require(await waitUntil { gate.arrivals == 1 })
            host.change(field)
            gate.open()
            #expect(await task.value == false)
            #expect(service.current.editJobs.first == Self.rememberedJob(job).input)
            #expect(!service.current.calls.contains("writeEdit") && service.current.fileOperations == 0)
        }
    }

    @Test func 일반_writeDraft의_확인창에서_원본이_바뀌면_쓰기호출은_0이다() async throws {
        for field in ["source", "revision", "snapshot", "epoch"] {
            let (usb, host, service, job) = try await setup()
            let edits = rememberDraft(usb, job: job)
            var summary = UsbTestData.editSummary()
            summary.edits = edits
            let prompter = SyncSourceChangingPrompter()
            prompter.onConfirm = { host.change(field) }
            let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
            #expect(await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share, reusing: summary) == false)
            #expect(!service.current.calls.contains("writeEdit") && service.current.fileOperations == 0)
        }
    }

    @Test func native_초안에_선택당시_문맥이_없으면_현재_원본으로_새로_채우지_않는다() async throws {
        let (usb, host, service, job) = try await setup()
        usb.setDraft([.syncSelection(draft: job.syncSelection!)], for: job.volumeKey)
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        #expect(await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share) == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
    }

    @Test func 원본이_같은_native_export와_일반_writeDraft는_보관한_문맥으로_쓴다() async throws {
        let (usb, host, service, job) = try await setup()
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        #expect(await coordinator.export(job) == true)
        #expect(service.current.calls == ["preview", "write"] && host.checks > 0)
        let edits = rememberDraft(usb, job: job)
        service.update { $0.calls = []; $0.editSummary.edits = edits }
        #expect(await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share) == true)
        #expect(service.current.calls == ["previewEdit", "writeEdit"])
        #expect(service.current.editJobs.allSatisfy { $0 == Self.rememberedJob(job).input })
    }

    @Test func 기억한_native_편집과_다른_summary를_새_원본으로_간주하지_않는다() async throws {
        let (usb, host, service, job) = try await setup()
        var edits = rememberDraft(usb, job: job)
        edits.append(.playlist(edit: .rename(playlist: .id("10"), name: "다른 초안")))
        var summary = UsbTestData.editSummary()
        summary.edits = edits
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        #expect(await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share, reusing: summary) == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
    }

    private func replaceVolume(_ host: SyncSourceWriteHost, volume: UsbVolumeInfo, field: String) {
        var replacement = volume
        switch field {
        case "detach": host.usbHost?.mounted = []; host.liveVolume?.set(nil); return
        case "uuid": replacement.volumeUUID = UsbTestData.otherUUID
        case "device": replacement.deviceProtocol = "바뀐 합성 장치"
        default: replacement.mountPoint += "-다른-합성-마운트"
        }
        host.usbHost?.mounted = [replacement]
        host.liveVolume?.set(replacement)
    }

    @Test func native_export의_preview_확인창_저널_대기중_분리와_교체는_write0이다() async throws {
        for phase in ["preview", "confirmation", "journal"] {
            for field in ["detach", "uuid", "device", "mount"] {
                let (usb, host, service, job) = try await setup()
                let gate = TestGate(), prompter = SyncSourceChangingPrompter()
                defer { gate.open() }
                if phase == "preview" { service.update { $0.onPreview = { gate.pass() } } }
                else if phase == "journal" { service.update { $0.onJournal = { if $0 == 2 { gate.pass() } } } }
                if phase == "confirmation" { prompter.onConfirm = { replaceVolume(host, volume: job.volume, field: field) } }
                let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter,
                                                       isRekordboxRunning: { false })
                let task = Task { await coordinator.export(job) }
                if phase != "confirmation" {
                    try #require(await waitUntil { gate.arrivals == 1 })
                    replaceVolume(host, volume: job.volume, field: field)
                }
                // 볼륨 이벤트도 refresh도 채택하지 않는다. 캐시는 계속 옛 볼륨이다.
                #expect(usb.volume(job.volumeKey) == job.volume)
                gate.open()
                #expect(await task.value == false)
                #expect(!service.current.calls.contains("write") && service.current.fileOperations == 0)
                #expect(!gate.timedOut)
            }
        }
    }

    @Test func native_edit의_preview_확인창_저널_대기중_분리와_교체는_writeEdit0이다() async throws {
        for phase in ["preview", "confirmation", "journal"] {
            for field in ["detach", "uuid", "device", "mount"] {
                let (usb, host, service, job) = try await setup()
                let edits = rememberDraft(usb, job: job), gate = TestGate(), prompter = SyncSourceChangingPrompter()
                defer { gate.open() }
                service.update { $0.editSummary.edits = edits }
                if phase == "preview" { service.update { $0.onPreviewEdit = { gate.pass() } } }
                else if phase == "journal" { service.update { $0.onJournal = { if $0 == 2 { gate.pass() } } } }
                if phase == "confirmation" { prompter.onConfirm = { replaceVolume(host, volume: job.volume, field: field) } }
                let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter,
                                                       isRekordboxRunning: { false })
                let task = Task { await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: job.share) }
                if phase != "confirmation" {
                    try #require(await waitUntil { gate.arrivals == 1 })
                    replaceVolume(host, volume: job.volume, field: field)
                }
                // 볼륨 이벤트도 refresh도 채택하지 않는다. 캐시는 계속 옛 볼륨이다.
                #expect(usb.volume(job.volumeKey) == job.volume)
                gate.open()
                #expect(await task.value == false)
                #expect(!service.current.calls.contains("writeEdit") && service.current.fileOperations == 0)
                #expect(!gate.timedOut)
            }
        }
    }

    @Test("export의 실제 마운트 확인 중 원본 변경은 쓰기 0회") func sourceChangeDuringExportActualCheckPreventsWrite() async throws {
        let (usb, host, service, job) = try await setup()
        let gate = TestGate(), live = try #require(host.liveVolume)
        defer { gate.open() }
        live.onRead { if $0 == 1 { gate.pass() } }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        let task = Task { await coordinator.export(job) }
        try #require(await waitUntil { gate.arrivals == 1 })
        host.change("epoch")
        gate.open()
        #expect(await task.value == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
    }

    @Test("export 최종 실제 마운트 확인의 분리는 캐시 갱신 없이 쓰기 0회") func detachAtFinalExportActualCheckPreventsWrite() async throws {
        let (usb, host, service, job) = try await setup()
        let counter = NativeFinalPreflightCounter(), live = try #require(host.liveVolume)
        service.update { $0.onJournal = { if $0 == 2 { counter.afterJournal() } } }
        live.onRead { _ in if counter.isFinalCheck() { live.set(nil) } }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        #expect(await coordinator.export(job) == false)
        #expect(counter.reachedFinalCheck)
        #expect(usb.volume(job.volumeKey) == job.volume)
        #expect(!service.current.calls.contains("write") && service.current.fileOperations == 0)
    }

    @Test func 마지막_guard_뒤_공유_URL을_교체해도_actual_service_DB는_고정_사본이다() async throws {
        let (usb, host, service, job) = try await setup()
        let original = host.database, expected = Data("합성 원본 A".utf8)
        let gate = TestGate()
        defer { gate.open() }
        service.update {
            $0.onWriteJob = { input in
                gate.pass()
                #expect(input.database != original)
                #expect((try? Data(contentsOf: input.database)) == expected)
            }
        }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        let task = Task { await coordinator.export(job) }
        try #require(await waitUntil { gate.arrivals == 1 })
        try Data("합성 원본 B".utf8).write(to: original, options: .atomic)
        host.readEpoch += 1
        host.lease = nil
        // 코디네이터의 소유권이 service await까지 파일을 유지한다.
        #expect(FileManager.default.fileExists(atPath: job.database.path))
        gate.open()
        #expect(await task.value == true)
        #expect(service.current.exportDatabases == [job.database, job.database])
        #expect(!FileManager.default.fileExists(atPath: job.database.path))
        #expect(usb.lastExports[job.volumeKey]?.snapshotLease == nil)
    }

    @Test func 재시도_시트가_사본을_이어_소유하고_닫으면_캐시_약한참조만_남아_정리된다() async throws {
        let (usb, host, _, job) = try await setup()
        var model = UsbExportSelection(volume: job.volume, selectedTrackIDs: [])
        model.restore(job, summary: UsbTestData.summary(), layout: host.source.layout)
        host.lease = nil
        #expect(FileManager.default.fileExists(atPath: job.database.path))
        var retry = model.job(database: host.database, share: host.share, volume: job.volume, layout: host.source.layout,
                              syncSource: host.source, catalogRevision: host.revision, readEpoch: host.readEpoch)
        #expect(retry?.database == job.database)
        #expect(retry?.options.snapshotTime == job.syncSourceContext?.snapshot?.provenance.snapshotTime)
        #expect(model.job(database: host.database, share: host.share, volume: job.volume, layout: host.source.layout,
                          syncSource: host.source, catalogRevision: host.revision, readEpoch: host.readEpoch + 1) == nil)
        usb.lastExports[job.volumeKey] = job
        // 반환 job과 시트가 마지막 소유자다. 캐시 job은 약한 참조만 들고 있다.
        retry = nil
        model.releaseRetrySnapshot()
        #expect(!FileManager.default.fileExists(atPath: job.database.path))
        #expect(usb.lastExports[job.volumeKey]?.syncSourceContext?.snapshot?.lease == nil)
    }

    @Test func 쓰기_실패와_확인취소의_약한_cache는_사본을_붙잡지_않는다() async throws {
        for stop in ["confirmation", "cancelled", "failure"] {
            let (usb, host, service, job) = try await setup()
            service.update {
                if stop == "cancelled" { $0.writeResult = .failure(.cancelled) }
                if stop == "failure" { $0.writeResult = .failure(.readFailed(detail: "합성 실패")) }
            }
            let prompt = ScriptedPrompter()
            if stop == "confirmation" { prompt.answers = [false] }
            let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompt,
                                                   isRekordboxRunning: { false })
            #expect(await coordinator.export(job) == false)
            host.lease = nil
            #expect(!FileManager.default.fileExists(atPath: job.database.path))
            #expect(job.syncSourceContext?.snapshot?.lease == nil)
            #expect(usb.lastExports[job.volumeKey]?.snapshotLease == nil)
        }
    }

    @Test(arguments: [false, true]) func awaited_preview가_사본을_소유하고_완료와_Task취소뒤_정리한다(cancelled: Bool) async throws {
        let (usb, host, service, job) = try await setup()
        let gate = TestGate()
        defer { gate.open() }
        service.update { $0.onPreview = { gate.pass() } }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        let task = Task { await coordinator.preview(job) }
        try #require(await waitUntil { gate.arrivals == 1 })
        host.lease = nil
        if cancelled { task.cancel() }
        #expect(FileManager.default.fileExists(atPath: job.database.path))
        gate.open()
        #expect((await task.value != nil) == !cancelled)
        #expect(!FileManager.default.fileExists(atPath: job.database.path))
        #expect(!gate.timedOut)
    }

    @Test func nil_context_일반_edit는_기본거부_host에서도_그대로_쓴다() async throws {
        let (usb, host, service, job) = try await setup()
        let edits: [UsbLibraryEdit] = [.playlist(edit: .rename(playlist: .id("10"), name: "일반 편집"))]
        usb.setDraft(edits, for: job.volumeKey)
        service.update { $0.editSummary.edits = edits }
        let coordinator = UsbWriteCoordinator(usb: usb, host: FakeUsbWriteHost(), service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        #expect(await coordinator.writeDraft(volumeKey: job.volumeKey, database: host.database, share: host.share) == true)
        #expect(service.current.calls == ["previewEdit", "writeEdit"] && service.current.fileOperations == 1)
        #expect(service.current.editJobs.allSatisfy { $0.database == host.database })
    }

}
