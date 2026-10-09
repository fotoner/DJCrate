import DJCAdapters
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
@testable import DJCrate
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// #227: 설정 › 저장 공간. 데이터 폴더·스냅샷 폴더는 임시 폴더로 주입한다(사용자 폴더를 열지 않는다).
@MainActor
@Suite("설정 저장 공간")
struct StorageSettingsTests {
    struct Scene {
        let root: URL
        var paths: DJCCachePaths { DJCCachePaths(root: root.appending(path: "home"), snapshots: root.appending(path: "snapshots")) }

        @discardableResult
        func write(_ relative: String, bytes: Int, under base: URL? = nil) throws -> URL {
            let url = (base ?? paths.root).appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            return url
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: paths.root.appending(path: relative).path) }
    }

    func scene() throws -> Scene {
        let scene = Scene(root: FileManager.default.temporaryDirectory.appending(path: "djc-storage-settings-\(UUID())"))
        try scene.write("waveforms/a-1.json", bytes: 3_000)
        try scene.write("analysis/chroma/a-1.bin", bytes: 2_000)
        try scene.write("loudness.json", bytes: 100)
        try scene.write("cue-drafts/a.json", bytes: 10)
        try scene.write("rekordbox-backups/20260101-write/master.db", bytes: 5_000)
        try scene.write("rekordbox-backups/20260102-write/master.db", bytes: 6_000)
        try scene.write("usb-backups/V/20260101-export/x.bin", bytes: 700)
        return scene
    }

    @Test func 탭을_열면_종류별_용량과_백업_개수를_읽는다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = StorageSettingsModel(paths: scene.paths, files: .live)
        await model.refresh()
        #expect(model.usage?.first { $0.kind == .waveforms }?.bytes == 3_000)
        #expect(model.usage?.first { $0.kind == .analysis }?.bytes == 2_000)
        #expect(model.backups.first { $0.kind == .rekordboxBackups } == .init(kind: .rekordboxBackups, count: 2, bytes: 11_000))
        #expect(model.backups.first { $0.kind == .usbBackups } == .init(kind: .usbBackups, count: 1, bytes: 700))
    }

    @Test func 시점_스냅샷도_용량을_보이고_자동_보관_일수를_설정에_저장한다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("point-snapshots/2026-01-01T000000Z-manual/master.db", bytes: 4_000)
        try scene.write("point-snapshots/.partial-x/master.db", bytes: 100)
        let defaults = TestDefaults.make("storage.points")
        let shared = scene.root.appending(path: "shared-settings.json")
        let model = StorageSettingsModel(paths: scene.paths, files: .live, settings: SettingsStore(defaults: defaults, persist: true, sharedFile: .live(file: shared)))
        await model.refresh()
        #expect(model.backups.first { $0.kind == .pointSnapshots } == .init(kind: .pointSnapshots, count: 1, bytes: 4_000), "뜨는 중인 폴더는 세지 않는다")
        #expect(model.autoSnapshotDays == 7)
        model.autoSnapshotDays = 14
        #expect(defaults.double(forKey: SettingKeys.pointSnapshotAutoDays.name) == 14)
        #expect(StorageSettingsModel(paths: scene.paths, files: .live, settings: SettingsStore(defaults: defaults, persist: true)).autoSnapshotDays == 14)
        // CLI(다른 프로세스)도 같은 값을 읽게 데이터 폴더의 공유 파일에도 적는다
        #expect(SharedSettingsFile.value(SettingKeys.pointSnapshotAutoDays, in: shared) == 14)
    }

    @Test func 자동_시점_스냅샷은_기본으로_켜고_끄면_저장한다() throws {
        let defaults = TestDefaults.make("storage.auto")
        let settings = SettingsStore(defaults: defaults, persist: true, sharedFile: nil)
        // 캐시 폴더는 읽지 않는다(설정만 본다)
        let unused = FileManager.default.temporaryDirectory.appending(path: "djc-storage-settings-\(UUID())")
        let model = StorageSettingsModel(paths: DJCCachePaths(root: unused, snapshots: unused), files: .live, settings: settings)
        #expect(model.autoSnapshotEnabled)
        model.autoSnapshotEnabled = false
        #expect(!settings.value(SettingKeys.pointSnapshotAuto))
    }

    @Test func 다른_디스크라_클론이_안_되면_자동_스냅샷을_뜨지_않는다고_알린다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let cloning = StorageSettingsModel(paths: scene.paths, files: .live, canClone: { true })
        await cloning.refresh()
        #expect(cloning.autoSnapshotNote == nil)
        let other = StorageSettingsModel(paths: scene.paths, files: .live, canClone: { false })
        await other.refresh()
        #expect(other.autoSnapshotNote?.contains("다른 디스크") == true, "\(other.autoSnapshotNote ?? "")")
    }

    @Test func 앱을_켜면_지금_설정을_공유_파일에_맞춘다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make("storage.sync")
        defaults.set(21.0, forKey: SettingKeys.pointSnapshotAutoDays.name)
        let shared = root.appending(path: "shared-settings.json")
        SettingsStore(defaults: defaults, persist: true, sharedFile: .live(file: shared)).syncShared()
        #expect(SharedSettingsFile.value(SettingKeys.pointSnapshotAutoDays, in: shared) == 21)
        // 자가 테스트(설정을 쓰지 않는 실행)는 파일을 만들지 않는다
        let other = root.appending(path: "other.json")
        SettingsStore(defaults: defaults, persist: false, sharedFile: .live(file: other)).syncShared()
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func 종류를_비우면_확인_없이_지우고_한_줄로_알리고_용량을_다시_읽는다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = StorageSettingsModel(paths: scene.paths, files: .live)
        await model.refresh()
        await model.clear([.waveforms])
        #expect(!scene.exists("waveforms/a-1.json"))
        #expect(scene.exists("analysis/chroma/a-1.bin") && scene.exists("cue-drafts/a.json"))
        #expect(model.usage?.first { $0.kind == .waveforms }?.bytes == 0)
        #expect(model.message?.contains("파형") == true, "\(model.message ?? "")")

        await model.clear(DJCCacheKind.allCases)
        #expect(!scene.exists("analysis/chroma/a-1.bin") && !scene.exists("loudness.json"))
        #expect(scene.exists("cue-drafts/a.json"))
        #expect(scene.exists("rekordbox-backups/20260101-write/master.db"), "백업은 읽기만 한다")
    }

    @Test func 앱이_연_스냅샷은_남긴다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let opened = try scene.write("master-2026-01-01T000000.db", bytes: 10, under: scene.paths.snapshots)
        try scene.write("master-2026-01-02T000000.db", bytes: 10, under: scene.paths.snapshots)
        try scene.write("master-2026-01-03T000000.db", bytes: 10, under: scene.paths.snapshots)
        let model = StorageSettingsModel(paths: scene.paths, files: .live, openSnapshot: { opened })
        await model.clear([.snapshots])
        let left = try FileManager.default.contentsOfDirectory(atPath: scene.paths.snapshots.path).sorted()
        #expect(left == ["master-2026-01-01T000000.db", "master-2026-01-03T000000.db"])
        #expect(model.clearable[.snapshots] == 0, "남긴 사본뿐이면 비우기 단추를 막는다")
        #expect(model.usage?.first { $0.kind == .snapshots }?.bytes == 20, "용량은 남긴 사본까지 보인다")
    }

    @Test func 쓰는_중에는_비우지_않고_이유를_준다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let reason = Mutex<String?>("시험 쓰기 중")
        let model = StorageSettingsModel(paths: scene.paths, files: .live, busyReason: { reason.withLock { $0 } })
        #expect(model.blockReason == "시험 쓰기 중")
        await model.clear([.waveforms])
        #expect(scene.exists("waveforms/a-1.json"))
        reason.withLock { $0 = nil }
        #expect(model.blockReason == nil)
        await model.clear([.waveforms])
        #expect(!scene.exists("waveforms/a-1.json"))
    }

    @Test func 앱이_쓰는_중인지는_rekordbox와_USB_쓰기에서_나온다() {
        #expect(StorageSettingsModel.busyReason(writingRekordbox: false, writingUsb: false) == nil)
        #expect(StorageSettingsModel.busyReason(writingRekordbox: true, writingUsb: false) != nil)
        #expect(StorageSettingsModel.busyReason(writingRekordbox: false, writingUsb: true) != nil)
    }

    @Test func 비운_뒤_음량과_미리_보기_파형의_메모리도_비고_다시_쓰면_파일이_다시_생긴다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let audio = try AudioFixture.wav(seconds: 1, in: scene.root)
        let loudness = LoudnessCache(url: scene.paths.loudness, saveDelay: .milliseconds(10))
        loudness.store(Loudness(integrated: -9, peak: -1, clippedRuns: 0), for: audio)
        loudness.clear()
        #expect(loudness.value(for: audio) == nil)
        #expect(!FileManager.default.fileExists(atPath: scene.paths.loudness.path))
        loudness.store(Loudness(integrated: -8, peak: -1, clippedRuns: 0), for: audio)
        #expect(await waitForState { FileManager.default.fileExists(atPath: scene.paths.loudness.path) })

        let dat = scene.root.appending(path: "ANLZ.DAT")
        try AnlzBuilder.file([AnlzBuilder.pwav(Array(repeating: 31, count: 1200))]).write(to: dat)
        let source = PreviewWaveformStore.Source(uuid: "u", url: dat)
        let previews = PreviewWaveformStore(file: scene.paths.previewWaveforms)
        await previews.warm([source])
        #expect(FileManager.default.fileExists(atPath: scene.paths.previewWaveforms.path))
        await previews.clear()
        #expect(!FileManager.default.fileExists(atPath: scene.paths.previewWaveforms.path))
        await previews.warm([source])
        #expect(FileManager.default.fileExists(atPath: scene.paths.previewWaveforms.path), "목록을 다시 그리면 다시 만든다")
    }
}
