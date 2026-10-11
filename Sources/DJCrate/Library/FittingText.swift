import AppKit

/// 칸 자리에 글자가 안 들어가면 끝을 줄여 자르지 않고 대신 보일 짧은 글자로 바꾸는 규칙(평점 "★★★★★" → "5★", #65).
/// 잘린 별("★★★…")은 3·4·5가 같아 보여서다. 곡 목록 칸(`TrackTextCell`)과 태그 시트 칸(`SheetCell`)이 같이 쓴다.
enum FittingText {
    /// - Parameter compact: 안 들어갈 때 대신 보일 글자. nil이면 늘 `full`이다(안 들어가면 칸이 끝을 줄인다).
    /// - Parameter slot: 글자가 들어갈 자리 폭(칸 폭에서 글자 앞뒤 여백을 뺀 것). 칸 폭을 아직 모르면(배치 전) nil이고 `full`이다.
    static func choose(full: String, compact: String?, font: NSFont?, slot: CGFloat?) -> String {
        guard let compact, let slot, let font else { return full }
        return ceil((full as NSString).size(withAttributes: [.font: font]).width) > slot ? compact : full
    }
}
