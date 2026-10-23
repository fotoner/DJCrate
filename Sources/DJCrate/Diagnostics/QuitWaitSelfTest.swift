#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

/// 쓰는 중 앱 종료(#300) 자가 테스트(`--quit-wait-selftest`). 합성 사본(`DJC_REKORDBOX_DIR`)과 임시 `DJC_HOME`에서만 돈다.
/// 쓰기 관문을 몇 초 붙잡아 "rekordbox에 쓰는 중…" 단계를 길게 만든 뒤, 앱의 실제 종료 입구(`NSApp.terminate`)로 종료를 요청한다.
/// 1. [종료 취소]: 종료를 요청(이벤트 처리 자리, ⌘Q와 같다) → 기다림 카드 → 카드의 [종료 취소] 단추 자리에 마우스 이벤트를 넣는다 → 종료만 취소되고 쓰기는 끝까지 간다
/// 2. 종료를 메인 큐 블록 안에서 요청(`terminateLater`로 미루면 멈추는 자리) → 한 번 더 요청 → 종료만 취소된다
/// 3. 종료를 요청하고 그대로 둔다 → 쓰기가 끝나면 앱이 스스로 종료 코드 0으로 끝난다(`willTerminate` 줄에 그때 쓰기 상태를 남긴다)
/// `--quit-wait-poweroff`를 함께 주면 쓰는 도중에 Mac을 끄는 중이라고 알린 채(`isPoweringOff`) 같은 순서를 한다.
/// 이때는 종료를 `terminateLater`로 미루고 `reply`로 답한다(요청은 모두 이벤트 처리 자리에서 한다).
/// `--quit-wait-capture=<폴더>`를 주면 기다리는 동안의 창을 `waiting-card.jpg`로 남긴다. 결과는 표준 오류의 "[종료 대기 시험]" 줄이다.
@MainActor
enum QuitWaitSelfTest {
    private static let holdSeconds = 4.0

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--quit-wait-selftest") }

    static func runIfRequested(store: LibraryStore) {
        guard isRequested else { return }
        guard guardsPass() else { exit(2) }
        let capture = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--quit-wait-capture=") }
            .map { String($0.dropFirst("--quit-wait-capture=".count)) }
        Task {
            var failures = 0
            @MainActor func check(_ ok: Bool, _ text: String) {
                if !ok { failures += 1 }
                log("\(ok ? "통과" : "실패"): \(text)")
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func until(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 20) where !condition() { await wait(0.05) }
                return condition()
            }
            @MainActor func loaded() -> Bool { if case .loaded = store.phase { !store.rows.isEmpty } else { false } }
            for _ in 0..<50 { if loaded() || store.isLoading { break }; await wait(0.1) }
            if !loaded(), !store.isLoading { await store.takeSnapshot() }
            for _ in 0..<600 { if loaded() { break }; await wait(0.1) }
            guard loaded() else { log("라이브러리를 읽지 못했습니다"); exit(1) }
            guard let rated = store.rows.first(where: { !$0.isStaged && !$0.track.isStreaming && TrackListTagEditing.unavailableReason($0, key: .rating) == nil }) else {
                log("평점을 쓸 수 있는 곡이 없습니다"); exit(1)
            }
            // 쓰기 관문을 붙잡아 쓰는 단계를 길게 만든다: 붙잡는 동안은 아직 아무것도 쓰지 않았고, 붙잡은 뒤 실제 쓰기를 한다
            var gate = RekordboxWriteGate.live()
            let live = gate.write, hold = holdSeconds
            gate.write = { batch, inputs, target, dryRun in
                if !dryRun { Thread.sleep(forTimeInterval: hold) }
                return try live(batch, inputs, target, dryRun)
            }
            let coordinator = AppComposition.reflection(store: store, gate: gate, prompter: AutoConfirmPrompter())
            let powerOff = ProcessInfo.processInfo.arguments.contains("--quit-wait-poweroff")
            var rating = rated.track.rating
            @MainActor func startWriteOfNewRating() {
                rating = rating == 4 ? 5 : 4
                // 앞 쓰기 뒤 다시 읽은 최신 줄에 초안을 만든다(옛 줄이면 기준값이 달라 막힌 초안이 된다)
                store.tags.setTag(.rating, "\(rating)", rows: [store.rowsByUUID[rated.track.uuid] ?? rated])
                coordinator.startWrite(rows: store.rows, playlists: false)
            }
            /// 쓰는 도중에 Mac이 꺼지는 중이라고 알린다(`--quit-wait-poweroff`). 쓰기를 시작한 뒤에만 알려야 시작을 거절하지 않는다
            @MainActor func arm() { if powerOff { store.isPoweringOff = true } }
            @MainActor func disarm() { store.isPoweringOff = false }
            @MainActor func reachWritingStage() async -> Bool {
                let reached = await until(60) { store.quitBlocked && store.writeStage?.phase == .writing }
                log("쓰는 단계 도달=\(reached) · 단계=\(store.writeStage?.text ?? "-") · 잠금=\(store.quitBlocked)")
                return reached
            }
            @MainActor func finishWrite() async -> Bool {
                await until(60) { !store.quitBlocked && store.writeTask == nil }
            }
            @MainActor func elapsed() -> Int { store.quitWait.current?.elapsedSeconds(at: Date()) ?? -1 }

            // 1. [종료 취소]
            startWriteOfNewRating()
            check(await reachWritingStage(), "1. 쓰는 단계(끊지 않는 단계)에 들어섰다")
            arm()
            requestQuit()
            check(await until(5) { store.quitWait.isWaiting }, "1. 종료 요청 → 기다림 시작(앱은 끝나지 않았다)")
            check(store.quitBlocked, "1. 기다리는 동안 쓰기는 계속된다")
            await wait(1.2)
            check(elapsed() >= 1, "1. 지난 시간이 흐른다(\(elapsed())초)")
            if let capture { capturePanel(capture, "waiting-card.jpg") }
            let clicked = await clickCancelQuit()
            check(await until(3) { !store.quitWait.isWaiting }, "1. [종료 취소] 단추 클릭 이벤트가 종료 기다림을 취소했다(이벤트 \(clicked ? "보냄" : "못 보냄"))")
            if store.quitWait.isWaiting { store.quitWait.cancel() }
            check(await finishWrite(), "1. 종료만 취소됐고 쓰기는 끝까지 갔다")
            disarm()
            check(store.lastError == nil && store.toast?.kind != .failure, "1. 쓰기 결과가 실패가 아니다")

            // 2. ⌘Q를 한 번 더
            startWriteOfNewRating()
            check(await reachWritingStage(), "2. 쓰는 단계에 들어섰다")
            arm()
            requestQuit(inEventLoop: powerOff)
            check(await until(5) { store.quitWait.isWaiting }, "2. 종료 요청 → 기다림 시작")
            await wait(0.5)
            if powerOff {
                // 종료를 `terminateLater`로 미룬 동안 온 `terminate:`는 AppKit이 델리게이트에 넘기지 않고 쥐고 있다가, 미룬 종료에 취소로 답하면 다시 시작한다(확인).
                // 그래서 이 방식에서 빠져나가는 길은 [종료 취소] 단추 하나다. 두 번째 요청은 보내지 않는다.
                store.quitWait.cancel()
                check(await until(3) { !store.quitWait.isWaiting }, "2. [종료 취소]로 종료만 취소됐다")
            } else {
                requestQuit(inEventLoop: false)
                check(await until(3) { !store.quitWait.isWaiting }, "2. 종료를 한 번 더 요청하면 종료만 취소된다")
            }
            check(store.quitBlocked, "2. 쓰기는 계속된다")
            check(await finishWrite(), "2. 쓰기가 끝까지 갔다")
            disarm()

            // 3. 끝나면 스스로 종료
            startWriteOfNewRating()
            check(await reachWritingStage(), "3. 쓰는 단계에 들어섰다")
            let expectedRating = rating
            _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated {
                    log("종료 직전: 쓰기 잠금=\(store.quitBlocked) · 단계=\(store.writeStage?.text ?? "-") · 남은 평점 초안=\(store.tagDrafts[rated.track.uuid] != nil) · 쓴 평점=\(expectedRating)")
                }
            }
            check(failures == 0, "3. 앞 단계가 모두 통과했다(\(failures)건 실패)")
            arm()
            log("3. 종료를 요청하고(\(powerOff ? "Mac을 끄는 중: 종료를 미루고 reply로 답한다" : "기본: 취소로 답한 뒤 쓰기가 끝나면 앱이 다시 요청한다")) 쓰기가 끝나기를 기다린다(붙잡는 시간 \(Int(holdSeconds))초) · 쓸 평점=\(expectedRating)")
            requestQuit()
            check(await until(5) { store.quitWait.isWaiting }, "3. 종료 요청 → 기다림 시작")
            // 앱이 스스로 끝나면 이 아래는 돌지 않는다. 끝나지 않으면 실패로 끝낸다.
            await wait(60)
            log("실패: 쓰기가 끝났는데도 앱이 종료되지 않았다")
            exit(1)
        }
    }

    /// 종료를 요청한다. `inEventLoop`면 ⌘Q처럼 이벤트 처리(런루프 타이머) 자리에서 `terminate:`를 부른다. 종료를 미루면 AppKit은 그 자리에서 답을 기다리며 이벤트 순환을 안쪽에서 돈다.
    /// 아니면 메인 큐 블록 안에서 부른다(메인 액터 작업이나 업데이트 도구의 완료 처리가 이런 자리다): 거기서 종료를 미루면 안쪽 순환이 메인 큐를 처리하지 못해 멈춘다.
    /// 자가 테스트의 작업(Task)도 메인 큐 블록이라 직접 부르지 않는다.
    private static func requestQuit(inEventLoop: Bool = true) {
        if inEventLoop {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func log(_ text: String) {
        let stamp = String(format: "%.2f", ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write(Data("[종료 대기 시험] \(stamp) \(text)\n".utf8))
    }

    /// 사본·임시 폴더가 아니면 하지 않는다(SAFE-7·SAFE-9)
    private static func guardsPass() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let rekordbox = env["DJC_REKORDBOX_DIR"], let home = env["DJC_HOME"], !rekordbox.isEmpty, !home.isEmpty else {
            log("사본 폴더(DJC_REKORDBOX_DIR·DJC_HOME)가 아니면 하지 않습니다"); return false
        }
        let temp = [NSTemporaryDirectory(), "/tmp/", "/private/tmp/", "/private/var/folders/"]
            .map { URL(filePath: $0).resolvingSymlinksInPath().path }
        for path in [rekordbox, home] {
            let resolved = URL(filePath: path).resolvingSymlinksInPath().path
            guard temp.contains(where: { resolved.hasPrefix($0) }) else {
                log("임시 폴더 밖입니다: \(resolved)"); return false
            }
        }
        let realShare = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/share/PIONEER/USBANLZ")
            .resolvingSymlinksInPath().path
        guard RekordboxShare.directory.appending(path: "PIONEER/USBANLZ").resolvingSymlinksInPath().path != realShare else {
            log("분석 파일 폴더가 실제 rekordbox 폴더를 가리킵니다. 사본으로 바꾼 뒤 하세요"); return false
        }
        return true
    }

    private static func capturePanel(_ directory: String, _ name: String) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try UsbDragCapture.captureWindow(window, to: directory + "/" + name)
            log("캡처: \(directory)/\(name)")
        } catch {
            log("캡처하지 못했습니다: \(error)")
        }
    }

    /// [종료 취소] 단추 자리에 마우스 누름·뗌 이벤트를 앱의 이벤트 큐로 넣는다(물리 입력이 아니다). 종료를 기다리는 동안의 이벤트 처리가 막히지 않는지도 본다.
    private static func clickCancelQuit() async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), let content = window.contentView,
              let rect = SelfTestFrames.frames["quit-wait.cancel"] else { return false }
        let y = content.isFlipped ? rect.midY : content.bounds.height - rect.midY
        let point = content.convert(NSPoint(x: rect.midX, y: y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { return false }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(60))
        }
        return true
    }

    /// 확인 창을 띄우지 않고 늘 확인한다
    private final class AutoConfirmPrompter: HeadlessReflectionPrompter {
        func show(_ prompt: ReflectionPrompt) -> Bool { true }
    }
}
#endif
