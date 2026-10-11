import AppKit
import DJCDomain
import SwiftUI

/// 설정 창(⌘,). 값은 덱 모델에 바로 묶여 덱 화면과 함께 바뀌고, 바꾸면 곧바로 저장된다.
/// 새 설정 묶음은 `SettingsTab`과 아래 `TabView`에 함께 더한다.
struct SettingsView: View {
    @Bindable var store: LibraryStore
    @Bindable var deck: DeckModel
    /// 저장 공간 탭의 모델(조립 지점이 캐시 자리·캐시 폴더를 붙여 만든다)
    let storage: () -> StorageSettingsModel
    @State private var tab: SettingsTab

    init(store: LibraryStore, deck: DeckModel, storage: @escaping () -> StorageSettingsModel, tab: SettingsTab = .general) {
        self.store = store
        self.deck = deck
        self.storage = storage
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(.ui("일반"), systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(deck: deck, store: store)
            }
            Tab(.ui("덱"), systemImage: "dial.medium", value: SettingsTab.deck) {
                DeckSettingsView(deck: deck)
            }
            Tab(.ui("단축키"), systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutSettingsView(deck: deck)
            }
            Tab(.ui("파형"), systemImage: "waveform", value: SettingsTab.waveform) {
                Form {
                    Picker(.ui("색 모드"), selection: $deck.waveformColorMode) {
                        ForEach(WaveformColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(.ui("덱의 확대·전체 파형과 곡 목록 미리 보기에 함께 적용합니다."))
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(width: 520, height: 180)
            }
            Tab(.ui("저장 공간"), systemImage: "internaldrive", value: SettingsTab.storage) {
                StorageSettingsView(model: storage())
            }
            Tab(.ui("실험실"), systemImage: "testtube.2", value: SettingsTab.lab) {
                LabSettingsView(store: store)
            }
        }
        .background(SettingsWindow.Tracker())
    }
}

enum SettingsTab: Hashable {
    case general, deck, shortcuts, waveform, storage, lab
}

/// 지금 열린 설정 창. 설정 창도 주 창이 될 수 있어서, KeyRouter가 이 창의 키(단축키 기록 등)를 덱으로 보내지 않게 한다.
@MainActor
enum SettingsWindow {
    static weak var current: NSWindow?

    struct Tracker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { TrackingView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class TrackingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { SettingsWindow.current = window }
            }
        }
    }
}

// MARK: - 일반

struct GeneralSettingsView: View {
    @Bindable var deck: DeckModel
    @Bindable var store: LibraryStore
    @AppStorage(SettingKeys.textScale.name) private var textScale = SettingKeys.textScale.defaultValue
    @AppStorage(SettingKeys.sidebarShowsStatus.name) private var sidebarShowsStatus = SettingKeys.sidebarShowsStatus.defaultValue

    var body: some View {
        Form {
            Section {
                Picker(.ui("글자 크기"), selection: Binding(get: { SettingKeys.textScale.value(from: textScale) }, set: { textScale = $0 })) {
                    ForEach(TextScale.steps, id: \.self) { scale in
                        Text(scale == 1 ? String(ui: "기본(100%)") : "\(Int((scale * 100).rounded()))%").tag(scale)
                    }
                }
            } header: {
                Text(.ui("화면"))
            } footer: {
                Text(.ui("곡 목록·태그 시트·덱·알림의 글자를 키웁니다. 보기 › 글자 크게·작게(⌘+ · ⌘−)로도 바꿀 수 있습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(.ui("현황·스냅샷 보이기"), isOn: $sidebarShowsStatus)
            } header: {
                Text(.ui("사이드바"))
            } footer: {
                Text(.ui("실제 컬렉션·삭제 행·수동 큐 곡 수와 지금 연 스냅샷 파일 이름을 사이드바 맨 아래에 보여 줍니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(.ui("스트리밍 곡 숨기기"), isOn: $store.hideStreaming)
            } header: {
                Text(.ui("곡 목록"))
            } footer: {
                Text(.ui("곡 목록과 곡 수에서 스트리밍 곡을 뺍니다. rekordbox 라이브러리는 바뀌지 않습니다."))
                    .foregroundStyle(.secondary)
            }
            Section(.ui("코멘트")) {
                Picker(.ui("코멘트 프리셋"), selection: $store.commentPreset) {
                    ForEach(CommentPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(.ui("애니송을 고르면 코멘트 분류·필터·현황·형식 검사를 켭니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(.ui("재생을 멈춘 뒤 오디오 엔진 끄기"), selection: $deck.idleSeconds) {
                    ForEach(SettingKeys.idleSecondsChoices, id: \.self) { seconds in
                        Text(Self.durationText(seconds)).tag(seconds)
                    }
                }
            } header: {
                Text(.ui("오디오"))
            } footer: {
                Text(.ui("짧을수록 쉬는 동안 CPU를 덜 쓰고, 길수록 멈춘 뒤 CUE·재생이 바로 소리 납니다."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 묶음 폼은 스크롤 뷰라 내용 높이를 스스로 알리지 않는다. 설정 창 높이를 탭마다 정한다.
        .frame(width: 520, height: 640)
    }

    static func durationText(_ seconds: Double) -> String {
        seconds < 60 ? String(ui: "\(Int(seconds))초") : String(ui: "\(Int(seconds / 60))분")
    }
}

// MARK: - 실험실

/// 아직 rekordbox와 결과를 견주지 않은 실험 기능을 켜고 끄는 곳. 모두 기본으로 꺼 두고, 끄면 그 기능이 없던 때와 똑같이 보인다.
/// 새 실험 기능은 `SettingKeys`에 `lab.` 이름으로 더하고 아래에 구역을 하나 더한다.
struct LabSettingsView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        Form {
            Section {
                Text(.ui("여기 기능은 아직 rekordbox와 결과를 견주지 않았습니다. 기본은 꺼져 있습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(.ui("인텔리전트 재생 목록 보기"), isOn: $store.showSmartPlaylists)
            } header: {
                Text(.ui("재생 목록"))
            } footer: {
                Text(.ui("인텔리전트 재생 목록의 조건을 DJCrate가 계산해 읽기 전용으로 보입니다. rekordbox 화면과 곡이 다를 수 있고, 계산하지 못하는 조건이 있으면 곡을 보이지 않습니다."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}

// MARK: - 덱

struct DeckSettingsView: View {
    @Bindable var deck: DeckModel

    var body: some View {
        Form {
            Section(.ui("재생")) {
                Toggle(.ui("키 고정(템포를 바꿔도 음정 유지)"), isOn: $deck.keyLock)
                Toggle(.ui("퀀타이즈(Q): 큐·루프 등록과 핫큐 점프"), isOn: $deck.playQuantize)
                LabeledContent(.ui("메트로놈 소리 크기")) {
                    HStack {
                        Slider(value: $deck.metronomeVolume, in: 0...1)
                            .frame(width: 180)
                        Text(verbatim: "\(Int((deck.metronomeVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section(.ui("편집")) {
                Toggle(.ui("그리드를 고칠 때 큐도 함께 옮기기(핫큐·메모리 큐·루프)"), isOn: $deck.carryCues)
                Toggle(.ui("메모리 큐 제안 보이기(섹션 경계)"), isOn: $deck.showSuggestions)
            }
            Section(.ui("게인")) {
                Toggle(.ui("오토게인(곡마다 목표 음량에 맞춤)"), isOn: $deck.autoGain)
                Toggle(.ui("rekordbox 값 사용"), isOn: $deck.useRekordboxGain)
                    .disabled(!deck.autoGain)
                Picker(.ui("목표 음량"), selection: $deck.gainTarget) {
                    ForEach(SettingKeys.gainTargetChoices, id: \.self) { Text(String(format: "%.0f LUFS", $0)).tag($0) }
                }
                .disabled(!deck.autoGain)
                Toggle(.ui("피크 보호(0dBFS를 넘지 않을 만큼만 올림)"), isOn: $deck.peakProtection)
                    .disabled(!deck.autoGain)
            }
            Section {
                HStack {
                    Spacer()
                    Button(.ui("기본값으로 되돌리기")) { deck.resetDeckSettings() }
                }
            } footer: {
                Text(.ui("덱에서 바로 만지는 볼륨·확대·트림은 그대로 둡니다."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
    }
}
