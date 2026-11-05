@testable import DJCrate
import AppKit
import SwiftUI
import Testing

/// 창 알림 카드는 내용 폭에 맞추되, 긴 글은 정한 폭에서 줄을 바꾸고 그만큼 카드가 높아진다(#307 캡처에서 나옴)
@MainActor
@Suite("창 알림 카드 크기")
struct AppToastLayoutTests {
    static let title = "라이브러리 XML을 내보냈습니다: library.xml · 곡 12 · 큐·루프 12 · 재생 목록 2"
    static let detail = "뺀 것: 스트리밍 곡 1 · 인텔리전트 목록 1 · XML로 옮길 수 없는 큐 0 · 뺀 곡을 가리킨 목록 항목 1 · 상위 폴더가 없는 목록 0\n쓰지 않은 초안은 넣지 않았습니다(rekordbox에 있는 그대로입니다)"

    @Test func 긴_글은_정한_폭에서_줄을_바꾸고_카드가_그만큼_높아진다() {
        let card = NSHostingView(rootView: AppToastView(toast: AppToast(kind: .success, title: Self.title, detail: Self.detail), onClose: {}))
            .fittingSize
        // 같은 글을 정한 폭(420pt)에서 줄을 바꿔 잰 높이. 카드는 위아래 여백(12+12)을 더해 이보다 낮을 수 없다
        let text = NSHostingView(rootView: VStack(alignment: .leading, spacing: 2) {
            Text(Self.title).font(.body.weight(.semibold))
            Text(Self.detail).font(.caption)
        }.frame(width: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)).fittingSize
        #expect(card.height >= text.height + 24, "카드 \(card) 글 \(text)")
    }

    @Test func 짧은_글은_내용_폭에_맞춘다() {
        let short = NSHostingView(rootView: AppToastView(toast: AppToast(kind: .success, title: "썼습니다"), onClose: {})).fittingSize
        let long = NSHostingView(rootView: AppToastView(toast: AppToast(kind: .success, title: Self.title, detail: Self.detail), onClose: {}))
            .fittingSize
        #expect(short.width < long.width && short.width < 300, "짧은 \(short) 긴 \(long)")
    }
}
