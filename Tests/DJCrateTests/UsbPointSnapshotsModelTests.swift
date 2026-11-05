@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Synchronization
import Testing

/// #226: 화면 모델은 기존 시점 스냅샷 유스케이스에 가짜 포트를 붙여 본다(USB·파일 쓰기 없음).
@MainActor
@Suite("USB 시점 스냅샷 화면")
struct UsbPointSnapshotsModelTests {
    final class Ports: Sendable {
        struct State {
            var entries: [UsbPointSnapshotEntry] = []
            var calls: [String] = []
            var changed = false
            var changeAfterPreview = false
            var blocks: [UsbBlock] = []
            var writeOptions: [UsbWriteOptions] = []
        }
        let state = Mutex(State())
        let volume = FakeUsbVolume.diskImageFAT32(name: "DJC226")
        let directory = URL(filePath: "/private/tmp/djc-fixture/usb-point-snapshots")

        func entry(_ name: String = "공연 전") -> UsbPointSnapshotEntry {
            .init(url: directory.appending(path: "saved"),
                  metadata: .init(name: name, kind: .manual, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  volumeUUID: volume.usbKey, volumeName: volume.name, files: [:]))
        }

        func useCase() -> UsbPointSnapshots {
            var engine = UsbLibraryEngine.live(fileSystem: PosixUsbFileSystem())
            engine.pointSnapshot = .init(create: { [self] request in
                expectBlockingOffPool()
                let entry = entry(request.name)
                state.withLock { $0.calls.append("create"); $0.entries = [entry] }
                return entry
            }, list: { [self] _, key in
                expectBlockingOffPool()
                #expect(key == volume.usbKey)
                return state.withLock { $0.entries }
            }, setPinned: { [self] pinned, entry, _ in
                expectBlockingOffPool()
                var entry = entry
                entry.metadata.pinned = pinned
                state.withLock { $0.calls.append("pin"); $0.entries = [entry] }
                return entry
            }, delete: { [self] entry, _ in
                expectBlockingOffPool()
                #expect(!entry.metadata.pinned)
                state.withLock { $0.calls.append("delete"); $0.entries = [] }
            }, planRestore: { [self] input in
                expectBlockingOffPool()
                state.withLock {
                    $0.calls.append("plan")
                    if $0.changeAfterPreview { $0.changed = true }
                }
                var result = UsbPointRestoreResult()
                result.blocks = state.withLock { $0.blocks }
                result.changes = UsbChangeSet(session: input.session, label: "point-restore-saved", purpose: .edit,
                                              formats: [.deviceLibrary], requiredRules: [], databases: [], copies: [], writes: [], removals: [],
                                              base: input.base, target: .init(mustExist: [:], mustNotExist: []),
                                              stagingDirectory: input.staging.path, idHighWater: [:])
                result.databases = 1
                return result
            }, volumeEvents: { _, _, _ in [] })
            engine.writer.journalStatus = { _, _ in .missing }
            engine.writer.databaseFingerprint = { [self] _ in
                let hash = state.withLock { $0.changed } ? "기기 변경" : ""
                return UsbFingerprint(files: hash.isEmpty ? [:] : [UsbLayout.exportPdb: .init(size: 1, mtime: Date(), sha256: hash)])
            }
            engine.writer.preexistingAppleDoubles = { _ in [] }
            engine.writer.write = { [self] request in
                expectBlockingOffPool()
                state.withLock { $0.calls.append("write"); $0.writeOptions.append(request.options) }
                request.progress(.init(phase: .commit, cancellable: false))
                return UsbWriteReport(outcome: .written, session: "restore", backup: "/private/tmp/djc-fixture/usb-backups/B/restore")
            }
            var device = UsbDevice.live()
            device.realPath = { $0 }
            device.isUnderScratch = { _ in true }
            device.makeFolders = { _, _ in }
            device.remove = { _ in }
            let volume = volume
            let guardValue = UsbWriteGuard(volume: { _ in volume }, isRekordboxRunning: { false }, protectedRoots: [],
                                            gate: .init(consented: false))
            return UsbPointSnapshots(directory: directory,
                                     paths: .init(backups: directory.appending(path: "backups"), sessions: directory.appending(path: "sessions"),
                                                  staging: directory.appending(path: "staging")),
                                     writeGuard: { guardValue }, engine: engine, device: device, now: { Date() })
        }
    }

    @MainActor struct Scene {
        let ports = Ports()
        let service = FakeUsbWriteService()
        let prompter = ScriptedPrompter()
        let host = FakeUsbWriteHost()
        let usb: UsbStore
        let usbHost: FakeUsbHost
        var coordinator: UsbWriteCoordinator { .init(usb: usb, host: host, service: service, prompter: prompter) }
        var model: UsbPointSnapshotsModel { .init(volume: ports.volume, usb: usb, snapshots: ports.useCase(), coordinator: coordinator) }

        init() {
            service.update { $0.liveVolumeReader = { $0 } }
            usbHost = FakeUsbHost([ports.volume])
            usbHost.serveEmpty(ports.volume)
            usb = UsbStore(host: usbHost, readPolicy: .all, writeService: service, localLibrary: { nil })
        }
    }

    @Test func 만들기_목록_고정_풀기_지우기는_같은_유스케이스를_쓴다() async {
        let scene = Scene()
        await scene.usb.refresh()
        let model = scene.model
        model.name = "공연 전"
        await model.create()
        #expect(model.entries.map(\.displayName) == ["공연 전"])
        #expect(model.name.isEmpty && model.message != nil)
        await model.togglePinned(model.entries[0])
        #expect(model.entries[0].metadata.pinned)
        await model.delete(model.entries[0])
        #expect(scene.ports.state.withLock { $0.calls } == ["create", "pin"], "고정한 것은 지우지 않는다")
        await model.togglePinned(model.entries[0])
        await model.delete(model.entries[0])
        #expect(model.entries.isEmpty)
        #expect(scene.ports.state.withLock { $0.calls } == ["create", "pin", "pin", "delete"])
    }

    @Test func 되돌리기는_쓰기_확인과_기기_변경_동의를_따로_받고_취소하면_쓰지_않는다() async {
        let scene = Scene()
        await scene.usb.refresh()
        scene.ports.state.withLock { $0.changed = true }
        scene.prompter.answers = [true, false]
        let model = scene.model
        await model.restore(scene.ports.entry())
        #expect(scene.prompter.shown.count == 2)
        #expect(scene.prompter.shown.last?.text.contains("잃습니다") == true)
        #expect(!scene.ports.state.withLock { $0.calls }.contains("write"))
        #expect(scene.usb.activeWrite == nil && scene.usb.busyVolumes.isEmpty)
        scene.prompter.answers = [true, true]
        await model.restore(scene.ports.entry())
        #expect(scene.ports.state.withLock { $0.calls }.filter { $0 == "write" }.count == 1)
        #expect(scene.ports.state.withLock { $0.writeOptions.first?.expectedVolumeUUID } == scene.ports.volume.volumeUUID)
        #expect(scene.host.toast?.kind == .success)
        #expect(model.undoBackup != nil)
        await model.undoRestore()
        #expect(scene.service.current.restoredBackups.count == 1)
        #expect(model.undoBackup == nil && scene.usb.activeWrite == nil)
    }

    @Test func 스냅샷_뒤_새_DB는_막힘_한_문장으로_알리고_확인_없이_멈춘다() async {
        let scene = Scene()
        await scene.usb.refresh()
        let reason = String(ui: "스냅샷 뒤 새 DB가 생겨 되돌릴 수 없으니, 그 DB를 만든 쓰기를 `djc usb-restore`로 먼저 되돌리세요")
        scene.ports.state.withLock {
            $0.blocks = [.init(code: "pointSnapshotNewDatabase", scope: .volume, message: "스냅샷 뒤 새 DB가 생겼습니다. usb-restore를 먼저 하세요")]
        }
        await scene.model.restore(scene.ports.entry())
        #expect(scene.prompter.shown.map(\.text) == [reason])
        #expect(!scene.ports.state.withLock { $0.calls }.contains("write"))
    }

    @Test func 볼륨이_빠지거나_다른_쓰기가_있으면_만들기와_되돌리기를_막는다() async {
        let scene = Scene()
        await scene.usb.refresh()
        let model = scene.model
        _ = scene.usb.beginWrite(scene.ports.volume, title: "시험")
        await model.create()
        await model.restore(scene.ports.entry())
        #expect(scene.ports.state.withLock { $0.calls }.isEmpty)
        scene.usb.endWrite(scene.ports.volume.usbKey)
        scene.usbHost.mounted = []
        await scene.usb.refresh()
        await model.create()
        #expect(!model.canUseVolume && scene.ports.state.withLock { $0.calls }.isEmpty)
    }

    @Test func 실물_확인에는_이름과_용량을_보이고_첫_확인_취소는_쓰지_않는다() async {
        let physical = FakeUsbVolume.physicalFAT32(name: "합성 실물")
        let prompt = UsbWriteFlow.pointRestoreConfirmation(physical, entry: Ports().entry(),
                                                          summary: .init(result: .init(), blocks: [], deviceChanged: false))
        #expect(prompt.details.contains { $0.contains("실물 USB입니다") && $0.contains(physical.name) })
        #expect(prompt.confirm == String(ui: "되돌리기"))
        let scene = Scene()
        await scene.usb.refresh()
        scene.prompter.answer = false
        await scene.model.restore(scene.ports.entry())
        #expect(scene.prompter.shown.count == 1)
        #expect(!scene.ports.state.withLock { $0.calls }.contains("write"))
    }

    @Test func 미리_보기_뒤_새_기기_변경도_따로_묻고_다른_쓰기_뒤에는_취소_백업을_놓는다() async {
        let scene = Scene()
        await scene.usb.refresh()
        scene.ports.state.withLock { $0.changeAfterPreview = true }
        let model = scene.model
        await model.restore(scene.ports.entry())
        #expect(scene.prompter.shown.count == 2)
        #expect(scene.prompter.shown.last?.title == String(ui: "스냅샷 뒤의 기기 변경을 버릴까요?"))
        #expect(scene.ports.state.withLock { $0.calls }.filter { $0 == "write" }.count == 1)
        #expect(model.undoBackup != nil)
        let job = UsbExportJob(database: URL(filePath: "/private/tmp/djc-fixture/copy.db"), share: URL(filePath: "/private/tmp/djc-fixture/share"),
                               volume: scene.ports.volume, selection: .tracks(["1"]), formats: [.deviceLibrary], snapshotTime: nil)
        #expect(await scene.coordinator.export(job))
        #expect(model.undoBackup == nil)
    }

    @Test func 캡처는_라이브러리를_읽기_전에_임시_합성_사본을_요구한다() throws {
        let root = try TemporaryFolder()
        let args = ["DJCrate", "--usb-snapshot-capture=" + root.url.path]
        #expect(UsbSelfTest.startupRefusal(arguments: args, environment: [:]) != nil)
        #expect(UsbSelfTest.startupRefusal(arguments: args, environment: ["DJC_HOME": root.url.path]) != nil)
        let database = root.url.appending(path: "master.db")
        try Data().write(to: database)
        let environment = ["DJC_HOME": root.url.path, "DJC_REKORDBOX_DIR": root.url.path]
        #expect(UsbSelfTest.startupRefusal(arguments: args + ["--db", database.path], environment: environment) == nil)
        #expect(UsbSelfTest.startupRefusal(arguments: args + ["--db", "/outside/master.db"], environment: environment) != nil)
    }
}
