import DJCDomain
import SwiftUI

/// 처음 읽기에 실패했을 때(이전 목록이 없을 때)의 화면(#299). 원인마다 제목과 할 일이 다르다.
/// 원인을 가를 수 없는 실패만 [자세히 보기]로 원문 오류를 보인다(`detail`이 있을 때). 개인 경로는 이미 홈 폴더를 `~`로 줄였다.
/// 잎 뷰라 값과 클로저만 받는다(MVVM-3).
struct LibraryReadFailureView: View {
    let title: String
    let guidance: String?
    let detail: String?
    let retry: () -> Void
    @State private var showsDetail = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            if let guidance { Text(guidance) }
            if showsDetail, let detail {
                Text(detail).font(.caption.monospaced()).textSelection(.enabled)
            }
        } actions: {
            Button(.ui("다시 시도"), action: retry)
            if detail != nil {
                Button(showsDetail ? .ui("자세히 숨기기") : .ui("자세히 보기")) { showsDetail.toggle() }
            }
        }
    }
}
