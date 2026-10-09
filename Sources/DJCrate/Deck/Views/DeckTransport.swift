import DJCDomain
import SwiftUI

struct TransportBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 22, justified: true) {
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { slot in
                        HotCuePad(deck: deck, slot: slot)
                    }
                }
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Button { deck.jumpToCue(forward: false) } label: { Image(systemName: "backward.end.fill") }
                            .help(.ui("이전 큐로 (\(deck.shortcuts.keyLabel(for: .previousCue)))")).accessibilityLabel(.ui("이전 큐로"))
                        Button { deck.jumpToCue(forward: true) } label: { Image(systemName: "forward.end.fill") }
                            .help(.ui("다음 큐로 (\(deck.shortcuts.keyLabel(for: .nextCue)))")).accessibilityLabel(.ui("다음 큐로"))
                    }
                    .disabled(!deck.canPlay)
                    Button(.ui("+ 메모리 큐")) {
                        // Shift+클릭 = 이 자리 메모리 큐 지우기
                        if NSEvent.modifierFlags.contains(.shift) { deck.deleteMemoryCue(at: deck.currentTime) } else { deck.addMemoryCue() }
                    }
                    .help(.ui("CUE 위치에 메모리 큐 추가 (\(deck.shortcuts.keyLabel(for: .memoryCue))). Shift를 누르고 누르면 현재 재생 위치의 메모리 큐를 지웁니다"))
                }
                LoopControl(deck: deck)
                HStack(spacing: 6) {
                    MetronomeToggle(deck: deck)
                    PlayQuantizeToggle(deck: deck)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(ControlSize.small.scaled(textScale))
    }
}

/// Q 하나로 큐·루프 등록 스냅과 재생 중 핫큐 점프 퀀타이즈를 함께 켠다.
struct PlayQuantizeToggle: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let on = deck.playQuantize
        // CUE·루프 버튼처럼 켜지면 색이 찬다(핫큐·메모리·루프 색과 겹치지 않는 파랑).
        Button { deck.playQuantize.toggle() } label: {
            Text(verbatim: "Q")
                .font(.scaled(size: 11, weight: .heavy, textScale))
                .frame(width: TextScale.length(22, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(on ? UIColors.onFill : UIColors.info.color)
                .background(on ? UIColors.info.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.info.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .help(.ui("큐·루프를 박에 맞춥니다(Q). 재생 중 핫큐는 다음 박에서 저장 위치로 점프합니다."))
        .accessibilityLabel(.ui("퀀타이즈(Q): 큐·루프 등록과 핫큐 점프"))
        .accessibilityValue(on ? String(ui: "켜짐") : String(ui: "꺼짐"))
    }
}

/// 확대 파형 왼쪽의 세로 확대 막대. 현재 값을 누르면 기존 프리셋을 고를 수 있다.
struct ZoomControl: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let availableHeight: Double

    var body: some View {
        let size = TextScale.length(38, scale: textScale)
        let itemHeight = min(TextScale.length(26, scale: textScale), max(16, (availableHeight - 16) / 3))
        VStack(spacing: 4) {
            Button { deck.zoom(by: 0.8) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: size, height: itemHeight)
            }
            .help(.ui("확대 (\(deck.shortcuts.keyLabel(for: .zoomIn)))"))
            .accessibilityLabel(.ui("파형 확대"))
            Menu {
                ForEach([4.0, 8, 16, 32, 64], id: \.self) { seconds in
                    Button(.ui("\(Int(seconds))초")) { deck.setZoom(seconds) }
                }
            } label: {
                Text(.ui("\(Int(deck.zoomSeconds.rounded()))초")).font(.scaled(.caption, textScale).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: size, height: itemHeight)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(.ui("확대 창 폭. 파형 위에서 휠(세로)로 확대·축소, 가로 스크롤로 이동, 핀치로 확대"))
            Button { deck.zoom(by: 1.25) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: size, height: itemHeight)
            }
            .help(.ui("축소 (\(deck.shortcuts.keyLabel(for: .zoomOut)))"))
            .accessibilityLabel(.ui("파형 축소"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .controlSize(ControlSize.small.scaled(textScale))
        .padding(4)
        .background(Palette.well.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.2)))
    }
}

/// CDJ의 CUE 버튼. 누르는 순간과 떼는 순간을 모두 받아야 해서(미리 듣기) Button 대신 제스처를 쓴다.
struct CueButton: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    @State private var pressed = false

    var body: some View {
        // 재생 중에는 위치를 읽지 않는다(매 프레임 다시 그리지 않게).
        let lit = deck.isCuePreviewing || deck.isAtCue
        Text(verbatim: "CUE")
            .font(.scaled(size: 10, weight: .heavy, textScale))
            .frame(width: TextScale.length(36, scale: textScale), height: TextScale.length(36, scale: textScale))
            .foregroundStyle(lit ? Color.black : Palette.cue)
            .background(lit ? Palette.cue : Color.clear, in: Circle())
            .overlay(Circle().stroke(Palette.cue, lineWidth: 2))
            .opacity(deck.canPlay ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    deck.cueDown()
                }
                .onEnded { _ in
                    pressed = false
                    deck.cueUp()
                })
            .help(.ui("큐로 돌아가 정지합니다(\(deck.shortcuts.keyLabel(for: .cue))). 정지 중: 큐 설정·누르고 미리 듣기. 큐 \(deck.cuePoint.clockText)"))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "CUE"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { deck.cueDown(); deck.cueUp() }
    }
}

/// 왼쪽 덱 조작 열의 재생·일시정지 버튼.
struct DeckPlayButton: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        Button { deck.togglePlay() } label: {
            Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                .font(.scaled(size: 14, weight: .bold, textScale))
                .frame(width: TextScale.length(36, scale: textScale), height: TextScale.length(36, scale: textScale))
                .foregroundStyle(deck.isPlaying ? Color.white : Color.white.opacity(0.75))
                .background(deck.isPlaying ? Palette.hot.opacity(0.25) : Color.clear, in: Circle())
                .overlay(Circle().stroke(Palette.hot, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!deck.canPlay)
        .opacity(deck.canPlay ? 1 : 0.4)
        .help(.ui("재생/일시정지 (\(deck.shortcuts.keyLabel(for: .playPause)))"))
    }
}

struct HotCuePad: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let slot: Int

    var body: some View {
        let cue = deck.hotCue(slot: slot)
        let letter = String(UnicodeScalar(UInt8(65 + slot)))
        let keys = DeckAction.allCases.first { $0.hotCueSlot == slot }.map { deck.shortcuts.keyLabel(for: $0) } ?? String(ui: "미지정")
        let color = cue.map(UIColors.color(for:)) ?? .secondary
        let engaged = cue != nil && cue?.id == deck.engagedLoopID
        let accessibility = deck.hotCueAccessibility(slot: slot)
        Button {
            // Shift+클릭 = 지우기
            if NSEvent.modifierFlags.contains(.shift) { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
        } label: {
            // 루프 핫큐는 글자 옆에 반복 심볼을 같은 글꼴로 붙인다(파형 칩과 같은 표기).
            // 글자는 번역하지 않아 지역화 문자열 보간 대신 나란히 둔다.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: letter)
                if cue?.loop != nil { Image(systemName: "repeat") }
            }
                .font(.scaled(size: 11, weight: .bold, textScale))
                .imageScale(.small)
                .frame(width: TextScale.length(24, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(cue == nil ? Color.secondary : UIColors.onFill)
                .background(cue == nil ? Color.clear : color, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(engaged ? Color.primary : cue == nil ? Color.secondary.opacity(0.5) : color,
                                                                  lineWidth: engaged ? 2 : 1))
        }
        .buttonStyle(.plain)
        .selfTestFrame("hotCue.\(slot)")
        .help((cue == nil ? deck.hotCueCreationUnavailableReason : nil) ?? (cue == nil ? (deck.instantLoop != nil ? String(ui: "핫큐 \(letter) (\(keys)): 지금 루프를 루프 핫큐로 저장") : String(ui: "핫큐 \(letter) (\(keys)): 플레이헤드에 설정"))
              : cue?.loop != nil ? String(ui: "루프 핫큐 \(letter) (\(keys)): 누르면 루프 반복, 반복 중에 다시 누르면 나가기 · Shift+클릭: 지우기")
              : String(ui: "핫큐 \(letter) (\(keys))로 이동 (\(cue!.time.clockText)) · Shift+클릭 또는 Shift와 단축키: 지우기")))
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .contextMenu {
            if cue != nil {
                Button(.ui("플레이헤드로 옮기기")) { deck.moveHotCueToPlayhead(slot: slot) }
                Button(.ui("삭제"), role: .destructive) { if let id = cue?.id { deck.delete(id) } }
            }
        }
    }
}

/// 오토 비트 루프: ½ · LOOP n박 · ×2. 반복 중에 빈 핫큐 칸이나 + 메모리 큐를 누르면 그 루프가 저장된다.
struct LoopControl: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let looping = deck.isLooping
        HStack(spacing: 2) {
            Button { deck.resizeLoop(-1) } label: { Text(verbatim: "½").frame(width: TextScale.length(14, scale: textScale)) }
                .help(.ui("루프 길이 반으로 (\(deck.shortcuts.keyLabel(for: .loopHalve)))")).accessibilityLabel(.ui("루프 길이 반으로"))
            Button { deck.toggleLoop() } label: {
                // 심볼과 글자에 같은 글꼴을 한 번만 주고, 심볼은 작은 크기로 글자 높이에 맞춘다.
                HStack(spacing: 3) {
                    Image(systemName: "repeat").imageScale(.small)
                    Text(deck.loopSizeText).monospacedDigit()
                }
                .font(.scaled(size: 11, weight: .heavy, textScale))
                .frame(width: TextScale.length(44, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(looping ? UIColors.onFill : UIColors.loop.color)
                .background(looping ? UIColors.loop.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.loop.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(deck.canPlay ? 1 : 0.4)
            .help(deck.playbackUnavailableReason ?? (looping ? String(ui: "루프에서 나가기 (\(deck.shortcuts.keyLabel(for: .loop)))")
                  : String(ui: "플레이헤드에서 \(deck.loopSizeText)박 루프 (\(deck.shortcuts.keyLabel(for: .loop))). 반복 중에 빈 핫큐 칸을 누르면 루프 핫큐, + 메모리 큐를 누르면 메모리 루프로 저장")))
            .accessibilityLabel(looping ? String(ui: "루프 나가기") : String(ui: "\(deck.loopSizeText)박 루프"))
            Button { deck.resizeLoop(1) } label: { Text(verbatim: "×2").frame(width: TextScale.length(18, scale: textScale)) }
                .help(.ui("루프 길이 두 배로 (\(deck.shortcuts.keyLabel(for: .loopDouble)))")).accessibilityLabel(.ui("루프 길이 두 배로"))
        }
        .disabled(!deck.canPlay)
    }
}
