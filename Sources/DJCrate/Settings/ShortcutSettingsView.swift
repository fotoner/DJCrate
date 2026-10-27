import AppKit
import DJCDomain
import SwiftUI

/// 설정 › 단축키: 덱 동작마다 키를 눌러 다시 지정한다. 키는 자리(키 코드)로 기억해 한글 입력기에서도 같다.
/// 키를 누르면 바꾸고, +로 더하고, 마우스를 올려 나오는 ⨯(오른쪽 클릭 메뉴도 된다)로 뺀다. 겹친 키는 경고하고, 목록 위쪽 동작이 받는다.
struct ShortcutSettingsView: View {
    @Bindable var deck: DeckModel
    /// 키를 기다리는 자리: 그 동작의 키 하나를 바꾸거나(`replacing`) 새로 더한다(nil).
    @State private var recording: Recording?
    @State private var message: Message?

    struct Recording: Equatable {
        var action: DeckAction
        var replacing: UInt16?
    }

    struct Message: Equatable {
        var text: String
        var isWarning: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !deck.shortcuts.conflicts.isEmpty {
                    Section { conflictBanner }
                }
                ForEach(DeckAction.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(DeckAction.allCases.filter { $0.group == group }, id: \.self) { action in
                            row(action)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer.padding(12)
        }
        .frame(width: 640, height: 620)
    }

    // MARK: 줄

    private func row(_ action: DeckAction) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(deck.shortcuts.keys(for: action), id: \.self) { key in
                    if recording == Recording(action: action, replacing: key) {
                        recorderChip(for: Recording(action: action, replacing: key))
                    } else {
                        keyChip(key, in: action)
                    }
                }
                // 키가 하나도 없는 동작은 글 대신 빈 칩으로 보인다(옆의 +·되돌리기로 채운다)
                if Self.showsEmptyChip(keys: deck.shortcuts.keys(for: action), recordingNewKey: recording == Recording(action: action, replacing: nil)) {
                    emptyChip(for: action)
                }
                if recording == Recording(action: action, replacing: nil) {
                    recorderChip(for: Recording(action: action, replacing: nil))
                } else {
                    Button { start(Recording(action: action, replacing: nil)) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help(.ui("키 더하기"))
                        .accessibilityLabel(.ui("\(action.title)에 키 더하기"))
                }
                Button { reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(.ui("이 동작만 기본 키로"))
                    .accessibilityLabel(.ui("\(action.title) 기본 키로"))
                    .opacity(deck.shortcuts.isStandard(action) ? 0 : 1)
                    .disabled(deck.shortcuts.isStandard(action))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let shift = action.shiftTitle {
                    Text(shift).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyChip(_ key: UInt16, in action: DeckAction) -> some View {
        let name = KeyLabel.name(for: key)
        return KeyChip(name: name, isConflicting: !deck.shortcuts.otherActions(using: key, besides: action).isEmpty,
                       accessibilityTitle: "\(action.title): \(name)", removeTitle: String(ui: "‘\(name)’ 빼기"),
                       onChange: { start(Recording(action: action, replacing: key)) },
                       onRemove: { remove(key, from: action) })
    }

    private func emptyChip(for action: DeckAction) -> some View {
        Text(.ui("키 없음"))
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3])))
            .accessibilityLabel(Text(verbatim: "\(action.title): \(String(ui: "키 없음"))"))
    }

    private func recorderChip(for target: Recording) -> some View {
        Text(verbatim: Self.recordingChipText)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
            .background(KeyRecorder(onKey: { record($0, $1, for: target) }, onCancel: { cancel(target) }))
    }

    // MARK: 겹침·안내

    private var conflictBanner: some View {
        let lines = deck.shortcuts.conflicts
            .sorted { $0.key < $1.key }
            .map { String(ui: "‘\(KeyLabel.name(for: $0.key))’: \($0.value.map(\.title).joined(separator: ", "))") }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(.ui("겹치는 키가 있습니다. 목록 위쪽 동작만 받습니다.")).bold()
                ForEach(lines, id: \.self) { Text($0).font(.callout) }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(UIColors.warning.color)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let message {
                    Text(message.text)
                        .foregroundStyle(message.isWarning ? UIColors.warning.color : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(.ui("모두 기본값으로")) {
                recording = nil
                message = nil
                deck.shortcuts.resetAll()
            }
            .disabled(deck.shortcuts.isStandard)
        }
    }

    // MARK: 동작

    private func start(_ target: Recording) {
        recording = target
        message = nil
    }

    /// 다른 칸을 눌러 새로 기다리기 시작한 뒤 늦게 온 취소는 무시한다.
    private func cancel(_ target: Recording) {
        guard recording == target else { return }
        recording = nil
        message = nil
    }

    private func record(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, for target: Recording) {
        guard recording == target else { return }
        let name = KeyLabel.name(for: keyCode)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else {
            message = Message(text: String(ui: "⌘·⌃·⌥ 조합은 메뉴 단축키와 겹쳐 쓸 수 없습니다. 키 하나만 누르세요."), isWarning: true)
            return
        }
        var shortcuts = deck.shortcuts
        do {
            if let old = target.replacing {
                try shortcuts.replace(old, with: keyCode, in: target.action)
            } else {
                try shortcuts.add(keyCode, to: target.action)
            }
        } catch {
            // 기록은 이어 가서 다른 키를 바로 누를 수 있게 한다.
            message = Message(text: String(ui: "‘\(name)’ 키는 곡 고르기·칸 나가기에 써서 지정할 수 없습니다. 다른 키를 누르세요."), isWarning: true)
            return
        }
        deck.shortcuts = shortcuts
        recording = nil
        let others = shortcuts.otherActions(using: keyCode, besides: target.action)
        message = others.isEmpty
            ? nil
            : Message(text: Self.conflictMessage(with: others), isWarning: true)
    }

    private func remove(_ key: UInt16, from action: DeckAction) {
        recording = nil
        deck.shortcuts.remove(key, from: action)
        message = nil
    }

    /// 키가 하나도 없는 동작에 '키 없음' 칩을 보일지. 새 키를 기다리는 중이면 그 자리는 키 기록 칩이 차지한다.
    static func showsEmptyChip(keys: [UInt16], recordingNewKey: Bool) -> Bool { keys.isEmpty && !recordingNewKey }

    /// 키를 기다리는 칩의 글. 취소 키는 칩이 말하므로 따로 안내 줄을 두지 않는다.
    static var recordingChipText: String { String(ui: "키를 누르세요 (Esc 취소)") }

    /// 방금 지정한 키가 다른 동작과 겹칠 때. 목록 위쪽 동작이 받는다는 규칙은 위 배너가 말하므로 할 일만 쓴다.
    static func conflictMessage(with others: [DeckAction]) -> String {
        String(ui: "\(quotedTitles(others))에도 지정돼 있습니다. 한쪽을 바꾸세요.")
    }

    /// ‘재생’, ‘핫큐 A’처럼 동작 이름마다 따옴표를 씌운다(따옴표 모양은 언어마다 다르다).
    static func quotedTitles(_ actions: [DeckAction]) -> String {
        actions.map { String(ui: "‘\($0.title)’") }.joined(separator: ", ")
    }

    private func reset(_ action: DeckAction) {
        recording = nil
        message = nil
        deck.shortcuts.reset(action)
    }
}

/// 키 칩 하나. 칩을 누르면 새 키로 바꾸고, 마우스를 올리면 모서리에 ⨯(빼기)가 나온다. 숨은 오른쪽 클릭 제스처는 메뉴로 남겨 둔다.
private struct KeyChip: View {
    let name: String
    let isConflicting: Bool
    let accessibilityTitle: String
    let removeTitle: String
    let onChange: () -> Void
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onChange) {
            HStack(spacing: 3) {
                if isConflicting {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                }
                Text(name)
            }
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(minWidth: 28)
            .foregroundStyle(isConflicting ? UIColors.warning.color : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isConflicting ? UIColors.warning.color : Color.primary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: accessibilityTitle))
        // 겹침을 알리던 툴팁을 없앤 대신 화면 낭독은 값으로 읽는다(보는 사람은 주황 삼각형과 위 배너가 말한다)
        .accessibilityValue(Text(.ui("다른 동작과 겹침")), isEnabled: isConflicting)
        .accessibilityHint(.ui("누른 뒤 새 키를 누르면 바꿉니다"))
        .accessibilityAction(named: Text(removeTitle), onRemove)
        // 빼기 배지가 칩 위·오른쪽 모서리 밖으로 튀어나올 자리. 마우스를 올려 두는 영역에는 들지만(안쪽 여백) 줄 배치는 바꾸지 않는다(바깥 음수 여백).
        // 칩 사이 간격(6pt)보다 좁게(5pt) 잡아 옆 칩의 올려 두는 영역과 겹치지 않는다.
        .padding(.top, 5).padding(.trailing, 5)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                }
                .buttonStyle(.plain)
                .help(removeTitle)
                // 화면 낭독은 위 접근성 동작으로 뺀다. 이 배지는 마우스를 올려야만 나타난다.
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .padding(.top, -5).padding(.trailing, -5)
        .contextMenu {
            Button(removeTitle, action: onRemove)
        }
    }
}
