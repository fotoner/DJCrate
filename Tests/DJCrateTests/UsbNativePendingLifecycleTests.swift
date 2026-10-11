@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Observation
import RekordboxKit
import Testing

/// 이벤트 채택과 무관하게 지금 마운트 결과를 돌려준다. 실제 볼륨·DB를 읽지 않는다.
final class FakeUsbLiveVolumeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var volume: UsbVolumeInfo?
    private var count = 0
    private var hook: (@Sendable (Int) -> Void)?
    init(_ volume: UsbVolumeInfo?) { self.volume = volume }
    func set(_ volume: UsbVolumeInfo?) { lock.withLock { self.volume = volume } }
    func onRead(_ hook: @escaping @Sendable (Int) -> Void) { lock.withLock { self.hook = hook } }
    func read(_ confirmed: UsbVolumeInfo) throws -> UsbVolumeInfo {
        let (count, hook) = lock.withLock {
            self.count += 1
            return (self.count, self.hook)
        }
        hook?(count)
        guard let current = lock.withLock({ volume }) else { throw UsbError.cancelled }
        return current
    }
}

@MainActor @Observable
private final class PendingSyncSourceHost: UsbWriteHost {
    var toast: AppToast?
    var epoch = 1
    var revision = 1
    var source = UsbSyncSource.make(rekordbox: PlaylistLayout([(.init(id: "10", name: "합성 목록"), 0)]),
                                    iTunes: SyncedITunesLibrary(snapshot: .init(status: .ready), tracks: []))
    let database: URL
    let share: URL
    init(database: URL, share: URL) { self.database = database; self.share = share }
    func usbSyncSourceIsCurrent(_ context: UsbExportSyncSourceContext, database: URL?, share: URL?) -> Bool {
        context.readEpoch == epoch && context.catalogRevision == revision && context.source == source
            && context.snapshot?.provenance.sourceURL == self.database
            && database == context.snapshot?.database && share == self.share
    }
}

/// XML 생산 관문을 열지 않고, 계획·디스크 초안 저장 이후의 앱 인계를 그대로 사용한다.
@MainActor
private final class FakePreparedSyncViewModel {
    var lease: UsbSyncSnapshotLease?
    let job: UsbEditJob
    let edits: [UsbLibraryEdit]
    init(job: UsbEditJob, edits: [UsbLibraryEdit]) { self.job = job; self.edits = edits; lease = job.syncSourceContext?.snapshot?.lease }
    func sync(using coordinator: UsbWriteCoordinator) async -> Bool {
        defer { lease = nil }
        return await coordinator.writeSyncDraft(job, edits: edits)
    }
}

@MainActor
private final class NativePendingFixture {
    let root: URL
    let volume: UsbVolumeInfo
    let usbHost: FakeUsbHost
    let usb: UsbStore
    let host: PendingSyncSourceHost
    let service = FakeUsbWriteService()
    let live: FakeUsbLiveVolumeReader
    let job: UsbEditJob
    let edits: [UsbLibraryEdit]
    /// USB 초안 폴더(`usb.drafts`가 쓰는 곳)
    let drafts: URL
    var lease: UsbSyncSnapshotLease?

    /// physical이면 실물 FAT32로 보이는 볼륨(쓰기 확인 창이 볼륨 줄과 "실물 USB입니다"를 보여야 한다)
    init(physical: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-native-pending-\(UUID())")
        self.root = root
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "snapshot.db")
        try Data("합성 스냅샷".utf8).write(to: source)
        host = PendingSyncSourceHost(database: source, share: root.appending(path: "share"))
        lease = try UsbSyncSnapshotLease.capture(.capture(source), directory: root.appending(path: "copies"))
        var volume = physical ? FakeUsbVolume.physicalFAT32(name: "합성 실물 USB") : FakeUsbVolume.diskImageFAT32(name: "합성 pending USB")
        volume.mountPoint = root.appending(path: "fake-mount").path
        self.volume = volume
        live = FakeUsbLiveVolumeReader(volume)
        usbHost = FakeUsbHost([volume])
        usbHost.serve(volume, library: UsbTestData.library(formats: [.oneLibrary]))
        usb = UsbStore(host: usbHost, readPolicy: .all, writeService: service, localLibrary: { nil })
        drafts = root.appending(path: "drafts")
        usb.drafts = .live(directory: drafts)
        let owner = lease!
        job = UsbEditJob(database: owner.database, share: host.share, volume: volume, snapshotTime: owner.provenance.snapshotTime,
                         syncSourceContext: .init(source: host.source, catalogRevision: host.revision, readEpoch: host.epoch,
                                                  snapshot: owner.reference))
        edits = [.syncSelection(draft: .init(localDBID: 42, sourceNodes: host.source.nativeNodes,
                                             selection: .init(selectedIDs: ["10"]), enabled: true,
                                             playlistRefs: ["10": .id("10")], baseFiles: [:]))]
        try UsbDraftStore(directory: drafts).save(.init(volumeKey: volume.usbKey, base: .init(files: [:]), edits: edits,
                                                                     createdAt: Date()))
        let live = live, directory = drafts
        service.update {
            $0.liveVolumeReader = { try live.read($0) }
            $0.liveSyncFilesReader = { _, _ in [:] }
            $0.drafts = directory
            $0.editSummary.edits = edits
            $0.editSummary.isTestVolume = !physical
        }
        initialized = true
    }
    func coordinator(_ prompt: any ReflectionPrompter = ScriptedPrompter()) -> UsbWriteCoordinator {
        UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompt, isRekordboxRunning: { false })
    }
    func prepare() async { await usb.refresh() }
    func remember() {
        let host = host, job = job
        usb.rememberSyncDraft(job, edits: edits, sourceIsCurrent: {
            host.usbSyncSourceIsCurrent(job.syncSourceContext!, database: job.database, share: job.share)
        })
        lease = nil
    }
    var copyExists: Bool { FileManager.default.fileExists(atPath: job.database!.path) }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite("USB native pending 사본 소유권과 실제 제출")
struct UsbNativePendingLifecycleTests {
    @Test("확인 취소 후 창을 닫고 쓰기 대기에서 미리 보기·쓰기를 하면 같은 사본으로 한 번 쓴다")
    func cancelClosePreviewAndWriteRetainsDraftLease() async throws {
        let f = try NativePendingFixture()
        await f.prepare()
        let prompt = ScriptedPrompter(); prompt.answers = [false]
        var model: FakePreparedSyncViewModel? = FakePreparedSyncViewModel(job: f.job, edits: f.edits)
        f.lease = nil
        #expect(await model?.sync(using: f.coordinator(prompt)) == false)
        #expect(!f.service.current.calls.contains("writeEdit") && f.service.current.fileOperations == 0)
        #expect(f.usb.syncDraftSources[f.volume.usbKey]?.snapshotLease != nil && f.copyExists)
        model = nil
        f.usb.syncSheet = nil
        #expect(f.copyExists && f.job.syncSourceContext?.snapshot?.lease != nil)
        let pending = UsbPendingWorkflow(coordinator: f.coordinator(), volumeKey: f.volume.usbKey,
                                         database: f.host.database, share: f.host.share)
        let summary = try #require(await pending.preview())
        #expect(f.copyExists && summary.edits == f.edits)
        let directory = f.drafts, key = f.volume.usbKey
        f.service.update { $0.onWriteEdit = { try? UsbDraftStore(directory: directory).discard(volumeKey: key) } }
        #expect(await pending.write(reusing: summary))
        #expect(f.service.current.calls.filter { $0 == "writeEdit" }.count == 1 && f.service.current.fileOperations == 1)
        #expect(f.service.current.editJobs.allSatisfy { $0 == f.job.input })
        #expect(f.usb.syncDraftSources[key] == nil && !f.copyExists)
        #expect(FileManager.default.fileExists(atPath: f.host.database.path))
    }

    @Test("실물 USB 동기화는 볼륨 줄·'실물 USB입니다'를 보인 쓰기 확인 창을 거쳐야 쓰고, 취소하면 쓰지 않는다")
    func physicalSyncRequiresWriteConfirmation() async throws {
        let f = try NativePendingFixture(physical: true)
        await f.prepare()
        let declined = ScriptedPrompter(); declined.answers = [false]
        var model: FakePreparedSyncViewModel? = FakePreparedSyncViewModel(job: f.job, edits: f.edits)
        f.lease = nil
        #expect(await model?.sync(using: f.coordinator(declined)) == false)
        #expect(!f.service.current.calls.contains("writeEdit") && f.service.current.fileOperations == 0)
        let shown = try #require(declined.shown.last)
        #expect(shown.confirm == "USB에 쓰기")
        #expect(shown.details.first?.hasPrefix("실물 USB입니다: 합성 실물 USB · ") == true)
        #expect(!shown.details.contains("시험 볼륨(디스크 이미지)입니다"))
        model = nil

        let accepted = ScriptedPrompter(); accepted.answers = [true]
        let directory = f.drafts, key = f.volume.usbKey
        f.service.update { $0.onWriteEdit = { try? UsbDraftStore(directory: directory).discard(volumeKey: key) } }
        #expect(await f.coordinator(accepted).writeDraft(volumeKey: key, database: f.host.database, share: f.host.share))
        #expect(accepted.shown.count == 1 && accepted.shown[0].details.first?.hasPrefix("실물 USB입니다: ") == true)
        #expect(f.service.current.calls.filter { $0 == "writeEdit" }.count == 1)
    }

    @Test("미리 보기(Mac 사본에서 계획)가 실패하면 USB를 되돌렸다고 하지 않고 미리 보기 실패로 알리며 쓰지 않는다")
    func previewFailureIsNotReportedAsRollback() async throws {
        let f = try NativePendingFixture(physical: true)
        await f.prepare(); f.remember()
        f.service.update { $0.editPreviewError = .writeRolledBack(reason: "reread differs: key.onlyRight×1") }
        let prompt = ScriptedPrompter()
        #expect(await f.coordinator(prompt).writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(!f.service.current.calls.contains("writeEdit") && f.service.current.fileOperations == 0)
        #expect(prompt.shown.map(\.title) == ["USB 미리 보기를 하지 못했습니다"])
    }

    @Test("실제 마운트 확인이 없으면 native는 거부하고 일반 편집은 그대로 쓴다")
    func missingLiveReaderRejectsNativeAndKeepsOrdinaryEdit() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.service.update { $0.liveVolumeReader = nil }
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(f.service.current.calls.isEmpty && f.service.current.fileOperations == 0)
        #expect(!f.copyExists && f.usb.syncDraftSources[f.volume.usbKey] == nil)
        let ordinary: [UsbLibraryEdit] = [.playlist(edit: .rename(playlist: .id("10"), name: "일반"))]
        try UsbDraftStore(directory: f.drafts).save(.init(volumeKey: f.volume.usbKey, base: .init(files: [:]), edits: ordinary, createdAt: Date()))
        await f.usb.reloadDraft(f.volume.usbKey)
        f.service.update { $0.editSummary.edits = ordinary }
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share))
        #expect(f.service.current.calls == ["previewEdit", "writeEdit"])
    }

    @Test("현재 마운트 API를 구현하지 않은 서비스는 native를 기본 거부한다")
    func legacyServiceRejectsNativeByDefault() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        let coordinator = UsbWriteCoordinator(usb: f.usb, host: f.host, service: LegacyUsbWriteService(base: f.service),
                                               prompter: ScriptedPrompter(), isRekordboxRunning: { false })
        #expect(await coordinator.writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(f.service.current.calls.isEmpty && f.service.current.fileOperations == 0)
        #expect(!f.copyExists)
    }

    @Test("실제 마운트 확인 중 epoch가 바뀌면 다시 판정하여 쓰기를 호출하지 않는다")
    func epochChangeDuringActualCheckPreventsWrite() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        let gate = TestGate(); defer { gate.open() }
        f.live.onRead { if $0 == 1 { gate.pass() } }
        let task = Task { await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) }
        try #require(await waitUntil { gate.arrivals == 1 })
        f.host.epoch += 1
        gate.open()
        #expect(await task.value == false)
        #expect(f.service.current.calls.isEmpty && f.service.current.fileOperations == 0)
        #expect(!f.copyExists && f.usb.syncDraftSources[f.volume.usbKey] == nil)
    }

    @Test("최종 제출 직전 실제 마운트 확인의 교체는 캐시 갱신 없이 쓰기를 막는다")
    func replacementAtFinalActualCheckPreventsWrite() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        let counter = NativeFinalPreflightCounter(), live = f.live
        var replacement = f.volume; replacement.volumeUUID = UsbTestData.otherUUID
        let replaced = replacement
        f.service.update { $0.onJournal = { if $0 == 2 { counter.afterJournal() } } }
        live.onRead { _ in if counter.isFinalCheck() { live.set(replaced) } }
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(counter.reachedFinalCheck)
        #expect(f.usb.volume(f.volume.usbKey) == f.volume)
        #expect(!f.service.current.calls.contains("writeEdit") && f.service.current.fileOperations == 0)
        #expect(!f.copyExists)
    }

    @Test(arguments: ["epoch", "revision", "source"])
    func sourceObservationReleasesLeaseAndKeepsDraft(field: String) async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        switch field {
        case "epoch": f.host.epoch += 1
        case "revision": f.host.revision += 1
        default: f.host.source.layout = PlaylistLayout()
        }
        try #require(await waitUntil { f.usb.syncDraftSources[f.volume.usbKey] == nil })
        #expect(!f.copyExists && f.usb.draftEdits[f.volume.usbKey] == f.edits)
        #expect(try UsbDraftStore(directory: f.drafts).load(volumeKey: f.volume.usbKey)?.edits == f.edits)
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(f.service.current.fileOperations == 0 && FileManager.default.fileExists(atPath: f.host.database.path))
    }

    /// UsbStore를 사이드바 상태와 쓰기 세션(`UsbWriteSession`)으로 나눈 뒤에도 native 초안 관찰(`withObservationTracking`)은
    /// 원본(라이브러리 쪽 값)이 바뀔 때만 사본을 놓는다: 잠금·진행·지난 쓰기를 바꿔도 놓지 않고, 원본이 바뀌면 다음 차례에 놓는다
    @Test("쓰기 세션 상태를 바꿔도 native 초안을 놓지 않고, 원본이 바뀌면 바로 놓는다")
    func sessionChangesKeepNativeDraft() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        let key = f.volume.usbKey
        let flag = f.usb.beginWrite(f.volume, title: "합성 미리 보기", cancellable: true)
        f.usb.setWriteTitle("합성 쓰기", for: key)
        f.usb.report(UsbProgress(phase: .files, cancellable: true), for: key)
        f.usb.migrationBackups[key] = f.root
        f.usb.migrationBlockReasons[key] = "합성 막힘"
        f.usb.endWrite(key)
        for _ in 0..<20 { await Task.yield() }
        #expect(flag != nil && f.usb.session.busyVolumes.isEmpty && f.usb.activeWrite == nil)
        #expect(f.usb.syncDraftSources[key] != nil && f.copyExists)
        f.host.epoch += 1
        try #require(await waitUntil { f.usb.syncDraftSources[key] == nil })
        #expect(!f.copyExists && f.usb.draftEdits[key] == f.edits)
    }

    @Test("native 원문이 바뀌면 쓰기 대기 미리 보기에서 사본을 해제한다")
    func changedNativeFilesInvalidatePendingLease() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.service.update { $0.liveSyncFilesReader = { _, _ in [.oneLibrary: Data("합성 바뀐 XML".utf8)] } }
        #expect(await f.coordinator().previewDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == nil)
        #expect(f.usb.syncDraftSources[f.volume.usbKey] == nil && !f.copyExists)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits && f.service.current.fileOperations == 0)
    }

    @Test("USB 새로 읽기가 native 원문 변경을 발견하면 남은 초안의 사본을 해제한다")
    func usbRefreshInvalidatesChangedNativeFiles() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.service.update { $0.liveSyncFilesReader = { _, _ in [.oneLibrary: Data("합성 다른 원문".utf8)] } }
        await f.usb.refresh()
        #expect(f.usb.syncDraftSources[f.volume.usbKey] == nil && !f.copyExists)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits && f.service.current.fileOperations == 0)
    }

    @Test(arguments: [false, true]) func discardAndEditChangesReleaseLease(discard: Bool) async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.usb.setDraft(discard ? [] : f.edits + [.playlist(edit: .rename(playlist: .id("10"), name: "변경"))], for: f.volume.usbKey)
        #expect(f.usb.syncDraftSources[f.volume.usbKey] == nil && !f.copyExists)
        #expect(FileManager.default.fileExists(atPath: f.host.database.path))
    }

    @Test(arguments: [false, true]) func detachAndSameUUIDReplacementReleaseLease(replace: Bool) async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        if replace { var changed = f.volume; changed.deviceProtocol = "다른 장치"; f.usbHost.mounted = [changed] }
        else { f.usbHost.mounted = [] }
        await f.usb.refresh()
        #expect(!f.copyExists && f.usb.syncDraftSources[f.volume.usbKey] == nil)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits)
        if !replace { #expect(f.usb.absentDrafts[f.volume.usbKey] != nil) }
    }

    @Test(arguments: ["throw", "cancelled", "noReport", "nonWrittenReport"])
    func unsuccessfulWritesRetainUnchangedPendingLease(stop: String) async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.service.update {
            switch stop {
            case "throw": $0.editWriteResult = .failure(.readFailed(detail: "합성 실패"))
            case "cancelled": $0.editWriteResult = .failure(.cancelled)
            case "nonWrittenReport": $0.editWriteResult = .success(UsbWriteReport(outcome: .needsReplan, session: "synthetic"))
            default: $0.editWriteResult = .success(nil)
            }
        }
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(f.usb.syncDraftSources[f.volume.usbKey] != nil && f.copyExists)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits)
        f.usb.setDraft([], for: f.volume.usbKey)
        #expect(!f.copyExists)
    }

    @Test("초안 줄 대기 중 디스크 편집이 바뀌면 native 문맥을 재사용하지 않는다")
    func diskDraftChangeWhileQueuedInvalidatesContext() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        let gate = TestGate(); defer { gate.open() }
        let blocker = Task { await f.usb.draftQueue(f.volume.usbKey) { await BlockingWork.run { gate.pass() } } }
        try #require(await waitUntil { gate.arrivals == 1 })
        let task = Task { await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) }
        try #require(await waitUntil { f.usb.draftQueueLength(f.volume.usbKey) == 2 })
        var changed = try #require(try UsbDraftStore(directory: f.drafts).load(volumeKey: f.volume.usbKey))
        changed.edits.append(.playlist(edit: .rename(playlist: .id("10"), name: "별도 변경")))
        try UsbDraftStore(directory: f.drafts).save(changed)
        gate.open(); await blocker.value
        #expect(await task.value == false)
        #expect(!f.service.current.calls.contains("writeEdit") && !f.copyExists)
    }

    @Test("여유 용량 변화만으로는 같은 실행의 유효한 초안을 잃지 않는다")
    func availableSpaceChangeKeepsPendingLease() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        var current = f.volume
        current.available -= 4096
        f.live.set(current)
        f.usbHost.mounted = [current]
        await f.usb.refresh()
        #expect(f.usb.syncDraftSources[f.volume.usbKey] != nil && f.copyExists)
        let pending = UsbPendingWorkflow(coordinator: f.coordinator(), volumeKey: f.volume.usbKey,
                                         database: f.host.database, share: f.host.share)
        let summary = try #require(await pending.preview())
        #expect(await pending.write(reusing: summary))
        #expect(f.service.current.calls.filter { $0 == "writeEdit" }.count == 1)
        #expect(!f.copyExists && FileManager.default.fileExists(atPath: f.host.database.path))
    }

    @Test("쓰기 창구가 분리·교체를 보고하면 초안은 보존하고 사본은 해제한다", arguments: [false, true])
    func reportedVolumeLossInvalidatesLease(replaced: Bool) async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.remember()
        f.service.update { $0.editWriteResult = .failure(replaced ? .volumeChanged(volumeName: "합성 USB") : .volumeLost(volumeName: "합성 USB")) }
        #expect(await f.coordinator().writeDraft(volumeKey: f.volume.usbKey, database: f.host.database, share: f.host.share) == false)
        #expect(f.usb.syncDraftSources[f.volume.usbKey] == nil && !f.copyExists)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits)
    }

    @Test("문맥 없는 디스크 native 초안은 현재 DB로 다시 만들지 않고 재준비를 안내한다")
    func diskNativeDraftWithoutRuntimeContextRequiresPreparation() async throws {
        let f = try NativePendingFixture()
        await f.prepare(); f.lease = nil
        #expect(!f.copyExists && f.usb.syncDraftSources.isEmpty)
        let pending = UsbPendingWorkflow(coordinator: f.coordinator(), volumeKey: f.volume.usbKey,
                                         database: f.host.database, share: f.host.share)
        #expect(await pending.preview() == nil)
        #expect(await pending.write(reusing: nil) == false)
        #expect(f.host.toast?.detail == String(ui: "동기화 초안의 원본을 다시 준비해야 하므로 쓰기 대기 목록에서 초안을 버린 뒤 USB 동기화 창을 새로고침하세요"))
        #expect(f.service.current.calls.isEmpty && f.service.current.fileOperations == 0)
        #expect(f.usb.draftEdits[f.volume.usbKey] == f.edits)
    }
}

final class NativeFinalPreflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var readsAfterJournal: Int?
    func afterJournal() { lock.withLock { readsAfterJournal = 0 } }
    var reachedFinalCheck: Bool { lock.withLock { (readsAfterJournal ?? 0) >= 3 } }
    func isFinalCheck() -> Bool {
        lock.withLock {
            guard let previous = readsAfterJournal else { return false }
            readsAfterJournal = previous + 1
            return previous == 2
        }
    }
}

/// 현재 마운트·원문 API는 의도적으로 생략하여 protocol의 안전 기본값을 시험한다.
private struct LegacyUsbWriteService: UsbWriting {
    let base: FakeUsbWriteService
    func journal(volumeKey: String) -> UsbJournalInfo { base.journal(volumeKey: volumeKey) }
    func preview(_ job: UsbExportInput) throws -> UsbExportSummary { try base.preview(job) }
    func write(_ job: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        try base.write(job, progress: progress, isCancelled: isCancelled)
    }
    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary { try base.previewMigration(volume) }
    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten {
        try base.writeMigration(volume, progress: progress, isCancelled: isCancelled)
    }
    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport { try base.recover(volume) }
    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try base.restore(volume, backup: backup, discardDeviceChanges: discardDeviceChanges)
    }
    func latestBackup(volumeKey: String) -> URL? { base.latestBackup(volumeKey: volumeKey) }
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint { try base.draftBase(volume) }
    func previewEdit(_ job: UsbEditInput) throws -> UsbEditSummary { try base.previewEdit(job) }
    func writeEdit(_ job: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten {
        try base.writeEdit(job, progress: progress, isCancelled: isCancelled)
    }
    func isScratchMount(_ mountPoint: String) -> Bool { base.isScratchMount(mountPoint) }
    var syncGate: UsbSyncSelectionGate { base.syncGate }
    func isRekordboxRunning() -> Bool { base.isRekordboxRunning() }
    func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                           rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan {
        try base.planCueGridImport(volume: volume, snapshot: snapshot, share: share, scratch: scratch, rows: rows)
    }
}
