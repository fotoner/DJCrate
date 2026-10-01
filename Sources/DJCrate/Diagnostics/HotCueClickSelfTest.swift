#if DEBUG
import AppKit
import DJCDomain

/// 합성 입력이 실제 파형 모니터에 도착하고, 관성 이벤트를 삼켰는지 확인한다.
@MainActor
enum HotCueScrollTrace {
    static var enabled = false
    static var scrubEvents = 0
    static var momentumEvents = 0
    static var escapedMomentumEvents = 0
    static var dragChanges: [String: Int] = [:]
    static var dragEnds: [String: Int] = [:]
    static var buttonActions = 0
    static var buttonDowns = 0
    static var buttonUps = 0

    static func recordDrag(wave: String, ended: Bool) {
        guard enabled else { return }
        if ended { dragEnds[wave, default: 0] += 1 } else { dragChanges[wave, default: 0] += 1 }
    }

    static func recordButton() {
        if enabled { buttonActions += 1 }
    }

    static func record(_ event: NSEvent, action: WaveformScrollPolicy.Action) {
        guard enabled else { return }
        if case .scrub = action { scrubEvents += 1 }
        if !event.momentumPhase.isEmpty {
            momentumEvents += 1
            if action != .swallow { escapedMomentumEvents += 1 }
        }
    }
}

extension DevSelfTests {
    /// 개발용(#92): 트랙패드로 파형을 스크럽하고 손을 뗀 뒤, 관성 이벤트가 이어지는 동안 커서를 핫큐 A 버튼으로 옮겨 누르면
    /// 버튼이 눌리는지 실제 창에서 확인한다(`--hotcue-click-selftest`). 합성 라이브러리(EditLayoutFixtureCapture)와 `DJC_HOME`이 있을 때만.
    /// 스크롤·클릭은 대상 창을 가진 합성 이벤트로 넣는다(실제 커서·다른 앱은 건드리지 않는다).
    static func runHotCueClickSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        guard ProcessInfo.processInfo.arguments.contains("--hotcue-click-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[핫큐 클릭 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<150 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard let row = store.rows.first(where: { $0.title.hasPrefix("편집 화면 시험") }) else { log("합성 곡 없음"); exit(1) }
            store.selection = [row.id]
            store.loadToDeck(row)
            for _ in 0..<150 where deck.row?.id != row.id || deck.draft == nil || deck.waveform == nil || !deck.canPlay { await wait(0.1) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) ?? NSApp.mainWindow,
                  let hotCue = deck.hotCue(slot: 0) else { log("창 또는 핫큐 A 없음"); exit(1) }
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
            await wait(0.3)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<100 where !window.isKeyWindow { await wait(0.1) }
            guard window.isKeyWindow else {
                log("미검증: 덱 창을 키 창으로 만들지 못함 · 앱 활성=\(NSApp.isActive) · 키 창 가능=\(window.canBecomeKey)")
                exit(2)
            }
            await wait(0.5)
            if let mode = ProcessInfo.processInfo.environment["DJC_HOTCUE_CLICK_MATRIX"] {
                guard await runHotCueClickMatrix(window: window, deck: deck, mode: mode) else { exit(1) }
                log("조건표 뒤 기존 스크롤·관성 시험도 같은 창에서 확인")
            }
            guard let wave = SelfTestFrames.frames["zoomWaveform"].flatMap({ windowRect($0, in: window) }),
                  let pad = SelfTestFrames.frames["hotCue.0"].flatMap({ windowRect($0, in: window) }) else {
                log("파형·핫큐 버튼 자리를 모름"); exit(1)
            }
            log(String(format: "파형 %@ · 핫큐 A %@", NSStringFromRect(wave), NSStringFromRect(pad)))
            let wavePoint = NSPoint(x: wave.midX, y: wave.midY), padPoint = NSPoint(x: pad.midX, y: pad.midY)

            deck.volume = 0
            deck.setZoom(16)
            deck.seek(20)
            deck.togglePlay()
            await wait(0.6)
            deck.selectedCueID = nil

            let beforeScrub = deck.currentTime
            HotCueScrollTrace.scrubEvents = 0
            HotCueScrollTrace.momentumEvents = 0
            HotCueScrollTrace.escapedMomentumEvents = 0
            HotCueScrollTrace.enabled = true
            // 1) 파형 위에서 두 손가락 가로 스크럽(2초) → 손을 뗌
            scroll(window, at: wavePoint, phase: 1 << 7, momentum: 0, dx: 0)   // mayBegin
            scroll(window, at: wavePoint, phase: 1, momentum: 0, dx: -20)       // began
            for _ in 0..<20 {
                scroll(window, at: wavePoint, phase: 2, momentum: 0, dx: -30)
                await wait(0.1)
            }
            scroll(window, at: wavePoint, phase: 4, momentum: 0, dx: 0)         // ended
            let afterScrub = deck.playhead
            // 2) 관성이 이어지는 동안 커서를 핫큐 A로 옮겨 누른다(관성 이벤트 위치도 커서를 따라 바뀐다)
            scroll(window, at: padPoint, phase: 0, momentum: 1, dx: -25, dy: 3)  // momentum began
            for i in 0..<40 {
                scroll(window, at: padPoint, phase: 0, momentum: 2, dx: -20 + Double(i) / 2, dy: i < 10 ? 2 : 0)
                if i == 12 { click(window, at: padPoint, down: true) }
                if i == 14 { click(window, at: padPoint, down: false) }
                await wait(0.016)
            }
            scroll(window, at: padPoint, phase: 0, momentum: 3, dx: 0)          // momentum ended
            await wait(0.4)
            HotCueScrollTrace.enabled = false
            let pressed = deck.selectedCueID == hotCue.id
            let jumped = deck.playhead >= hotCue.time - 0.05 && deck.playhead < hotCue.time + 1.5
            let scrubbed = HotCueScrollTrace.scrubEvents == 21 && afterScrub > beforeScrub + 2
            let contained = HotCueScrollTrace.momentumEvents == 42 && HotCueScrollTrace.escapedMomentumEvents == 0
            log("실제 파형 모니터: 스크럽 \(HotCueScrollTrace.scrubEvents)/21 · 관성 \(HotCueScrollTrace.momentumEvents)/42 · 외부 전달 \(HotCueScrollTrace.escapedMomentumEvents)")
            log(String(format: "스크럽 뒤 위치 %.2f초 · 핫큐 A %.2f초 · 지금 %.2f초 · 선택된 큐=%@", afterScrub, hotCue.time, deck.playhead,
                       deck.selectedCueID == hotCue.id ? "A" : "없음"))
            deck.togglePlay()
            let ok = scrubbed && contained && pressed && jumped
            log(ok ? "통과: 스크럽·관성 차단·핫큐 클릭 확인(물리 트랙패드 감속은 별도 확인 필요)"
                : "실패: 스크럽=\(scrubbed) · 관성 차단=\(contained) · 클릭=\(pressed) · 이동=\(jumped)")
            exit(ok ? 0 : 1)
        }
    }

    /// #92 조건표: 앱 안 마우스 이벤트로 실제 제스처 종료와 버튼 action을 각각 확인한다.
    private static func runHotCueClickMatrix(window: NSWindow, deck: DeckModel, mode: String) async -> Bool {
        func log(_ text: String) { FileHandle.standardError.write(Data("[핫큐 클릭 시험] \(text)\n".utf8)) }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard ["paused", "starting", "playing"].contains(mode), let cue = deck.hotCue(slot: 0) else {
            log("미검증: 조건은 paused·starting·playing 중 하나여야 함"); exit(2)
        }
        func capture(_ name: String) {
            guard let directory = ProcessInfo.processInfo.environment["DJC_HOTCUE_CAPTURE_DIR"] else { return }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "jpg",
                                 URL(filePath: directory).appending(path: "\(mode)-\(name).jpg").path]
            do { try process.run(); process.waitUntilExit(); log("\(name) 캡처 종료 \(process.terminationStatus)") }
            catch { log("\(name) 캡처 실패") }
        }
        deck.volume = 0
        deck.setZoom(16)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            if HotCueScrollTrace.enabled, event.window === window,
               let pad = SelfTestFrames.frames["hotCue.0"].flatMap({ windowRect($0, in: window) }),
               pad.contains(event.locationInWindow) {
                if event.type == .leftMouseDown { HotCueScrollTrace.buttonDowns += 1 }
                else { HotCueScrollTrace.buttonUps += 1 }
            }
            return event
        }
        var passed = 0, attempted = 0
        for waveName in ["overviewWaveform", "zoomWaveform"] {
            for duration in [2.0, 0.1, 3.2] {
                for delay in [0.0, 0.15, 3.1] {
                    for repetition in 1...2 {
                        guard window.isKeyWindow,
                              let wave = SelfTestFrames.frames[waveName].flatMap({ windowRect($0, in: window) }),
                              let pad = SelfTestFrames.frames["hotCue.0"].flatMap({ windowRect($0, in: window) }) else {
                            log("미검증: 키 창 또는 파형·버튼 자리 없음"); exit(2)
                        }
                        deck.stopPlayback()
                        deck.seek(60)
                        if mode != "paused" { deck.togglePlay() }
                        if mode == "playing" { await wait(0.6) }
                        deck.selectedCueID = nil
                        if attempted == 0 {
                            await wait(0.1)
                            capture("before")
                        }
                        HotCueScrollTrace.dragChanges = [:]
                        HotCueScrollTrace.dragEnds = [:]
                        HotCueScrollTrace.buttonActions = 0
                        HotCueScrollTrace.buttonDowns = 0
                        HotCueScrollTrace.buttonUps = 0
                        HotCueScrollTrace.enabled = true
                        let startX = wave.midX + wave.width * 0.18
                        let y = wave.midY
                        let steps = max(3, Int(duration / 0.05))
                        mouse(window, at: NSPoint(x: startX, y: y), type: .leftMouseDown)
                        for i in 1...steps {
                            await wait(duration / Double(steps))
                            let x = startX + wave.width * 0.12 * sin(Double(i) * .pi / 3)
                            let jitter = repetition == 2 ? wave.height * 0.1 * sin(Double(i)) : 0
                            mouse(window, at: NSPoint(x: x, y: y + jitter), type: .leftMouseDragged)
                        }
                        let end = NSPoint(x: startX - wave.width * 0.12, y: y)
                        mouse(window, at: end, type: .leftMouseDragged)
                        mouse(window, at: end, type: .leftMouseUp)
                        await wait(delay)
                        let point = NSPoint(x: pad.midX, y: pad.midY)
                        mouse(window, at: point, type: .mouseMoved)
                        click(window, at: point, down: true)
                        await wait(0.02)
                        click(window, at: point, down: false)
                        await wait(0.7)
                        HotCueScrollTrace.enabled = false
                        let changes = HotCueScrollTrace.dragChanges[waveName, default: 0]
                        let ends = HotCueScrollTrace.dragEnds[waveName, default: 0]
                        let action = HotCueScrollTrace.buttonActions
                        let selected = deck.selectedCueID == cue.id
                        let jumped = deck.playhead >= cue.time - 0.05 && deck.playhead < cue.time + 1.5
                        let ok = changes >= 2 && ends == 1 && action == 1 && selected && jumped
                        attempted += 1
                        if ok { passed += 1 }
                        log(String(format: "%@ · %@ · 스크럽 %.2fs · 클릭 +%.2fs · 반복 %d: changed=%d ended=%d action=%d 선택=%@ 이동=%@ %@",
                                   mode, waveName, duration, delay, repetition, changes, ends, action, String(selected), String(jumped), ok ? "통과" : "실패"))
                        log("버튼 이벤트 down=\(HotCueScrollTrace.buttonDowns) up=\(HotCueScrollTrace.buttonUps) · 놓은 뒤 anchor=\(deck.scrubAnchor != nil) resume=\(deck.resumeAfterScrub)")
                        if attempted == 1 { capture("after") }
                    }
                }
            }
        }
        deck.stopPlayback()
        if let monitor { NSEvent.removeMonitor(monitor) }
        log("조건표 \(mode): \(passed)/\(attempted) 통과(앱 안 합성 마우스, 물리 마우스는 미검증)")
        return passed == attempted
    }

    /// SwiftUI `.global`(위 왼쪽 원점) 사각형 → 창 좌표(아래 왼쪽 원점)
    private static func windowRect(_ rect: CGRect, in window: NSWindow) -> NSRect? {
        guard let content = window.contentView else { return nil }
        let y = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        return content.convert(NSRect(x: rect.minX, y: y, width: rect.width, height: rect.height), to: nil)
    }

    /// 트랙패드 스크롤 이벤트를 창에 넣는다. phase: NSEvent.Phase 원시값, momentum: CGMomentumScrollPhase(1 시작 · 2 계속 · 3 끝).
    private static func scroll(_ window: NSWindow, at point: NSPoint, phase: Int64, momentum: Int64, dx: Double, dy: Double = 0) {
        // CGEvent로 바로 만들면 창 번호가 0이라 파형 모니터가 모두 건너뛴다.
        // 공개 NSEvent 생성자로 대상 창을 먼저 붙인 뒤 스크롤 이벤트로 바꾼다.
        guard let seed = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0),
              let cg = seed.cgEvent else { return }
        cg.type = .scrollWheel
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cg), event.window === window else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func click(_ window: NSWindow, at point: NSPoint, down: Bool) {
        mouse(window, at: point, type: down ? .leftMouseDown : .leftMouseUp)
    }

    private static func mouse(_ window: NSWindow, at point: NSPoint, type: NSEvent.EventType) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
