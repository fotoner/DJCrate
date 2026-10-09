@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite("USB native quiet 읽기 epoch", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct UsbSyncReadEpochTests {
    /// 기본은 명시한 사본(`--db`)으로 연 창. `explicitCopy`가 거짓이면 스냅샷을 뜰 수 있는 보통 실행(사본 rekordbox 폴더 없음)이다.
    private func store(_ fixture: RekordboxFixture, explicitCopy: Bool = true) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usb-epoch"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 rekordboxShareRoot: fixture.shareRoot,
                                 arguments: explicitCopy ? ["test", "--db", fixture.database.path] : ["test"], environment: [:])
        return store
    }

    private func context(_ store: LibraryStore, lease: UsbSyncSnapshotLease) -> UsbExportSyncSourceContext {
        .init(source: UsbSyncSource.make(rekordbox: store.rekordboxPlaylists, iTunes: store.iTunesLibrary),
              catalogRevision: store.previewRevision, readEpoch: store.snapshotReadEpoch, snapshot: lease.reference)
    }

    private func job(_ context: UsbExportSyncSourceContext, lease: UsbSyncSnapshotLease, volume: UsbVolumeInfo,
                     share: URL) -> UsbExportJob {
        UsbExportJob(database: lease.database, share: share, volume: volume, selection: .tracks(["101"]),
                     formats: [.oneLibrary], snapshotTime: lease.provenance.snapshotTime,
                     syncSelection: .init(localDBID: 42, sourceNodes: context.source.nativeNodes, selection: .init(),
                                          enabled: true, playlistRefs: [:], baseFiles: [:]), syncSourceContext: context)
    }

    @Test func 같은초_같은URL_교체뒤_목록채택을_기다리는_구간에서는_native_write0이다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let directory = fixture.root.appending(path: "snapshots")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let source = fixture.database
        let snapshot = try LibrarySnapshot.take(from: source, into: directory, force: true, now: stamp)
        // 조용한 스냅샷 다시 뜨기를 하는 실행(명시한 사본이 아니다)
        let store = store(fixture, explicitCopy: false)
        await store.load(snapshot: snapshot)
        let lease = try #require(await store.leaseUsbSyncSnapshot(directory: fixture.root.appending(path: "private-copies")))
        let before = context(store, lease: lease), revision = store.previewRevision
        #expect(store.usbSyncSourceIsCurrent(before, database: lease.database, share: fixture.shareRoot))
        try fixture.execute("UPDATE djmdContent SET Title = '합성 B'")
        let gate = TestGate()
        defer { gate.open() }
        let loading = Task {
            await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         let replacement = try LibrarySnapshot.take(from: source, into: directory, force: force, now: stamp)
                                         // 파일 교체는 끝났지만 아직 load()와 새 목록 채택을 시작하지 않았다.
                                         gate.pass()
                                         return replacement
                                     })
        }
        try #require(await waitUntil { gate.arrivals == 1 })
        #expect(store.snapshotURL == snapshot && store.previewRevision == revision && !store.isLoading)
        #expect(store.snapshotReadEpoch != before.readEpoch && store.snapshotForUsbSync == nil)
        #expect(!store.usbSyncSourceIsCurrent(before, database: lease.database, share: fixture.shareRoot))
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 epoch USB"), usbHost = FakeUsbHost([])
        usbHost.mounted = [volume]
        usbHost.serveEmpty(volume)
        let service = FakeUsbWriteService(), usb = UsbStore(host: usbHost, readPolicy: .all, writeService: service, localLibrary: { nil })
        await usb.refresh()
        let coordinator = UsbWriteCoordinator(usb: usb, host: store, service: service, prompter: ScriptedPrompter(),
                                               isRekordboxRunning: { false })
        #expect(await coordinator.export(job(before, lease: lease, volume: volume, share: fixture.shareRoot)) == false)
        #expect(service.current.calls.isEmpty && service.current.fileOperations == 0)
        #expect(try UsbSyncSnapshotProvenance.capture(snapshot) != lease.provenance)
        gate.open()
        await loading.value
        #expect(!gate.timedOut)
    }

    @Test func quiet_load도_결과채택전_epoch로_옛문맥을_거부한다() async throws {
        let fixture = try RekordboxFixture(), store = store(fixture)
        await store.load(snapshot: fixture.database)
        let lease = try #require(await store.leaseUsbSyncSnapshot(directory: fixture.root.appending(path: "copies")))
        let before = context(store, lease: lease), revision = store.previewRevision
        let gate = TestGate(), snapshot = fixture.database
        defer { gate.open() }
        let loading = Task {
            await store.load(snapshot: snapshot, quiet: true, refreshITunes: true,
                             captureITunes: { gate.pass(); return .init(status: .ready) })
        }
        try #require(await waitUntil { gate.arrivals == 1 })
        #expect(store.snapshotURL == snapshot && store.previewRevision == revision && !store.isLoading)
        #expect(store.snapshotReadEpoch != before.readEpoch)
        #expect(!store.usbSyncSourceIsCurrent(before, database: lease.database, share: fixture.shareRoot))
        #expect(await store.leaseUsbSyncSnapshot(directory: fixture.root.appending(path: "copies")) == nil)
        gate.open()
        await loading.value
        #expect(!gate.timedOut)
    }

    @Test func 목록읽기_중_DB가_교체되면_일반화면은_유지해도_native_출처를_채택하지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots")
        let snapshot = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true)
        let replacement = fixture.database, store = store(fixture)
        await store.load(snapshot: snapshot, refreshITunes: true, captureITunes: {
                             // 합성 DB 파일만 교체한다. 열린 reader는 옛 inode, 다음 작업은 새 inode를 보게 된다.
                             try? FileManager.default.removeItem(at: snapshot)
                             try? FileManager.default.copyItem(at: replacement, to: snapshot)
                             return .init(status: .ready)
                         })
        #expect(store.snapshotURL == snapshot)
        #expect(store.snapshotForUsbSync == nil)
        #expect(await store.leaseUsbSyncSnapshot(directory: fixture.root.appending(path: "copies")) == nil)
    }
}
