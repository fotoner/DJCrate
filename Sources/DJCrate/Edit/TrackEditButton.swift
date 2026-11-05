import DJCDomain
import SwiftUI

/// 확대 파형 오른쪽의 세로 단추 한 쌍: 위는 곡 편집 창, 아래는 Flip 기록(누르면 기록, 다시 누르면 마치고 결과 창).
struct TrackEditButton: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.appWindows) private var windows
    let deck: DeckModel
    /// 확대 파형 높이(가장 낮을 때도 두 칸이 들어가게 줄인다)
    let availableHeight: Double

    var body: some View {
        let width = TextScale.length(46, scale: textScale)
        let half = min(TextScale.length(40, scale: textScale), max(28, (availableHeight - 16) / 2))
        VStack(spacing: 0) {
            editHalf.frame(width: width, height: half)
            Rectangle().fill(.white.opacity(0.2)).frame(width: width, height: 1)
            flipHalf.frame(width: width, height: half)
        }
        .background(Palette.well.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.2)))
    }

    private var editHalf: some View {
        Button {
            windows?.trackEdit.startOpen()
        } label: {
            label(symbol: "scissors",
                  title: LocalizedStringResource("deck.editButton", defaultValue: "편집", bundle: UIStrings.bundle))
        }
        .buttonStyle(.plain)
        .disabled(!deck.canOpenTrackEdit)
        .help(deck.trackEditUnavailableReason ?? String(ui: "마디 단위로 잘라 이은 편집본 만들기"))
    }

    private var flipHalf: some View {
        let recording = deck.isFlipRecording
        return Button {
            windows?.flip.toggleRecording()
        } label: {
            label(symbol: recording ? "stop.circle.fill" : "record.circle",
                  title: LocalizedStringResource("deck.flipButton", defaultValue: "Flip", bundle: UIStrings.bundle))
                .background(recording ? Color.red.opacity(0.8) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(deck.flipUnavailableReason != nil)
        .help(deck.flipUnavailableReason ?? String(ui: "핫큐 점프·루프 연주를 편집본으로 기록 (다시 누르면 마침)"))
        .accessibilityLabel(.ui("Flip 기록"))
        .accessibilityValue(recording ? String(ui: "기록 중") : String(ui: "꺼짐"))
        .accessibilityAddTraits(.isToggle)
    }

    private func label(symbol: String, title: LocalizedStringResource) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.scaled(.caption, textScale))
            Text(title)
                .font(.scaled(.caption2, textScale))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
