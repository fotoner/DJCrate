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
    /// 쓰기 상태 칩 장면(#324)은 알림 없이 상태 줄만 보인다. 칩·Dock 배지 값은 표준 오류에 `[쓰기 상태]` 줄로 남긴다.
    /// - `idle-`: 쓰기 대기 없음(큐 초안을 만들지 않는다)
    /// - `plonly-`: 재생 목록 편집만 있는 상태(「재생 목록 편집 1건」)
    /// - `busy-`: 쓰는 중(쓰기 잠금을 걸고 1초를 넘겨 기다린 뒤 찍는다)
    /// - `chip-`: 곡 초안 1곡과 마지막 쓰기가 있는 채 쓰기 상태 팝오버를 연 모습(팝오버는 `<캡처 이름>-popover.png`)
    /// 곡 초안이 있는 장면(위 `status-` 등)의 칩은 「쓰기 대기 1건」이다.
    /// rekordbox 켜짐·꺼짐 장면(#326)은 곡 초안 1곡이 있는 채 감지 판정을 합성으로 넣는다(감지 서비스를 멈추고 값만 넣는다). 확인 줄은 같은 `[쓰기 상태]`다.
    /// - `run-on-`: rekordbox가 켜져 있다(「rekordbox가 켜져 있습니다 · 쓰기 대기 1건」)
    /// - `run-agent-`: rekordboxAgent만 켜져 있다
    /// - `run-stopping-`: 켜짐에서 꺼짐으로 바뀐 직후(확인 시간 3초 안, 「rekordbox가 끝나는 중…」)
    /// - `run-off-`: 확인 시간 뒤에도 꺼져 있어 [지금 쓰기]가 강조된 모습(전이 뒤 약 3초 기다린다)
    /// 켜진 채 종료 시트(#326)는 아래 장면이 실제 판정(`AppQuitPolicy.confirmation`)으로 시트를 주 창에 띄워 찍는다(시트 창을 찍는다).
    /// - `quit-on-`: rekordbox가 켜져 있고 쓰기 대기 1건
    /// - `quit-agent-`: rekordboxAgent만 켜져 있고 쓰기 대기 1건
    static func runReflectionLayoutIfRequested(store: LibraryStore, libraryWindow: LibraryWindowModel, statusBar: StatusBarModel,
                                               rekordboxRun: RekordboxRunModel) {
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
            let runScene = ["run-on-", "run-agent-", "run-stopping-", "run-off-", "quit-on-", "quit-agent-"].first(where: argument.contains)
            let writeScene = ["idle-", "plonly-", "busy-", "chip-"].first(where: argument.contains) ?? runScene
            if writeScene != "idle-", writeScene != "plonly-" {
                var draft = CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues, newID: { UUID() })
                draft.cues.append(EditableCue(id: UUID(), kind: .memory, time: 10, name: "레이아웃 시험"))
                try? CueDraftStore.save(draft)
                store.cueDraftChanged(draft)
            }
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
            // 쓰기 상태 장면은 알림 없는 상태 줄(`status-`)과 같은 바탕이다
            let statusScene = writeScene != nil ? "status-" : ["status-", "unread-", "popover-", "open-"].first(where: argument.contains)
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
            if let writeScene {
                if writeScene == "plonly-" {
                    var playlists = PlaylistDraft()
                    try? playlists.append(.create(key: "layout", name: "LAYOUT", isFolder: false, parent: PlaylistRef(PlaylistLayout.root)),
                                          rekordbox: PlaylistLayout())
                    // 메모리에만 두면 1초마다 하는 바깥 초안 확인이 빈 디스크 초안으로 되돌린다. 저장하는 입구로 넣는다
                    store.playlists.setPlaylistDraft(playlists, actionName: "LAYOUT")
                }
                if writeScene == "chip-" {
                    store.activityLog.record(WriteResult(kind: .success, title: title, text: detail, backups: [backup]))
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    statusBar.write?.isPresented = true
                }
                if writeScene == "busy-" {
                    store.setWriteLock(true)
                    // 쓰는 중 칩은 쓰기가 1초를 넘길 때만 보인다
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                // 감지 판정은 합성으로 넣는다. 끝나는 중·꺼짐 강조는 켜짐에서 꺼짐으로 바뀌는 전이를 만들어야 한다
                var reason: ReflectionChip.Reason?
                if let runScene {
                    rekordboxRun.inject(runScene == "quit-agent-" || runScene == "run-agent-" ? .agentOnly : .running)
                    reason = runScene.hasSuffix("agent-") ? .agentRunning : .rekordboxRunning
                    if runScene == "run-stopping-" || runScene == "run-off-" {
                        for _ in 0..<30 where statusBar.write?.chip.reason != .rekordboxRunning { try? await Task.sleep(for: .milliseconds(100)) }
                        rekordboxRun.inject(.stopped)
                        reason = runScene == "run-off-" ? .rekordboxStopped : .rekordboxStopping
                    }
                }
                // 시작 직후 메인 스레드가 바쁜 동안은 칩이 따라오지 못한다. 값이 맞을 때까지(최대 6초, 꺼짐 강조는 확인 시간 3초를 기다린다) 기다린 뒤 읽는다
                let expected = writeScene == "idle-" ? ReflectionChip.clean : writeScene == "plonly-" ? .pending(items: 0, playlistEdits: 1)
                    : writeScene == "busy-" ? .writing : .pending(items: 1, playlistEdits: 0, reason: reason)
                for _ in 0..<60 where statusBar.write?.chip != expected { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
                if runScene?.hasPrefix("quit-") == true {
                    // 켜진 채 종료 시트: 실제 판정이 정한 내용을 주 창에 시트로 띄운다
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    if let sheet = AppQuitPolicy.confirmation(for: store.writeActivity, cause: .user, run: runScene == "quit-agent-" ? .agentOnly : .running,
                                                              pending: store.pendingWriteSummary) {
                        QuitConfirmationAlert.present(sheet) { _ in }
                        FileHandle.standardError.write(Data("[종료 시트] \(sheet.title) | \(sheet.message)\n".utf8))
                    } else {
                        FileHandle.standardError.write(Data("[종료 시트] 판정이 시트를 띄우지 않았습니다\n".utf8))
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                let dock = NSApplication.shared.dockTile.badgeLabel ?? "없음"
                let write = statusBar.write
                FileHandle.standardError.write(Data("[쓰기 상태] 칩 \(write?.chip.title ?? "-") · 단추 \(write?.writeButtonTitle ?? "-")\(write?.emphasizesWrite == true ? "(강조)" : "") · Dock 배지 \(dock) · 보조 글 \(write?.lastWriteText ?? "없음")\n".utf8))
            }
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
