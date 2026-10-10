import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

#if DEBUG
/// 확인 창에 늘 "예"라고 답하고 내용은 로그로 남긴다(개발용 자가 시험).
@MainActor
private struct AgreeingPrompter: HeadlessReflectionPrompter {
    var log: (String) -> Void
    func show(_ prompt: ReflectionPrompt) -> Bool {
        log("창: \(prompt.title)\n" + (prompt.text.components(separatedBy: "\n") + prompt.details).map { "    \($0)" }.joined(separator: "\n"))
        return prompt.confirm != nil
    }
}

extension DevSelfTests {
    /// 개발용: 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)와 사본 초안(`DJC_HOME`)으로 곡 넣기 → 되돌리기 → 다시 넣기 → 빼기 → 되돌리기를
    /// 앱 흐름(`ReflectionCoordinator`) 그대로 해 본다(`--track-selftest <음원,…>`).
    static func runTrackSelfTestIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--track-selftest"), args.indices.contains(i + 1) else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[곡 시험] \(text)\n".utf8)) }
        let env = ProcessInfo.processInfo.environment
        guard env["DJC_REKORDBOX_DIR"]?.isEmpty == false, env["DJC_HOME"]?.isEmpty == false else {
            log("사본 폴더(DJC_REKORDBOX_DIR·DJC_HOME)가 아니면 하지 않습니다"); exit(2)
        }
        let realShare = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/share").resolvingSymlinksInPath().path
        guard RekordboxShare.directory.resolvingSymlinksInPath().path != realShare else {
            log("분석 파일 폴더가 실제 rekordbox 폴더를 가리킵니다. 사본으로 바꾼 뒤 하세요"); exit(2)
        }
        let files = args[i + 1].split(separator: ",").map { URL(filePath: String($0)) }
        let coordinator = AppComposition.reflection(store: store, prompter: AgreeingPrompter(log: log))
        Task {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func loaded() -> Bool { if case .loaded = store.phase { !store.rows.isEmpty } else { false } }
            for _ in 0..<50 { if loaded() || store.isLoading { break }; await wait(0.1) }
            if !loaded(), !store.isLoading { await store.takeSnapshot() }
            for _ in 0..<600 { if loaded() { break }; await wait(0.1) }
            guard loaded() else { log("라이브러리를 읽지 못했습니다"); exit(1) }
            let before = store.rows.count
            @MainActor func rows(at paths: [String]) -> [TrackRow] {
                let wanted = Set(paths.map(\.precomposedStringWithCanonicalMapping))
                return store.rows.filter { wanted.contains($0.track.folderPath.precomposedStringWithCanonicalMapping) }
            }
            @MainActor func toast() -> String { "\(store.toast?.title ?? "-") / \(store.toast?.detail?.replacingOccurrences(of: "\n", with: " · ") ?? "")" }
            @MainActor func latestBackup() -> RekordboxWriter.Backup? { RekordboxWriter.backups(in: DJCPaths.rekordboxBackups).first(where: \.isWrite) }

            // 1. 추가 목록에 넣고 그리드 추정을 기다린다
            await store.staging.addFiles(files)
            while store.staging.gridJob != nil { await wait(0.3) }
            let paths = store.staging.staged.map(\.path)
            log("추가 목록 \(store.staging.staged.count)곡 · 그리드 " + store.staging.staged.map { "\($0.title.prefix(16)) \($0.bpm.map { String(format: "%.2f", $0) } ?? "-")" }.joined(separator: ", "))
            // 곡마다 큐 초안(메모리 큐·핫큐)을 만들어 둔다(넣을 때 함께 들어가는지)
            for track in store.staging.staged {
                var draft = CueDraft(trackUUID: track.uuid)
                draft.place(EditableCue(id: UUID(), kind: .memory, time: 0.2))
                draft.place(EditableCue(id: UUID(), kind: .hot(0), time: 0.6))
                try? CueDraftStore.save(draft)
            }

            // 2. 넣기
            await coordinator.addTracks(rows: store.staging.stagedRows)
            let added = rows(at: paths)
            log("넣기: 컬렉션 \(before) → \(store.rows.count)곡 · 알림 \(toast())")
            for row in added {
                let files = ["DAT", "EXT", "2EX"].compactMap { ext in
                    RekordboxShare.analysisURL(row.track.analysisDataPath).map { $0.deletingPathExtension().appendingPathExtension(ext) }
                }.filter { FileManager.default.fileExists(atPath: $0.path) }
                let artwork = [RekordboxShare.ArtworkSize.full, .medium, .small].compactMap { RekordboxShare.artworkURL(row.track.imagePath, size: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                log("  \(row.title.prefix(24)) · BPM \(row.track.bpm.map { String(format: "%.2f", $0) } ?? "-") · 분석 파일 \(files.count)개 · 아트워크 파일 \(artwork.count)개 · 오토게인 \(row.autoGain.map { String(format: "%+.1f dB", $0.gainDB) } ?? "-") · 큐 \(row.cues.count)개 · 반영 대기 \(store.pendingUUIDs.contains(row.track.uuid))")
            }
            log("추가 목록 남은 곡 \(store.staging.staged.count)")
            guard !added.isEmpty, let addBackup = latestBackup() else { log("넣은 곡이 없습니다"); exit(1) }
            let createdFiles = (addBackup.trackReport?.createdFiles ?? []).map { URL(filePath: $0, relativeTo: RekordboxShare.directory) }

            // 3. 되돌리기: 곡이 빠지고 분석 파일이 지워지고 추가 목록으로 돌아온다
            await coordinator.restore(addBackup)
            let leftFiles = createdFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count
            log("되돌리기: 컬렉션 \(store.rows.count)곡(처음 \(before)) · 남은 만든 파일(분석·아트워크) \(leftFiles)/\(createdFiles.count) · 추가 목록 \(store.staging.staged.count)곡 · 알림 \(toast())")

            // 4. 다시 넣고 빼기 → 되돌리기
            await coordinator.addTracks(rows: store.staging.stagedRows)
            let again = rows(at: paths)
            log("다시 넣기: \(again.count)곡 · 컬렉션 \(store.rows.count)")
            await coordinator.deleteTracks(rows: again)
            log("빼기: 컬렉션 \(store.rows.count)곡 · 남은 곡 \(rows(at: paths).count) · 알림 \(toast())")
            guard let deleteBackup = latestBackup() else { log("백업 없음"); exit(1) }
            await coordinator.restore(deleteBackup)
            let revived = rows(at: paths)
            let revivedFiles = revived.filter { row in
                RekordboxShare.analysisURL(row.track.analysisDataPath).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }.count
            let revivedArtwork = revived.filter { row in
                RekordboxShare.artworkURL(row.track.imagePath, size: .full).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }.count
            log("빼기 되돌리기: 되살아난 곡 \(revived.count) · 분석 파일 있는 곡 \(revivedFiles) · 아트워크 있는 곡 \(revivedArtwork) · 알림 \(toast())")

            // 4b. 동기화 상태 곡은 빼지 않고 이유를 알린다(#196). 합성 사본의 기존 곡은 동기화를 마친 상태(256)다.
            if let synced = store.rows.first(where: { !$0.isStaged && !$0.track.isStreaming && !paths.contains($0.track.folderPath) }) {
                let count = store.rows.count
                await coordinator.deleteTracks(rows: [synced])
                log("동기화 곡 빼기: 컬렉션 \(store.rows.count)곡(처음 \(count)) · 그 곡 남음 \(store.rows.contains { $0.id == synced.id }) · 알림 \(toast())")
            } else {
                log("동기화 곡 빼기: 시험할 기존 곡이 없습니다")
            }

            // 5. rekordbox가 바깥에서 곡을 지운 것처럼 하고 창으로 돌아온다: 새로 읽어 목록·선택·덱에서 빠지고 다시 추가할 수 있어야 한다
            store.selection = Set(revived.prefix(1).map(\.id))
            store.loadToDeck(revived.first)
            await wait(1.5)
            let outside = try? RekordboxTrackWriter.delete(contentIDs: revived.map(\.track.id), from: store.rekordboxDatabase, dryRun: false,
                                                           backups: FileManager.default.temporaryDirectory.appending(path: "djc-outside-\(UUID().uuidString)"))
            log("바깥에서 지움: \(outside?.deleted.filter(\.written).count ?? 0)곡 · 새로 읽기 전 목록에 남은 곡 \(rows(at: paths).count)")
            await store.refreshIfRekordboxChanged()
            log("창으로 돌아옴: 목록에 남은 곡 \(rows(at: paths).count) · 선택 \(store.selection.count) · 덱 \(store.deckTrackID == nil ? "비움" : "남음")")
            await store.staging.addFiles(files)
            log("다시 추가: 추가 목록 \(store.staging.staged.count)곡 · \(store.staging.stagingMessage?.text ?? "")")
            log("끝")
            exit(0)
        }
    }
}
#endif
