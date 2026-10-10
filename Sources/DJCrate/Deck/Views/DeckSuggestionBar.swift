import DJCDomain
import SwiftUI

/// 덱 제안 줄: 덱에 올린 곡의 게인·그리드·키 제안을 칩처럼 나란히 보인다(그리드 편집 막대 아래).
/// 보류 중인 제안만 보이고, 없으면 그리드 상태 안내와 [재분석]만 남는다. 목록 상태(태그 초안·무시한 키 제안)는
/// 이 뷰 안에서만 읽는다: 덱 본문이 읽으면 태그를 고칠 때마다 덱 전체를 다시 계산한다(#129).
struct DeckSuggestionBar: View {
    let tags: TagEditStore
    let deck: DeckModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let suggestions = DeckSuggestions(deck: deck, tags: tags)
        DeckSuggestionBarContent(list: suggestions.list, gridStatus: suggestions.gridStatus, isLocked: suggestions.isLocked,
                                 apply: suggestions.apply, dismiss: suggestions.dismiss,
                                 restore: suggestions.restoreDismissed, reanalyze: deck.reanalyze)
    }
}

/// 제안 줄의 모양. 한 줄에 들어가면 [아이콘] 게인 … [적용] [무시]  그리드 … [적용] [무시]  키 … [적용] [무시] … [다시 보기] [재분석],
/// 모자라면 칩을 통째로 다음 줄로 넘기고, 좁거나 글자 배율이 커서 칩 하나가 칸보다 넓으면 그 칩의 값이 줄을 바꾸고 단추는 그 아래로 간다(덱 폭을 넘지 않는다).
struct DeckSuggestionBarContent: View {
    /// 단추·표식 이름(세 제안 모두 같다). 배치 시험이 다른 언어 길이를 넣어 본다.
    struct Titles {
        var apply = DeckSuggestion.applyTitle
        var dismiss = DeckSuggestion.dismissTitle
        var check = DeckSuggestion.checkTitle
        var restore = DeckSuggestionList.restoreTitle
        var reanalyze = String(ui: "재분석")
    }

    @Environment(\.textScale) private var textScale
    var list: DeckSuggestionList
    var gridStatus: DeckSuggestions.GridStatus?
    var isLocked: Bool
    var titles = Titles()
    var apply: @MainActor (DeckSuggestion.Kind) -> Void = { _ in }
    var dismiss: @MainActor (DeckSuggestion.Kind) -> Void = { _ in }
    var restore: @MainActor () -> Void = {}
    var reanalyze: @MainActor () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 넓으면 한 줄: [재분석]은 오른쪽 끝(예전 그리드 제안 줄과 같은 자리)
            HStack(spacing: 8) {
                if !list.shown.isEmpty { icon }
                ForEach(list.shown) { chip($0) }
                status
                Spacer(minLength: 0)
                restoreButton
                reanalyzeButton
            }
            .lineLimit(1)
            // 모자라면 칩을 통째로 다음 줄로 넘기고, 칸보다 넓은 칩만 안에서 줄을 바꾼다.
            SuggestionFlow(spacing: 8, lineSpacing: 4) {
                if !list.shown.isEmpty { icon }
                ForEach(list.shown) { chip($0) }
                status.fixedSize(horizontal: false, vertical: true)
                restoreButton
                reanalyzeButton
            }
        }
        .font(.scaled(.caption, textScale))
        .controlSize(ControlSize.small.scaled(textScale))
    }

    /// "DJCrate 제안:" 대신 줄 앞에 한 번만 둔다.
    private var icon: some View {
        Image(systemName: "wand.and.stars").foregroundStyle(UIColors.suggestion.color).accessibilityHidden(true)
    }

    /// 제안 하나: 이름 값 (확인 필요) [적용] [무시]. 칸이 이 한 줄보다 좁으면 값이 줄을 바꾸고 단추는 그 아래로 간다.
    private func chip(_ item: DeckSuggestion) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label(item).lineLimit(1)
                checkMark(item)
                buttons(item)
            }
            VStack(alignment: .leading, spacing: 3) {
                label(item).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    checkMark(item)
                    buttons(item)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(UIColors.suggestion.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        // 단추는 따로 누를 수 있게 두고(.combine이 아니다), 묶음에 "게인 제안 +1.7 dB …" 이름을 준다.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.spokenLabel)
    }

    /// 이름은 굵게, 값은 그대로. 한 글로 두어 좁으면 함께 줄을 바꾼다(번역할 문구가 아니라 이미 번역한 두 값이다).
    private func label(_ item: DeckSuggestion) -> some View {
        var title = AttributedString(item.title)
        title.inlinePresentationIntent = .stronglyEmphasized
        return Text(title + AttributedString(" " + item.value))
            .help(item.detail ?? "")
    }

    @ViewBuilder private func checkMark(_ item: DeckSuggestion) -> some View {
        if item.needsCheck {
            // 경고 표식(초안 주황과 모양으로 구분)
            Label(titles.check, systemImage: WarningMark.symbol)
                .font(.scaled(.caption, textScale).bold())
                .foregroundStyle(UIColors.warning.color)
                .help(DeckSuggestion.checkHelp)
        }
    }

    @ViewBuilder private func buttons(_ item: DeckSuggestion) -> some View {
        Button(titles.apply) { apply(item.kind) }
            .help(item.applyHelp)
            .disabled(isLocked)
        Button(titles.dismiss) { dismiss(item.kind) }
            .help(item.dismissHelp)
            .disabled(isLocked)
    }

    @ViewBuilder private var status: some View {
        switch gridStatus {
        case .estimating?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(.ui("rekordbox 그리드가 없습니다 · BPM·박 위치를 추정하는 중…"))
            }
            .foregroundStyle(.secondary)
        case .failed?:
            Text(.ui("rekordbox 그리드가 없고, 분석에 실패해 추정하지 못했습니다.")).foregroundStyle(.secondary)
        case .matches?:
            Label { Text(.ui("DJCrate 추정과 지금 그리드가 사실상 같습니다")) } icon: { Image(systemName: "checkmark.seal") }
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var restoreButton: some View {
        if list.canRestore {
            Button(titles.restore) { restore() }
                .buttonStyle(.link)
                .help(DeckSuggestionList.restoreHelp)
                .disabled(isLocked)
        }
    }

    private var reanalyzeButton: some View {
        Button { reanalyze() } label: {
            Label(titles.reanalyze, systemImage: "arrow.triangle.2.circlepath")
        }
        .help(.ui("이 곡의 섹션·그리드 추정·조성 분석 캐시를 지우고 다시 분석합니다(파형·초안은 그대로)"))
        .accessibilityLabel(titles.reanalyze)
    }
}

/// 제안 줄의 칩 흐름: 칩은 자연 크기로 줄을 채우고 모자라면 통째로 다음 줄로 간다. 칸보다 넓은 칩만 칸 폭을 받아
/// 안에서 줄을 바꾼다(`FlowLayout`은 칩을 줄이지 않아 칸보다 넓은 칩이 넘친다). 자연 크기는 캐시에 재 둔다(#138).
struct SuggestionFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    /// 칸보다 넓은 칩만 칸 폭으로 다시 잰다.
    private func sizes(_ subviews: Subviews, cache: [CGSize], width: CGFloat) -> [CGSize] {
        zip(subviews, cache).map { view, ideal in
            ideal.width > width ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
    }

    /// 줄마다 (칩 범위, 줄 높이)
    private func lines(_ sizes: [CGSize], width: CGFloat) -> [(range: Range<Int>, height: CGFloat)] {
        var result: [(range: Range<Int>, height: CGFloat)] = []
        var start = 0, x: CGFloat = 0, height: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if index > start, x + spacing + size.width > width {
                result.append((start..<index, height))
                start = index; x = 0; height = 0
            }
            x += (index > start ? spacing : 0) + size.width
            height = max(height, size.height)
        }
        if start < sizes.count { result.append((start..<sizes.count, height)) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = sizes(subviews, cache: cache, width: width)
        let lines = lines(sizes, width: width)
        let widest = lines.map { line in
            line.range.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(line.range.count - 1, 0))
        }.max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        let sizes = sizes(subviews, cache: cache, width: bounds.width)
        var y = bounds.minY
        for line in lines(sizes, width: bounds.width) {
            var x = bounds.minX
            for index in line.range {
                let size = sizes[index]
                // 한 줄 안에서는 세로 가운데에 맞춘다(아이콘·단추·칩 높이가 다르다).
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
