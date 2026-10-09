#if DEBUG
import AppKit
import AVFoundation
import DJCApplication
import DJCDomain
import DJCStorage

extension TrackEditWindow {
    /// 개발용. 합성 라이브러리(EditLayoutFixtureCapture)의 곡으로 편집 창을 띄운다. 초안이 섞이지 않게 `DJC_HOME`이 있을 때만.
    /// - `--edit-layout=light|dark`: 클립 넷·원곡에서 고른 구간·고른 클립 상태로 띄우고 창 번호를 표준 오류에 적는다
    ///   (`screencapture -l`로 그 창만 찍는다).
    /// - `--edit-selftest`: 창 재생기(스페이스바·시킹·이음새 듣기, 덱은 그대로) → 고르기·자르기·복제·옮기기·지우기와
    ///   편집 메뉴 실행 취소·복귀 → 확대 키 → 실제 마우스 끌기(클립 끝 다듬기·원곡 구간 끌어 넣기, 앱이 앞에 있을 때만)
    ///   → 렌더 → 추가한 곡으로 이동 → 덱에 편집본이 올라오는지까지 돌린다.
    func runLayoutCaptureIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let layout = args.first { $0.hasPrefix("--edit-layout=") }
        let selfTest = args.contains("--edit-selftest")
        guard layout != nil || selfTest, ProcessInfo.processInfo.environment["DJC_HOME"] != nil else { return }
        Task { @MainActor in
            guard let store, let deck else { return }
            for _ in 0..<150 {
                if case .loaded = store.phase { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let row = store.rows.first(where: { $0.title.hasPrefix("편집 화면 시험") }) else { Self.log("합성 곡 없음"); return }
            if let layout { NSApp.appearance = NSAppearance(named: layout.hasSuffix("dark") ? .darkAqua : .aqua) }
            store.selection = [row.id]
            store.loadToDeck(row)
            for _ in 0..<150 where deck.row?.id != row.id || deck.draft == nil || deck.waveform == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard deck.waveform != nil else { Self.log("파형을 읽지 못함"); return }
            deck.seek(deck.duration * 0.42)
            await open(entries: [BarRange(0, 16), BarRange(1, 16), BarRange(17, 48), BarRange(81, 96)])
            guard let model, let bars = model.layout else { Self.log("편집 창을 열지 못함"); return }
            for _ in 0..<100 where !model.isAudioReady { try? await Task.sleep(for: .milliseconds(50)) }
            if layout != nil {
                // 원곡에서 49~64마디를 고르고, 결과의 세 번째 클립을 고른 상태
                model.select(from: bars.start(ofBar: 49), to: bars.start(ofBar: 65))
                model.finishSelection()
                model.selectedClip = model.entries[2].id
                model.seek(.output, to: (model.edit?.clips[2].outputStart ?? 0) + 6 * bars.barLength)
                try? await Task.sleep(for: .milliseconds(800))
                Self.log("창 번호 \(window?.windowNumber ?? -1)")
            }
            if selfTest { await runSelfTest(deck: deck, store: store) }
        }
    }

    private func runSelfTest(deck: DeckModel, store: LibraryStore) async {
        guard let model, let window, let layout = model.layout, let first = model.edit, first.pieces.count > 1 else {
            Self.log("실패: 편집 계획 없음")
            return
        }
        var passed = true
        func check(_ ok: Bool, _ text: String) {
            passed = passed && ok
            Self.log("\(ok ? "통과" : "실패"): \(text)")
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func until(_ seconds: Double, _ condition: () -> Bool) async {
            for _ in 0..<Int(seconds * 20) where !condition() { await wait(0.05) }
        }
        func press(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) async {
            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode) else { return }
                NSApp.postEvent(event, atStart: false)
                await wait(0.05)
            }
        }
        // SwiftUI `.global`(위 왼쪽 원점) 자리 → 창 좌표(아래 왼쪽 원점)
        func windowRect(_ name: String) -> CGRect? {
            guard let rect = SelfTestFrames.frames[name], let content = window.contentView else { return nil }
            let y = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
            return content.convert(NSRect(x: rect.minX, y: y, width: rect.width, height: rect.height), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) async {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            NSApp.postEvent(event, atStart: false)
            await wait(0.03)
        }
        // 누르고 12번에 나눠 끈 뒤 뗀다.
        func drag(from a: CGPoint, to b: CGPoint) async {
            await mouse(.leftMouseDown, a)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                await mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            await mouse(.leftMouseUp, b)
            await wait(0.2)
        }
        // 편집 메뉴(⌘Z·⇧⌘Z)가 이 창이 앞일 때 타는 길: 창의 응답자 사슬 → 창의 실행 취소 관리자.
        // 자가 테스트 중에는 앱이 앞에 없어 키 창이 없을 수 있어 창의 첫 응답자부터 직접 보낸다.
        func menu(_ action: String) -> Bool {
            (window.firstResponder ?? window).tryToPerform(Selector((action)), with: nil)
        }
        check(model.isAudioReady, "원곡을 메모리에 풀어 창에서 재생할 수 있음")

        // 1) 스페이스바: 편집 창이 앞(주 창)이면 창 재생기가 마지막으로 누른 줄(결과)을 재생하고 덱은 그대로다.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeFirstResponder(window.contentView)
        await until(2) { NSApp.keyWindow === window }
        model.seek(.output, to: 10)
        await press(49, " ")
        await until(2) { model.playing == .output }
        let before = model.position(.output)
        await wait(0.6)
        let after = model.position(.output)
        check(model.playing == .output && !deck.isPlaying && after - before > 0.3,
              String(format: "스페이스바 → 결과 재생(주 창=%@, 덱 멈춤 그대로) · 0.6초 동안 %.2f초 진행", window === NSApp.mainWindow ? "편집 창" : "다른 창", after - before))
        await press(49, " ")
        await until(1) { model.playing == nil }
        check(model.playing == nil && abs(model.position(.output) - after) < 0.5 && !deck.isPlaying,
              String(format: "다시 스페이스바 → 일시정지, 재생선 %.2f초에 멈춤", model.position(.output)))

        // 2) 결과 어디서든: 재생 중 시킹하면 그 자리에서 잇는다.
        model.play(.output)
        await wait(0.2)
        model.seek(.output, to: 60)
        await wait(0.4)
        let seeked = model.position(.output)
        check(model.playing == .output && seeked > 60.1 && seeked < 61, String(format: "재생 중 60초로 시킹 → 0.4초 뒤 %.2f초", seeked))
        model.pause()

        // 3) 이음새 듣기: 원곡이 이어지지 않는 자리 앞 2마디부터 뒤 2마디까지 듣고 멈춘다.
        let seam = first.pieces[1].outputStart, span = 2 * layout.barLength
        model.auditionSeam(1)
        let auditionStart = model.position(.output)
        await until(span + 1.5) { model.position(.output) > seam + 0.1 || model.playing == nil }
        let crossed = model.position(.output)
        await until(span * 2 + 2) { model.playing == nil }
        check(abs(auditionStart - (seam - span)) < 0.05 && crossed > seam && model.playing == nil
              && abs(model.position(.output) - (seam + span)) < 0.1,
              String(format: "이음새 %.2f초: %.2f초부터 들어 이음새를 지나 %.2f초에서 멈춤", seam, auditionStart, model.position(.output)))

        // 4) 원곡 줄: 덱과 따로 원곡을 재생한다.
        model.seek(.source, to: 30)
        model.play(.source)
        await wait(0.5)
        let source = model.position(.source)
        model.pause()
        check(source > 30.25 && source < 31 && !deck.isPlaying, String(format: "원곡 30초부터 재생 → 0.5초 뒤 %.2f초", source))

        // 5) 원곡에서 끌어 고르기 → 고른 클립(17-48) 뒤에 넣기 → 자르기 → 복제 → 끌어 옮기기 → 지우기, 편집 메뉴 실행 취소·복귀
        let original = model.entries.map(\.range)
        model.selectedClip = model.entries[2].id
        model.select(from: layout.start(ofBar: 49) + 0.2, to: layout.start(ofBar: 65) - 0.3)
        await press(36, "\r")
        guard model.selectedIndex == 3, model.clipLayout.count == 5 else { check(false, "결과에 넣지 못함"); return }
        model.seek(.output, to: model.clipLayout[3].outputStart + 4 * layout.barLength + 0.3)
        await press(11, "b", modifiers: .command)
        await press(2, "d", modifiers: .command)
        if let copy = model.selectedClip { model.moveClip(copy, toOffset: 3) }
        await press(51, "\u{8}")
        let edited = model.entries.map(\.range)
        check(edited == original.prefix(3) + [BarRange(49, 52), BarRange(53, 64)] + original.suffix(1) && model.edit != nil,
              "⏎ 넣기·⌘B 자르기·⌘D 복제·끌어 옮기기·⌫ 지우기 → \(edited.map(\.description).joined(separator: ","))")
        var handled = (0..<5).map { _ in menu("undo:") }
        let undone = model.entries.map(\.range)
        handled.append(menu("redo:"))
        let redone = model.entries.map(\.range)
        handled.append(menu("undo:"))
        passed = passed && handled.allSatisfy { $0 }
        check(undone == original && redone == original.prefix(3) + [BarRange(49, 64)] + original.suffix(1)
              && model.entries.map(\.range) == original,
              "편집 › 실행 취소 5번 → \(undone.map(\.description).joined(separator: ",")), 실행 복귀 → \(redone.map(\.description).joined(separator: ","))")

        // 5-1) 확대(#134): 결과 줄에서 = 두 번 → 4배(재생선 자리를 둔다), 0 → 전체
        model.seek(.output, to: 60)
        await press(24, "=")
        await press(24, "=")
        let zoomed = model.viewport(.output).scale(length: model.extent(.output))
        await press(29, "0")
        check(abs(zoomed - 4) < 1e-6 && model.viewport(.output) == EditViewport() && model.viewport(.source) == EditViewport(),
              String(format: "= 두 번 → 결과 %.1f배, 0 → 전체", zoomed))

        // 5-2) 실제 마우스 끌기(#134): 클립 끝 다듬기, 원곡에서 고른 구간을 결과로 끌어 넣기. 창에 마우스 이벤트를 넣어
        // SwiftUI 제스처까지 가는지 본다. 앱이 앞에 없으면(키 창이 아님) 합성 이벤트가 제스처에 닿지 않아 건너뛴다.
        if NSApp.keyWindow === window, let output = windowRect("editOutput"), let sourceLane = windowRect("editSource") {
            let clip = model.clipLayout[2]
            let scale = EditLaneScale(model, .output, width: output.width)
            let bar = scale.x(layout.barLength) - scale.x(0)
            let edge = CGPoint(x: output.minX + scale.x(clip.outputEnd) - 2, y: output.midY)
            await drag(from: edge, to: CGPoint(x: edge.x + 2.1 * bar, y: edge.y))
            let trimmed = model.entries.map(\.range)
            passed = passed && menu("undo:")
            check(trimmed == original.prefix(2) + [BarRange(17, 50)] + original.suffix(1) && model.entries.map(\.range) == original,
                  "마우스로 클립 3 끝을 2마디 끌기 → \(trimmed.map(\.description).joined(separator: ",")), 실행 취소 → 처음")
            model.select(from: layout.start(ofBar: 49), to: layout.start(ofBar: 65))
            let from = CGPoint(x: sourceLane.minX + EditLaneScale(model, .source, width: sourceLane.width).x(layout.start(ofBar: 55)),
                               y: sourceLane.midY)
            let to = CGPoint(x: output.minX + scale.x(model.clipLayout[1].outputStart + 3 * layout.barLength), y: output.midY)
            await drag(from: from, to: to)
            let inserted = model.entries.map(\.range)
            passed = passed && menu("undo:")
            check(inserted == original.prefix(1) + [BarRange(49, 64)] + original.suffix(3) && model.entries.map(\.range) == original,
                  "마우스로 원곡 49-64를 결과 클립 2 앞으로 끌어 넣기 → \(inserted.map(\.description).joined(separator: ",")), 실행 취소 → 처음")
        } else {
            Self.log("건너뜀: 앱이 앞에 없어(편집 창이 키 창이 아님) 실제 마우스 끌기를 확인하지 못함")
        }

        // 6) 렌더 → 추가한 곡
        guard let edit = model.edit else { check(false, "편집 계획 없음"); return }
        let started = Date()
        model.render()
        for _ in 0..<600 where model.staged == nil && model.renderProgress != nil { await wait(0.1) }
        guard let staged = model.staged else { check(false, "렌더: \(model.message?.text ?? "끝나지 않음")"); return }
        let rendered = try? AVAudioFile(forReading: URL(filePath: staged.path))
        let length = rendered.map { Double($0.length) / $0.processingFormat.sampleRate } ?? -1
        check(abs(length - edit.duration) < 0.001 && staged.path.hasPrefix(DJCPaths.userData.appending(path: "edits").path),
              String(format: "렌더 %.1f초 걸림 · 결과 %.3f초(계획 %.3f초) · %@", Date().timeIntervalSince(started), length, edit.duration,
                     URL(filePath: staged.path).lastPathComponent))

        // 7) 창이 닫히고 추가한 곡에서 편집본이 덱에 올라온다(변환한 그리드·옮긴 큐)
        for _ in 0..<100 where deck.row?.track.uuid != staged.uuid || deck.draft == nil { await wait(0.1) }
        check(store.sidebar == .staged && store.selection == [staged.id] && self.model == nil
              && window.isVisible != true && !model.audio.isPlaying, "창 닫고(재생기 멈춤) 추가한 곡에서 고름")
        check(deck.row?.track.uuid == staged.uuid && deck.gridDraft?.segments == [edit.outputGrid]
              && deck.draft?.cues.count == model.carry?.placed.count,
              "덱에 편집본 · 그리드 \(deck.gridDraft?.segments.first.map { String(format: "%.2f BPM", $0.bpm) } ?? "없음") · 큐 \(deck.draft?.cues.count ?? 0)개")
        Self.log("끝: \(passed ? "통과" : "실패")")
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("[편집 화면] \(text)\n".utf8))
    }
}
#endif
