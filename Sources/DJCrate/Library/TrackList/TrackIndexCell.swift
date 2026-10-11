import AppKit
import DJCDomain

/// # 칸: 목록 순번. 덱에 올린 곡은 번호 대신 스피커로 보인다(재생 중이면 소리 나는 모양, Apple Music처럼, #93).
/// 색만이 아니라 모양으로 알리고, VoiceOver는 번호 대신 '덱에 올린 곡'을 읽는다.
final class TrackIndexCell: NSTableCellView {
    struct DeckState: Equatable {
        var playing: Bool
    }

    let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    /// 보이는 스피커 심볼(시험용). 덱에 올린 곡이 아니면 nil.
    private(set) var deckSymbol: String?
    private var iconPointSize: CGFloat = 0

    var text: String { label.stringValue }
    /// VoiceOver가 읽는 덱 상태(시험용)
    var spokenDeckState: String? { deckSymbol == nil ? nil : icon.accessibilityLabel() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byClipping
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = true
        addSubview(icon)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(number: String, font: NSFont, deck: DeckState?) {
        if label.stringValue != number { label.stringValue = number }
        if label.font != font { label.font = font }
        let symbol = deck.map { $0.playing ? "speaker.wave.2.fill" : "speaker.fill" }
        label.isHidden = symbol != nil
        icon.isHidden = symbol == nil
        if symbol != deckSymbol || iconPointSize != font.pointSize {
            iconPointSize = font.pointSize
            let spoken = deck.map { $0.playing ? String(ui: "덱에 올린 곡, 재생 중") : String(ui: "덱에 올린 곡") }
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: spoken) }?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            icon.setAccessibilityLabel(spoken)
            icon.toolTip = spoken
        }
        deckSymbol = symbol
        updateColor()
    }

    private func updateColor() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
    }
}
