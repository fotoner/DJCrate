import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import ImageIO
import RekordboxKit
import UniformTypeIdentifiers

// 개발용 자가 시험은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 개발용: 합성 로컬 라이브러리 → 디스크 이미지 내보내기(앱 흐름 그대로) → 꺼내기·다시 붙여 확인 →
/// 편집(곡 빼기·목록 만들기·이름 바꾸기 초안 → 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기) → 되돌리기 → Device Library만 내보내기·OneLibrary 더하기·되돌리기(`--usb-selftest`).
/// 이미지·마운트 지점·합성 라이브러리·초안은 모두 `DJC_HOME` 아래다. 스냅샷을 뜨거나 정리하지 않는다.
/// 출력은 표준 출력에 "USB 시험 …" 줄로 남긴다. 편집 단계가 통과하면 "USB 시험 편집 통과 …", 마지막 줄은 "USB 시험 통과 …" 또는 "USB 시험 실패: <이유>"다.
@MainActor
enum UsbSelfTest {
    /// 띄우면 안 되는 까닭(띄워도 되면 nil). `DJC_HOME`은 임시 폴더여야 하고, 명시한 사본(`--db`·`DJC_DB`)이 있어야 한다 —
    /// `DJC_HOME`은 스냅샷 폴더를 옮기지 않아서 사본 없이 띄운 앱은 사용자 스냅샷 폴더를 연다
    nonisolated static func launchRefusal(arguments: [String], environment: [String: String]) -> String? {
        guard let home = environment["DJC_HOME"], !home.isEmpty else { return "USB 시험 실패: DJC_HOME을 임시 폴더로 주세요" }
        do {
            _ = try UsbScratchPath.check(home, as: .existingDirectory)
        } catch {
            return "USB 시험 실패: DJC_HOME이 임시 폴더가 아닙니다(\(error))"
        }
        guard explicitDatabase(arguments: arguments, environment: environment) != nil else {
            return "USB 시험 실패: --db <스냅샷 사본>으로 띄우세요"
        }
        return nil
    }

    /// 앱 시작 때(라이브러리를 읽기 전) 볼 거부. 자가 테스트 인자가 없으면 nil —
    /// 거부를 시험 Task 안에서만 보면 그 사이 `loadInitial`이 사용자 스냅샷 폴더를 먼저 연다
    nonisolated static func startupRefusal(arguments: [String], environment: [String: String]) -> String? {
        guard arguments.contains("--usb-selftest") else { return nil }
        return launchRefusal(arguments: arguments, environment: environment)
    }

    /// `--db <경로>` 또는 `DJC_DB`
    nonisolated static func explicitDatabase(arguments: [String], environment: [String: String]) -> String? {
        let database = arguments.firstIndex(of: "--db").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        return [database, environment["DJC_DB"]].compactMap { $0 }.first { !$0.isEmpty && !$0.hasPrefix("--") }
    }

    static func runIfRequested(store: LibraryStore) {
        guard CommandLine.arguments.contains("--usb-selftest") else { return }
        Task { await run(store: store) }
    }

    nonisolated static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func finish(_ code: Int32, _ line: String) -> Never {
        log(line)
        exit(code)
    }

    private static func run(store: LibraryStore) async {
        let environment = ProcessInfo.processInfo.environment
        if await Task.detached(operation: { LibrarySnapshot.isRekordboxRunning() }).value {
            finish(0, "USB 시험 건너뜀: rekordbox 켜짐")
        }
        if let refusal = launchRefusal(arguments: CommandLine.arguments, environment: environment) { finish(2, refusal) }
        guard UsbReadPolicy.current() == .diskImagesOnly else { finish(2, "USB 시험 실패: 읽기 정책이 diskImagesOnly가 아닙니다") }
        // 라이브러리(명시한 사본)가 읽히기를 기다린다. 실패해도 스냅샷을 뜨지 않는다
        func loaded() -> Bool { if case .loaded = store.phase { true } else { false } }
        for _ in 0..<1800 {
            if loaded() { break }
            if case .failed = store.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard loaded(), let usb = store.usb else { finish(1, "USB 시험 실패: 라이브러리를 읽지 못했습니다") }
        guard let home = environment["DJC_HOME"].flatMap(UsbScratchRoots.realPath),
              let schema = explicitDatabase(arguments: CommandLine.arguments, environment: environment) else {
            finish(2, "USB 시험 실패: DJC_HOME·--db를 확인하세요")
        }
        let scenario = UsbSelfTestScenario(home: URL(filePath: home), schemaSource: URL(filePath: schema), log: log)
        do {
            let passed = try await scenario.run(usb: usb, host: store)
            finish(0, passed)
        } catch {
            finish(1, "USB 시험 실패: \(error)")
        }
    }
}

/// 자가 테스트 한 번(앱과 시험 하네스가 같이 쓴다). 실패는 이유를 담은 `Failure`로 던지고, 붙인 이미지는 늘 뗀다
@MainActor
struct UsbSelfTestScenario {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// DJC_HOME(realpath). 백업·저널·준비·세션 사본이 여기 아래로 간다
    let home: URL
    /// 합성 라이브러리의 표 구조를 가져올 로컬 사본(구조만 읽는다)
    let schemaSource: URL
    var volumeName = "DJCSELF"
    var log: (String) -> Void

    var base: URL { home.appending(path: "usb-selftest") }
    var image: URL { base.appending(path: "selftest.img") }
    var mountPoint: URL { base.appending(path: "mnt") }
    /// USB 초안(편집 단계)
    var drafts: URL { home.appending(path: "usb-drafts") }

    /// 앱이 쓰는 창구와 같다. 다만 자가 테스트는 DJC_HOME 아래에 이미지를 붙이므로, 보호 폴더에서 DJC_HOME 전체 대신
    /// DJC_HOME 안의 USB 쓰기 폴더(백업·저널·준비·세션 사본)와 합성 라이브러리만 막는다(실물 관문·임시 폴더 뿌리 확인은 그대로)
    func makeService(fileSystem: any UsbFileSystem = PosixUsbFileSystem()) -> UsbWriteService {
        let paths = UsbWritePaths(backups: home.appending(path: "usb-backups"), sessions: home.appending(path: "usb-sessions"),
                                  staging: home.appending(path: "usb-staging"))
        let copies = home.appending(path: "usb-snapshots")
        let homeReal = UsbScratchRoots.realPath(home.path) ?? home.path
        let ours = [paths.backups, paths.sessions, paths.staging, copies, drafts, base.appending(path: "local")]
        return UsbAppComposition.writeService(policy: .diskImagesOnly, paths: paths, localCopies: copies, drafts: drafts, fileSystem: fileSystem,
                                              writeGuard: {
            var writeGuard = UsbWriteGuard.system
            writeGuard.protectedRoots = writeGuard.protectedRoots.filter { (UsbScratchRoots.realPath($0.path) ?? $0.path) != homeReal } + ours
            return writeGuard
        })
    }

    /// 통과하면 마지막 줄("USB 시험 통과 …")
    func run(usb: UsbStore, host: any UsbWriteHost) async throws -> String {
        guard !FileManager.default.fileExists(atPath: base.path) else {
            throw Failure("\(base.path)가 이미 있습니다. 새 DJC_HOME으로 다시 띄우세요")
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        let library = try await detached { [base, schemaSource] in
            try UsbSelfTestLibrary.make(in: base.appending(path: "local"), schemaFrom: schemaSource)
        }
        log("USB 시험 합성 라이브러리: 곡 \(library.trackIDs.count) · 재생 목록 1")
        let (image, mount, name) = (self.image.path, self.mountPoint.path, volumeName)
        let created = try await detached { try UsbDiskImage.create(image: image, size: 4 << 30, name: name) }
        log("USB 시험 이미지: \(created.summary)")
        _ = try await detached { try UsbDiskImage.attach(image: image, mountPoint: mount) }
        do {
            let result = try await exercise(usb: usb, host: host, library: library)
            try await detach()
            return result
        } catch {
            try? await detach()
            throw error
        }
    }

    private func detach() async throws {
        let image = self.image.path
        if try await detached({ try UsbDiskImage.detach(image: image) }) { log("USB 시험: 이미지를 뗐습니다") }
    }

    private func exercise(usb: UsbStore, host: any UsbWriteHost, library: UsbSelfTestLibrary.Made) async throws -> String {
        let recorder = UsbAppleDoubleRecorder()
        let service = UsbSelfTestRecordingService(base: makeService(fileSystem: recorder))
        let prompter = UsbSelfTestPrompter(log: log)
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter)
        // 편집 단계의 초안은 DJC_HOME 아래 이 시험 폴더에만
        usb.drafts = .live(directory: drafts)
        var volume = try await waitForVolume(usb)
        guard volume.isDiskImage else { throw Failure("시험 볼륨이 디스크 이미지로 보이지 않습니다") }
        let root = UsbRoot(URL(filePath: volume.mountPoint))
        let before = try await detached { try UsbTree.walk(root) }
        let doublesBefore = try await detached { try UsbInvariantVerifier.appleDoubles(on: root) }

        // 미리 보기(두 번 해도 같다) → 확인 창(자동 확인) → 쓰기
        let snapshotTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let job = UsbExportJob(database: library.database, share: library.share, volume: volume, selection: .playlists([library.playlistID]),
                               formats: UsbFormat.defaultSet, snapshotTime: snapshotTime)
        guard let first = await coordinator.preview(job), let second = await coordinator.preview(job) else {
            throw Failure("미리 보기를 하지 못했습니다(\(prompter.lastText))")
        }
        log("USB 시험 미리 보기: 곡 \(first.trackCount) · 재생 목록 \(first.playlistCount) · 막힘 \(first.blockCounts.count) · CDJ 확인 항목 \(first.rules.count) · 두 번째 같음 \(first == second)")
        guard first.canWrite, first == second else { throw Failure("미리 보기로 쓸 수 없습니다(\(UsbWriteFlow.stoppingText(first)))") }
        let journal = await detached { service.journal(volumeKey: job.volumeKey) }
        log("USB 시험 미리 보기 뒤 저널: \(Self.journalText(journal)) · 끝나지 않은 쓰기 \(journal.isPending)")
        await coordinator.export(job)
        guard let report = service.lastWrite, report.outcome == .written else { throw Failure("쓰지 못했습니다(\(prompter.lastText))") }
        guard prompter.titles.allSatisfy({ $0 != UsbWriteFlow.pendingPrompt(volume).title }) else {
            throw Failure("드라이 런 저널이 끝나지 않은 쓰기로 보였습니다")
        }
        guard let toast = host.toast, toast.action == .ejectUsb(volumeKey: job.volumeKey) else { throw Failure("쓰기 토스트가 없습니다") }
        log("USB 시험 쓰기: \(toast.title) · 만든 파일 \(report.filesCreated) · 지운 ._ \(report.appleDoubleRemoved)")
        let written = try await detached { try UsbTree.walk(root) }
        let beforePaths = Set(before.map(\.relativePath))
        let appFiles = written.filter { !$0.isDirectory && !beforePaths.contains($0.relativePath)
            && !UsbLayout.isAppleDouble(($0.relativePath as NSString).lastPathComponent) }
        // 쓰기 절차가 지운 ._ 가운데 앱이 쓴 최종 파일 옆의 것(되돌리기가 지우는 것은 세지 않는다)
        let doubled = Self.appleDoubleCount(appFiles: appFiles.map(\.relativePath), root: URL(filePath: volume.mountPoint),
                                            removed: recorder.removedAppleDoubles)

        // 토스트의 [꺼내기] → 이미지가 떨어졌는지 → 다시 붙여 읽기
        await coordinator.perform(toast.action!)
        try await waitDetached()
        log("USB 시험 꺼내기: 이미지가 떨어졌습니다")
        let (image, mount) = (self.image.path, self.mountPoint.path)
        _ = try await detached { try UsbDiskImage.attach(image: image, mountPoint: mount) }
        volume = try await waitForVolume(usb)
        let doublesAfter = try await detached { try UsbInvariantVerifier.appleDoubles(on: root) }
        let left = doublesAfter.subtracting(doublesBefore).count
        // ._ 생김 = 앱이 쓴 최종 파일 옆에 생겨 쓰기 절차가 지운 ._ 수, 쓸기 뒤 = 꺼냈다 다시 붙인 USB에 남은 새 ._ 수
        log("USB 시험 provenance: 앱이 쓴 파일 \(appFiles.count)개 중 ._ 생김 \(doubled)개, 쓸기 뒤 \(left)개")
        let reattached = volume
        let scratch = base.appending(path: "info-\(UUID().uuidString)")
        let info = try await detached {
            try UsbRead.live.info(root: URL(filePath: reattached.mountPoint), scratch: scratch, volume: reattached)
        }
        let formats = Set(info.formats)
        let oneLibrary = info.oneLibrary, deviceLibrary = info.deviceLibrary
        log("USB 시험 다시 읽기: 형식 \(info.formats.sorted().joined(separator: "·")) · OneLibrary 곡 \(oneLibrary?.tracks ?? -1) 목록 \(oneLibrary?.playlists ?? -1) · Device Library 곡 \(deviceLibrary?.tracks ?? -1) 목록 \(deviceLibrary?.playlists ?? -1) 왕복 \(deviceLibrary?.roundTripOK.map { "\($0)" } ?? "-") · 경고 \(info.warnings.count)")
        guard formats == Set(UsbFormat.allCases.map(\.rawValue)), oneLibrary?.tracks == 3, oneLibrary?.playlists == 1,
              oneLibrary?.integrityOK == true, deviceLibrary?.tracks == 3, deviceLibrary?.playlists == 1,
              deviceLibrary?.structureIssues == 0, deviceLibrary?.roundTripOK != false, info.warnings.isEmpty,
              info.consistency.trackIDsMatch, info.consistency.playlistMismatches == 0 else {
            throw Failure("다시 붙인 USB가 쓴 것과 다릅니다")
        }

        // 편집(초안 → 미리 보기 → 쓰기 → 다시 읽기 → 이 편집의 백업으로 되돌리기)
        log(try await exerciseEdit(usb: usb, host: host, coordinator: coordinator, service: service, prompter: prompter, volume: reattached,
                                   library: library, snapshotTime: snapshotTime))

        // 되돌리기(이 쓰기의 백업으로) → 트리가 쓰기 전과 같다
        guard usb.beginWrite(reattached, title: "USB 시험: 되돌리는 중", cancellable: false) != nil else { throw Failure("볼륨을 잠그지 못했습니다") }
        let writtenBackup = report.backup.map { URL(filePath: $0) }
        let restored = await detached { Result { try service.restore(reattached, backup: writtenBackup, discardDeviceChanges: false) } }
        usb.endWrite(reattached.usbKey)
        guard case let .success(restoreReport) = restored, restoreReport.outcome == .restored else {
            throw Failure("되돌리지 못했습니다(\(restored))")
        }
        let after = try await detached { try UsbTree.walk(root) }
        let differ = Set(before).symmetricDifference(Set(after)).map(\.relativePath).sorted()
        log("USB 시험 되돌리기: 트리 차이 \(differ.count)" + (differ.isEmpty ? "" : " (\(differ.prefix(5).joined(separator: ", ")))"))
        guard differ.isEmpty else { throw Failure("되돌린 트리가 쓰기 전과 다릅니다") }
        log(try await exerciseMigration(usb: usb, host: host, coordinator: coordinator, service: service, prompter: prompter,
                                        volume: reattached, library: library, snapshotTime: snapshotTime))
        return "USB 시험 통과 · 곡 \(first.trackCount) · 재생 목록 \(first.playlistCount) · 앱이 쓴 파일 \(appFiles.count)개 · 되돌린 뒤 트리 같음"
    }

    /// Device Library만 내보낸 뒤 옮기기. 미리 보기의 USB 불변, 원래 파일 보존, 다시 붙여 읽기, 두 쓰기의 백업 복원을 확인한다.
    private func exerciseMigration(usb: UsbStore, host: any UsbWriteHost, coordinator: UsbWriteCoordinator, service: UsbSelfTestRecordingService,
                                   prompter: UsbSelfTestPrompter, volume: UsbVolumeInfo, library: UsbSelfTestLibrary.Made,
                                   snapshotTime: String) async throws -> String {
        let root = UsbRoot(URL(filePath: volume.mountPoint))
        let empty = try await detached { try UsbTree.fingerprint(root).files }
        let job = UsbExportJob(database: library.database, share: library.share, volume: volume, selection: .playlists([library.playlistID]),
                               formats: [.deviceLibrary], snapshotTime: snapshotTime)
        await coordinator.export(job)
        guard let exported = service.lastWrite, exported.outcome == .written else { throw Failure("Device Library만 내보내지 못했습니다") }
        let before = try await detached { try UsbTree.fingerprint(root).files }
        guard let first = await coordinator.previewMigration(volume), let second = await coordinator.previewMigration(volume),
              first.canWrite, first == second, first.rules.allSatisfy(\.needsDeviceCheck) else { throw Failure("옮기기 미리 보기 실패") }
        let previewTree = try await detached { try UsbTree.fingerprint(root).files }
        guard before == previewTree else { throw Failure("옮기기 미리 보기가 USB를 바꿈") }
        log("USB 시험 옮기기 미리 보기: 곡 \(first.trackCount) · 목록 \(first.playlistCount) · 아트워크 \(first.artworkFiles) · CDJ 확인 항목 \(first.rules.count) · 트리 그대로")
        await coordinator.migrate(volume)
        guard service.lastMigration?.outcome == .written, usb.migrationBackups[volume.usbKey] != nil,
              host.toast?.action == .ejectUsb(volumeKey: volume.usbKey) else { throw Failure("옮기기 쓰기 실패(\(prompter.lastText))") }
        let after = try await detached { try UsbTree.fingerprint(root).files }
        guard before.allSatisfy({ after[$0.key] == $0.value }) else { throw Failure("옮기기가 원래 파일을 바꿈") }
        await coordinator.perform(.ejectUsb(volumeKey: volume.usbKey))
        try await waitDetached()
        let (image, mount) = (self.image.path, self.mountPoint.path)
        _ = try await detached { try UsbDiskImage.attach(image: image, mountPoint: mount) }
        let current = try await waitForVolume(usb)
        guard usb.libraries[current.usbKey]?.formats == UsbFormat.defaultSet,
              let info = usb.infos[current.usbKey], info.oneLibrary?.integrityOK == true, info.deviceLibrary?.roundTripOK == true,
              info.consistency.trackIDsMatch, info.consistency.playlistMismatches == 0, info.warnings.isEmpty else {
            throw Failure("옮긴 USB를 다시 붙여 읽은 결과가 다름")
        }
        await coordinator.restoreMigration(current)
        let restored = try await detached { try UsbTree.fingerprint(root).files }
        guard usb.migrationBackups[current.usbKey] == nil, before == restored else { throw Failure("옮기기 되돌림 트리가 다름") }
        let backup = exported.backup.map { URL(filePath: $0) }
        _ = try await detached { try service.restore(current, backup: backup, discardDeviceChanges: false) }
        let final = try await detached { try UsbTree.fingerprint(root).files }
        guard final == empty else { throw Failure("Device Library 내보내기 되돌림 트리가 다름") }
        return "USB 시험 옮기기 통과 · 곡 \(first.trackCount) · 목록 \(first.playlistCount) · 아트워크 \(first.artworkFiles) · 원래 파일 그대로 · 왕복 true · 되돌림 차이 0"
    }

    /// 편집 단계: 내보낸 USB에 곡 하나 빼기·새 목록·목록 이름 바꾸기를 앱 동작(`UsbEditActions`)으로 초안에 쌓고,
    /// 쓰기 대기 목록처럼 미리 보기 → 그 미리 보기로 쓰기(확인 창 자동 확인) → 다시 읽어 확인 → 이 편집의 백업으로 되돌려 편집 전 트리와 견준다.
    /// 통과하면 "USB 시험 편집 통과 …" 줄
    private func exerciseEdit(usb: UsbStore, host: any UsbWriteHost, coordinator: UsbWriteCoordinator, service: UsbSelfTestRecordingService,
                              prompter: UsbSelfTestPrompter, volume: UsbVolumeInfo, library: UsbSelfTestLibrary.Made,
                              snapshotTime: String) async throws -> String {
        let key = volume.usbKey
        let root = UsbRoot(URL(filePath: volume.mountPoint))
        guard usb.acceptsEdits(key), let read = usb.libraries[key], let exported = read.playlists.first(where: { $0.attribute == 0 }),
              let removed = read.tracks.first else {
            throw Failure("편집할 USB 라이브러리를 읽지 못했습니다")
        }
        let before = try await detached { try UsbTree.walk(root) }
        let names = UsbSelfTestNamePrompter(answers: ["DJC 시험 새 목록", "DJC 시험 목록 2"])
        let actions = UsbEditActions(usb: usb, host: host, prompter: prompter, namePrompter: names)
        let rows = UsbLibraryRows.collection(library: read, volumeKey: key, mountPoint: volume.mountPoint, badges: [:])
        await actions.removeTracks(rows.filter { UsbEditActions.usbContentID($0, volumeKey: key) == removed.id }, volumeKey: key)
        await actions.createPlaylist(isFolder: false, parent: nil, volumeKey: key)
        await actions.renamePlaylist(exported.id, volumeKey: key)
        guard usb.draftCounts[key] == 3 else { throw Failure("초안에 편집 3건이 쌓이지 않았습니다(\(usb.draftCounts[key] ?? 0)건)") }

        // 미리 보기(쓰지 않음) → 저널이 쓰기를 막지 않는다 → 그 미리 보기로 쓰기
        guard let preview = await coordinator.previewDraft(volumeKey: key, database: library.database, share: library.share,
                                                           snapshotTime: snapshotTime) else {
            throw Failure("편집 미리 보기를 하지 못했습니다(\(prompter.lastText))")
        }
        let formats = preview.formats.filter(\.written).map(\.format.displayName).joined(separator: "·")
        log("USB 시험 편집 미리 보기: 편집 \(preview.editCount) · 쓸 편집 \(preview.writtenCount) · 막힌 편집 \(preview.blockedCount) · 지울 파일 \(preview.removals) · 형식 \(formats)")
        guard preview.canWrite, preview.writtenCount == 3 else {
            throw Failure("편집 미리 보기로 쓸 수 없습니다(\((preview.stopping + UsbWriteFlow.editLines(preview)).joined(separator: " / ")))")
        }
        let journal = await detached { service.journal(volumeKey: key) }
        log("USB 시험 편집 미리 보기 뒤 저널: \(Self.journalText(journal)) · 끝나지 않은 쓰기 \(journal.isPending)")
        await coordinator.writeDraft(volumeKey: key, database: library.database, share: library.share, snapshotTime: snapshotTime,
                                     reusing: preview)
        guard let report = service.lastEdit, report.outcome == .written else { throw Failure("편집을 쓰지 못했습니다(\(prompter.lastText))") }
        guard prompter.titles.allSatisfy({ $0 != UsbWriteFlow.pendingPrompt(volume).title }) else {
            throw Failure("미리 보기 뒤 저널이 끝나지 않은 쓰기로 보였습니다")
        }
        guard let toast = host.toast, toast.action == .ejectUsb(volumeKey: key), toast.title == String(ui: "USB에 편집 \(preview.writtenCount)건을 썼습니다") else {
            throw Failure("편집 쓰기 토스트가 없습니다")
        }
        guard (usb.draftCounts[key] ?? 0) == 0 else { throw Failure("쓴 뒤에도 초안이 남았습니다") }
        log("USB 시험 편집 쓰기: \(toast.title) · 만든 파일 \(report.filesCreated) · 덮어쓴 파일 \(report.filesOverwritten) · 지운 파일 \(report.filesRemoved)")

        // 다시 읽기: 두 형식 곡 2 · 목록 2, 새 이름
        let scratch = base.appending(path: "info-\(UUID().uuidString)")
        let info = try await detached {
            try UsbRead.live.info(root: URL(filePath: volume.mountPoint), scratch: scratch, volume: volume)
        }
        let oneLibrary = info.oneLibrary, deviceLibrary = info.deviceLibrary
        let playlistNames = Set(usb.libraries[key]?.playlists.map(\.name) ?? [])
        log("USB 시험 편집 다시 읽기: OneLibrary 곡 \(oneLibrary?.tracks ?? -1) 목록 \(oneLibrary?.playlists ?? -1) · Device Library 곡 \(deviceLibrary?.tracks ?? -1) 목록 \(deviceLibrary?.playlists ?? -1) 왕복 \(deviceLibrary?.roundTripOK.map { "\($0)" } ?? "-") · 경고 \(info.warnings.count) · 새 이름 \(playlistNames.isSuperset(of: ["DJC 시험 새 목록", "DJC 시험 목록 2"]))")
        guard oneLibrary?.tracks == read.tracks.count - 1, oneLibrary?.playlists == 2, oneLibrary?.integrityOK == true,
              deviceLibrary?.tracks == read.tracks.count - 1, deviceLibrary?.playlists == 2, deviceLibrary?.structureIssues == 0,
              deviceLibrary?.roundTripOK != false, info.warnings.isEmpty, info.consistency.trackIDsMatch, info.consistency.playlistMismatches == 0,
              playlistNames == ["DJC 시험 새 목록", "DJC 시험 목록 2"] else {
            throw Failure("편집한 USB가 편집과 다릅니다")
        }

        // 이 편집의 백업으로 되돌리기 → 트리가 편집 전과 같다
        guard usb.beginWrite(volume, title: "USB 시험: 편집을 되돌리는 중", cancellable: false) != nil else { throw Failure("볼륨을 잠그지 못했습니다") }
        let backup = report.backup.map { URL(filePath: $0) }
        let restored = await detached { Result { try service.restore(volume, backup: backup, discardDeviceChanges: false) } }
        usb.endWrite(key)
        guard case let .success(restoreReport) = restored, restoreReport.outcome == .restored else {
            throw Failure("편집을 되돌리지 못했습니다(\(restored))")
        }
        let after = try await detached { try UsbTree.walk(root) }
        let differ = Set(before).symmetricDifference(Set(after)).map(\.relativePath).sorted()
        log("USB 시험 편집 되돌리기: 트리 차이 \(differ.count)" + (differ.isEmpty ? "" : " (\(differ.prefix(5).joined(separator: ", ")))"))
        guard differ.isEmpty else { throw Failure("되돌린 트리가 편집 전과 다릅니다") }
        await usb.refresh()
        return "USB 시험 편집 통과 · 편집 3 · 곡 \(read.tracks.count)→\(read.tracks.count - 1) · 재생 목록 \(read.playlists.count)→2 · 되돌린 뒤 트리 같음"
    }

    nonisolated static func journalText(_ journal: UsbJournalInfo) -> String {
        switch journal {
        case .none: "없음"
        case let .state(state): state.rawValue
        case .unreadable: "읽지 못함"
        }
    }

    /// 사이드바가 시험 볼륨을 볼 때까지(15초)
    private func waitForVolume(_ usb: UsbStore) async throws -> UsbVolumeInfo {
        let mount = UsbScratchRoots.realPath(mountPoint.path) ?? mountPoint.path
        for _ in 0..<60 {
            await usb.refresh()
            if let volume = usb.volumes.first(where: { $0.mountPoint == mount }) { return volume }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("사이드바가 시험 볼륨을 보지 못했습니다")
    }

    /// 꺼내기 뒤 이미지가 떨어질 때까지(10초). 떨어지지 않으면 떼고 실패
    private func waitDetached() async throws {
        let image = self.image.path
        for _ in 0..<40 {
            let lines = try await detached { try UsbDiskImage.info(image: image) }
            if lines.contains("붙어 있지 않음") { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("꺼내기로 이미지가 떨어지지 않았습니다")
    }

    /// 앱이 쓴 파일(루트 기준 상대 경로) 가운데 옆의 `._<이름>`을 쓰기 절차가 지운 파일 수.
    /// 임시 이름·폴더의 `._`는 세지 않는다. 경로는 NFC로 맞춘다(FAT·macOS가 한글을 NFD로 돌려줄 수 있다)
    nonisolated static func appleDoubleCount(appFiles: [String], root: URL, removed: [String]) -> Int {
        let roots = Set([root.path, UsbScratchRoots.realPath(root.path)].compactMap { $0 }.map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        let removedRelative = Set(removed.compactMap { path -> String? in
            guard let prefix = roots.first(where: { path.hasPrefix($0) }) else { return nil }
            return String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
        })
        return appFiles.filter { file in
            let relative = file.precomposedStringWithCanonicalMapping
            let name = (relative as NSString).lastPathComponent, parent = (relative as NSString).deletingLastPathComponent
            let double = UsbLayout.appleDoubleName(for: name)
            return removedRelative.contains(parent.isEmpty ? double : parent + "/" + double)
        }.count
    }

    private func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    private func detached<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }
}

/// 실제 창구를 그대로 부르고 마지막 쓰기 보고서만 남긴다(provenance 줄·편집 되돌리기에 쓴다)
final class UsbSelfTestRecordingService: UsbWriting, @unchecked Sendable {
    let base: UsbWriteService
    private let lock = NSLock()
    private var written: UsbWriteReport?
    private var edited: UsbWriteReport?
    private var migrated: UsbWriteReport?

    init(base: UsbWriteService) { self.base = base }

    var lastWrite: UsbWriteReport? { lock.withLock { written } }
    /// 마지막 수정 쓰기 보고서(쓸 것이 없었으면 nil)
    var lastEdit: UsbWriteReport? { lock.withLock { edited } }
    var lastMigration: UsbWriteReport? { lock.withLock { migrated } }

    func journal(volumeKey: String) -> UsbJournalInfo { base.journal(volumeKey: volumeKey) }
    func preview(_ input: UsbExportInput) throws -> UsbExportSummary { try base.preview(input) }
    func write(_ input: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        let report = try base.write(input, progress: progress, isCancelled: isCancelled)
        lock.withLock { written = report }
        return report
    }
    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary { try base.previewMigration(volume) }
    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten {
        let written = try base.writeMigration(volume, progress: progress, isCancelled: isCancelled)
        lock.withLock { migrated = written.report }
        return written
    }
    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport { try base.recover(volume) }
    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try base.restore(volume, backup: backup, discardDeviceChanges: discardDeviceChanges)
    }
    func latestBackup(volumeKey: String) -> URL? { base.latestBackup(volumeKey: volumeKey) }
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint { try base.draftBase(volume) }
    func previewEdit(_ input: UsbEditInput) throws -> UsbEditSummary { try base.previewEdit(input) }
    func writeEdit(_ input: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten {
        let written = try base.writeEdit(input, progress: progress, isCancelled: isCancelled)
        lock.withLock { edited = written.report }
        return written
    }
    func isScratchMount(_ mountPoint: String) -> Bool { base.isScratchMount(mountPoint) }
    var syncGate: UsbSyncSelectionGate { base.syncGate }
    func isRekordboxRunning() -> Bool { base.isRekordboxRunning() }
    func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                           rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan {
        try base.planCueGridImport(volume: volume, snapshot: snapshot, share: share, scratch: scratch, rows: rows)
    }
}

/// 지운 `._` 파일을 적는 USB 파일 연산(나머지는 그대로 POSIX로 한다)
final class UsbAppleDoubleRecorder: UsbFileSystem, @unchecked Sendable {
    let base: any UsbFileSystem
    private let lock = NSLock()
    private var removed: [String] = []

    init(base: any UsbFileSystem = PosixUsbFileSystem()) { self.base = base }

    var removedAppleDoubles: [String] { lock.withLock { removed } }

    func stat(_ url: URL) throws -> UsbFileStat? { try base.stat(url) }
    func list(_ directory: URL) throws -> [String] { try base.list(directory) }
    func makeDirectory(_ url: URL) throws { try base.makeDirectory(url) }
    func writeNew(_ data: Data, to url: URL) throws { try base.writeNew(data, to: url) }
    func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String) {
        try base.copyDataNew(from: source, to: url, progress: progress)
    }
    func setModificationDate(_ url: URL, _ date: Date) throws { try base.setModificationDate(url, date) }
    func fullSync(_ url: URL) throws { try base.fullSync(url) }
    func syncDirectory(_ url: URL) throws { try base.syncDirectory(url) }
    func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
    func remove(_ url: URL) throws {
        try base.remove(url)
        if UsbLayout.isAppleDouble(url.lastPathComponent) { lock.withLock { removed.append(url.path) } }
    }
    func removeDirectoryIfEmpty(_ url: URL) throws -> Bool { try base.removeDirectoryIfEmpty(url) }
    func sha256(_ url: URL, uncached: Bool) throws -> String { try base.sha256(url, uncached: uncached) }
    func read(_ url: URL, maxBytes: Int) throws -> Data { try base.read(url, maxBytes: maxBytes) }
    func readFile(root: UsbRoot, relativePath: String, maxBytes: Int) throws -> UsbFileRead? {
        try base.readFile(root: root, relativePath: relativePath, maxBytes: maxBytes)
    }
    func mountedOn(_ url: URL) throws -> String? { try base.mountedOn(url) }
    func holdVolume(_ root: URL) throws -> any UsbVolumeHold { try base.holdVolume(root) }
}

/// 편집 단계의 이름 창: 정해 둔 이름을 차례로 넣는다
@MainActor
final class UsbSelfTestNamePrompter: UsbNamePrompter {
    private var answers: [String]

    init(answers: [String]) { self.answers = answers }

    func askName(title: String, text: String, initial: String, confirm: String) -> String? {
        answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// 쓰기 확인 창만 자동으로 확인한다. 그 밖의 창(실패·백업 폴더 열기·끝나지 않은 쓰기)은 적어 두고 누르지 않는다
@MainActor
final class UsbSelfTestPrompter: HeadlessReflectionPrompter {
    let log: (String) -> Void
    private(set) var titles: [String] = []
    private(set) var lastText = ""

    init(log: @escaping (String) -> Void) { self.log = log }

    func show(_ prompt: ReflectionPrompt) -> Bool {
        titles.append(prompt.title)
        lastText = ([prompt.title, prompt.text] + prompt.details).joined(separator: " / ")
        log("USB 시험 창: \(prompt.title)")
        return prompt.confirm == String(ui: "USB에 쓰기") || prompt.confirm == String(ui: "OneLibrary 더하기")
            || (prompt.confirm == String(ui: "되돌리기") && !prompt.critical && prompt.title == String(ui: "USB를 쓰기 전으로 되돌릴까요?"))
    }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        _ = show(prompt)
        return .cancel
    }
}

/// 합성 로컬 rekordbox 라이브러리: 표 구조만 로컬 사본에서 가져오고(행은 읽지 않는다) 곡 3·목록 1·분석 파일·아트워크를 합성한다.
/// 제목·이름·ID·DB ID는 모두 지어낸 값이다
enum UsbSelfTestLibrary {
    struct Made: Sendable {
        var database: URL
        var share: URL
        var playlistID: String
        var trackIDs: [String]
    }

    /// 지어낸 로컬 DB ID
    static let dbid = "626262"
    static let stamp = "2026-01-01 00:00:00.000 +00:00"
    /// rekordbox 기본 색·메뉴 이름(순서·ID는 지어낸 값)
    static let colorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]
    static let menuNames = ["Genre", "Artist", "Album", "Track", "BPM", "Rating", "Year", "Key", "Label", "Color", "Time", "Bitrate",
                            "Comments", "Date Added"]

    static func make(in folder: URL, schemaFrom source: URL) throws -> Made {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let share = folder.appending(path: "share"), audio = folder.appending(path: "audio")
        for url in [share, audio] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let key = try RekordboxKey.derive()
        let schema = try readSchema(source, key: key)
        let database = folder.appending(path: "master.db")
        let db = try CipherDatabase(path: database.path, key: .hex(key), mode: .create)
        defer { db.close() }
        for statement in schema { try db.execute(statement) }

        func insert(_ table: String, _ values: [String: CipherDatabase.Value]) throws {
            var values = values
            values["created_at"] = values["created_at"] ?? .text(stamp)
            values["updated_at"] = values["updated_at"] ?? .text(stamp)
            let keys = values.keys.sorted()
            _ = try db.run("INSERT INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))",
                           keys.map { values[$0]! })
        }
        func uuid() -> CipherDatabase.Value { .text(UUID().uuidString.lowercased()) }

        try insert("djmdProperty", ["DBID": .text(dbid), "DBVersion": .text("6000")])
        for (index, name) in colorNames.enumerated() {
            try insert("djmdColor", ["ID": .text(String(index + 1)), "ColorCode": .int(index), "SortKey": .int(index + 1),
                                     "Commnt": .text(name), "UUID": uuid(), "rb_local_deleted": .int(0)])
        }
        for (index, name) in menuNames.enumerated() {
            try insert("djmdMenuItems", ["ID": .text(String(index + 1)), "Class": .int(index + 1), "Name": .text(name), "UUID": uuid(),
                                         "rb_local_deleted": .int(0)])
        }
        try insert("djmdArtist", ["ID": .text("1"), "Name": .text("DJC 시험 아티스트"), "rb_local_deleted": .int(0)])
        try insert("djmdAlbum", ["ID": .text("1"), "Name": .text("DJC 시험 앨범"), "Compilation": .int(0), "rb_local_deleted": .int(0)])

        var ids: [String] = []
        for number in 1...3 {
            let id = String(number)
            let fileName = "djc-selftest-\(number).mp3"
            let audioURL = audio.appending(path: fileName)
            let bytes = Data((0..<(48_000 + 1_000 * number)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ number) })
            try bytes.write(to: audioURL)
            let analysis = "/PIONEER/USBANLZ/s\(number)/t\(number)/ANLZ0000.DAT"
            let datURL = share.appending(path: String(analysis.dropFirst()))
            try fm.createDirectory(at: datURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try UsbSelfTestAnlz.dat(path: "?/" + fileName).write(to: datURL)
            try UsbSelfTestAnlz.ext(path: "?/" + fileName).write(to: datURL.deletingPathExtension().appendingPathExtension("EXT"))
            try UsbSelfTestAnlz.twoEx(path: "?/" + fileName).write(to: datURL.deletingPathExtension().appendingPathExtension("2EX"))
            let imagePath = "/PIONEER/Artwork/s\(number)/artwork.jpg"
            let artwork = share.appending(path: String(imagePath.dropFirst())).deletingLastPathComponent()
            try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
            try jpeg(size: 80, hue: Double(number) / 4).write(to: artwork.appending(path: "artwork_s.jpg"))
            try jpeg(size: 240, hue: Double(number) / 4).write(to: artwork.appending(path: "artwork_m.jpg"))
            try insert("djmdContent", [
                "ID": .text(id), "UUID": uuid(), "Title": .text("DJC 시험 곡 \(number)"), "FileType": .int(1), "BitRate": .int(320),
                "Analysed": .int(105), "Length": .int(200), "BPM": .int(12800), "FolderPath": .text(audioURL.path), "FileNameL": .text(fileName),
                "FileSize": .int(bytes.count), "CueUpdated": .text("1"), "AnalysisDataPath": .text(analysis), "AnalysisUpdated": .text("1"),
                "TrackInfoUpdated": .text("1"), "MasterDBID": .text(dbid), "MasterSongID": .text("90\(number)"), "ArtistID": .text("1"),
                "AlbumID": .text("1"), "ImagePath": .text(imagePath), "rb_data_status": .int(256), "rb_local_deleted": .int(0),
                "rb_local_usn": .int(10),
            ])
            ids.append(id)
        }
        try insert("djmdPlaylist", ["ID": .text("1"), "Seq": .int(1), "Name": .text("DJC 시험 목록"), "Attribute": .int(0),
                                    "ParentID": .text("root"), "UUID": uuid(), "rb_local_deleted": .int(0)])
        for (index, id) in ids.enumerated() {
            try insert("djmdSongPlaylist", ["ID": .text("1-\(index)"), "PlaylistID": .text("1"), "ContentID": .text(id),
                                            "TrackNo": .int(index + 1), "UUID": uuid(), "rb_local_deleted": .int(0)])
        }
        return Made(database: database, share: share, playlistID: "1", trackIDs: ids)
    }

    /// 표·색인 구조(SQL)만 읽는다. 행은 읽지 않는다
    static func readSchema(_ source: URL, key: String) throws -> [String] {
        let db = try CipherDatabase.diagnostic(path: source.path, key: key)
        defer { db.close() }
        var statements: [String] = []
        try db.query("""
            SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END, rowid
            """) { row in
            if let sql = row.string(0) { statements.append(sql) }
        }
        guard statements.contains(where: { $0.contains("djmdContent") }) else { throw UsbSelfTestScenario.Failure("--db가 rekordbox 라이브러리 사본이 아닙니다") }
        return statements
    }

    /// 한 색으로 칠한 JPEG
    static func jpeg(size: Int, hue: Double) throws -> Data {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw UsbSelfTestScenario.Failure("아트워크를 만들지 못했습니다")
        }
        context.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw UsbSelfTestScenario.Failure("아트워크를 만들지 못했습니다")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw UsbSelfTestScenario.Failure("아트워크를 만들지 못했습니다") }
        return data as Data
    }
}

/// 로컬 share 모양의 합성 분석 파일. 파형·박자·프레이즈 값은 모두 지어낸 것이고, 큐 태그는 로컬처럼 비어 있다
enum UsbSelfTestAnlz {
    static let beats = (0..<16).map { BeatGridTags.Beat(number: $0 % 4 + 1, bpm100: 12_800, time: 50 + Double($0) * 60_000 / 128) }

    /// `.DAT`: PPTH · PVBR · PQTZ · PWAV · PWV2 · PCOB(핫, 빈) · PCOB(메모리, 빈)
    static func dat(path: String) -> Data {
        file([ppth(path), opaque("PVBR", bytes: 1_608), BeatGridTags.pqtz(beats), opaque("PWAV", bytes: 408), opaque("PWV2", bytes: 108),
              emptyPCOB(kind: 1), emptyPCOB(kind: 0)])
    }

    /// `.EXT`: PPTH · PWV3 · PCOB×2 · PCO2×2 · PQT2 · PWV5 · PWV4 · PSSI
    static func ext(path: String) -> Data {
        file([ppth(path), opaque("PWV3", bytes: 3_000), emptyPCOB(kind: 1), emptyPCOB(kind: 0), emptyPCO2(kind: 1), emptyPCO2(kind: 0),
              BeatGridTags.pqt2(beats, unknown: 0x1234), opaque("PWV5", bytes: 600), opaque("PWV4", bytes: 1_200), pssi()])
    }

    /// `.2EX`: PPTH · PWV7 · PWV6 · PWVC · PVDI
    static func twoEx(path: String) -> Data {
        file([ppth(path), opaque("PWV7", bytes: 900), opaque("PWV6", bytes: 360), opaque("PWVC", bytes: 8), pvdi()])
    }

    static func file(_ tags: [Data]) -> Data {
        let body = tags.reduce(into: Data()) { $0.append($1) }
        var out = Data("PMAI".utf8)
        out.append(be(28))
        out.append(be(UInt32(28 + body.count)))
        out.append(contentsOf: [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        out.append(body)
        return out
    }

    static func ppth(_ path: String) -> Data {
        var text = Data()
        for unit in (path + "\0").utf16 { text.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
        var out = Data("PPTH".utf8)
        out.append(be(16))
        out.append(be(UInt32(16 + text.count)))
        out.append(be(UInt32(text.count)))
        out.append(text)
        return out
    }

    /// 뜻 없는 값으로 채운 태그
    static func opaque(_ fourcc: String, bytes: Int) -> Data {
        var out = Data(fourcc.utf8)
        out.append(be(12))
        out.append(be(UInt32(12 + bytes)))
        out.append(Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        return out
    }

    static func emptyPCOB(kind: UInt32) -> Data {
        var out = Data("PCOB".utf8)
        for value in [0x18, 0x18, kind, 0, 0xFFFF_FFFF] as [UInt32] { out.append(be(value)) }
        return out
    }

    static func emptyPCO2(kind: UInt32) -> Data {
        var out = Data("PCO2".utf8)
        for value in [0x14, 0x14, kind, 0] as [UInt32] { out.append(be(value)) }
        return out
    }

    /// 평문 PSSI(항목 3개, mood 2)
    static func pssi() -> Data {
        let entries = 3
        var bytes = [UInt8](repeating: 0, count: 32 + 24 * entries)
        func put(_ value: Int, _ offset: Int, _ width: Int = 2) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (width - i - 1))) }
        }
        bytes.replaceSubrange(0..<4, with: "PSSI".utf8)
        put(32, 4, 4)
        put(bytes.count, 8, 4)
        put(24, 12, 4)
        put(entries, 0x10)
        put(2, 0x12)
        put(1 + 16 * entries, 0x1A)
        bytes[0x1E] = 3
        for i in 0..<entries {
            let p = 32 + 24 * i
            put(i + 1, p)
            put(1 + 16 * i, p + 2)
            put(i % 3 + 1, p + 4)
            for k in 6..<24 { bytes[p + k] = UInt8(truncatingIfNeeded: (i + 1) * 17 + k) }
        }
        return Data(bytes)
    }

    /// 로컬 PVDI: 머리 24바이트 · 본문
    static func pvdi() -> Data {
        let body = 90
        var out = Data("PVDI".utf8)
        out.append(be(0x18))
        out.append(be(UInt32(0x18 + body)))
        out.append(contentsOf: [0x00, 0x00, 0x04, 0x00, 0x56, 0x22, 0x00, 0x01])
        out.append(be(UInt32(body)))
        out.append(Data((0..<body).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }))
        return out
    }

    static func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
#endif
