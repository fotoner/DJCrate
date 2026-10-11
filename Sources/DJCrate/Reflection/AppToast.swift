import DJCApplication
import DJCDomain
import SwiftUI

/// 창 아래에 잠깐 뜨는 알림. rekordbox 반영이 끝났을 때 결과와 되돌리기를 보여 준다.
struct AppToast: Identifiable, Equatable {
    enum Kind: String, Codable {
        case success, warning, failure

        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .failure: .red
            }
        }
    }

    /// 알림 안의 동작 단추
    enum Action: Equatable {
        /// USB 쓰기가 끝난 뒤 그 볼륨 꺼내기
        case ejectUsb(volumeKey: String)

        var title: String {
            switch self {
            case .ejectUsb: String(ui: "꺼내기")
            }
        }
    }

    let id = UUID()
    var kind: Kind = .success
    var title: String
    var detail: String?
    /// 되돌리기 버튼(이번 쓰기 직전 백업)
    var undoBackup: URL?
    var action: Action?
    /// USB 쓰기 알림(rekordbox 쓰기 결과 보기를 붙이지 않는다)
    var isUsb = false
    /// 아무것도 쓰지 않은 안내(지금은 못 함·할 것 없음). 쓰기 결과가 아니라 결과 보기를 붙이지 않는다(#230)
    var isNotice = false

    /// 결과 보기 단추를 붙일지(rekordbox 쓰기 결과일 때만)
    var showsResult: Bool { !isUsb && !isNotice }

    /// 창 대신 띄우는 안내. 경고는 닫을 때까지 남는다.
    static func notice(_ title: String, _ detail: String?, kind: Kind = .warning, isUsb: Bool = false) -> Self {
        Self(kind: kind, title: title, detail: detail?.isEmpty == true ? nil : detail, isUsb: isUsb, isNotice: true)
    }

    /// 실패·경고는 사용자가 닫을 때까지 남긴다.
    var duration: Double {
        switch kind {
        case .success: undoBackup == nil && action == nil ? 3.5 : 7
        case .warning, .failure: .infinity
        }
    }
    func automaticallyDismisses(voiceOverEnabled: Bool) -> Bool {
        duration.isFinite && !voiceOverEnabled
    }
}

/// 토스트 모양: 둥근 카드, 아이콘 + 제목 + 설명 + (되돌리기) + 닫기. 마우스를 올려 두면 사라지지 않는다.
struct AppToastView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var textScale
    let toast: AppToast
    var onUndo: (() -> Void)?
    var onDetails: (() -> Void)?
    var onAction: (() -> Void)?
    var onClose: () -> Void
    @State private var timer = AppToastTimer()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: toast.kind.icon)
                .font(.scaled(.title2, textScale))
                .imageScale(.large)
                .foregroundStyle(toast.kind.tint)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
            // 카드는 내용 폭에 맞춘다(긴 설명만 이 폭에서 줄을 바꾼다)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.scaled(.body, textScale).weight(.semibold))
                if let detail = toast.detail {
                    Text(detail).font(.scaled(.caption, textScale)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: TextScale.length(420, scale: textScale), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let onDetails { Button(.ui("결과 보기"), action: onDetails).controlSize(ControlSize.small.scaled(textScale)) }
            if let onAction, let action = toast.action {
                Button(action.title, action: onAction).controlSize(ControlSize.small.scaled(textScale))
            }
            if let onUndo, toast.undoBackup != nil {
                Button(.ui("쓰기 전으로 복원"), action: onUndo)
                    .controlSize(ControlSize.small.scaled(textScale))
                    .help(.ui("라이브러리 전체를 이번 쓰기 전으로 복원합니다. rekordbox를 먼저 종료하세요."))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.scaled(.caption, textScale).bold())
                    .frame(minWidth: 20, minHeight: 20)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(.ui("알림 닫기"))
                .help(.ui("알림 닫기"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(toast.kind.tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .selfTestFrame("toast.\(toast.id)")
        .onDisappear { SelfTestFrames.frames.removeValue(forKey: "toast.\(toast.id)") }
        .onHover { timer.hovering = $0 }
        .task(id: toast.id) { await timer.run(toast, close: onClose) }
    }


}

/// rekordbox에 쓰는 동안 창 전체를 덮어 다른 조작을 막는다.
struct WritingOverlay: View {
    let stage: WriteStage
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            WritingStageCard(stage: stage, onCancel: onCancel)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// 쓰기 진행 카드: 단계 문구 + (진행 막대) + 안내 + (취소).
struct WritingStageCard: View {
    @Environment(\.textScale) private var textScale
    let stage: WriteStage
    var onCancel: () -> Void

    var body: some View {
        // 막대가 창 폭을 다 차지하지 않게 문구 폭에 맞추고, 긴 문구만 최대 폭에서 줄을 바꾼다(#122).
        FittingWidthLayout(minWidth: TextScale.length(240, scale: textScale), maxWidth: TextScale.length(400, scale: textScale)) {
            VStack(spacing: 10) {
                if let done = stage.completed, let total = stage.total {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text(verbatim: "\(done)/\(total)").font(.scaled(.caption, textScale).monospacedDigit())
                } else { ProgressView().controlSize(.regular) }
                Text(stage.text).font(.scaled(.body, textScale).weight(.semibold))
                Text(stage.cancellable ? LocalizedStringResource.ui("아직 rekordbox에 쓰지 않았습니다")
                                       : LocalizedStringResource.ui("끝날 때까지 rekordbox를 켜지 마세요"))
                    .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                if stage.cancellable {
                    Button(.ui("취소"), action: onCancel).keyboardShortcut(.cancelAction)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

/// 내용의 한 줄 폭(최소 폭 이상)에 맞추고, 최대 폭을 넘으면 그 폭에서 줄을 바꾼 높이를 쓴다.
/// frame(maxWidth:) + fixedSize는 높이를 한 줄로 재서 줄 바꾼 문구가 잘린다.
private struct FittingWidthLayout: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(max(content.sizeThatFits(.unspecified).width, minWidth), maxWidth, proposal.width ?? .infinity)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 내용이 최소 폭보다 좁으면 왼쪽에 붙어 카드 안에서 치우쳐 보였다(#148). 가운데에 둔다.
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(bounds.size))
    }
}
