import DJCApplication
import DJCDomain
import SwiftUI

/// 템포(변속) · 키 고정 · 큐 제안 표시 · 게인 초안 버리기
struct AudioBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                FlowLayout(spacing: 12, justified: true) {
                    HStack(spacing: 4) {
                        Text(.ui("템포")).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { deck.tempoPercent }, set: { deck.tempoPercent = ($0 * 10).rounded() / 10 }),
                               in: -16...16, neutralValue: 0) {
                            Text(.ui("재생 템포"))
                        } ticks: {
                            SliderTick(-16); SliderTick(-8); SliderTick(0); SliderTick(8); SliderTick(16)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Text(verbatim: deck.tempoPercent.unitText(signed: true) + "%").font(.scaled(.caption, textScale).monospacedDigit())
                            .frame(width: TextScale.length(46, scale: textScale), alignment: .trailing)
                        Button { deck.tempoPercent = 0 } label: { Text(verbatim: "RST") }.help(.ui("원래 속도로"))
                            .accessibilityLabel(.ui("템포 0으로"))
                    }
                    HStack(spacing: 12) {
                        Toggle(.ui("키 고정"), isOn: $deck.keyLock)
                            .toggleStyle(.checkbox)
                            .help(.ui("켜면 음정을 유지한 채 속도만 바꿉니다(마스터 템포). 끄면 바이닐처럼 음정도 함께 바뀝니다."))
                        Toggle(.ui("큐 제안 표시"), isOn: $deck.showSuggestions)
                            .toggleStyle(.checkbox)
                            .help(.ui("큐 제안을 표시합니다. 파형 아래 + 배지를 누르면 메모리 큐로 추가합니다."))
                    }
                }
                .frame(maxWidth: .infinity)
                ShortcutsButton()
            }
            // 게인 제안은 덱 제안 줄에 있다. 초안을 만든 뒤에는 여기서 바로 버릴 수 있다.
            if deck.hasGainOverride {
                Button(.ui("게인 초안 버리기")) { deck.clearGainDraft() }
                    .font(.scaled(.caption, textScale))
                    .help(.ui("이 곡의 게인 초안을 지우고 rekordbox 오토게인으로 돌아갑니다"))
            }
        }
        .controlSize(ControlSize.small.scaled(textScale))
    }
}

/// Q와 같은 크기로 표시하는 메트로놈 아이콘 버튼.
struct MetronomeToggle: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel

    var body: some View {
        let on = deck.metronome
        Button { deck.metronome.toggle() } label: {
            Image(systemName: "metronome")
                .font(.scaled(size: 11, weight: .semibold, textScale))
                .frame(width: TextScale.length(22, scale: textScale), height: TextScale.length(20, scale: textScale))
                .foregroundStyle(on ? UIColors.onFill : UIColors.info.color)
                .background(on ? UIColors.info.color : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UIColors.info.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityLabel(.ui("메트로놈"))
        .accessibilityValue(on ? String(ui: "켜짐") : String(ui: "꺼짐"))
        .help(.ui("그리드의 박마다 클릭 (1박은 높은 음)"))
    }
}

/// 창 상단에서 덱 출력 음량을 조절한다.
struct VolumeControl: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var previewVolume: Double?

    private var shownVolume: Double { previewVolume ?? deck.volume }

    var body: some View {
        HStack(spacing: 4) {
            // 아이콘이 바뀌어도 슬라이더의 자리는 고정한다.
            Group {
                if shownVolume == 0 {
                    Image(systemName: "speaker.slash")
                } else {
                    Image(systemName: "speaker.wave.3", variableValue: shownVolume)
                }
            }
            .frame(width: TextScale.length(22, scale: textScale), height: TextScale.length(20, scale: textScale))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Slider(value: Binding(get: { shownVolume }, set: { value in
                previewVolume = value
                deck.previewVolume(value)
            }), in: 0...1, onEditingChanged: { editing in
                if !editing { saveVolume() }
            })
                .frame(width: TextScale.length(90, scale: textScale))
                .accessibilityLabel(.ui("재생 볼륨"))
                .help(String(ui: "재생 볼륨 \(Int((shownVolume * 100).rounded()))%"))
        }
        .controlSize(ControlSize.small.scaled(textScale))
        .onDisappear { saveVolume() }
    }

    private func saveVolume() {
        guard let previewVolume else { return }
        deck.volume = previewVolume
        self.previewVolume = nil
    }
}

/// 세 줄로 현재 게인·음량을 보여 주고, 누르면 오토게인·트림 설정.
struct GainControl: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var shown = false

    var body: some View {
        let isHot = deck.loudness?.isHot == true
        Button { shown.toggle() } label: {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Text(verbatim: deck.autoGain ? (deck.useRekordboxGain && deck.rekordboxGainDB != nil ? "RB AUTO" : "AUTO") : "GAIN")
                        .font(.system(size: 9 * textScale, weight: .semibold))
                        .foregroundStyle(deck.autoGain ? Color.accentColor : Color.primary)
                    if deck.isGainSuspicious {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8 * textScale))
                            .foregroundStyle(UIColors.warning.color)
                            .help(.ui("rekordbox 오토게인이 DJCrate 측정과 1.5dB 넘게 다릅니다"))
                    }
                }
                Text(verbatim: deck.appliedGain.unitText(signed: true) + " dB")
                    .font(.system(size: 9 * textScale).monospacedDigit())
                if let loudness = deck.loudness, let lufs = loudness.integrated {
                    Text(verbatim: lufs.unitText() + " LUFS")
                    .font(.system(size: 9 * textScale).monospacedDigit())
                    .foregroundStyle(loudness.isHot ? UIColors.warning.color : Color.secondary)
                } else {
                    Text(verbatim: "— LUFS")
                        .font(.system(size: 9 * textScale).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // 경고가 생겨도 위의 수치가 움직이지 않도록 마지막 줄을 늘 확보한다.
                Image(systemName: WarningMark.symbol)
                    .font(.system(size: 10 * textScale))
                    .foregroundStyle(UIColors.warning.color)
                    .frame(height: TextScale.length(12, scale: textScale))
                    .opacity(isHot ? 1 : 0)
                    .accessibilityLabel(.ui("경고"))
                    .accessibilityHidden(!isHot)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(.ui("오토게인·목표 음량·트림을 정합니다. LUFS 느낌표는 과도한 음량이나 클리핑 경고입니다."))
        .popover(isPresented: $shown, arrowEdge: .trailing) { GainSettings(deck: deck).padding(16).frame(width: 340) }
    }
}

struct GainSettings: View {
    @Bindable var deck: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.ui("게인")).font(.headline)
            Toggle(.ui("오토게인"), isOn: $deck.autoGain)
                .help(.ui("곡마다 목표 음량에 맞춥니다"))
            Toggle(.ui("rekordbox 값 사용"), isOn: $deck.useRekordboxGain)
                .disabled(!deck.autoGain)
                .help(.ui("rekordbox 오토게인 값을 씁니다(rekordbox는 약 −10 LUFS에 맞춤)"))
            Picker(.ui("목표 음량"), selection: $deck.gainTarget) {
                ForEach([-14.0, -12, -11, -10, -9, -8], id: \.self) { Text(verbatim: $0.unitText(digits: 0) + " LUFS").tag($0) }
            }
            .disabled(!deck.autoGain)
            Toggle(.ui("피크 보호"), isOn: $deck.peakProtection)
                .disabled(!deck.autoGain)
                .help(.ui("0dBFS를 넘지 않을 만큼만 올립니다"))
            HStack {
                Text(.ui("트림"))
                Slider(value: Binding(get: { deck.gainTrim }, set: { deck.gainTrim = ($0 * 2).rounded() / 2 }),
                       in: -12...12, neutralValue: 0) {
                    Text(.ui("게인 트림"))
                } ticks: {
                    SliderTick(-12); SliderTick(-6); SliderTick(0); SliderTick(6); SliderTick(12)
                }
                .labelsHidden()
                Text(verbatim: deck.gainTrim.unitText(signed: true) + " dB").font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                Button { deck.gainTrim = 0 } label: { Text(verbatim: "0") }
                    .accessibilityLabel(.ui("트림 0 dB로"))
                    .help(.ui("트림을 0 dB로 되돌립니다"))
            }
            Divider()
            if let loudness = deck.loudness {
                VStack(alignment: .leading, spacing: 4) {
                    Text(.ui("이 곡")).font(.subheadline.bold())
                    Text(loudness.integrated.map { String(ui: "음량 \($0, specifier: "%.1f") LUFS · 피크 \(loudness.peak, specifier: "%.1f") dBFS") }
                         ?? String(ui: "음량 — (무음) · 피크 \(loudness.peak, specifier: "%.1f") dBFS"))
                        .help(.ui("통합 음량(BS.1770)과 샘플 피크"))
                    Text(.ui("적용 \(deck.appliedGain, specifier: "%+.1f") dB (오토 \(deck.autoGainDB, specifier: "%+.1f") · 트림 \(deck.gainTrim, specifier: "%+.1f"))"))
                    if let rekordbox = deck.rekordboxGainDB {
                        Text(verbatim: "rekordbox \(rekordbox.unitText(signed: true)) dB" + (deck.measuredGainDB.map { " · DJCrate \($0.unitText(signed: true)) dB" } ?? ""))
                            .help(.ui("rekordbox 오토게인 값과 DJCrate가 잰 음량으로 계산한 값"))
                        HStack(spacing: 6) {
                            Text(.ui("곡 게인"))
                            Button { deck.adjustTrackGain(by: -1) } label: { Text(verbatim: "−1") }
                            Button { deck.adjustTrackGain(by: -0.1) } label: { Text(verbatim: "−0.1") }
                            // 초안 값은 초안 색 하나와 연필 표식으로 보인다(목록·시트·인스펙터와 같다).
                            HStack(spacing: 3) {
                                if deck.gainDraft != nil {
                                    Image(systemName: DraftMark.symbol).accessibilityLabel(DraftMark.spoken)
                                }
                                Text(verbatim: (deck.trackGainDB ?? rekordbox).unitText(signed: true) + " dB")
                            }
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(deck.gainDraft != nil ? UIColors.draft.color : Color.primary)
                            .frame(width: 84)
                            Button { deck.adjustTrackGain(by: 0.1) } label: { Text(verbatim: "+0.1") }
                            Button { deck.adjustTrackGain(by: 1) } label: { Text(verbatim: "+1") }
                            if deck.gainDraft != nil {
                                Button(.ui("게인 초안 버리기")) { deck.clearGainDraft() }
                            }
                        }
                        .controlSize(.small)
                        .help(deck.gainDraft != nil ? String(ui: "rekordbox에 쓰면 이 곡의 오토게인이 초안 값으로 바뀝니다.") : String(ui: "이 곡의 rekordbox 오토게인을 고칩니다(초안)"))
                    } else {
                        Text(.ui("rekordbox 값 없음(분석 전)")).foregroundStyle(.secondary)
                    }
                    if deck.isGainSuspicious, let mismatch = deck.gainMismatchDB {
                        Label(.ui("rekordbox 값이 실제 음량과 \(abs(mismatch), specifier: "%.1f")dB 다름"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color)
                            .help(.ui("파일을 바꿨거나 분석이 오래됐을 수 있습니다. rekordbox에서 다시 분석하거나 DJCrate 값을 쓰세요"))
                    }
                    if loudness.isLoud {
                        Label(.ui("매우 큼(−6 LUFS 초과)"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(UIColors.warning.color)
                            .help(.ui("라이브러리 대부분의 곡보다 세게 들립니다"))
                    }
                    if loudness.clippedRuns > 0 {
                        Label(loudness.isHeavilyClipped ? String(ui: "클리핑 흔적 \(loudness.clippedRuns)곳 · 심함") : String(ui: "클리핑 흔적 \(loudness.clippedRuns)곳"),
                              systemImage: "waveform.path.badge.minus")
                            .foregroundStyle(loudness.isHeavilyClipped ? UIColors.warning.color : Color.secondary)
                            .help(.ui("원본에서 풀스케일에 붙은 구간"))
                    }
                }
                .font(.callout)
            } else {
                Text(deck.row == nil ? String(ui: "곡을 올리면 음량을 잽니다") : String(ui: "음량을 재는 중이거나 잴 수 없는 파일입니다"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// 파형 오른쪽의 세로 레벨 미터(게인 뒤·볼륨 앞, L/R 피크).
/// 아래는 곡을 올린 뒤 최고 피크(0dBFS를 넘은 적이 있으면 빨간 점, 누르면 지움).
struct LevelMeterView: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let meterHeight: Double
    @State private var ballistics = MeterBallistics()

    var body: some View {
        // 재생 틱이 올리는 meterFrame으로 다시 그린다(따로 타이머를 돌리지 않는다).
        let _ = deck.meterFrame
        Group {
            let reading = deck.meter.read()
            let now = ProcessInfo.processInfo.systemUptime
            let state = ballistics.step(reading, now: now, playing: deck.isPlaying)
            let clipping = now - reading.clipTime < 2 || reading.clipCount > 0
            VStack(spacing: 4) {
                Canvas { context, size in draw(context, size: size, state: state) }
                    .frame(width: TextScale.length(12, scale: textScale), height: meterHeight)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 2))
                    .environment(\.colorScheme, .dark)
                    .accessibilityElement()
                    .accessibilityLabel(.ui("레벨 미터"))
                    .modifier(LevelMeterAccessibility(deck: deck))
                // 최고 피크. 0dBFS를 넘은 적이 있으면 빨간 점이 켜진다. 누르면 기록을 지운다.
                Button { deck.meter.resetPeaks() } label: {
                    HStack(spacing: 3) {
                        Circle().fill(UIColors.memory.color).frame(width: 5, height: 5).opacity(clipping ? 1 : 0)
                        Text(verbatim: reading.maxPeak > 0 ? Double(20 * log10(reading.maxPeak)).unitText(signed: true) : "−∞")
                            .font(.system(size: 9 * textScale).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(reading.maxPeak >= 1 ? UIColors.memory.color : reading.maxPeak >= 0.708 ? UIColors.warning.color : Color.secondary)
                    }
                    .frame(width: TextScale.length(52, scale: textScale), height: TextScale.length(18, scale: textScale))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reading.clipCount > 0
                      ? String(ui: "최고 피크(dBFS, 게인 뒤). 0dBFS를 \(reading.clipCount)번 넘었습니다 — 게인을 낮추세요. 누르면 기록을 지웁니다")
                      : String(ui: "곡을 올린 뒤 최고 피크(dBFS, 게인 뒤). 0dBFS를 넘으면 빨간 점이 켜집니다. 누르면 기록을 지웁니다"))
                // 최고 피크는 곡마다 가끔만 바뀐다(값이 바뀔 때만 VoiceOver에 알린다).
                .accessibilityLabel(.ui("최고 피크"))
                .accessibilityValue(reading.maxPeak > 0 ? Double(20 * log10(reading.maxPeak)).unitText(signed: true) + " dB" : String(ui: "없음"))
                .accessibilityHint(.ui("누르면 최고 피크와 클리핑 기록을 지웁니다"))
            }
            .frame(width: TextScale.length(58, scale: textScale))
        }
    }

    private static let floor: Double = -48
    private static let top: Double = 3

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        CGFloat((Self.top - min(max(db, Self.floor), Self.top)) / (Self.top - Self.floor)) * height
    }

    private func draw(_ context: GraphicsContext, size: CGSize, state: MeterBallistics.State) {
        let barWidth = (size.width - 2) / 2
        let zones: [(from: Double, to: Double, color: Color)] = [(-48, -12, Palette.meterLow), (-12, -3, Palette.meterMid), (-3, 3, Palette.meterHigh)]
        for (column, channel) in [state.left, state.right].enumerated() {
            let x = CGFloat(column) * (barWidth + 2)
            context.fill(Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)), with: .color(Palette.well))
            let level = y(channel.level, size.height)
            for zone in zones {
                let bottom = y(zone.from, size.height), top = max(level, y(zone.to, size.height))
                if bottom > top {
                    context.fill(Path(CGRect(x: x, y: top, width: barWidth, height: bottom - top)),
                                 with: .color(zone.color.opacity(0.75)))
                }
            }
            if channel.hold > Self.floor {
                let holdY = y(channel.hold, size.height)
                context.fill(Path(CGRect(x: x, y: holdY - 1, width: barWidth, height: 2)),
                             with: .color(channel.hold >= 0 ? Palette.meterHigh : .white.opacity(0.8)))
            }
        }
        // 0dBFS 눈금
        let zero = y(0, size.height)
        context.fill(Path(CGRect(x: 0, y: zero, width: size.width, height: 1)), with: .color(.white.opacity(0.5)))
    }
}

/// 레벨 미터 VoiceOver 값(지금 피크·클리핑). 미터 그림은 재생 틱(초당 30번)으로 그리지만 값은 `displayTime` 주기(초당 15번)로만 읽는다.
struct LevelMeterAccessibility: ViewModifier {
    let deck: DeckModel

    func body(content: Content) -> some View {
        let _ = deck.displayTime
        content.accessibilityValue(WaveformAccessibility.meterValue(deck.meter.read(), playing: deck.isPlaying,
                                                                    now: ProcessInfo.processInfo.systemUptime))
    }
}

/// 미터 움직임: 오를 땐 바로, 내릴 땐 초당 24dB. 피크 표시는 1.5초 머문 뒤 내려온다.
final class MeterBallistics {
    struct Channel {
        var level: Double = -120
        var hold: Double = -120
        var holdTime: Double = 0
    }

    struct State {
        var left = Channel()
        var right = Channel()
    }

    private var state = State()
    private var last: Double = 0

    func step(_ reading: LevelMeter.Reading, now: Double, playing: Bool) -> State {
        let dt = last == 0 ? 0 : min(max(now - last, 0), 0.5)
        last = now
        // 재생이 멈췄거나 탭이 한동안 오지 않으면 무음으로 본다.
        let fresh = playing && now - reading.time < 0.25
        func db(_ value: Float) -> Double { value > 0 ? 20 * log10(Double(value)) : -120 }
        func update(_ channel: inout Channel, _ peak: Float) {
            let input = fresh ? db(peak) : -120
            channel.level = input >= channel.level ? input : max(input, channel.level - 24 * dt)
            if input >= channel.hold {
                channel.hold = input
                channel.holdTime = now
            } else if now - channel.holdTime > 1.5 {
                channel.hold = max(input, channel.hold - 12 * dt)
            }
        }
        update(&state.left, reading.peak.left)
        update(&state.right, reading.peak.right)
        if !playing { state = State() }
        return state
    }
}

extension Double {
    /// 단위만 붙는 수(dB·LUFS·%) 표시. 번역하지 않고 소수점만 로캘을 따른다. 모양은 `%.1f`·`%+.1f`와 같다.
    fileprivate func unitText(digits: Int = 1, signed: Bool = false) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits)).grouping(.never)
        return formatted(signed ? style.sign(strategy: .always()) : style)
    }
}
