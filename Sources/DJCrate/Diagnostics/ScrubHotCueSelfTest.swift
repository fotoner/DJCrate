#if DEBUG
import AppKit
import DJCDomain

/// #133: 확대 파형을 끄는 동안 제스처·KeyRouter에 무엇이 도착했는지 센다.
@MainActor
enum ScrubHotCueTrace {
    static var enabled = false
    static var dragChanges = 0
    static var dragEnds = 0
    static var routedKeyDowns = 0

    static func recordDrag(ended: Bool) {
        guard enabled else { return }
        if ended { dragEnds += 1 } else { dragChanges += 1 }
    }

    static func recordKey(_ event: NSEvent) {
        guard enabled, event.type == .keyDown else { return }
        routedKeyDowns += 1
    }
}

extension DevSelfTests {
    /// 개발용(#133): 확대 파형을 마우스로 누른 채 끄는 동안 핫큐 키를 누르면 빈 칸(C)은 끄는 중 자리에 찍히고,
    /// 저장된 칸(A)은 그 자리로 옮겨 끌기가 거기서 이어지며, 놓으면 재생을 이어 가는지 실제 창에서 확인한다(`--scrub-hotcue-selftest`).
    /// 끄는 동안 진짜 키 이벤트는 SwiftUI 제스처의 이벤트 추적에 버려져 KeyRouter까지 오지 않는 것도 함께 센다.
    /// 마우스는 대상 창에 합성 이벤트로 넣고, 키는 합성 키보드 상태(`DragHotCueKeys.selfTestInput`)로 준다(실제 키보드·커서는 건드리지 않는다).
    /// 합성 마우스는 창이 키 창일 때만 제스처에 닿는다. 앱을 앞으로 가져오지 못하면 미검증(exit 2)으로 끝낸다.
    /// 합성 라이브러리(EditLayoutFixtureCapture)와 `DJC_HOME`·`DJC_REKORDBOX_DIR`이 있을 때만.
    static func runScrubHotCueSelfTestIfRequested(store: LibraryStore, deck: DeckModel) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--scrub-hotcue-selftest"),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        func log(_ text: String) { FileHandle.standardError.write(Data("[스크럽 핫큐 시험] \(text)\n".utf8)) }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for _ in 0..<150 {
                if case .loaded = store.phase { break }
                await wait(0.1)
            }
            guard let row = store.rows.first(where: { $0.title == "편집 화면 시험" }) else { log("합성 곡 없음"); exit(2) }
            store.selection = [row.id]
            store.loadToDeck(row)
            for _ in 0..<150 where deck.row?.id != row.id || deck.draft == nil || deck.waveform == nil || !deck.canPlay {
                await wait(0.1)
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }), let content = window.contentView,
                  let hotCueA = deck.hotCue(slot: 0) else {
                log("덱 창 또는 핫큐 A 없음"); exit(2)
            }
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            for _ in 0..<100 where !(window.isKeyWindow && window === NSApp.mainWindow) { await wait(0.1) }
            guard window.isKeyWindow, window === NSApp.mainWindow else {
                log("미검증: 덱 창을 키 창으로 만들지 못함(다른 앱이 앞에 있음). 합성 마우스가 제스처에 닿지 않는다")
                exit(2)
            }
            guard let frame = SelfTestFrames.frames["zoomWaveform"] else { log("확대 파형 자리 없음"); exit(2) }
            let y = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
            let wave = content.convert(NSRect(x: frame.minX, y: y - 1, width: frame.width, height: 2), to: nil)

            @MainActor func mouse(_ type: NSEvent.EventType, x: CGFloat) {
                guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: wave.midY), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
                NSApp.postEvent(event, atStart: false)
            }
            @MainActor func key(_ code: UInt16, _ text: String) {
                for type: NSEvent.EventType in [.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: text, charactersIgnoringModifiers: text,
                                                       isARepeat: false, keyCode: code) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
            }
            // 합성 키보드: 이 집합에 든 키가 눌린 것으로 보인다. 마우스는 끄는 동안 눌린 것으로 본다.
            var pressed: Set<UInt16> = []
            DragHotCueKeys.selfTestInput = .init(isKeyDown: { pressed.contains($0) }, isShiftDown: { false }, isMouseDown: { true })
            @MainActor func tap(_ code: UInt16) async {
                pressed = [code]
                await wait(0.08)
                pressed = []
                await wait(0.05)
            }

            deck.volume = 0
            deck.setZoom(16)
            deck.stopPlayback()
            if deck.hotCue(slot: 2) != nil { deck.deleteHotCue(slot: 2) }
            if deck.hotCue(slot: 3) != nil { deck.deleteHotCue(slot: 3) }
            deck.seek(60)
            deck.togglePlay()
            deck.selectedCueID = nil
            window.makeFirstResponder(window)
            await wait(0.4)
            ScrubHotCueTrace.enabled = true
            let pointsPerSecond = wave.width / 16
            // 1) 큐가 없는 자리(가운데 오른쪽)를 누르고 왼쪽으로 끈다 → 곡 위치가 앞으로 간다.
            let startX = wave.midX + wave.width * 0.1
            mouse(.leftMouseDown, x: startX)
            await wait(0.1)
            for i in 1...5 {
                mouse(.leftMouseDragged, x: startX - CGFloat(i) * 8)
                await wait(0.04)
            }
            await wait(0.1)
            let scrubbed = deck.playhead
            let paused = !deck.isPlaying
            let reached = ScrubHotCueTrace.dragChanges > 0 && ScrubHotCueTrace.dragEnds == 0
            log(String(format: "끌기: 제스처 changed=%d · 위치 60.00→%.2f초(기대 %.2f) · 끄는 동안 정지=%@", ScrubHotCueTrace.dragChanges,
                       scrubbed, 60 + 40 / pointsPerSecond, String(paused)))
            // 2) 진짜 키 이벤트(4 = 빈 D)는 제스처의 이벤트 추적에 버려져 KeyRouter까지 오지 않는다(#133 원인).
            key(21, "4")
            await wait(0.2)
            let dropped = ScrubHotCueTrace.routedKeyDowns == 0 && deck.hotCue(slot: 3) == nil
            log("끄는 중 진짜 키 이벤트: KeyRouter 도착 \(ScrubHotCueTrace.routedKeyDowns)개 · 핫큐 D=\(deck.hotCue(slot: 3) == nil ? "없음" : "찍힘")")
            // 3) 키보드 상태로 3(빈 C) → 끄는 중 자리에 찍힌다.
            let beforeC = deck.playhead
            await tap(20)
            let c = deck.hotCue(slot: 2)
            let placed = c.map { abs($0.time - deck.snapped(beforeC)) < 0.001 } == true && !deck.isPlaying
            log(String(format: "C(빈 칸): 끄는 중 위치 %.3f초 → 핫큐 C %@초 · 재생=%@", beforeC,
                       c.map { String(format: "%.3f", $0.time) } ?? "없음", String(deck.isPlaying)))
            // 4) 1(저장된 A) → A로 옮기고, 이어서 끌면 A에서 이어진다.
            await tap(18)
            let movedToA = abs(deck.playhead - hotCueA.time) < 0.001 && !deck.isPlaying && deck.selectedCueID == hotCueA.id
            log(String(format: "A(저장된 칸 %.3f초): 위치 %.3f초 · 재생=%@ · 선택=%@", hotCueA.time, deck.playhead, String(deck.isPlaying),
                       deck.selectedCueID == hotCueA.id ? "A" : "다른 큐"))
            for i in 6...8 {
                mouse(.leftMouseDragged, x: startX - CGFloat(i) * 8)
                await wait(0.04)
            }
            await wait(0.1)
            let continued = deck.playhead - hotCueA.time
            let followed = abs(continued - 24 / pointsPerSecond) < 0.15
            log(String(format: "A에서 24pt 더 끔: A+%.3f초(기대 +%.3f, 끌기 시작 자리로 튀면 +%.1f)", continued, 24 / pointsPerSecond,
                       60 + 64 / pointsPerSecond - hotCueA.time))
            // 5) 놓으면 놓은 자리에서 재생을 이어 간다.
            mouse(.leftMouseUp, x: startX - 64)
            await wait(0.3)
            let resumed = deck.isPlaying && deck.playhead > hotCueA.time + continued - 0.05 && deck.playhead < hotCueA.time + continued + 1
            log(String(format: "놓은 뒤: 재생=%@ · 위치 %.2f초 · 제스처 ended=%d", String(deck.isPlaying), deck.playhead, ScrubHotCueTrace.dragEnds))
            ScrubHotCueTrace.enabled = false
            DragHotCueKeys.selfTestInput = nil
            deck.stopPlayback()
            let ok = reached && paused && dropped && placed && movedToA && followed && resumed && ScrubHotCueTrace.dragEnds == 1
            log(ok ? "통과: 끄는 중 빈 칸 찍기·저장된 칸으로 옮겨 이어 끌기·놓은 뒤 재생(물리 키보드 상태 읽기는 별도 확인)"
                : "실패: 제스처 도착=\(reached) · 정지=\(paused) · 키 이벤트 버려짐=\(dropped) · C 찍기=\(placed) · A 이동=\(movedToA) · 이어 끌기=\(followed) · 재생 이어 감=\(resumed)")
            exit(ok ? 0 : 1)
        }
    }
}
#endif
