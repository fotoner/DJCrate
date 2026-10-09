import DJCAdapters
import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

// 개발용 자가 시험은 디버그 빌드에만 들어간다(설치하는 릴리스 앱에는 없다).
#if DEBUG
/// 개발용 자가 테스트(실행 인자로만 돈다)
extension DeckModel {
    /// 개발용: `--grid-edit`, `--autoplay [--muted|--quiet] [--metronome]`
    func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--grid-edit") { gridEditing = true }
        if args.contains("--autoplay"), !isPlaying {
            if args.contains("--muted") { volume = 0 }
            if args.contains("--quiet") { volume = 0.0003 }   // 진단용 −70dB
            if args.contains("--metronome") { metronome = true }
            togglePlay()
        }
        if args.contains("--audio-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runAudioSelfTest()
        }
        if args.contains("--stale-cue-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runStaleCueSelfTest()
        }
        if args.contains("--analysis-play-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runAnalysisPlaySelfTest()
        }
        if args.contains("--grid-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runGridSelfTest()
        }
        if args.contains("--key-selftest"), !Self.selfTestStarted {
            Self.selfTestStarted = true
            runKeySelfTest()
        }
    }

    static var selfTestStarted = false

    /// 진단: 실제 조작 순서를 흉내 내며 단계마다 표시를 남긴다(`DJC_AUDIO_DEBUG=1`과 함께 쓴다).
    func runAudioSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("재생") { togglePlay() }
            await selfTestStep("일시정지", 1) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("탐색 60초") { seek(60) }
            await selfTestStep("0초로 탐색(지연 구간 안쪽)") { seek(0.01) }
            await selfTestStep("스크럽(끌기)") { beginScrub(); scrub(to: 80); scrub(to: 90); endScrub() }
            await selfTestStep("가로 스크롤 스크럽") { scrubCoalesced(to: 100); scrubCoalesced(to: 101) }
            await selfTestStep("템포 +8%") { tempoPercent = 8 }
            await selfTestStep("템포 +8% 탐색 30초") { seek(30) }
            await selfTestStep("키락 끔") { keyLock = false }
            await selfTestStep("키락 끔 탐색 40초") { seek(40) }
            await selfTestStep("템포 0%·키락 켬") { tempoPercent = 0; keyLock = true }
            await selfTestStep("탐색 50초") { seek(50) }
            await selfTestStep("메트로놈 켬") { metronome = true }
            await selfTestStep("일시정지 후 재개", 0.3) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("재생 중 CUE → 큐 지점 정지", 1) { cueDown(); cueUp() }
            await selfTestStep("탐색 70초(멈춤)", 0.5) { seek(70) }
            await selfTestStep("CUE → 70초를 새 큐 지점으로", 0.5) { cueDown(); cueUp() }
            await selfTestStep("CUE 누르고 있기(미리 듣기)", 1.5) { cueDown() }
            await selfTestStep("CUE 뗌 → 큐 지점 복귀", 1) { cueUp() }
            await selfTestStep("CUE 누른 채 재생 → 계속 재생", 0.5) { cueDown(); togglePlay() }
            await selfTestStep("CUE 뗌(계속 재생)", 1.5) { cueUp() }
            await selfTestStep("재생(복구 시험)") { if !isPlaying { togglePlay() } }
            await selfTestStep("엔진이 알림 없이 멈춤", 3) { audio.debugStopEngine() }
            await selfTestStep("출력 구성 변경", 3) { audio.debugConfigurationChange() }
            await selfTestStep("끝", 0.5) { togglePlay() }
        }
    }

    /// 진단: CUE를 뗀 신호를 놓친 상황(미리 듣기 상태만 남음)에서 스스로 풀리는지, 재생이 되는지 본다.
    func runStaleCueSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("큐 지점으로", 0.5) { seek(cuePoint) }
            await selfTestStep("재생", 1.5) { togglePlay() }
            await selfTestStep("정지 후 오래 쉼(엔진 꺼짐)", 4) { togglePlay() }
            await selfTestStep("오래 쉰 뒤 재생", 2) { togglePlay() }
            await selfTestStep("정지", 0.5) { togglePlay() }
            await selfTestStep("큐 지점으로 다시", 0.5) { seek(cuePoint) }
            await selfTestStep("CUE 누름(뗌 신호 없음)", 1.5) { cueDown() }
            await selfTestStep("재생 누름", 2) { togglePlay() }
            await selfTestStep("정지", 0.5) { togglePlay() }
            await selfTestStep("다시 재생", 2) { togglePlay() }
            await selfTestStep("끝", 0.5) { if isPlaying { togglePlay() } }
        }
    }

    /// 진단: 분석이 도는 동안 재생·일시정지·재개를 반복한다(곡을 고르자마자 재생하는 실제 사용과 같게).
    func runAnalysisPlaySelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("곡 로드 직후 재생", 3) { togglePlay() }
            for round in 1...8 {
                await selfTestStep("일시정지 \(round)", 1.2) { togglePlay() }
                await selfTestStep("재개 \(round)", 2.5) { togglePlay() }
            }
            await selfTestStep("끝", 0.5) { if isPlaying { togglePlay() } }
        }
    }

    /// 진단: 그리드 편집 중·후에 소리가 끊기는지 본다.
    func runGridSelfTest() {
        volume = 0.0003
        Task {
            await selfTestStep("재생") { togglePlay() }
            await selfTestStep("그리드 편집 켬") { gridEditing = true }
            await selfTestStep("그리드 10ms 이동") { shiftGrid(ms: 10) }
            await selfTestStep("BPM +0.01") { nudgeGridBPM(0.01) }
            await selfTestStep("여기서 그리드 시작") { setGridAnchorAtPlayhead() }
            await selfTestStep("그리드 끌기") { beginGridDrag(); dragGrid(by: 0.02); dragGrid(by: 0.03); endGridDrag() }
            await selfTestStep("여기서 BPM 변경") { addTempoChangeAtPlayhead() }
            await selfTestStep("메트로놈 켬") { metronome = true }
            await selfTestStep("메트로놈 켠 채 10ms 이동") { shiftGrid(ms: 10) }
            await selfTestStep("일시정지", 0.5) { togglePlay() }
            await selfTestStep("재개") { togglePlay() }
            await selfTestStep("탐색 60초") { seek(60) }
            await selfTestStep("그리드 되돌리기") { revertGrid() }
            await selfTestStep("그리드 편집 끔") { gridEditing = false }
            await selfTestStep("끝", 0.5) { togglePlay() }
        }
    }

    /// 진단: 앱 안으로 키 이벤트를 흘려보내 단축키·포커스 경로를 확인한다(다른 앱에는 가지 않는다).
    func runKeySelfTest() {
        volume = 0.0003
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            @MainActor func key(_ characters: String, _ code: UInt16) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func shiftKey(_ characters: String, _ code: UInt16) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.shift],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            @MainActor func mark(_ name: String) {
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "없음"
                let line = "── \(name) · 재생=\(isPlaying) · 포커스=\(responder)"
                AudioDebug.log(line)
            }
            @MainActor func field(_ view: NSView?, placeholder: String) -> NSTextField? {
                guard let view else { return nil }
                if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
                for sub in view.subviews { if let found = field(sub, placeholder: placeholder) { return found } }
                return nil
            }
            mark("시작")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key(" ", 49); mark("스페이스(정지 기대)")
            gridEditing = true
            try? await Task.sleep(for: .milliseconds(400))
            if let bpm = field(window.contentView, placeholder: "BPM") { window.makeFirstResponder(bpm) }
            mark("BPM 칸 클릭")
            await key("\r", 36); mark("Return")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key(" ", 49); mark("스페이스(정지 기대)")
            await key("ㅊ", 8); mark("C 자리 키를 한글 입력으로(ㅊ) · 큐 \(String(format: "%.2f", cuePoint))")
            await key("ㄷ", 14); mark("E 자리(ㄷ) 다음 큐 · 위치 \(String(format: "%.2f", playhead))")
            await key("ㄷ", 14); mark("E 자리(ㄷ) 다음 큐 · 위치 \(String(format: "%.2f", playhead))")
            let hotA = hotCue(slot: 0).map { String(format: "%.2f", $0.time) } ?? "없음"
            await key("1", 18); mark("1 → 핫큐 A(\(hotA)) · 위치 \(String(format: "%.2f", playhead))")
            await key("5", 23); mark("5 → 핫큐 E · 위치 \(String(format: "%.2f", playhead))")
            let memoriesBefore = draft?.cues.filter { $0.kind == .memory }.count ?? 0
            await key("₩", 50); mark("` 자리(₩) → 메모리 큐 \(memoriesBefore) → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            seek(playhead + 5)
            await key("ㅡ", 46); mark("M 자리(ㅡ) → 메모리 큐 \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            await shiftKey("M", 46); mark("Shift+M → 이 자리 메모리 큐 지움 → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            await shiftKey("M", 46); mark("다시 Shift+M(이 자리에 없음) → \(draft?.cues.filter { $0.kind == .memory }.count ?? 0)")
            let hotB = hotCue(slot: 1).map { String(format: "%.2f", $0.time) } ?? "없음"
            await shiftKey("@", 19); mark("Shift+2 → 핫큐 B 지움(전 \(hotB)) · 지금 \(hotCue(slot: 1).map { String(format: "%.2f", $0.time) } ?? "없음")")
            await key("8", 91); mark("숫자 패드 8 → 핫큐 H · 위치 \(String(format: "%.2f", playhead)) · H=\(hotCue(slot: 7).map { String(format: "%.2f", $0.time) } ?? "없음")")
            await key("q", 12); mark("Q 이전 큐 · 위치 \(String(format: "%.2f", playhead))")
            await key(" ", 49); mark("스페이스(재생 기대)")
            await key("e", 14); mark("재생 중 E · 위치 \(String(format: "%.2f", playhead))")
            await key("q", 12); mark("재생 중 Q · 위치 \(String(format: "%.2f", playhead))")
            await key(" ", 49); mark("스페이스(정지 기대)")
        }
    }

    func selfTestStep(_ name: String, _ seconds: Double = 2.5, _ action: () -> Void) async {
        AudioDebug.log("── \(name)")
        action()
        let state = "   상태 재생=\(isPlaying) 위치=\(String(format: "%.2f", playhead)) 큐=\(String(format: "%.2f", cuePoint)) 미리듣기=\(isCuePreviewing)"
        AudioDebug.log(state)
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
