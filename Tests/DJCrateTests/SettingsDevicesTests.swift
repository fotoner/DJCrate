@testable import DJCrate
import AppKit
import SwiftUI
import Testing

/// 공통 장치: 비활성 이유(`disabled(because:)`)와 ⓘ 팝오버 단추(`InfoPopoverButton`).
/// 설정 창이 처음 쓰고, 다른 화면도 같은 장치를 쓴다.
@MainActor
@Suite("공통 장치 — 비활성 이유·ⓘ 팝오버")
struct SettingsDevicesTests {
    // MARK: 값

    @Test func 이유가_있으면_막고_이유를_툴팁과_접근성_값으로_쓴다() {
        let reason = DisabledReason("개발 빌드에서는 업데이트를 확인하지 않습니다. 배포한 앱에서 확인하세요")
        #expect(reason.isDisabled)
        #expect(reason.help == "개발 빌드에서는 업데이트를 확인하지 않습니다. 배포한 앱에서 확인하세요")
        #expect(reason.accessibilityValue == reason.help)
    }

    @Test func 이유가_없으면_막지_않고_평소_툴팁만_남긴다() {
        let plain = DisabledReason(nil)
        #expect(!plain.isDisabled && plain.help == nil && plain.accessibilityValue == nil)
        let withHelp = DisabledReason(nil, enabledHelp: "큐·루프 등록, 핫큐 점프에 적용")
        #expect(!withHelp.isDisabled)
        #expect(withHelp.help == "큐·루프 등록, 핫큐 점프에 적용")
        #expect(withHelp.accessibilityValue == nil, "막히지 않았으면 접근성 값에 이유를 싣지 않는다")
    }

    @Test func 토글은_이유를_힌트로_알려_켜짐_꺼짐_값을_지킨다() {
        let toggle = DisabledReason("새 버전 자동 확인을 켜면 쓸 수 있습니다", announcedAs: .hint)
        #expect(toggle.isDisabled && toggle.help == "새 버전 자동 확인을 켜면 쓸 수 있습니다")
        #expect(toggle.accessibilityValue == nil, "값(켜짐·꺼짐)을 이유로 덮지 않는다")
        #expect(toggle.accessibilityHint == "새 버전 자동 확인을 켜면 쓸 수 있습니다")
        let button = DisabledReason("이유")
        #expect(button.accessibilityValue == "이유" && button.accessibilityHint == nil)
        #expect(DisabledReason(nil, announcedAs: .hint).accessibilityHint == nil)
    }

    @Test func 막히면_평소_툴팁_대신_이유를_보인다() {
        let reason = DisabledReason("쓰는 중에는 비울 수 없습니다", enabledHelp: "평소 툴팁")
        #expect(reason.help == "쓰는 중에는 비울 수 없습니다")
    }

    @Test func 비었거나_공백뿐인_이유는_이유가_아니다() {
        #expect(!DisabledReason("").isDisabled)
        #expect(!DisabledReason("  \n").isDisabled)
    }

    // MARK: 화면에 걸린 모양

    /// 수정자 안쪽 뷰가 보는 `isEnabled`를 적어 둔다. SwiftUI의 접근성 트리는 시험 프로세스의 NSHostingView에서 열리지 않아
    /// (자식이 비어 있다) 툴팁·접근성 값은 위 값 시험으로 보고, 비활성은 환경으로 본다.
    @MainActor private final class Seen { var enabled: Bool? }

    private struct EnabledProbe: View {
        @Environment(\.isEnabled) private var isEnabled
        let seen: Seen

        var body: some View {
            seen.enabled = isEnabled
            return Color.clear.frame(width: 4, height: 4)
        }
    }

    private func enabled<Content: View>(_ content: (Seen) -> Content) -> Bool? {
        _ = NSApplication.shared
        let seen = Seen()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content(seen))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return seen.enabled
    }

    @Test func 이유를_주면_안쪽_컨트롤이_비활성이다() {
        #expect(enabled { EnabledProbe(seen: $0).disabled(because: "쓰는 중에는 비울 수 없습니다") } == false)
    }

    @Test func 이유가_없으면_안쪽_컨트롤은_켜져_있다() {
        #expect(enabled { EnabledProbe(seen: $0).disabled(because: nil, enabledHelp: "비웁니다") } == true)
    }

    @Test func 다른_이유로_막은_컨트롤은_이유가_없어도_막힌_채다() {
        #expect(enabled { EnabledProbe(seen: $0).disabled(true).disabled(because: nil) } == false)
        #expect(enabled { EnabledProbe(seen: $0).disabled(because: nil).disabled(true) } == false)
    }

    // MARK: ⓘ 팝오버

    @Test func 팝오버_본문은_긴_줄을_접어_정해진_폭_안에_둔다() {
        _ = NSApplication.shared
        let long = String(repeating: "보관 규칙이 길어도 줄을 접습니다. ", count: 12)
        let host = NSHostingView(rootView: InfoPopoverContent(title: "보관 규칙", lines: [long, "둘째 줄"]))
        let size = host.fittingSize
        #expect(size.width <= 301, "폭 \(size.width)")
        #expect(size.height > 120, "긴 줄이 접혀 여러 줄이 된다: 높이 \(size.height)")
    }

    @Test func ⓘ_단추는_글_옆에_둘_작은_아이콘이다() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InfoPopoverButton(label: "스킬이란?", lines: ["설명"]))
        #expect(host.fittingSize.width < 40 && host.fittingSize.height < 40)
    }
}
