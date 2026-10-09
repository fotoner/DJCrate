import DJCDomain
import SwiftUI

struct AppCommandContext {
    var store: LibraryStore
    var deck: DeckModel
    var windows: AppWindows
    var reflection: ReflectionCoordinator
    var showTagEditor: Binding<Bool>
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
                .disabled(context?.store.writeLockPolicy.allowsLibraryInteraction != true)
            Toggle(.ui("태그 시트"), isOn: Binding(get: { sheetMode }, set: { if $0 { sheetMode = true } }))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(context?.store.writeLockPolicy.allowsLibraryInteraction != true)
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
        CommandMenu(.ui("덱")) {
            // 키는 곡 목록·태그 시트가 받는다(글자 입력 중 ⌘→는 커서 이동이라 메뉴에 걸지 않는다).
            let loadTitle = "\(String(ui: "고른 곡 덱에 불러오기"))    ⌘→"
            Button(loadTitle) { context?.store.loadSelectionToDeck() }
                .disabled(context?.store.canLoadSelectionToDeck != true)
            Divider()
            ForEach(DeckAction.Group.allCases, id: \.self) { group in
                if group != .transport { Divider() }
                if group == .hotCues {
                    Menu(group.title) {
                        ForEach(DeckMenuCommand.actions(in: group), id: \.self) { action in
                            Menu(action.title) {
                                deckButton(.action(action))
                                if let slot = action.hotCueSlot {
                                    deckButton(.moveHotCue(slot))
                                    deckButton(.deleteHotCue(slot))
                                }
                            }
                        }
                    }
                } else {
                    ForEach(DeckMenuCommand.actions(in: group), id: \.self) { action in
                        deckButton(.action(action))
                        ForEach(DeckMenuCommand.variants(after: action), id: \.self) { deckButton($0) }
                    }
                }
            }
            Divider()
            Button(.ui("곡 편집…")) { Task { await context?.windows.trackEdit.open() } }
                .disabled(context.map { !$0.deck.canOpenTrackEdit } ?? true)
                .help(context.flatMap { $0.deck.trackEditUnavailableReason } ?? String(ui: "덱에 올린 곡으로 편집 창을 엽니다"))
            Button(context?.deck.isFlipRecording == true ? String(ui: "Flip 기록 마치기…")
                   : context?.deck.hasPendingFlipResult == true ? String(ui: "Flip 다시 기록…") : String(ui: "Flip 기록 시작")) {
                context?.windows.flip.toggleRecording()
            }
            .disabled(context.map { $0.deck.flipUnavailableReason != nil } ?? true)
            .help(context.flatMap { $0.deck.flipUnavailableReason }
                  ?? String(ui: "재생하며 쓴 핫큐 점프·루프만 모아 같은 소리로 재생되는 편집본을 만듭니다. 마치면 결과 창을 엽니다"))
        }
        CommandGroup(replacing: .help) {
            Button(.ui("DJCrate 단축키")) { openWindow(id: "shortcuts") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private var canEditTags: Bool {
        guard let store = context?.store, case .loaded = store.phase else { return false }
        return store.writeLockPolicy.allowsLibraryInteraction
    }

    private func libraryButton(_ action: LibraryMenuAction) -> some View {
        Button(context.map { action.menuTitle(in: $0.store) } ?? action.title) {
            if let context { action.perform(in: context.store, windows: context.windows, reflection: context.reflection) }
        }
        .keyboardShortcut(action.shortcut)
        .disabled(context.map { !action.isEnabled(in: $0.store) } ?? true)
        .help(context.flatMap { action.disabledReason(in: $0.store) } ?? action.title)
    }

    private func deckButton(_ command: DeckMenuCommand) -> some View {
        let keys = command.keyLabel(shortcuts: context?.deck.shortcuts ?? .standard)
        return Button(keys.isEmpty ? command.title : "\(command.title)    \(keys)") {
            if let deck = context?.deck { command.perform(on: deck) }
        }
        // keyboardShortcut를 달면 글자 입력 중에도 메뉴가 덱 키를 가로챈다.
        .disabled(context.map { !command.isEnabled(on: $0.deck) } ?? true)
    }
}
