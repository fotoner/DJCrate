import DJCAdapters
import DJCAnalysis
import DJCApplication
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

    @Test func USB_시점_스냅샷은_용량만_보이고_캐시_비우기에서_고정도_그대로_둔다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("usb-point-snapshots/V/saved/files/PIONEER/rekordbox/export.pdb", bytes: 900)
        try scene.write("usb-point-snapshots/V/pinned/files/PIONEER/rekordbox/export.pdb", bytes: 700)
        try scene.write("usb-point-snapshots/V/.partial-x/file", bytes: 100)
        let model = StorageSettingsModel(paths: scene.paths, files: .live)
        await model.refresh()
        #expect(model.backups.first { $0.kind == .usbPointSnapshots } == .init(kind: .usbPointSnapshots, count: 2, bytes: 1_600))
        await model.clear(DJCCacheKind.allCases)
        #expect(scene.exists("usb-point-snapshots/V/saved/files/PIONEER/rekordbox/export.pdb"))
        #expect(scene.exists("usb-point-snapshots/V/pinned/files/PIONEER/rekordbox/export.pdb"))
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
        // 용량 읽기·클론 확인은 폴더를 훑는 동기 입출력이라 협력 풀 밖에서 한다
        let cloning = StorageSettingsModel(paths: scene.paths, files: .live, canClone: { expectBlockingOffPool(); return true })
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
        // 비우기는 파일을 지우는 동기 입출력이라 협력 풀 밖에서 한다
        var files = CacheFiles.live
        let clear = files.clear
        files.clear = { kinds, paths, keeping, dryRun in expectBlockingOffPool(); return clear(kinds, paths, keeping, dryRun) }
        let model = StorageSettingsModel(paths: scene.paths, files: files)
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

    @Test func 비우기_단추는_일을_시작하고_그_손잡이를_모델이_든다() async throws {
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = StorageSettingsModel(paths: scene.paths, files: .live)
        model.startClear([.waveforms])
        await model.task?.value
        #expect(!scene.exists("waveforms/a-1.json") && scene.exists("analysis/chroma/a-1.bin"))
        #expect(model.message?.contains("파형") == true && !model.isWorking, "\(model.message ?? "")")
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

    @Test func LINK로_내어_주는_동안은_WAV_변환본만_비우지_않고_이유를_준다() async throws {
        // #287: CDJ가 NFS로 읽는 중인 변환본을 지우면 재생이 끊긴다. 다른 캐시는 그대로 비운다
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("link-audio/a-0011-22.wav", bytes: 4_000)
        let serving = Mutex(true)
        let model = StorageSettingsModel(paths: scene.paths, files: .live, linkServing: { serving.withLock { $0 } })
        await model.refresh()
        #expect(model.usage?.first { $0.kind == .linkAudio }?.bytes == 4_000)
        #expect(model.blockReason == nil)
        #expect(model.blockReason(of: .linkAudio)?.contains("LINK") == true)
        #expect(model.blockReason(of: .waveforms) == nil)

        await model.clear(DJCCacheKind.allCases)
        #expect(scene.exists("link-audio/a-0011-22.wav"))
        #expect(!scene.exists("waveforms/a-1.json"))
        #expect(model.message?.contains("LINK를 끈 뒤") == true, "\(model.message ?? "")")

        serving.withLock { $0 = false }
        #expect(model.blockReason(of: .linkAudio) == nil)
        await model.clear([.linkAudio])
        #expect(!scene.exists("link-audio/a-0011-22.wav"))
    }

    @Test func 변환본을_지우는_동안은_LINK_켜기를_붙잡고_다_지운_뒤_놓는다() async throws {
        // #287 PR 리뷰: 내어 주는지 처음에 한 번만 보면 비우는 사이 켠 LINK의 변환본을 지운다. 붙잡지 못하면(내어 주는 중) 건너뛴다
        let scene = try scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.write("link-audio/a-0011-22.wav", bytes: 4_000)
        let holding = Mutex(false)
        let heldWhileDeleting = Mutex<Bool?>(nil)
        var files = CacheFiles.live
        let clear = files.clear
        files.clear = { kinds, paths, keeping, dryRun in
            if !dryRun, kinds.contains(.linkAudio) { heldWhileDeleting.withLock { $0 = holding.withLock { $0 } } }
            return clear(kinds, paths, keeping, dryRun)
        }
        let model = StorageSettingsModel(paths: scene.paths, files: files, beginLinkAudioClear: {
            holding.withLock { $0 = true }
            return { holding.withLock { $0 = false } }
        })
        await model.clear([.linkAudio])
        #expect(heldWhileDeleting.withLock { $0 } == true)
        #expect(!holding.withLock { $0 })
        #expect(!scene.exists("link-audio/a-0011-22.wav"))

        try scene.write("link-audio/b-0033-44.wav", bytes: 10)
        let serving = StorageSettingsModel(paths: scene.paths, files: .live, beginLinkAudioClear: { nil })
        await serving.clear(DJCCacheKind.allCases)
        #expect(scene.exists("link-audio/b-0033-44.wav"))
        #expect(serving.message?.contains("LINK를 끈 뒤") == true, "\(serving.message ?? "")")
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
