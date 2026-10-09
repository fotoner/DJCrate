import AppKit
import DJCDomain

/// 고르기 태그 칸(키·평점·곡 색)의 앱 쪽: 고칠 곡 고르기(곡 행), 곡 색 점, 고르기 메뉴. 값의 규칙은 DJCDomain `TagChoice`.
extension TagChoice {
    /// 고르기에서 고른 값을 초안에 넣을 곡: 그 칸을 고칠 수 없는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡)은 뺀다.
    static func targets(_ key: TagFields.Key, _ rows: [TrackRow]) -> [TrackRow] {
        rows.filter { TrackListTagEditing.unavailableReason($0, key: key) == nil }
    }

    // MARK: 곡 색 표시

    /// rekordbox 곡 색의 화면 색(색 번호별). rekordbox XML 형식 문서의 곡 색(`Colour`) 값과 같은 순서(Pink·Red·Orange·Yellow·Green·Aqua·Blue·Purple)다.
    static func swatch(_ id: String) -> NSColor? {
        let rgb: [String: Int] = ["1": 0xFF007F, "2": 0xFF0000, "3": 0xFFA500, "4": 0xFFFF00, "5": 0x00FF00, "6": 0x25FDE9, "7": 0x0000FF, "8": 0x660099]
        return rgb[id].map { NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    }

    @MainActor private static var swatchImages: [String: NSImage] = [:]

    /// 메뉴·고르기에 넣는 색 점(템플릿이 아니라 색이 그대로 보인다). 테두리를 그어 밝은 색(Yellow)도 흰 바탕에서 보이게 한다.
    @MainActor static func swatchImage(_ id: String, size: CGFloat = 10) -> NSImage? {
        let key = "\(id)|\(size)"
        if let image = swatchImages[key] { return image }
        guard let color = swatch(id) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        swatchImages[key] = image
        return image
    }

    /// 고르기 메뉴. 지금 값에 체크하고(여러 값이면 아무 항목에도), 고를 수 없는 현재 값은 맨 앞에 흐리게 보인다.
    /// - Parameter represented: 항목마다 `representedObject`로 둘 값(고른 값을 받는다)
    @MainActor static func menu(_ key: TagFields.Key, current: (value: String, mixed: Bool), colors: [TrackColor], targetCount: Int,
                                action: Selector, target: AnyObject, represented: (String) -> Any) -> NSMenu {
        let menu = NSMenu(title: key.label)
        menu.autoenablesItems = false
        for option in options(key, current: current.mixed ? "" : current.value, colors: colors) {
            let item = NSMenuItem(title: option.title, action: option.enabled ? action : nil, keyEquivalent: "")
            item.target = target
            item.isEnabled = option.enabled
            if key == .color { item.image = swatchImage(option.value) }
            if key == .rating { item.setAccessibilityLabel(spoken(key, option.value, colors: colors)) }
            if targetCount > 1 { item.toolTip = String(ui: "고른 \(targetCount)곡에 모두 적용합니다") }
            item.representedObject = represented(option.value)
            item.state = !current.mixed && current.value == option.value ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
