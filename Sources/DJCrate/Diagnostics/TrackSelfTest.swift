import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

#if DEBUG
/// 확인 창에 늘 "예"라고 답하고 내용은 로그로 남긴다(개발용 자가 시험).
@MainActor
struct AgreeingPrompter: HeadlessReflectionPrompter {
    var log: (String) -> Void
    func show(_ prompt: ReflectionPrompt) -> Bool {
        log("창: \(prompt.title)\n" + (prompt.text.components(separatedBy: "\n") + prompt.details).map { "    \($0)" }.joined(separator: "\n"))
        return prompt.confirm != nil
    }
}

extension DevSelfTests {
    struct SelfTestMismatch: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func selfTestExitCode(passLine: String, log: (String) -> Void, verify: () async throws -> Void) async -> Int32 {
        do {
            try await verify()
            log(passLine)
            return 0
        } catch {
            log("실패 · \(error.localizedDescription)")
            return 1
        }
    }

    /// 사본 시험의 인자와 경로를 앱 조립·설정 이관 전에 확인한다.
    static func copySelfTestStartupRefusal(arguments: [String], environment: [String: String]) -> String? {
        let args = arguments.dropFirst()
        let retired: Set<String> = ["--audio-selftest", "--stale-cue-selftest", "--analysis-play-selftest",
                                    "--grid-selftest", "--key-selftest"]
        if let old = args.map(DiagnosticRun.optionName).first(where: retired.contains) {
            return "\(old) 옵션은 종료되었습니다. 합성 사본으로 --switch-selftest를 실행하세요"
        }
        let requested = args.filter { DiagnosticRun.copySelfTestOptions.contains(DiagnosticRun.optionName($0)) }
        guard let argument = requested.first else { return nil }
        let option = DiagnosticRun.optionName(argument)
        let trackTest = option == "--track-selftest"
        if trackTest {
            let paths = trackSelfTestPaths(argument)
            guard !paths.isEmpty, paths.allSatisfy({ (try? UsbScratchPath.check($0, as: .existingFile)) != nil }),
                  !args.contains(where: { DiagnosticRun.optionName($0) == "--db" }), environment["DJC_DB"] == nil else {
                return "곡 시험에는 --track-selftest=<임시 음원 경로,…> 형식을 쓰고 --db·DJC_DB를 빼세요"
            }
        } else if argument != option {
            return "\(option)에는 값을 붙이지 마세요"
        }
        if args.contains(where: { $0.hasPrefix("--db=") }) { return "사본을 열 때는 --db <경로> 형식을 쓰세요" }
        guard requested.count == 1,
              !args.contains(where: { ($0 != argument && DiagnosticRun.isDiagnosticArgument($0)) ||
                  ["--add-files", "--export-staged"].contains(DiagnosticRun.optionName($0)) }) else {
            return "사본 자가 테스트는 하나씩 실행하고 --add-files·--export-staged를 빼세요"
        }
        guard let home = environment["DJC_HOME"], let root = environment["DJC_REKORDBOX_DIR"],
              let homePath = try? UsbScratchPath.check(home, as: .existingDirectory),
              let rootPath = try? UsbScratchPath.check(root, as: .existingDirectory),
              !UsbScratchPath.allowedRoots().contains(homePath), !UsbScratchPath.allowedRoots().contains(rootPath),
              (try? UsbScratchPath.check(rootPath + "/master.db", as: .existingFile)) != nil,
              ["share", "share/PIONEER", "share/PIONEER/USBANLZ"].allSatisfy({
                  (try? UsbScratchPath.check(rootPath + "/" + $0, as: .existingDirectory)) != nil
              }) else {
            return "임시 DJC_HOME과 분석 파일을 실제 파일로 복사한 임시 DJC_REKORDBOX_DIR을 지정하세요"
        }
        let location = LibraryLocation.resolve(arguments: arguments, environment: environment)
        if location.opensExplicitCopy {
            guard let copy = location.explicitCopy, (try? UsbScratchPath.check(copy.path, as: .existingFile)) != nil else {
                return "--db·DJC_DB에는 임시 폴더에 있는 사본 DB를 지정하세요"
            }
        }
        let snapshots = location.snapshotDirectory.path
        var info = stat()
        if lstat(snapshots, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return "사본의 스냅샷 폴더를 실제 폴더로 두세요" }
        } else if errno != ENOENT {
            return "사본의 스냅샷 폴더를 확인할 수 없습니다"
        }
        return nil
    }

    private static func trackSelfTestPaths(_ argument: String) -> [String] {
        let prefix = "--track-selftest="
        guard argument.hasPrefix(prefix) else { return [] }
        return argument.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    static func loadSelfTestLibrary(_ store: LibraryStore) async -> Bool {
        if store.rows.isEmpty && !store.isLoading { await store.takeSnapshot(refreshITunes: false) }
        for _ in 0..<600 where store.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        return !store.rows.isEmpty && !store.isLoading
    }

    static func runTrackSelfTestIfRequested(store: LibraryStore) {
        let prefix = "--track-selftest="
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        guard let arg = args.first(where: { $0.hasPrefix(prefix) }) else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[곡 시험] \(text)\n".utf8)) }
        let paths = trackSelfTestPaths(arg)
        let coordinator = AppComposition.reflection(store: store, prompter: AgreeingPrompter(log: log))
        Task {
            guard await loadSelfTestLibrary(store) else { log("사본을 읽지 못했습니다"); exit(1) }
            let code = await selfTestExitCode(passLine: "곡 넣기·빼기 시험 통과", log: log) {
                try await runTrackSelfTest(files: paths.map { URL(filePath: $0) }, store: store, coordinator: coordinator, outsideGuard: .system, log: log)
            }
            exit(code)
        }
    }

    static func runTrackSelfTest(files: [URL], store: LibraryStore, coordinator: ReflectionCoordinator,
                                 outsideGuard: RekordboxWriteGuard, log: (String) -> Void) async throws {
        func check(_ ok: Bool, _ message: String) throws {
            log(message)
            if !ok { throw SelfTestMismatch(message) }
        }
        func paths(_ values: [String]) -> Set<String> {
            Set(values.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping })
        }
        let wanted = paths(files.map(\.path))
        let before = Set(store.rows.map(\.id))
        func added() -> [TrackRow] { store.rows.filter { !paths([$0.track.folderPath]).isDisjoint(with: wanted) } }
        func matches(_ rows: [TrackRow]) -> Bool {
            rows.count == wanted.count && paths(rows.map(\.track.folderPath)) == wanted && store.rows.count == before.count + wanted.count
        }
        func backup(for rows: [TrackRow], deleting: Bool, previous: Set<URL>) throws -> RekordboxWriteBackup {
            let ids = Set(rows.map(\.track.id))
            guard let backup = coordinator.session.writeBackups().first(where: { backup in
                guard !previous.contains(backup.url), let report = backup.trackReport, backup.isWrite else { return false }
                return Set((deleting ? report.deleted : report.added).filter(\.written).compactMap(\.contentID)) == ids
            }) else { throw SelfTestMismatch("이번 작업의 백업이 없습니다") }
            return backup
        }
        func mediaFiles(_ rows: [TrackRow]) throws -> [URL: Data] {
            var result: [URL: Data] = [:]
            for row in rows {
                guard let dat = RekordboxShare.analysisURL(row.track.analysisDataPath, root: store.shareRoot) else {
                    throw SelfTestMismatch("넣은 곡의 분석 경로가 없습니다")
                }
                let analysis = ["DAT", "EXT", "2EX"].map { dat.deletingPathExtension().appendingPathExtension($0) }
                let artwork = [RekordboxShare.ArtworkSize.full, .medium, .small].compactMap {
                    RekordboxShare.artworkURL(row.track.imagePath, size: $0, root: store.shareRoot)
                }
                for file in analysis + artwork { result[file] = try Data(contentsOf: file) }
            }
            return result
        }

        try check(!wanted.isEmpty && wanted.count == files.count && added().isEmpty && store.staging.staged.isEmpty, "추가할 새 음원 \(wanted.count)곡")
        await store.staging.addFiles(files)
        for _ in 0..<1200 where store.staging.gridJob != nil { try await Task.sleep(for: .milliseconds(100)) }
        let staged = store.staging.staged
        try check(store.staging.gridJob == nil && paths(staged.map(\.path)) == wanted, "추가 목록 \(staged.count)곡")
        let injected: [(kind: EditableCue.Kind, time: Double)] = [(.memory, 0.2), (.hot(0), 0.6)]
        let expected = RekordboxWriter.key(injected.map { EditableCue(id: UUID(), kind: $0.kind, time: $0.time) }, withSource: false)
        func checkCues(_ rows: [TrackRow], _ stage: String) throws {
            let matched = rows.allSatisfy { row in
                let reread = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues)
                return RekordboxWriter.key(reread.base, withSource: false) == expected
            }
            try check(matched, "\(stage) 큐 · \(rows.count)곡의 핫큐·메모리 큐 다시 읽기")
        }
        for track in staged {
            var draft = CueDraft(trackUUID: track.uuid)
            for cue in injected { draft.place(EditableCue(id: UUID(), kind: cue.kind, time: cue.time)) }
            try CueDraftStore.save(draft, directory: DraftLocations(home: store.draftFolder).cue)
        }

        let beforeAdd = Set(coordinator.session.writeBackups().map(\.url))
        await coordinator.addTracks(rows: store.staging.stagedRows)
        let first = added()
        try check(matches(first) && store.staging.staged.isEmpty, "넣기 · 컬렉션 \(before.count) → \(store.rows.count)곡")
        try checkCues(first, "넣기")
        let addBackup = try backup(for: first, deleting: false, previous: beforeAdd)
        let firstFiles = try mediaFiles(first)
        let reported = (addBackup.trackReport?.createdFiles ?? []).map { store.shareRoot.appending(path: $0) }
        await coordinator.restore(addBackup)
        let left = Set(Array(firstFiles.keys) + reported).filter { FileManager.default.fileExists(atPath: $0.path) }
        try check(Set(store.rows.map(\.id)) == before && left.isEmpty && paths(store.staging.staged.map(\.path)) == wanted,
                  "넣기 되돌림 · 컬렉션 \(store.rows.count)곡 · 만든 파일 중 남은 파일 \(left.count)개")

        await coordinator.addTracks(rows: store.staging.stagedRows)
        let again = added()
        try check(matches(again), "다시 넣기 · \(again.count)곡")
        try checkCues(again, "다시 넣기")
        let originals = try mediaFiles(again)
        let beforeDelete = Set(coordinator.session.writeBackups().map(\.url))
        await coordinator.deleteTracks(rows: again)
        try check(Set(store.rows.map(\.id)) == before && originals.keys.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                  "빼기 · 컬렉션 \(store.rows.count)곡 · 파일 \(originals.count)개")
        let deleteBackup = try backup(for: again, deleting: true, previous: beforeDelete)
        await coordinator.restore(deleteBackup)
        let revived = added()
        let restoredFiles = try mediaFiles(revived)
        try check(matches(revived) && Set(revived.map(\.id)) == Set(again.map(\.id)) && restoredFiles == originals,
                  "빼기 되돌림 · \(revived.count)곡 · 분석·그림 \(restoredFiles.count)개")
        try checkCues(revived, "빼기 되돌림")

        if let synced = store.rows.first(where: { before.contains($0.id) && $0.track.dataStatus == 256 && !$0.track.isStreaming }) {
            await coordinator.deleteTracks(rows: [synced])
            try check(store.rowsByID[synced.id] != nil && matches(revived), "동기화 곡 빼기 거부")
        }
        let selected = revived[0]
        store.selection = [selected.id]
        store.loadToDeck(selected)
        try check(store.deckTrackID == selected.id && store.selection == [selected.id], "바깥 삭제 직전 선택·덱 확인")
        // 스냅샷 파일 이름의 시각은 초 단위다. 바깥 삭제가 변경 감지의 1초 여유 뒤에 오게 한다.
        try await Task.sleep(for: .milliseconds(1100))
        let outside = try RekordboxTrackWriter.delete(contentIDs: revived.map(\.track.id), from: store.rekordboxDatabase,
            shareRoot: store.shareRoot, dryRun: false, backups: store.backupDirectory.appending(path: "outside"), guard: outsideGuard)
        try check(outside.deleted.filter(\.written).count == wanted.count, "바깥 삭제 · \(outside.deleted.filter(\.written).count)곡")
        await store.refreshIfRekordboxChanged()
        try check(Set(store.rows.map(\.id)) == before && added().isEmpty && store.selection.isEmpty && store.deckTrackID == nil,
                  "다시 읽기 · 남은 곡 \(added().count) · 선택 \(store.selection.count) · 덱 \(store.deckTrackID ?? "비움")")
        await store.staging.addFiles(files)
        try check(paths(store.staging.staged.map(\.path)) == wanted, "다시 추가 · \(store.staging.staged.count)곡")
    }
}
#endif
