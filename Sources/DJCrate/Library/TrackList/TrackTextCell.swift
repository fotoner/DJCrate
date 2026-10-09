import AppKit
import DJCDomain

/// 목록 글자 칸. 태그 초안이면 왼쪽 위 모서리 표식과 VoiceOver 값 "…, 초안"을 붙이고(#34),
/// 칸에서 바로 고칠 때(#88)는 목록 글자를 가리고 같은 자리에 입력 칸을 띄운다.
final class TrackTextCell: NSTableCellView {
    let label: NSTextField
    private let draftMark = DraftCornerView()
    private var normalColor = NSColor.labelColor
    /// 심볼만 따로 칠할 색(파일이 없는 곡의 경고 아이콘, #126). nil이면 글자색을 따른다.
    private var symbolColor: NSColor?
    /// 글자 앞 작은 심볼(스트리밍 곡 제목, #121). 쓰는 칸이 드물어 처음 필요할 때 만든다.
    private var icon: NSImageView?
    /// 글자 자리 시작점(심볼이 있으면 그 뒤)
    private var labelLeading: CGFloat = 2
    /// 보이는 글자 앞 심볼 이름·색(시험용)
    private(set) var leadingSymbol: String?
    var symbolTint: NSColor? { icon?.contentTintColor }
    private var iconPointSize: CGFloat = 0
    /// 접근성 값을 한 번이라도 덮었는지. 셀에 nil을 넣으면 기본값으로 돌아가지 않아 그 뒤로는 글자를 계속 넣는다.
    private var speaksCustomValue = false
    private var field: NSTextField?
    private var textHeight = TrackTextHeight()
    /// 칸에 넣은 글자 전체와, 그것이 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "5★", #65). 보이는 글자는 `label.stringValue`다.
    private var fullText = ""
    private var compactText: String?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .alternateSelectedControlTextColor : normalColor
        // 곡 색 점은 템플릿이 아니라 칠하지 않는다(고른 줄에서도 색이 보이게)
        icon?.contentTintColor = swatchShown ? nil : emphasized ? label.textColor : symbolColor ?? label.textColor
        draftMark.color = emphasized ? .alternateSelectedControlTextColor : UIColors.draft.nsColor
    }

    /// 글자 배율에 맞춘 본문·숫자 글꼴(표가 배율이 바뀔 때 한 번 만든다)
    struct Fonts {
        let text: NSFont
        let digits: NSFont
        /// 추정값(추가한 곡의 추정 키)
        let estimated: NSFont

        init(scale: Double) {
            let size = TextScale.pointSize(NSFont.systemFontSize, scale: scale)
            text = NSFont.systemFont(ofSize: size)
            digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            estimated = NSFontManager.shared.convert(text, toHaveTrait: .italicFontMask)
        }
    }

    var fonts = Fonts(scale: 1)

    /// 칸 글자·초안 표식(시험용)
    var text: String { label.stringValue }
    var showsDraftMark: Bool { !draftMark.isHidden }

    init(label: NSTextField = NSTextField(labelWithString: "")) {
        self.label = label
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        draftMark.isHidden = true
        addSubview(draftMark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 제약으로 두면 줄을 다시 채울 때마다(글자가 바뀌면 고유 크기도 바뀐다) 제약 엔진이 칸마다 다시 풀어
    // 목록 전환·스크롤이 무거웠다(#137). 글자 자리·심볼·초안 표식·입력 칸은 칸 크기로 정해지므로 프레임으로 둔다.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textHeight.invalidate()
        needsLayout = true
    }

    /// 칸 자리에 `fullText`가 들어가면 그대로, 모자라면 `compactText`를 보인다(짧은 글자가 없으면 끝을 줄이는 기본 동작).
    /// 잘린 글자("★★★…")가 다른 값처럼 읽히지 않게, 줄이지 않고 숫자로 바꾼다.
    /// 글자 자리 = 칸 폭 − 글자 앞(`labelLeading`) − 뒤 2pt. 칸 폭을 모르는 동안(배치 전)은 전체 글자다.
    @discardableResult
    private func showFittingText() -> Bool {
        let shown = FittingText.choose(full: fullText, compact: compactText, font: label.font,
                                       slot: bounds.width > 0 ? bounds.width - labelLeading - 2 : nil)
        guard label.stringValue != shown else { return false }
        label.stringValue = shown
        return true
    }

    override func layout() {
        super.layout()
        showFittingText()
        let height = bounds.height
        if let icon, !icon.isHidden, let size = icon.image?.size {
            icon.frame = backingAlignedRect(NSRect(x: 2, y: (height - size.height) / 2, width: size.width, height: size.height),
                                            options: .alignAllEdgesNearest)
        }
        // 글자 자리(정렬 사각형)는 양옆 2pt 안쪽에서 세로 가운데다. 글자 칸 프레임은 정렬 여백만큼 더 넓다.
        for text in [label, field].compactMap({ $0 }) {
            // 입력 칸은 편집 중 내용·필드 편집기가 바뀌므로 높이를 계속 직접 잰다.
            let measuredHeight = text === label
                ? textHeight.height(text: text.stringValue, font: text.font) { text.intrinsicContentSize.height }
                : text.intrinsicContentSize.height
            let slot = NSRect(x: labelLeading, y: (height - measuredHeight) / 2,
                              width: max(0, bounds.width - labelLeading - 2), height: measuredHeight)
            let frame = backingAlignedRect(text.frame(forAlignmentRect: slot), options: .alignAllEdgesNearest)
            if text.frame != frame { text.frame = frame }
        }
        draftMark.frame = NSRect(x: 0, y: isFlipped ? 0 : height - 7, width: 7, height: 7)
    }

    /// - Parameter draft: 반영 전 초안 값. 색과 함께 모서리 표식·VoiceOver "초안"으로도 알린다.
    /// - Parameter estimated: DJCrate 추정값. 색과 함께 기울임·툴팁·VoiceOver "추정"으로도 알린다.
    /// - Parameter symbol: 글자 앞 SF 심볼. 칸을 다시 쓸 때마다 부르므로 nil이면 지운다.
    /// - Parameter swatch: 글자 앞 색 점(곡 색, 템플릿이 아닌 그림이라 고른 줄에서도 색이 그대로다). `symbol`보다 먼저 쓴다.
    /// - Parameter spoken: VoiceOver가 읽을 글자(평점 별 대신 "별 3개"). nil이면 보이는 글자.
    /// - Parameter compact: `text`가 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "3★"). nil이면 안 들어가도 `text`를 그대로 두고 끝을 줄인다.
    func set(_ text: String, color: NSColor, digits: Bool = false, draft: Bool = false, estimated: Bool = false,
             symbol: String? = nil, symbolLabel: String? = nil, symbolColor: NSColor? = nil, swatch: NSImage? = nil, spoken: String? = nil,
             compact: String? = nil) {
        if fullText != text || compactText != compact {
            fullText = text
            compactText = compact
            needsLayout = true
        }
        let font = estimated ? fonts.estimated : digits ? fonts.digits : fonts.text
        if label.font != font {
            label.font = font
            needsLayout = true
        }
        if let swatch {
            showSwatch(swatch, label: text)
        } else if symbol != leadingSymbol || (symbol != nil && iconPointSize != font.pointSize) || swatchShown {
            showSymbol(symbol, label: symbolLabel, pointSize: font.pointSize)
        }
        // 글자 앞 심볼·색 점(`labelLeading`)이 정해진 뒤에 자리를 잰다
        if showFittingText() { needsLayout = true }
        normalColor = color
        self.symbolColor = symbolColor
        updateColor()
        if draftMark.isHidden == draft { draftMark.isHidden = !draft }
        let tip = estimated ? String(ui: "DJCrate가 소리로 추정한 키입니다. rekordbox 분석과 다를 수 있습니다") : nil
        if toolTip != tip { toolTip = tip }
        if draft || estimated || speaksCustomValue || spoken != nil {
            let words = spoken ?? text
            let value = draft ? "\(words), \(DraftMark.spoken)" : estimated ? "\(words), \(String(ui: "추정"))" : words
            label.cell?.setAccessibilityValue(value)
            speaksCustomValue = true
        }
    }

    /// 지금 글자 앞에 색 점을 보이는지(시험용)
    private(set) var swatchShown = false

    private func showSwatch(_ image: NSImage, label text: String) {
        leadingSymbol = nil
        swatchShown = true
        if icon == nil {
            let view = NSImageView()
            addSubview(view)
            icon = view
        }
        if icon?.image !== image { icon?.image = image }
        icon?.contentTintColor = nil
        icon?.toolTip = text
        icon?.isHidden = false
        labelLeading = 2 + ceil(image.size.width) + 4
        needsLayout = true
    }

    private func showSymbol(_ name: String?, label text: String?, pointSize: CGFloat) {
        leadingSymbol = name
        swatchShown = false
        iconPointSize = pointSize
        if name != nil, icon == nil {
            let view = NSImageView()
            addSubview(view)
            icon = view
        }
        let image = name.flatMap { Self.symbolImage($0, label: text, pointSize: round(pointSize * 0.85)) }
        icon?.image = image
        icon?.toolTip = image == nil ? nil : text
        icon?.isHidden = image == nil
        labelLeading = 2 + (image.map { ceil($0.size.width) + 3 } ?? 0)
        needsLayout = true
    }

    /// 스크롤로 칸을 다시 쓸 때마다 심볼 이미지를 새로 만들지 않는다.
    private static var symbolImages: [String: NSImage] = [:]

    private static func symbolImage(_ name: String, label: String?, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)|\(label ?? "")|\(pointSize)"
        if let image = symbolImages[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        symbolImages[key] = image
        return image
    }

    /// 칸 자리에 입력 칸을 띄운다(목록 글자는 가린다). 끝나면 `endEditing`으로 걷는다.
    func beginEditing(text: String, placeholder: String?) -> NSTextField {
        endEditing()
        let field = NSTextField(string: text)
        field.font = label.font
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        addSubview(field)
        label.isHidden = true
        self.field = field
        // 입력을 시작하기 전에 글자 자리에 둔다(필드 편집기가 필드 크기로 뜬다).
        needsLayout = true
        layoutSubtreeIfNeeded()
        return field
    }

    func endEditing() {
        textHeight.invalidate()
        field?.removeFromSuperview()
        field = nil
        label.isHidden = false
    }
}
