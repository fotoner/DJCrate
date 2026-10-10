import DJCDomain
import Foundation
import SwiftUI

/// 위쪽 덱: 커버·정보 헤더 / 확대·개요 파형과 컨트롤 | 큐 목록.
/// 높이는 내용에 맞춰 정해지고(잘리지 않음), 파형 높이만 사용자가 조절한다.
/// 커버는 창 폭과 관계없이 위쪽에 두고, 컨트롤 줄은 필요하면 줄바꿈한다.
struct DeckView: View {
    @Environment(\.textScale) private var textScale
    let store: LibraryStore
    @Bindable var deck: DeckModel
    var widthClass: DeckWidthClass

    /// 글자 배율의 절반만큼 넓힌다(큐 이름이 보이게 하되 파형 자리를 너무 빼앗지 않게).
    private var cueListWidth: CGFloat { TextScale.length(widthClass.cueListWidth, scale: 1 + (textScale - 1) / 2) }
    private var leftRailWidth: CGFloat { TextScale.length(66, scale: textScale) }
    private var rightRailWidth: CGFloat { TextScale.length(58, scale: textScale) }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        if let row = deck.row {
            VStack(alignment: .leading, spacing: 8) {
                    DeckInfoHeader(deck: deck, row: row, coverSize: TextScale.length(66, scale: textScale))
                    if !deck.currentDraftSaveFailures.isEmpty {
                        HStack(alignment: .top) {
                            Label(deck.currentDraftSaveFailures.map(\.message).joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(UIColors.warning.color)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button(.ui("다시 저장")) { deck.retryDraftSaves() }
                                .disabled(deck.isWriteLocked)
                        }
                        .font(.scaled(.caption, textScale))
                    }
                    DeckWaveformGroup(store: store, deck: deck, leftRailWidth: leftRailWidth, rightRailWidth: rightRailWidth)
                    VStack(alignment: .leading, spacing: 12) {
                        TransportBar(deck: deck)
                        AudioBar(deck: deck)
                    }
                    .padding(.leading, leftRailWidth + 8)
                    .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
                    GridEditorBar(deck: deck)
                        .padding(.leading, leftRailWidth + 8)
                        .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
                    // 게인·그리드·키 제안을 한 줄에 모은다. 좁으면 줄이 늘어나고, 한 줄일 때 높이는 예전 그리드 제안 줄과 같다.
                    DeckSuggestionBar(tags: store.tags, deck: deck)
                        .frame(maxWidth: .infinity, minHeight: TextScale.length(28, scale: textScale), alignment: .leading)
                        .padding(.leading, leftRailWidth + 8)
                        .padding(.trailing, PerfProbe.hidden.contains("meter") ? 0 : rightRailWidth + 8)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            // 큐 목록 높이는 상태로 다시 재지 않고 가운데 열이 정한 배치에 맞춘다(#138).
            .padding(.trailing, cueListWidth + 16)
            .overlay(alignment: .topTrailing) {
                CueListView(deck: deck)
                    .frame(width: cueListWidth)
                    .frame(maxHeight: .infinity)
            }
            .padding(Spacing.edge)
            // 단축키는 창 전체에서 KeyRouter가 받는다(포커스 위치와 무관).
        } else {
            ContentUnavailableView(.ui("덱에 곡을 불러오세요"), systemImage: "music.note",
                                   description: Text(.ui("아래 목록에서 곡을 더블클릭하거나 여기로 끌어다 놓으면(⌘→도 됩니다) 파형과 큐가 여기 뜹니다.")))
                .frame(height: 220)
        }
    }

}

extension EnvironmentValues {
    /// 창에 맞춘 높이는 파형·레일만 읽어 덱 전체의 본문 갱신을 피한다(#155).
    @Entry var deckWaveformHeight: Double = DeckLayout.defaultWaveformHeight
}

private struct DeckWaveformGroup: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.deckWaveformHeight) private var waveformHeight
    let store: LibraryStore
    let deck: DeckModel
    let leftRailWidth: CGFloat
    let rightRailWidth: CGFloat

    private var waveGroupHeight: Double {
        zoomWaveformHeight + 8 + WaveformMetrics(scale: textScale).overviewHeight
            + TextScale.length(28, scale: textScale)
    }
    /// 조작부의 최소 높이에서 남는 자리를 확대 파형이 채워 빈 띠를 남기지 않는다.
    private var zoomWaveformHeight: Double {
        max(waveformHeight, DeckLayout.minimumZoomWaveformHeight(scale: textScale))
    }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let _ = PerfProbe.recordWaveformHeight(waveformHeight)
        HStack(alignment: .top, spacing: 8) {
            DeckSideControls(store: store, deck: deck, availableHeight: waveGroupHeight)
                .frame(width: leftRailWidth, height: waveGroupHeight)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if PerfProbe.hidden.contains("zoom") {
                        EmptyView()
                    } else {
                        ZoomWaveformView(deck: deck)
                            .overlay(alignment: .leading) {
                                ZoomControl(deck: deck, availableHeight: zoomWaveformHeight).padding(.leading, 8)
                            }
                            .overlay(alignment: .trailing) {
                                TrackEditButton(deck: deck, availableHeight: zoomWaveformHeight).padding(.trailing, 8)
                            }
                    }
                }
                .frame(height: zoomWaveformHeight)
                .selfTestFrame("deck.zoom.\(ObjectIdentifier(deck))")
                .overlay(alignment: .center) { loadingOverlay }
                .overlay(alignment: .top) {
                    if let toast = deck.toast {
                        HStack {
                            Label(toast.text, systemImage: toast.kind.icon)
                                .foregroundStyle(toast.kind.tint)
                                .textSelection(.enabled)
                            Button { deck.toastTask?.cancel(); deck.toast = nil } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(.ui("덱 알림 닫기"))
                        }
                        .font(.scaled(.callout, textScale).weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 22)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: deck.toast)
                .environment(\.colorScheme, .dark)
                VStack(spacing: 0) {
                    Group { if PerfProbe.hidden.contains("overview") { EmptyView() } else { OverviewWaveformView(deck: deck) } }
                        .frame(height: WaveformMetrics(scale: textScale).overviewHeight)
                    GridTempoSegments(deck: deck)
                }
                .background(Palette.well)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if !PerfProbe.hidden.contains("meter") {
                let gainHeight = TextScale.length(60, scale: textScale)
                let meterHeight = min(TextScale.length(170, scale: textScale),
                                      max(TextScale.length(100, scale: textScale), waveGroupHeight - TextScale.length(90, scale: textScale)))
                VStack(spacing: 6) {
                    LevelMeterView(deck: deck, meterHeight: meterHeight)
                    GainControl(deck: deck)
                        .frame(height: gainHeight)
                }
                .frame(width: rightRailWidth, height: waveGroupHeight)
                .background(Palette.controlRail, in: RoundedRectangle(cornerRadius: 6))
                .environment(\.colorScheme, .dark)
            }
        }
        .selfTestFrame("deck.waveGroup.\(ObjectIdentifier(deck))")
    }

    @ViewBuilder private var loadingOverlay: some View {
        if deck.row?.track.isStreaming == true {
            Text(.ui("스트리밍 곡은 파형·재생·분석을 할 수 없습니다")).font(.scaled(.callout, textScale)).foregroundStyle(.secondary)
        } else if let error = deck.waveformError {
            Label(error, systemImage: "exclamationmark.triangle").font(.scaled(.callout, textScale)).foregroundStyle(UIColors.warning.color)
        } else if deck.waveform == nil {
            ProgressView().controlSize(.small)
                .accessibilityLabel(.ui("파형 불러오는 중"))
        }
    }

}

/// 현재 목록의 곡과 재생 위치를 큰 파형 왼쪽에서 조작한다.
private struct DeckSideControls: View {
    @Environment(\.textScale) private var textScale
    let store: LibraryStore
    let deck: DeckModel
    let availableHeight: Double
    @State private var beatStep = 4

    /// 넓은 간격에서 필요한 전체 높이. 조작 높이·여백과 함께 글자 배율을 따른다.
    private var roomyControlsHeight: Double {
        2 * TextScale.length(24, scale: textScale)
            + TextScale.length(26, scale: textScale)
            + 2 * TextScale.length(36, scale: textScale)
            + TextScale.length(20, scale: textScale)
            + TextScale.length(48, scale: textScale)
            + TextScale.length(12, scale: textScale)
            + 4 + 12 + 2 // 고정 간격·바깥쪽 여백과 레이아웃 반올림 여유
    }

    var body: some View {
        let compact = availableHeight < roomyControlsHeight
        VStack(spacing: 0) {
            DeckTrackStepButtons(store: store, deck: deck)
                .padding(.bottom, TextScale.length(compact ? 10 : 20, scale: textScale))
            HStack(spacing: 4) {
                Button { deck.beatJump(beats: -beatStep) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .help(.ui("\(beatStep)박 뒤로 이동"))
                    .accessibilityLabel(.ui("\(beatStep)박 뒤로 이동"))
                Button { deck.beatJump(beats: beatStep) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                    .help(.ui("\(beatStep)박 앞으로 이동"))
                    .accessibilityLabel(.ui("\(beatStep)박 앞으로 이동"))
            }
            .disabled(!deck.canPlay || deck.isWriteLocked)
            .padding(.bottom, 4)
            Menu {
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { beats in
                    Button(.ui("\(beats)박")) { beatStep = beats }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(.ui("\(beatStep)박"))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .frame(width: TextScale.length(54, scale: textScale), height: TextScale.length(26, scale: textScale))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: TextScale.length(54, scale: textScale), height: TextScale.length(26, scale: textScale))
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .help(.ui("한 번 누를 때 이동할 박 수를 고릅니다"))
            .accessibilityLabel(.ui("박 이동량"))
            .padding(.bottom, TextScale.length(compact ? 10 : 48, scale: textScale))
            CueButton(deck: deck)
                .padding(.bottom, TextScale.length(compact ? 6 : 12, scale: textScale))
            DeckPlayButton(deck: deck)
        }
        .font(.scaled(.caption, textScale))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .controlSize(ControlSize.small.scaled(textScale))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Palette.controlRail, in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .dark)
    }
}

/// 현재 목록의 이전·다음 곡. 이웃을 찾을 때마다 표시 목록을 훑으므로 파형 높이를 받는 조작부와 떼어,
/// 목록·덱 곡이 바뀔 때만 다시 찾는다(창 높이를 바꾸는 단계마다 찾지 않게, #155).
private struct DeckTrackStepButtons: View {
    @Environment(\.textScale) private var textScale
    let store: LibraryStore
    let deck: DeckModel

    private func load(_ row: TrackRow?) {
        guard let row else { return }
        store.selection = [row.id]
        store.loadToDeck(row)
    }

    var body: some View {
        let _ = PerfProbe.count("DeckTrackNavigation.adjacentRows")
        let (previous, next) = DeckTrackNavigation.adjacentRows(in: store.displayRows, currentUUID: deck.row?.track.uuid)
        HStack(spacing: 4) {
            Button { load(previous) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
                .disabled(previous == nil || !store.writeLockPolicy.allowsLibraryInteraction)
                .help(.ui("이전 곡"))
                .accessibilityLabel(.ui("이전 곡"))
            Button { load(next) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(24, scale: textScale))
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
                .disabled(next == nil || !store.writeLockPolicy.allowsLibraryInteraction)
                .help(.ui("다음 곡"))
                .accessibilityLabel(.ui("다음 곡"))
        }
    }
}

/// 창 폭과 관계없이 쓰는 한 줄 곡 정보 헤더.
struct DeckInfoHeader: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let row: TrackRow
    let coverSize: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cover
                details.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if !PerfProbe.hidden.contains("label") {
                    DeckHeaderTime(deck: deck)
                    DeckHeaderMetrics(deck: deck)
                }
            }
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    title
                    if !PerfProbe.hidden.contains("label") {
                        HStack(spacing: 8) {
                            DeckHeaderTime(deck: deck)
                            Spacer(minLength: 0)
                            DeckHeaderMetrics(deck: deck)
                        }
                    }
                }
            }
        }
        .frame(height: coverSize)
    }

    private var cover: some View {
        CoverView(image: deck.artwork, size: coverSize * 0.8)
            .frame(width: coverSize, height: coverSize, alignment: .center)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            Text([row.artist, row.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.scaled(.caption, textScale)).foregroundStyle(.secondary).lineLimit(1)
            if !row.comment.isEmpty {
                Text(row.comment).font(.scaled(.caption2, textScale)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var title: some View {
        HStack(spacing: 4) {
            Text(row.title).font(.scaled(.headline, textScale)).lineLimit(1)
            if !row.track.isStreaming, !row.isStaged, let note = analysisNote {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(UIColors.warning.color)
                    .accessibilityLabel(note.title)
                    .help(note.help)
            }
        }
    }

    /// 분석 파일이 없는 곡과 파형 파일이 빠진 곡은 그리드 쓰기 조건이 다르다(곡을 불러올 때 읽은 값).
    private var analysisNote: (title: String, help: String)? { deck.analysisState?.note }
}

/// 재생 틱보다 느린 표시 시각으로 남은 시간·현재 시각만 갱신한다.
/// 글자 자리 크기는 바뀌지 않는 기준 글자(`slot`)가 정한다. 바뀌는 글자를 자리 안에 넣으면 초당 15번 덱 전체
/// (`ScrollView`)가 크기를 다시 재므로(#139), 그 위에 얹어 크기 계산에 끼지 않게 한다.
struct DeckHeaderTime: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let elapsed = max(deck.displayTime, 0)
        let remaining = max(deck.duration - elapsed, 0)
        HStack(spacing: 4) {
            slot("-" + clock(remaining), width: 76, reference: "-00:00.00")
                .foregroundStyle(.primary)
                .help(.ui("남은 시간"))
            slot(clock(elapsed), width: 68, reference: "00:00.00")
                .foregroundStyle(.secondary)
                .help(.ui("재생 위치"))
        }
        .font(.scaled(.callout, textScale).monospacedDigit())
    }

    private func slot(_ text: String, width: Double, reference: String) -> some View {
        Text(verbatim: reference)
            .hidden()
            .frame(width: TextScale.length(width, scale: textScale), alignment: .trailing)
            .overlay(alignment: .trailing) { Text(verbatim: text) }
    }

    private func clock(_ seconds: Double) -> String {
        let hundredths = Int((seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// 현재 조성·실제 재생 BPM과 네 박 진행을 헤더 오른쪽에 고정한다.
private struct DeckHeaderMetrics: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let t = deck.displayTime
        let beat = deck.grid?.position(at: t)?.beat ?? 0
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                if let key = deck.key(at: t) {
                    HStack(spacing: 3) {
                        Circle().fill(UIColors.keyDot(key)).frame(width: 6, height: 6)
                        Text(key).font(.scaled(.caption, textScale).monospacedDigit())
                    }
                    .help(deck.keySegments.count > 1 ? String(ui: "지금 조성(Camelot, 추정). 이 곡은 조성이 바뀝니다") : String(ui: "지금 조성(Camelot)"))
                }
                if let bpm = deck.gridBPM {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: (bpm * deck.rate).formatted(.number.precision(.fractionLength(2)).grouping(.never)))
                            .font(.scaled(.callout, textScale).monospacedDigit().bold())
                        Text(verbatim: "BPM").font(.scaled(.caption2, textScale)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(deck.tempoPercent == 0 ? Color.primary : UIColors.cue.color)
                    .help(deck.tempoPercent == 0 ? String(ui: "지금 BPM(그리드 기준, 변속 곡은 구간마다 바뀝니다)")
                          : String(ui: "지금 BPM · 원래 \(bpm, specifier: "%.2f") BPM, 템포 \(deck.tempoPercent, specifier: "%+.1f")%"))
                }
            }
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { number in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(number == beat ? UIColors.tempo.color
                              : number < beat ? UIColors.tempo.color.opacity(0.45) : Color.secondary.opacity(0.22))
                        .frame(width: TextScale.length(7, scale: textScale), height: TextScale.length(7, scale: textScale))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(.ui("마디.박"))
            .accessibilityValue(deck.grid?.positionText(at: t) ?? "—")
            .help(.ui("마디.박"))
        }
        .frame(width: TextScale.length(112, scale: textScale), alignment: .trailing)
    }
}

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(UIColors.subtleFill)
                    Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 3))
        .accessibilityLabel(.ui("앨범아트"))
    }
}

// MARK: - 트랜스포트
