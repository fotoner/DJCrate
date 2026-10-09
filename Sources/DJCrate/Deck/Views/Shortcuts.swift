import DJCDomain
import SwiftUI
import AppKit

/// 도움말 메뉴와 같은 단축키 창을 연다.
struct ShortcutsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HelpLink { openWindow(id: "shortcuts") }
            .help(.ui("단축키"))
            .accessibilityLabel(.ui("단축키 보기"))
    }
}

/// 단축키 목록. 설정에서 바꿨으면 바꾼 표를 동작마다 보인다.
/// 글자는 텍스트 스타일에 앱 글자 배율(보기 › 글자 크게·작게)을 곱하고, 간격도 같은 배율을 따른다.
struct ShortcutsList: View {
    @Environment(\.textScale) private var scale
    var shortcuts = DeckShortcuts.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text(.ui("단축키")).font(.scaled(.title2, scale).bold())
            Grid(alignment: .leading, horizontalSpacing: 18 * scale, verticalSpacing: 9 * scale) {
                if shortcuts.isStandard { standardRows } else { customRows }
                row([String(ui: "더블클릭"), "/", "⌘", "→"], String(ui: "곡 목록·태그 시트: 고른 곡 덱에 불러오기 (덱으로 끌어다 놓아도 됨)"))
                row(["Return"], String(ui: "곡 목록: 고른 곡의 태그 칸 고치기 (고른 줄의 칸을 한 번 더 눌러도 됨, 키 칸은 누른 뒤 Return·더블클릭으로 메뉴)"))
                row(["⇧", "⌘", "E"], String(ui: "rekordbox에 쓰기"))
                row(["⌘", "I"], String(ui: "태그 편집"))
                row(["⌘", "O"], String(ui: "곡 추가"))
                row(["⌘", "R"], String(ui: "rekordbox와 동기화"))
                row(["⌘", "N", "/", "⇧", "⌘", "N"], String(ui: "새 재생 목록 · 새 폴더"))
                row(["⇧", "⌘", "P"], String(ui: "마지막에 쓴 목록에 넣기"))
                row(["⌥", "⌘", "P"], String(ui: "재생 목록에 넣기…"))
                row(["⌫"], String(ui: "재생 목록을 볼 때: 이 목록에서 빼기"))
                row(["⌘", "1", "/", "2"], String(ui: "목록 · 태그 시트"))
                // '+'는 구분 기호로 쓰여서 이 줄은 키캡을 직접 놓는다.
                GridRow {
                    HStack(spacing: 4 * scale) { keycap("⌘"); keycap("+"); separator("/"); keycap("⌘"); keycap("−") }
                    description(String(ui: "글자 크게 · 작게 (⌘0: 기본 크기)"))
                }
                row(["⌘", "?"], String(ui: "단축키 창"))
            }
            Text(.ui("덱 단축키는 설정(⌘,) › 단축키에서 바꿀 수 있습니다."))
                .font(.scaled(.callout, scale))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var standardRows: some View {
        row(["Space"], String(ui: "재생 / 정지"))
        row(["C"], String(ui: "CUE — 재생 중: 큐로 돌아가 정지 · 멈춤: 큐 지점 설정 · 누르고 있기: 미리 듣기"))
        row(["1", "~", "8"], String(ui: "핫큐 A~H (있으면 이동, 없으면 찍기)"))
        row(["Shift", "+", "1", "~", "8"], String(ui: "그 핫큐 지우기"))
        row(["`", "·", "M"], String(ui: "메모리 큐 찍기 (파형 더블클릭도)"))
        row(["Shift", "+", "`", "·", "M"], String(ui: "이 자리 메모리 큐 지우기"))
        row(["Q", "/", "E"], String(ui: "이전 · 다음 큐로"))
        row(["←", "→"], String(ui: "1박 이동 — 선택한 큐가 있으면 그 큐, 없으면 재생 위치"))
        row(["Shift", "+", "←", "→"], String(ui: "1마디 이동 (선택한 큐 또는 재생 위치)"))
        row(["Esc"], String(ui: "큐 선택 풀기 (그 뒤 ←→는 재생 위치를 옮김)"))
        row(["⌫"], String(ui: "선택한 큐 지우기"))
        row(["S"], String(ui: "다음 제안으로 (Shift: 이전 제안으로)"))
        row(["A"], String(ui: "재생 위치에서 가장 가까운 제안을 메모리 큐로 받기"))
        row(["L"], String(ui: "루프 걸기 · 나가기 (반복 중 빈 핫큐 = 루프 핫큐로 저장)"))
        row(["[", "/", "]"], String(ui: "루프 길이 ½ · ×2"))
        row(["T"], String(ui: "탭 템포"))
        row([String(ui: "휠"), "·", "+", "/", "−"], String(ui: "파형 확대 · 축소 (가로 스크롤: 이동)"))
    }

    /// 바꾼 표: 키가 있는 동작마다 한 줄(키 이름은 구분 기호와 섞이지 않게 키캡으로만 쓴다)
    @ViewBuilder private var customRows: some View {
        ForEach(DeckAction.allCases.filter { !shortcuts.keys(for: $0).isEmpty }, id: \.self) { action in
            GridRow {
                HStack(spacing: 4 * scale) {
                    ForEach(Array(shortcuts.keys(for: action).enumerated()), id: \.offset) { index, key in
                        if index > 0 { separator("·") }
                        keycap(KeyLabel.name(for: key))
                    }
                }
                description(action.title + (action.shiftTitle.map { " (\($0))" } ?? ""))
            }
        }
        row(["Esc"], String(ui: "큐 선택 풀기 (그 뒤 1박 이동 키는 재생 위치를 옮김)"))
        row([String(ui: "휠")], String(ui: "파형 확대 · 축소 (가로 스크롤: 이동)"))
    }

    /// 구분 기호(~ / · +)는 키캡 없이 글자로만 쓴다.
    private static let separators: Set<String> = ["~", "/", "·", "+"]

    private func row(_ keys: [String], _ text: String) -> some View {
        GridRow {
            HStack(spacing: 4 * scale) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if Self.separators.contains(key) { separator(key) } else { keycap(key) }
                }
            }
            description(text)
        }
    }

    private func separator(_ text: String) -> some View {
        Text(text).font(.scaled(.body, scale).weight(.medium)).foregroundStyle(.secondary)
    }

    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.scaled(.body, design: .rounded, scale).weight(.semibold))
            .padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
            .frame(minWidth: 24 * scale)
            .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Color.primary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5 * scale).strokeBorder(Color.primary.opacity(0.25)))
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.scaled(.body, scale))
            .frame(maxWidth: 520 * scale, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 단축키 창도 주 창이 될 수 있다. 이 창의 키를 덱 조작으로 보내지 않도록 구분한다.
@MainActor
enum ShortcutsWindow {
    static weak var current: NSWindow?

    struct Tracker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { TrackingView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class TrackingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { ShortcutsWindow.current = window }
            }
        }
    }
}

extension DeckShortcuts {
    /// 키를 지웠으면 기본 키 대신 미지정으로 안내한다.
    func keyLabel(for action: DeckAction) -> String {
        let keys = keys(for: action).map(KeyLabel.name(for:))
        return keys.isEmpty ? String(ui: "미지정") : keys.joined(separator: " · ")
    }
}
