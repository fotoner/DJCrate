import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

/// Flip: 덱의 Flip 단추로 기록을 시작·마치고, 마치면 결과 창 하나를 띄운다. 창 안에 자체 재생기가 있어 덱과 따로 듣는다.
///
/// 렌더해 넣으면 창을 닫고 추가한 곡에서 그 곡을 고른다(곡 편집 창과 같다). 창을 닫으면 그 기록은 버린다.
/// 기록은 다시 만들 수 없어 넣기 전에 버리는 일(창 닫기·⌘W·버리기·다시 기록·새 기록)은 먼저 묻는다(`FlipModel.confirmDiscard`).
/// 단축키(스페이스바 재생, Home·End)는 이 창이 앞에 있을 때만 받는다. 덱 단축키는 `KeyRouter`가 이 창을 빼고 받는다.
@MainActor
final class FlipWindow: NSObject, NSWindowDelegate {
    /// 조립 지점이 붙인 덱·목록·편집본 쓰기(곡 편집 창과 같은 값)
    private(set) var links: EditWindowLinks?
    var deck: DeckModel? { links?.deck }
    private(set) var window: NSWindow?
    private var host: NSHostingController<FlipView>?
    private(set) var model: FlipModel?
    private var monitors: [Any] = []
    /// 결과를 버리기 전에 묻는 창
    var prompter: any ReflectionPrompter = AlertPrompter()

    func attach(_ links: EditWindowLinks) {
        self.links = links
    }

    /// 결과 창을 열 곡이 덱에 없을 때
    static var noTrackReason: String { String(ui: "덱에 곡이 없습니다. 곡을 불러온 뒤 Flip을 기록하세요") }
    /// 결과 창을 열기 전에 덱의 곡이 기록한 곡에서 바뀌었을 때(같은 곡이라도 파일이 다르면 바뀐 것)
    static var trackChangedReason: String {
        String(ui: "기록한 곡이 덱에서 바뀌어 Flip 결과를 만들지 않았습니다. 그 곡을 다시 불러와 Flip을 기록하세요")
    }

    /// 덱의 Flip 단추·메뉴: 기록 중이 아니면 기록을 시작하고, 기록 중이면 마치고 결과 창을 연다.
    func toggleRecording() {
        guard let deck else { return }
        if deck.isFlipRecording {
            guard let recording = deck.finishFlipRecording() else { return }
            guard !recording.isEmpty else {
                deck.showToast(String(ui: "기록에 점프·루프가 없어 Flip을 만들지 않았습니다. Flip을 누르고 재생하며 핫큐·루프를 쓴 뒤 다시 누르세요"))
                return
            }
            // 결과 창 열기가 돌기 전에 곡을 바꿔도 묻도록, 기다림 표시와 기록한 곡은 지금 잡는다.
            let track = deck.row?.track
            let turn = deck.beginAwaitingFlipResult(recording)
            Task { await open(recording, track: track, turn: turn) }
        } else {
            // 마친 기록의 결과 창을 아직 여는 중이면 새로 기록하지 않는다(그 결과를 묻지 않고 닫지 않게).
            if deck.awaitingFlipResult != nil {
                deck.showToast(String(ui: "Flip 결과 창을 여는 중입니다. 창이 열린 뒤 다시 기록하세요"))
                return
            }
            if let reason = deck.flipUnavailableReason {
                deck.showToast(reason)
                return
            }
            if model?.renderProgress != nil {
                deck.showToast(String(ui: "Flip 렌더가 끝나거나 취소한 뒤 다시 기록하세요"))
                return
            }
            // 지난 결과 창은 새 기록과 섞이지 않게 닫는다(넣지 않은 결과면 버려도 되는지 묻는다).
            guard discardResult() else { return }
            deck.startFlipRecording()
        }
    }

    /// 마친 기록으로 결과 창을 연다. 음원 파일이 있는지는 메인 스레드 밖에서 본다.
    /// `track`은 기록을 마친 때 덱의 곡, `turn`은 그때 시작한 기다림 차례(`DeckModel.beginAwaitingFlipResult`)다.
    private func open(_ recording: FlipRecording, track: Track?, turn: Int) async {
        guard let links, let deck = links.deck else { return }
        var found = false
        // 기다리는 동안 곡을 바꾸려 하면 덱이 이 기록을 버릴지 묻는다(`confirmDiscardingFlip`).
        if let track, !track.isStreaming { found = await links.writer.sourceExists(URL(filePath: track.folderPath)) }
        // 그 사이 확인 창에서 이 기록을 버렸으면 결과 창도 안내도 없이 끝낸다.
        guard await deck.finishAwaitingFlipResult(turn) else { return }
        model?.close()
        let model: FlipModel
        do {
            // 기록한 곡이 덱에 그대로 있어야 한다(기다리는 사이 다른 곡·다른 파일을 올렸으면 만들지 않는다, 곡 편집 창과 같은 비교).
            guard let track, let current = deck.row?.track else { throw DJCError.editRefused(Self.noTrackReason) }
            guard current.uuid == track.uuid, current.folderPath == track.folderPath else {
                throw DJCError.editRefused(Self.trackChangedReason)
            }
            guard let source = deck.editSource(audioFileExists: found) else { throw DJCError.editRefused(Self.noTrackReason) }
            model = try FlipModel(source: source, recording: recording, audio: links.makeAudio(), deck: deck.editControl, writer: links.writer)
        } catch {
            self.model = nil
            window?.close()
            deck.showToast(TrackEditModel.reason(error))
            return
        }
        model.onStaged = { [weak self] staged in self?.finish(staged) }
        self.model = model
        deck.hasPendingFlipResult = true
        let root = FlipView(model: model, deck: deck,
                            onRerecord: { [weak self] in self?.rerecord() },
                            onDiscard: { [weak self] in self?.window?.performClose(nil) })
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 900, height: 520))
            window.contentMinSize = NSSize(width: 680, height: 460)
            window.center()
            window.setFrameAutosaveName("FlipWindow")
            self.host = host
            self.window = window
        }
        window?.title = String(ui: "Flip — \(model.row.title)")
        installMonitors()
        window?.makeKeyAndOrderFront(nil)
        // SwiftUI가 첫 글자 칸(제목)에 포커스를 주면 스페이스바가 글자로 들어간다. 창 본문에서 시작한다.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    /// 이 결과를 버리고 덱에서 다시 기록한다.
    private func rerecord() {
        guard discardResult() else { return }
        deck?.startFlipRecording()
    }

    /// 열린 결과 창을 닫는다. 넣지 않은 결과면 먼저 묻고, 취소하면 false(창은 그대로).
    private func discardResult() -> Bool {
        guard let window, window.isVisible, let model else { return true }
        guard model.confirmDiscard(prompter) else { return false }
        window.close()
        return true
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }) { monitors.append(keys) }
    }

    /// 이 창에 온 키: 스페이스바 재생·일시정지, Home·End. 글자를 입력하는 중(제목 칸)이나 시트·모달이 떠 있으면 넘긴다.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSText), let model,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 49: model.togglePlay()
        case 115: model.seek(to: 0)
        case 119: model.seek(to: model.duration)
        default: return false
        }
        return true
    }

    private func finish(_ staged: StagedTrack) {
        let hasGrid = !(model?.grid.isEmpty ?? true)
        links?.showStaged(staged, hasGrid)
        window?.close()
        model = nil
        deck?.hasPendingFlipResult = false
    }

    /// 닫기 단추·⌘W·버리기: 넣지 않은 결과면 버려도 되는지 묻는다.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.confirmDiscard(prompter) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        model = nil
        deck?.hasPendingFlipResult = false
    }
}
