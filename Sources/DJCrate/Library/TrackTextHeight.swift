import AppKit

/// 한 줄 글자 칸은 폭이 바뀌어도 같은 글자·글꼴의 높이를 쓴다.
struct TrackTextHeight {
    private var cached: (text: String, font: NSFont?, height: CGFloat)?

    mutating func height(text: String, font: NSFont?, measure: () -> CGFloat) -> CGFloat {
        if let cached, cached.text == text, cached.font == font { return cached.height }
        let height = measure()
        cached = (text, font, height)
        return height
    }

    mutating func invalidate() { cached = nil }
}
