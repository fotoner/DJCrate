import AppKit
import DJCDomain
import SwiftUI

/// AppKit의 버튼 추적이 마우스를 뗄 때 반복도 함께 끝낸다.
struct GridShiftButton: NSViewRepresentable {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let milliseconds: Double

    func makeNSView(context: Context) -> GridShiftControl { GridShiftControl(frame: .zero) }

    func updateNSView(_ button: GridShiftControl, context: Context) {
        button.deck = deck
        button.stepMilliseconds = milliseconds
        let amount = Int(abs(milliseconds))
        button.title = milliseconds < 0 ? "◀│\(amount)" : "\(amount)│▶"
        let description = milliseconds < 0
            ? String(ui: "그리드를 \(amount)ms 왼쪽으로 이동")
            : String(ui: "그리드를 \(amount)ms 오른쪽으로 이동")
        button.setAccessibilityLabel(description)
        button.toolTip = description + " · " + String(ui: "1초 동안 누르면 반복합니다")
        button.isEnabled = context.environment.isEnabled && deck.canEditGrid
        button.controlSize = context.environment.controlSize == .small ? .small : .regular
        let font = NSFont.systemFont(ofSize: 11 * textScale, weight: .semibold)
        button.font = font
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: font,
            .foregroundColor: button.isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GridShiftControl, context: Context) -> CGSize? {
        CGSize(width: max(nsView.intrinsicContentSize.width, 32),
               height: CGFloat(TextScale.length(24, scale: textScale)))
    }

    static func dismantleNSView(_ button: GridShiftControl, coordinator: ()) {
        button.endHold()
        button.target = nil
        button.action = nil
    }
}

final class GridShiftControl: NSButton {
    static let repeatDelay: Float = 1
    static let repeatInterval: Float = 0.075
    weak var deck: DeckModel?
    var stepMilliseconds: Double = 1
    private var isHolding = false
    private var heldTrackUUID: String?
    private var distance: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        target = self
        action = #selector(moveGrid)
        isContinuous = true
        setPeriodicDelay(Self.repeatDelay, interval: Self.repeatInterval)
        sendAction(on: [.leftMouseDown, .periodic])
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        beginHold()
        defer { endHold() }
        super.mouseDown(with: event)
    }

    func beginHold() {
        guard !isHolding, isEnabled, let deck, deck.canEditGrid else { return }
        isHolding = true
        heldTrackUUID = deck.row?.track.uuid
        distance = 0
        // 반복 횟수와 관계없이 누르기부터 떼기까지 한 번의 편집으로 저장한다.
        deck.beginGridDrag()
    }

    func endHold() {
        guard isHolding else { return }
        if deck?.row?.track.uuid == heldTrackUUID { deck?.endGridDrag() }
        isHolding = false
        heldTrackUUID = nil
        distance = 0
    }

    @objc func moveGrid() {
        guard isEnabled, let deck, deck.canEditGrid else { return }
        if isHolding {
            // 곡 전환·쓰기·다시 읽기가 드래그 기준을 지우면 남은 반복도 버린다.
            guard deck.row?.track.uuid == heldTrackUUID, deck.gridDragBase != nil else { return }
            distance += stepMilliseconds / 1000
            deck.dragGrid(by: distance)
        } else {
            // 키보드·VoiceOver의 단일 실행도 기본 버튼과 같은 한 단계다.
            deck.shiftGrid(ms: stepMilliseconds)
        }
    }
}
