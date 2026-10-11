import Foundation

// 편집 화면이 쓰는 규칙: 출력 마디 수. 고르기·자르기·옮기기는 `EditTimeline.swift`, 재생 예약표는 `EditPlayback.swift`.

public extension TrackEdit {
    /// 출력 마디 수. 곡 머리(0마디)는 세지 않고, 끝에서 잘린 마지막 마디는 한 마디로 센다.
    var barCount: Int { pieces.reduce(0) { $0 + $1.bars.last - max($1.bars.first, 1) + 1 } }
}
