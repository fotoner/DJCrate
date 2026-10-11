import Foundation

/// 확대 파형 위 눈금 줄의 마디.박 라벨(rekordbox처럼 박은 1부터: 14.1 → 14.2 → 14.3 → 14.4).
/// 자리가 모자라면 글자를 줄이지 않고 라벨 수를 줄인다: 뒷박은 `.2 .3 .4`로 줄였다가 빼고,
/// 첫 박도 마디 폭에 들어가지 않으면 2·4·8·16마디마다만 쓴다.
public enum BeatRulerLabel {
    /// 숫자 한 자의 폭(글자 크기의 0.6배, 10pt에서 6pt)
    public static func charWidth(pointSize: Double) -> Double {
        pointSize * 0.6
    }

    /// 라벨이 차지하는 폭: 글자 + 다음 라벨과의 여백(10pt에서 5pt)
    public static func width(of text: String, charWidth: Double) -> Double {
        Double(text.count) * charWidth + charWidth * 5 / 6
    }

    /// `beat`: 마디 안 박 번호(1~4), `beatWidth`: 한 박의 화면 폭(pt). nil이면 이 박에는 라벨을 쓰지 않는다.
    public static func text(bar: Int, beat: Int, isDownbeat: Bool, beatWidth: Double, charWidth: Double) -> String? {
        let full = "\(bar).\(beat)"
        let fullWidth = width(of: full, charWidth: charWidth)
        if isDownbeat {
            let barWidth = beatWidth * 4
            let stride = barStrides.first { Double($0) * barWidth >= fullWidth } ?? barStrides[barStrides.count - 1]
            return (bar - 1) % stride == 0 ? full : nil
        }
        // 이 마디 첫 박 라벨이 이 박 자리까지 넘어오면 겹치므로 쓰지 않는다.
        guard Double(beat - 1) * beatWidth >= width(of: "\(bar).1", charWidth: charWidth) else { return nil }
        if beatWidth >= fullWidth { return full }
        let short = ".\(beat)"
        return beatWidth >= width(of: short, charWidth: charWidth) ? short : nil
    }

    /// 그리드 편집 중 아래쪽 박 번호(1~4): 첫 박은 늘, 나머지는 박 사이에 들어갈 때만
    public static func showsBeatNumber(isDownbeat: Bool, beatWidth: Double, charWidth: Double) -> Bool {
        isDownbeat || beatWidth >= width(of: "4", charWidth: charWidth)
    }

    private static let barStrides = [1, 2, 4, 8, 16]
}
