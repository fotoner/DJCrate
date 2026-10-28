import DJCDomain
import SwiftUI

struct AppCommandContext {
    /// 주 창 화면 모델. 파일·rekordbox 메뉴 항목(`LibraryMenuAction`)은 이 모델로 보고 부른다
    var window: LibraryWindowModel
    var windows: AppWindows
    var reflection: ReflectionCoordinator
    var showTagEditor: Binding<Bool>

    var store: LibraryStore { window.store }
}

private struct AppCommandContextKey: FocusedValueKey {
    typealias Value = AppCommandContext
}

/// 파형 높이 메뉴. 본문(`LibraryDetail`)이 잰 크기에서 나오므로 `AppCommandContext`와 따로 싣는다(주 창이 그 값을 읽지 않게, #138).
private struct WaveformHeightKey: FocusedValueKey {
    typealias Value = WaveformHeightMenu
}

extension FocusedValues {
    var appCommands: AppCommandContext? {
        get { self[AppCommandContextKey.self] }
        set { self[AppCommandContextKey.self] = newValue }
    }

    var waveformHeight: WaveformHeightMenu? {
        get { self[WaveformHeightKey.self] }
        set { self[WaveformHeightKey.self] = newValue }
    }
}

/// 글자 크기 메뉴. 메뉴 전체(`AppCommands`)가 글자 배율을 `@AppStorage`로 읽으면, 이름에 점이 든 설정이라
/// 창 크기를 바꾸는 동안 창 프레임이 저장될 때마다 메뉴 막대 전체를 다시 만들었다(#138). 여기서만 읽는다.
private struct TextScaleCommands: View {
    var body: some View {
        // macOS는 Dynamic Type이 없어 앱 안에서 글자를 키운다(곡 목록·태그 시트·덱·알림).
        // ⌘+는 Shift 없이 누른 ⌘=로도 온다(KeyRouter가 바꿔 넣는다).
        let setting = SharedSettings.textScale
        let scale = setting.value
        Button(.ui("글자 크게")) { setting.value = TextScale.stepped(scale, by: 1) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!TextScale.canStep(scale, by: 1))
        Button(.ui("글자 작게")) { setting.value = TextScale.stepped(scale, by: -1) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!TextScale.canStep(scale, by: -1))
        Button(.ui("기본 글자 크기")) { setting.value = SettingKeys.textScale.defaultValue }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(scale == SettingKeys.textScale.defaultValue)
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.appCommands) private var context
    @FocusedValue(\.waveformHeight) private var waveformHeight
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingKeys.sheetMode.name) private var sheetMode = SettingKeys.sheetMode.defaultValue

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            ForEach(LibraryMenuAction.fileActions, id: \.self) { libraryButton($0) }
        }
        CommandGroup(before: .sidebar) {
            Toggle(.ui("목록"), isOn: Binding(get: { !sheetMode }, set: { if $0 { sheetMode = false } }))
                .keyboardShortcut("1", modifiers: .command)
                .disabled(context?.store.editsFrozen != false)
            Toggle(.ui("태그 시트"), isOn: Binding(get: { sheetMode }, set: { if $0 { sheetMode = true } }))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(context?.store.editsFrozen != false)
            Divider()
            Toggle(.ui("태그 편집"), isOn: context?.showTagEditor ?? .constant(false))
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!canEditTags)
            Divider()
            // 덱·목록 사이 핸들을 끌지 않고 키보드·VoiceOver로 파형 높이를 바꾼다.
            Button(.ui("파형 크게")) { waveformHeight?.grow() }
                .disabled(waveformHeight?.canGrow != true)
            Button(.ui("파형 작게")) { waveformHeight?.shrink() }
                .disabled(waveformHeight?.canShrink != true)
            Divider()
            TextScaleCommands()
        }
        CommandMenu(Text(verbatim: "rekordbox")) {
            ForEach(LibraryMenuAction.rekordboxActions, id: \.self) { libraryButton($0) }
        }
        CommandMenu(.ui("재생 목록")) { PlaylistCommands(store: context?.store, reflection: context?.reflection) }
        CommandGroup(replacing: .help) {
            Button(.ui("DJCrate 단축키")) { openWindow(id: "shortcuts") }
                .keyboardShortcut("?", modifiers: .command)
            Divider()
            ForEach(LibraryMenuAction.helpActions, id: \.self) { libraryButton($0) }
        }
    }

    private var canEditTags: Bool {
        guard let store = context?.store, case .loaded = store.phase else { return false }
        return !store.editsFrozen
    }

    private func libraryButton(_ action: LibraryMenuAction) -> some View {
        Button(context.map { action.menuTitle(in: $0.window) } ?? action.title) {
            if let context { action.perform(in: context.window, windows: context.windows, reflection: context.reflection) }
        }
        .keyboardShortcut(action.shortcut)
        .disabled(context.map { !action.isEnabled(in: $0.window) } ?? true)
        .help(context.flatMap { action.disabledReason(in: $0.window) } ?? action.title)
    }
}
