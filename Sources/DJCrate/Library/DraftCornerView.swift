import AppKit
import DJCDomain
import SwiftUI

/// 초안 칸 왼쪽 위 모서리의 작은 삼각형(엑셀의 칸 표식처럼 글자 자리를 빼앗지 않는다). 태그 시트와 곡 목록 칸이 같이 쓴다.
final class DraftCornerView: NSView {
    /// 곡 목록의 강조된 선택 줄에서는 선택 글자색으로 바꿔 보이게 한다.
    var color = UIColors.draft.nsColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: bounds.width, y: 0))
        path.line(to: NSPoint(x: 0, y: bounds.height))
        path.close()
        color.setFill()
        path.fill()
    }
}

/// 범례용 칸 모양: 시트 칸처럼 테두리 안 왼쪽 위에 초안 삼각형
struct DraftCornerSwatch: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(Color(nsColor: .separatorColor))
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 7, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.closeSubpath()
            }
            .fill(UIColors.draft.color)
        }
        .frame(width: 16, height: 12)
    }
}
