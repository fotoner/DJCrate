import AppKit
import DJCDomain
import SwiftUI

/// 설정 › 단축키: 덱 동작마다 키를 눌러 다시 지정한다. 키는 자리(키 코드)로 기억해 한글 입력기에서도 같다.
/// 키를 누르면 바꾸고, +로 더하고, 오른쪽 클릭으로 뺀다. 겹친 키는 경고하고, 목록 위쪽 동작이 받는다.
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
        let others = deck.shortcuts.otherActions(using: key, besides: action)
        return Button { start(Recording(action: action, replacing: key)) } label: {
            HStack(spacing: 3) {
                if !others.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                }
                Text(KeyLabel.name(for: key))
            }
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(minWidth: 28)
            .foregroundStyle(others.isEmpty ? Color.primary : UIColors.warning.color)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(others.isEmpty ? Color.primary.opacity(0.25) : UIColors.warning.color))
        }
        .buttonStyle(.plain)
        .help(others.isEmpty
              ? String(ui: "누르고 새 키를 누르면 바꿉니다(오른쪽 클릭: 빼기)")
              : String(ui: "\(Self.quotedTitles(others))에도 지정된 키입니다. 목록 위쪽 동작이 받습니다"))
        .contextMenu {
            Button(.ui("‘\(KeyLabel.name(for: key))’ 빼기")) { remove(key, from: action) }
        }
        .accessibilityLabel(Text(verbatim: "\(action.title): \(KeyLabel.name(for: key))"))
        .accessibilityHint(.ui("누른 뒤 새 키를 누르면 바꿉니다"))
    }

    private func recorderChip(for target: Recording) -> some View {
        Text(.ui("키를 누르세요…"))
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
                Text(.ui("Shift는 핫큐·메모리 큐 지우기, 1마디 이동, 이전 제안에 씁니다. Esc는 덱에서 큐 선택을 풉니다(그 뒤 1박 이동 키는 재생 위치를 옮깁니다). ⌘·⌃·⌥ 조합(메뉴·실행 취소 ⌘Z)과 Return·Esc·Tab·↑↓·Home·End·Page Up/Down(곡 고르기·칸 나가기)은 지정할 수 없습니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        message = Message(text: String(ui: "‘\(target.action.title)’에 쓸 키를 누르세요(Esc: 취소)."), isWarning: false)
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
            : Message(text: String(ui: "‘\(name)’ 키는 \(Self.quotedTitles(others))에도 지정돼 있습니다. 목록 위쪽 동작이 받으니 한쪽을 바꾸세요."),
                      isWarning: true)
    }

    private func remove(_ key: UInt16, from action: DeckAction) {
        recording = nil
        deck.shortcuts.remove(key, from: action)
        message = deck.shortcuts.keys(for: action).isEmpty
            ? Message(text: String(ui: "‘\(action.title)’에 키가 없습니다. +로 더하거나 되돌리기를 누르세요."), isWarning: false)
            : nil
    }

    /// ‘재생’, ‘핫큐 A’처럼 동작 이름마다 따옴표를 씌운다(따옴표 모양은 언어마다 다르다).
    private static func quotedTitles(_ actions: [DeckAction]) -> String {
        actions.map { String(ui: "‘\($0.title)’") }.joined(separator: ", ")
    }

    private func reset(_ action: DeckAction) {
        recording = nil
        message = nil
        deck.shortcuts.reset(action)
    }
}
