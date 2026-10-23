#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage

extension DevSelfTests {
    /// LayoutFixtureCapture가 만든 합성 라이브러리로 최소 창의 반영 UI를 확인한다.
    /// 값에 `activity-`가 있으면 합성 알림 몇 건을 활동 기록에 남기고 활동 기록 창을 연다(#296).
    /// 상태 줄 장면(#298)은 결과 알림 대신 아래를 보인다. 팝오버는 따로 된 창이라 `<캡처 이름>-popover.png`로도 찍는다.
    /// - `status-`: 읽지 않은 알림이 없는 상태 줄
    /// - `unread-`: 읽지 않은 알림 3건(경고·실패·띄우지 못한 USB 알림)이 있는 상태 줄
    /// - `popover-`: 그 3건을 둔 채 맨 위 경고를 펼친 활동 팝오버
    /// - `open-`: [열기]가 붙은 경고 알림(결과 보기 없음)
    static func runReflectionLayoutIfRequested(store: LibraryStore, libraryWindow: LibraryWindowModel, statusBar: StatusBarModel) {
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
            if argument.contains("activity-") {
                // 같은 안내 두 번(합친 횟수), 성공 안내, 실패 결과를 앞에 둔다. 경고 알림은 아래에서 맨 위 항목이 된다.
                for _ in 0..<2 { store.showToast(.notice(String(ui: "rekordbox가 켜져 있어 쓰지 않았습니다"), ReflectionPrompts.quitRekordboxText)) }
                store.showToast(AppToast(title: String(ui: "현재 rekordbox 내용을 불러왔습니다")))
                store.activityLog.record(WriteResult(kind: .failure, title: String(ui: "rekordbox에 쓰지 않았습니다"), text: detail))
            }
            let statusScene = ["status-", "unread-", "popover-", "open-"].first(where: argument.contains)
            if let statusScene {
                if statusScene != "status-" {
                    store.activityLog.record(AppToast(title: String(ui: "현재 rekordbox 내용을 불러왔습니다")))
                    store.activityLog.record(WriteResult(kind: .failure, title: String(ui: "rekordbox에 쓰지 않았습니다"), text: detail))
                    store.activityLog.record(AppToast.notice(String(ui: "USB에서 재생 기록 \(1)개를 가져왔습니다"), "LAYOUT-USB", kind: .success, isUsb: true),
                                             shown: false)
                }
                let quit = AppToast.notice(String(ui: "rekordbox가 켜져 있어 쓰지 않았습니다"), ReflectionPrompts.quitRekordboxText)
                if statusScene == "open-" {
                    store.showToast(quit)
                } else if statusScene != "status-" {
                    let warning = store.activityLog.record(quit)
                    if statusScene == "popover-" {
                        NSApp.activate()
                        window.makeKeyAndOrderFront(nil)
                        statusBar.open(warning)
                    }
                }
            } else {
                store.showToast(AppToast(kind: .warning, title: title, detail: detail, undoBackup: backup),
                                for: WriteResult(kind: .warning, title: title, text: detail, backups: [backup]))
            }
            if argument.contains("activity-") { libraryWindow.showActivityLog(selecting: store.toast?.activityID) }
            if argument.contains("locked-") || argument.contains("reload-") {
                store.dismissToast()
                store.setWriteLock(true)
                store.writeStage = argument.contains("reload-") ? .reloadingLibrary : WriteStage(String(ui: "rekordbox에 쓰는 중…"))
            }
            if let capture = args.first(where: { $0.hasPrefix("--reflection-capture=") }) {
                try? await Task.sleep(for: .milliseconds(500))
                let command = Process()
                command.executableURL = URL(filePath: "/usr/sbin/screencapture")
                // 활동 기록은 시트(따로 된 창)라 그 창을 찍는다
                command.arguments = ["-x", "-l", String((window.attachedSheet ?? window).windowNumber), String(capture.dropFirst("--reflection-capture=".count))]
                try? command.run()
                command.waitUntilExit()
                // 활동 팝오버는 따로 된 창이다
                let popover = NSApp.windows.first { $0.isVisible && $0 !== window && String(describing: type(of: $0)).contains("Popover") }
                if let popover, command.terminationStatus == 0 {
                    let path = String(capture.dropFirst("--reflection-capture=".count))
                    let shot = Process()
                    shot.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    shot.arguments = ["-x", "-l", String(popover.windowNumber), (path as NSString).deletingPathExtension + "-popover.png"]
                    try? shot.run()
                    shot.waitUntilExit()
                    exit(shot.terminationStatus)
                }
                exit(command.terminationStatus)
            }
        }
    }
}
#endif
