#if DEBUG
import AppKit
import DJCApplication
import DJCDomain

extension DevSelfTests {
    /// #108: 같은 합성 곡에서 버튼·숫자키로 저장된 핫큐를 불러 실제 오디오의 정지→재생을 확인한다.
    static func runPausedHotCueSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--paused-hotcue-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            func log(_ text: String) { FileHandle.standardError.write(Data("[정지 핫큐 시험] \(text)\n".utf8)) }
            @MainActor func capture(_ window: NSWindow, _ name: String) -> Bool {
                guard let arg = args.first(where: { $0.hasPrefix("--paused-hotcue-captures=") }) else { return true }
                let directory = String(arg.dropFirst("--paused-hotcue-captures=".count))
                let command = Process()
                command.executableURL = URL(filePath: "/usr/sbin/screencapture")
                command.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
                do { try command.run() } catch { return false }
                command.waitUntilExit()
                return command.terminationStatus == 0
            }
            for _ in 0..<150 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard let row = store.rows.first(where: { $0.title == "편집 화면 시험" }) else {
                log("합성 곡 없음"); exit(2)
            }
            store.selection = [row.id]
            store.loadToDeck(row)
            for _ in 0..<150 where deck.row?.id != row.id || deck.draft == nil || deck.waveform == nil || !deck.canPlay {
                await wait(0.1)
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
                  let content = window.contentView, let loopCue = deck.hotCue(slot: 1), deck.canPlay else {
                log("합성 덱 또는 창 없음"); exit(2)
            }
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            window.setContentSize(NSSize(width: 1440, height: 900))
            deck.volume = 0
            deck.setLoop(loopCue.id, beats: 4)
            for _ in 0..<600 where window !== NSApp.mainWindow { await wait(0.1) }
            guard window === NSApp.mainWindow else { log("덱 창을 활성화하지 못함"); exit(2) }
            await wait(1)
            var failures = 0
            for quantized in [false, true] {
                deck.playQuantize = quantized
                for keyboard in [false, true] {
                    for slot in [0, 1] {
                        let name = "q\(quantized ? 1 : 0)-\(keyboard ? "key" : "button")-\(slot)"
                        guard let cue = deck.hotCue(slot: slot) else { log("핫큐 없음"); exit(2) }
                        deck.stopPlayback()
                        deck.exitLoop()
                        deck.seek(10)
                        deck.selectedCueID = nil
                        window.makeFirstResponder(window)
                        await wait(0.3)
                        guard window === NSApp.mainWindow else { log("시험 중 덱 창 포커스를 잃음"); exit(2) }
                        let stopped = !deck.isPlaying && !deck.audio.isPlaying
                        log("입력 준비 \(name) · 주 창=\(window === NSApp.mainWindow) · 포커스=\(KeyRouter.focus(in: window))")
                        if !capture(window, "\(name)-before") { failures += 1 }
                        if keyboard {
                            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: String(slot + 1), charactersIgnoringModifiers: String(slot + 1),
                                    isARepeat: false, keyCode: slot == 0 ? 18 : 19) else { exit(2) }
                                NSApp.postEvent(event, atStart: false)
                                await wait(0.05)
                            }
                        } else {
                            guard let rect = SelfTestFrames.frames["hotCue.\(slot)"] else { log("패드 위치 없음"); exit(2) }
                            let y = content.isFlipped ? rect.midY : content.bounds.height - rect.midY
                            let point = content.convert(NSPoint(x: rect.midX, y: y), to: nil)
                            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { exit(2) }
                                NSApp.postEvent(event, atStart: false)
                                await wait(0.05)
                            }
                        }
                        await wait(0.15)
                        let first = deck.audio.position
                        await wait(0.25)
                        let second = deck.audio.position
                        let selected = deck.selectedCueID == cue.id
                        let playing = deck.isPlaying && deck.audio.isPlaying
                        let moved = first >= cue.time && first < cue.time + 1
                        let advanced = second > first + 0.1
                        let loop = slot == 0 ? !deck.isLooping : deck.engagedLoopID == cue.id
                        let ok = stopped && selected && playing && moved && advanced && loop
                        if !ok { failures += 1 }
                        log(String(format: "%@ · 정지=%@ · 선택=%@ · 재생=%@ · 오디오 %.3f→%.3f · 루프=%@ · %@",
                                   name, String(stopped), String(selected), String(playing), first, second, String(loop), ok ? "통과" : "실패"))
                        if !capture(window, "\(name)-after") { failures += 1 }
                    }
                }
            }
            deck.stopPlayback()
            log("완료: 8조건 · 실패 \(failures)건(합성 입력, 물리 키보드·트랙패드 확인 아님)")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
