#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension DevSelfTests {
    /// 합성 목록의 막힘 → 비교 → 초안 재적용 → 기존 쓰기 미리 보기를 활성화 없이 확인한다.
    static func runPlaylistRecoveryIfRequested(store: LibraryStore, reflection: ReflectionCoordinator) {
        let args = ProcessInfo.processInfo.arguments, environment = ProcessInfo.processInfo.environment
        guard args.contains("--playlist-recovery-selftest") else { return }
        Task {
            do {
                guard let home = environment["DJC_HOME"], let root = environment["DJC_REKORDBOX_DIR"],
                      URL(filePath: home).path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      URL(filePath: root).path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      let output = args.first(where: { $0.hasPrefix("--playlist-recovery-capture=") }) else {
                    throw DJCError.writeRefused("합성 사본·임시 데이터·캡처 폴더를 지정하세요")
                }
                for _ in 0..<100 {
                    if case .loaded = store.phase { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard case .loaded = store.phase, store.rows.allSatisfy({ $0.title.hasPrefix("합성 곡 ") }),
                      store.playlists.playlistDraft.steps.count == 2, store.playlists.blockedPlaylistEditCount == 2,
                      let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
                    throw DJCError.writeRefused("합성 목록의 막힌 편집을 확인하지 못했습니다")
                }
                let directory = URL(filePath: String(output.dropFirst("--playlist-recovery-capture=".count)))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSApp.appearance = NSAppearance(named: .aqua)
                window.setContentSize(NSSize(width: 1100, height: 700))
                store.sidebar = .playlist("179")
                try await Task.sleep(for: .milliseconds(300))
                guard !NSApp.isActive else { throw DJCError.writeRefused("앱이 활성화되어 캡처를 중단했습니다") }
                let before = args.contains("--playlist-recovery-stage=before")
                try capturePlaylistWindow(window, at: directory.appending(path: before ? "before.jpg" : "after-blocked.jpg"))
                if before { exit(0) }
                // 복구 시트(#232)의 한 줄을 화면 없이 읽고 고르고 저장한다.
                let sheet = RecoverySheetModel(host: store, requests: [.playlist("179")])
                await sheet.load()
                guard let line = sheet.lines.first, line.phase == .ready, line.canKeep else {
                    throw DJCError.writeRefused("합성 목록을 비교하지 못했습니다")
                }
                sheet.choose(.keep, for: line)
                guard await sheet.save() else { throw DJCError.writeRefused("비교 뒤 초안을 저장하지 못했습니다") }
                let prompter = PlaylistCapturePrompter(directory: directory)
                guard store.playlists.blockedPlaylistEditCount == 0, store.playlists.playlistItem("179")?.name == "합성 내 목록",
                      store.playlists.playlistItem("179")?.trackIDs == ["1", "2", "3"] else {
                    throw DJCError.writeRefused("비교 뒤 초안을 다시 적용하지 못했습니다")
                }
                let saved = PlaylistDraftStore.load()
                guard saved == store.playlists.playlistDraft else { throw DJCError.writeRefused("다시 적용한 초안을 저장하지 못했습니다") }
                try await Task.sleep(for: .milliseconds(700))
                try capturePlaylistWindow(window, at: directory.appending(path: "after-reapplied.jpg"))
                store.setWriteLock(true)
                defer { store.setWriteLock(false) }
                let preview = try await reflection.session.previewWrite(rows: [], playlists: true)
                guard preview.report.playlistWritten.count == 2, preview.report.playlistBlocked.isEmpty else {
                    throw DJCError.writeRefused("다시 적용한 편집의 쓰기 미리 보기가 막혔습니다")
                }
                _ = prompter.show(ReflectionPrompts.confirmation(preview.report))
                guard prompter.captureSucceeded, !NSApp.isActive else { throw DJCError.writeRefused("비교·미리 보기 창을 캡처하지 못했습니다") }
                FileHandle.standardError.write(Data("재생 목록 복구 시험 통과: 막힘 2 → 다시 적용 2 → 미리 보기 2, 실제 쓰기 0\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("재생 목록 복구 시험 실패: \(DJCError.reason(of: error))\n".utf8))
                exit(2)
            }
        }
    }

    fileprivate static func capturePlaylistWindow(_ window: NSWindow, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DJCError.writeRefused("창을 캡처하지 못했습니다") }
    }
}

@MainActor
private final class PlaylistCapturePrompter: HeadlessReflectionPrompter {
    let directory: URL
    var filename = "after-preview.jpg"
    var captureSucceeded = true
    init(directory: URL) { self.directory = directory }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        alert.window.orderFront(nil)
        // 앱 안의 실제 알림 레이아웃이 그려진 뒤 이 프로세스의 창만 캡처한다.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        do { try DevSelfTests.capturePlaylistWindow(alert.window, at: directory.appending(path: filename)) }
        catch { captureSucceeded = false }
        alert.window.orderOut(nil)
        return .cancel
    }
    func show(_ prompt: ReflectionPrompt) -> Bool { choose(prompt) == .confirm }
}
#endif
