import DJCDomain
import SwiftUI

/// LINK 칸의 장치 그림. SF Symbols에는 CDJ·DJ 믹서 모양이 없어(디스크 드라이브는 하드 디스크처럼 보였다) 선으로 직접 그린다.
/// 플레이어는 위 화면과 가운데 조그 휠, 믹서는 위 노브 줄과 채널 페이더다. 그 밖의 장치는 SF Symbols를 쓴다.
struct LinkDeviceIcon: View {
    let kind: LinkDevice.Kind
    var color: Color = .secondary
    var size: CGFloat = 20

    var body: some View {
        switch kind {
        case .player:
            Canvas { context, canvas in Self.drawPlayer(in: &context, rect: CGRect(origin: .zero, size: canvas), color: color) }
                .frame(width: size, height: size)
        case .mixer:
            Canvas { context, canvas in Self.drawMixer(in: &context, rect: CGRect(origin: .zero, size: canvas), color: color) }
                .frame(width: size, height: size)
        case .rekordbox:
            Image(systemName: "laptopcomputer").font(.system(size: size * 0.7)).foregroundStyle(color)
        case .other:
            Image(systemName: "questionmark.circle").font(.system(size: size * 0.7)).foregroundStyle(color)
        }
    }

    /// CDJ: 세로로 긴 몸체, 위 화면, 그 아래 가운데 조그 휠
    static func drawPlayer(in context: inout GraphicsContext, rect: CGRect, color: Color) {
        let unit = min(rect.width, rect.height) / 20
        let line = max(unit * 1.4, 1)
        let body = CGRect(x: rect.midX - 8 * unit, y: rect.minY + 0.8 * unit, width: 16 * unit, height: 18.4 * unit)
        context.stroke(Path(roundedRect: body, cornerRadius: 2.2 * unit), with: .color(color), lineWidth: line)
        let screen = CGRect(x: body.midX - 4.5 * unit, y: body.minY + 2.4 * unit, width: 9 * unit, height: 2.6 * unit)
        context.fill(Path(roundedRect: screen, cornerRadius: 0.6 * unit), with: .color(color))
        // 실제 CDJ처럼 조그 휠은 몸체 폭의 절반쯤이고 화면 아래에 둔다
        let jogCenter = CGPoint(x: body.midX, y: body.minY + 11.8 * unit)
        let jogRadius = 4 * unit
        context.stroke(Path(ellipseIn: CGRect(x: jogCenter.x - jogRadius, y: jogCenter.y - jogRadius,
                                              width: jogRadius * 2, height: jogRadius * 2)),
                       with: .color(color), lineWidth: line)
        let hub = 1 * unit
        context.fill(Path(ellipseIn: CGRect(x: jogCenter.x - hub, y: jogCenter.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(color))
    }

    /// DJ 믹서: 가로로 넓은 몸체, 위 노브 줄, 채널마다 세로 페이더와 손잡이
    static func drawMixer(in context: inout GraphicsContext, rect: CGRect, color: Color) {
        let unit = min(rect.width, rect.height) / 20
        let line = max(unit * 1.4, 1)
        let body = CGRect(x: rect.midX - 9 * unit, y: rect.minY + 1.5 * unit, width: 18 * unit, height: 17 * unit)
        context.stroke(Path(roundedRect: body, cornerRadius: 2.2 * unit), with: .color(color), lineWidth: line)
        let channels = 3
        let spacing = body.width / CGFloat(channels + 1)
        // 페이더 손잡이 높이를 채널마다 달리해 믹서로 읽히게 한다
        let knobLevels: [CGFloat] = [0.35, 0.7, 0.5]
        for index in 0..<channels {
            let x = body.minX + spacing * CGFloat(index + 1)
            let knob = 1.2 * unit
            context.fill(Path(ellipseIn: CGRect(x: x - knob, y: body.minY + 2.4 * unit, width: knob * 2, height: knob * 2)),
                         with: .color(color))
            let top = body.minY + 6.4 * unit, bottom = body.maxY - 2.2 * unit
            var track = Path()
            track.move(to: CGPoint(x: x, y: top))
            track.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(track, with: .color(color.opacity(0.6)), lineWidth: max(unit * 0.8, 0.8))
            let capY = top + (bottom - top) * knobLevels[index]
            let cap = CGRect(x: x - 1.9 * unit, y: capY - 1 * unit, width: 3.8 * unit, height: 2 * unit)
            context.fill(Path(roundedRect: cap, cornerRadius: 0.5 * unit), with: .color(color))
        }
    }
}
