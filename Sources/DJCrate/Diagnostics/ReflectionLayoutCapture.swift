#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage

extension DevSelfTests {
    /// LayoutFixtureCapture가 만든 합성 라이브러리로 최소 창의 반영 UI를 확인한다.
    static func runReflectionLayoutIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let argument = args.first(where: { $0.hasPrefix("--reflection-layout=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task {
            for _ in 0..<100 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !store.rows.isEmpty, store.rows.allSatisfy({ $0.title.hasPrefix("레이아웃 시험 ") }),
                  let row = store.rows.first, let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
            NSApp.appearance = NSAppearance(named: argument.hasSuffix("dark") ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
            var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues, newID: { UUID() })
            draft.cues.append(EditableCue(id: UUID(), kind: .memory, time: 10, name: "레이아웃 시험"))
            try? CueDraftStore.save(draft)
            store.cueDraftChanged(draft)
            store.selection = [row.id]
            store.loadToDeck(row)
            let backup = DJCPaths.userData.appending(path: "synthetic-backup")
            store.lastWriteBackup = backup
            // 화면 배치를 언어별로 보려고 실제 알림처럼 번역되는 문구를 쓴다.
            let title = String(ui: "일부 곡을 썼습니다")
            let detail = String(ui: "합성 데이터의 화면 배치 시험입니다")
            store.resultHistory.record(WriteResult(kind: .warning, title: title, text: detail))
            store.toast = AppToast(kind: .warning, title: title, detail: detail, undoBackup: backup)
            if argument.contains("locked-") || argument.contains("reload-") {
                store.toast = nil
                store.setWriteLock(true)
                store.writeStage = argument.contains("reload-") ? .reloadingLibrary : WriteStage(String(ui: "rekordbox에 쓰는 중…"))
            }
            if let capture = args.first(where: { $0.hasPrefix("--reflection-capture=") }) {
                try? await Task.sleep(for: .milliseconds(500))
                let command = Process()
                command.executableURL = URL(filePath: "/usr/sbin/screencapture")
                command.arguments = ["-x", "-l", String(window.windowNumber), String(capture.dropFirst("--reflection-capture=".count))]
                try? command.run()
                command.waitUntilExit()
                exit(command.terminationStatus)
            }
        }
    }
}
#endif
