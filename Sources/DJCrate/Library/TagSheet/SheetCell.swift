import AppKit
import DJCDomain

/// 시트 칸의 초안 표시. 글자색(초안 색)만이 아니라 왼쪽 위 모서리 삼각형과 VoiceOver 값("…, 초안")으로도 알린다.
struct SheetCellAppearance: Equatable {
    enum Tone { case primary, secondary, draft }

    var tone: Tone
    /// 선택해도 남긴다(선택하면 글자색이 기본색으로 바뀌어 색으로는 알 수 없다).
    var showsDraftMark: Bool
    private var speaksDraft: Bool

    init(edited: Bool, readOnly: Bool, selected: Bool, editing: Bool) {
        // 선택한 칸은 선택 배경 위에서 읽히게 기본색으로 쓴다.
        tone = selected && !editing ? .primary : edited ? .draft : readOnly ? .secondary : .primary
        showsDraftMark = edited
        // 입력 중에는 칸 값을 덮지 않는다(입력한 글자를 VoiceOver가 그대로 읽게).
        speaksDraft = edited && !editing
    }

    /// VoiceOver가 읽을 칸 값. nil이면 칸 글자 그대로 읽힌다.
    func accessibilityValue(for text: String) -> String? {
        speaksDraft ? "\(text), \(DraftMark.spoken)" : nil
    }
}

/// 시트 셀: 표시용 라벨 위에 편집할 때만 입력 칸을 띄운다.
final class SheetCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private(set) var editingField: NSTextField?
    /// 초안 칸에만 만든다. 칸마다 뷰가 늘면 스크롤 때 AppKit이 하위 뷰를 모두 훑는 비용이 그만큼 는다(#140).
    private var draftMark: DraftCornerView?
    private var edited = false
    private var readOnly = false
    private var selected = false
    private var active = false
    /// 마지막으로 칠한 색 상태. 같으면 그리기 직전 갱신에서 레이어·글자색을 다시 쓰지 않는다.
    private var paintedState: PaintState?
    /// 칸에 넣은 글자 전체와, 그것이 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "5★", #65), VoiceOver가 읽을 글자(평점 "별 5개").
    /// 보이는 글자는 `label.stringValue`다.
    private var fullText = ""
    private var compactText: String?
    private var spokenText: String?

    private struct PaintState: Equatable {
        var tone: SheetCellAppearance.Tone
        var selected: Bool
        var active: Bool
        var emphasized: Bool
        var appearance: NSAppearance.Name
    }

    /// 초안 모서리 표식이 보이는지(시험용)
    var showsDraftMark: Bool { draftMark?.isHidden == false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.font(scale: 1)
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = false
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 시트 글자(12pt × 글자 배율)
    static func font(scale: Double) -> NSFont {
        .systemFont(ofSize: TextScale.pointSize(12, scale: scale))
    }

    var font: NSFont {
        get { label.font ?? Self.font(scale: 1) }
        set {
            guard label.font != newValue else { return }
            label.font = newValue
            needsLayout = true
        }
    }

    // 제약으로 두면 스크롤로 칸을 다시 쓸 때마다 제약 엔진이 칸마다 풀어 프레임이 밀렸다(#140, 곡 목록은 #137).
    // 글자 칸·초안 표식·입력 칸은 칸 크기로 정해지므로 프레임으로 둔다.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsLayout = true }
    }

    /// 칸 자리에 `fullText`가 들어가면 그대로, 모자라면 `compactText`를 보인다(짧은 글자가 없으면 끝을 줄이는 기본 동작).
    /// 잘린 별("★★★…")이 다른 평점처럼 읽히지 않게, 줄이지 않고 숫자로 바꾼다(곡 목록 평점 칸과 같은 규칙, `FittingText`).
    /// 글자 자리 = 칸 폭 − 양옆 4pt. 칸 폭을 모르는 동안(배치 전)은 전체 글자다.
    @discardableResult
    private func showFittingText() -> Bool {
        let shown = FittingText.choose(full: fullText, compact: compactText, font: label.font,
                                       slot: bounds.width > 0 ? max(0, bounds.width - 8) : nil)
        guard label.stringValue != shown else { return false }
        label.stringValue = shown
        return true
    }

    override func layout() {
        super.layout()
        showFittingText()
        let height = bounds.height
        // 글자 자리(정렬 사각형)는 양옆 4pt 안쪽에서 세로 가운데다. 글자 칸 프레임은 정렬 여백만큼 더 넓다.
        let width = max(0, bounds.width - 8)
        place(label, width: width, cellHeight: height, alignmentHeight: Self.labelAlignmentHeight(of: label))
        if let editingField {
            place(editingField, width: width, cellHeight: height, alignmentHeight: Self.measureAlignmentHeight(of: editingField))
        }
        draftMark?.frame = NSRect(x: 0, y: isFlipped ? 0 : height - 7, width: 7, height: 7)
    }

    private func place(_ view: NSTextField, width: CGFloat, cellHeight: CGFloat, alignmentHeight: CGFloat) {
        let slot = NSRect(x: 4, y: (cellHeight - alignmentHeight) / 2, width: width, height: alignmentHeight)
        view.frame = backingAlignedRect(view.frame(forAlignmentRect: slot), options: .alignAllEdgesNearest)
    }

    /// 글자 칸의 정렬 사각형 높이. 글자 크기마다 한 번만 잰다(칸을 다시 쓸 때마다 재지 않는다).
    private static var labelAlignmentHeights: [NSFont: CGFloat] = [:]

    private static func labelAlignmentHeight(of label: NSTextField) -> CGFloat {
        let font = label.font ?? Self.font(scale: 1)
        if let known = labelAlignmentHeights[font] { return known }
        let height = measureAlignmentHeight(of: label)
        labelAlignmentHeights[font] = height
        return height
    }

    private static func measureAlignmentHeight(of field: NSTextField) -> CGFloat {
        let frameHeight = field.intrinsicContentSize.height
        return field.alignmentRect(forFrame: NSRect(x: 0, y: 0, width: 100, height: frameHeight)).height
    }

    /// - Parameter compact: `text`가 칸 자리에 안 들어갈 때 대신 보일 짧은 글자(평점 "3★"). nil이면 안 들어가도 `text`를 그대로 두고 끝을 줄인다.
    /// - Parameter spoken: VoiceOver가 읽을 글자(평점 별 대신 "별 3개"). nil이면 `text`.
    func configure(text: String, edited: Bool, readOnly: Bool, selected: Bool, active: Bool, compact: String? = nil, spoken: String? = nil) {
        fullText = text
        compactText = compact
        spokenText = spoken
        if showFittingText() { needsLayout = true }
        self.edited = edited
        self.readOnly = readOnly
        self.selected = selected
        self.active = active
        updateAccessibilityValue()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewWillDraw() {
        updateColors()
        super.viewWillDraw()
    }

    private var appearanceState: SheetCellAppearance {
        SheetCellAppearance(edited: edited, readOnly: readOnly, selected: selected, editing: editingField != nil)
    }

    /// 글자 칸의 접근성 요소는 셀(NSTextFieldCell)이라 값도 셀에 둔다. 셀에 nil을 넣으면 기본값으로 돌아가지 않고
    /// 값이 비므로(재사용한 칸을 VoiceOver가 못 읽는다) 초안이 아니어도 글자를 그대로 넣는다.
    private func updateAccessibilityValue() {
        // 칸이 숫자로 줄어도("5★") 읽는 값은 같다
        let words = spokenText ?? fullText
        label.cell?.setAccessibilityValue(appearanceState.accessibilityValue(for: words) ?? words)
    }

    private func showDraftMark(_ visible: Bool) {
        if visible, draftMark == nil {
            let mark = DraftCornerView()
            addSubview(mark)
            draftMark = mark
            needsLayout = true
        }
        if let draftMark, draftMark.isHidden == visible { draftMark.isHidden = !visible }
    }

    private func updateColors() {
        // AppKit이 창·표 포커스가 바뀔 때 다시 그리므로 선택색도 그때 풀어 쓴다.
        let editing = editingField != nil
        let emphasized = window?.isKeyWindow == true && (window?.firstResponder is SheetTableView || editing)
        let appearance = appearanceState
        showDraftMark(appearance.showsDraftMark)
        let state = PaintState(tone: appearance.tone, selected: selected, active: active, emphasized: emphasized,
                               appearance: effectiveAppearance.name)
        guard state != paintedState else { return }
        paintedState = state
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = switch appearance.tone {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            case .draft: UIColors.draft.nsColor
            }
            let selection: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            layer?.backgroundColor = selected ? selection.withAlphaComponent(0.28).cgColor : nil
            layer?.borderWidth = active ? 2 : 0
            layer?.borderColor = UIColors.info.nsColor.cgColor
        }
    }

    func beginEditing(text: String) -> NSTextField {
        // 표의 라벨을 편집 가능으로 바꾸면 AppKit이 제약 갱신을 반복한다. 목록처럼 입력 칸을 따로 둔다.
        let field = NSTextField(string: text)
        field.font = label.font
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(label.accessibilityLabel())
        addSubview(field)
        label.isHidden = true
        editingField = field
        needsLayout = true
        updateAccessibilityValue()
        return field
    }

    func endEditing() {
        editingField?.removeFromSuperview()
        editingField = nil
        label.isHidden = false
        updateAccessibilityValue()
        updateColors()
    }
}
