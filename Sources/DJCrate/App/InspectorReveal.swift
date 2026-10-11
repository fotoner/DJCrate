import SwiftUI

/// 인스펙터 내용을 그릴지(`ContentView`의 그리기 상태)를 열림 상태에 맞춘다. 닫혀 있어도 SwiftUI가 내용을 계속 계산해
/// 곡을 고를 때마다 덱까지 창 레이아웃을 다시 잡았다(#129). 그래서 열려 있을 때만 그린다.
@MainActor
enum InspectorReveal {
    /// 접히는 애니메이션이 끝날 때까지
    static let hideDelay = Duration.milliseconds(400)

    /// 열면 바로 그리고, 닫으면 접힌 뒤에 지운다(빈 패널이 미끄러지지 않게). 그사이 다시 열면 `.task(id:)`가 이 일을 취소한다.
    static func follow(_ presented: Bool, shown: Binding<Bool>, after delay: Duration = hideDelay) async {
        if presented { shown.wrappedValue = true; return }
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { shown.wrappedValue = false }
    }
}
