import SwiftUI

/// 주 창 사이드바를 보일지 정한다(#119). 표시 상태는 저장해 다음 실행을 같은 모양으로 시작하고,
/// 넉넉하던 본문이 모자라게 줄어들 때만(인스펙터를 열거나 창·열을 좁힐 때) 저절로 접는다.
struct SidebarVisibility: Equatable {
    /// 마지막으로 잰 본문 폭이 최소 폭 이상이었는지(자동 접기의 기준). 본문을 새로 그린 뒤 아직 재지 않았으면 없다.
    /// 폭 자체를 들고 있으면 창 크기·사이드바·인스펙터가 움직이는 동안 프레임마다 상태가 바뀌어
    /// 주 창 본문·사이드바 목록·메뉴까지 다시 계산했다(#138). 최소 폭을 넘나들 때만 바뀐다.
    private(set) var baselineWide: Bool?

    static func columns(visible: Bool) -> NavigationSplitViewVisibility { visible ? .all : .detailOnly }

    /// 탐색 열만 숨긴 `.detailOnly`가 닫힌 상태다.
    static func isVisible(_ columns: NavigationSplitViewVisibility) -> Bool { columns != .detailOnly }

    /// 본문 폭을 새로 쟀을 때 사이드바를 접어야 하는지.
    /// 본문을 처음 그릴 때는 100pt 같은 임시 폭이 한 번 오므로 첫 측정은 기준으로만 쓰고,
    /// 창 프레임을 복원하기 전의 기본 크기 폭은 기준으로도 쓰지 않는다.
    mutating func shouldCollapse(detailWidth: Double, windowFrameRestored: Bool) -> Bool {
        guard windowFrameRestored, detailWidth > 0 else { return false }
        let wide = detailWidth >= DeckLayout.minimumDetailWidth
        defer { if baselineWide != wide { baselineWide = wide } }
        return baselineWide == true && !wide
    }

    /// 본문(덱·목록)이 사라질 때(새 스냅샷을 읽는 동안 등). 다시 그리면 첫 측정부터 기준을 새로 잡는다.
    mutating func reset() { baselineWide = nil }
}
