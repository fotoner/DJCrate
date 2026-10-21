@testable import DJCrate
import DJCDomain
import Testing

/// 도움말 › 단축키 창이 덱 단축키를 빠짐없이 안내한다. 메뉴 막대에 덱 메뉴가 있던 때는 그 메뉴가 같은 약속을 지켰다.
@MainActor
@Suite("단축키 창 — 덱 단축키 안내")
struct ShortcutsListTests {
    private var entries: [ShortcutsList.Entry] { ShortcutsList.standardEntries }

    @Test func 기본_표에서_키가_있는_모든_덱_동작을_한_줄씩_안내한다() {
        let keyed = DeckAction.allCases.filter { !DeckShortcuts.standard.keys(for: $0).isEmpty }
        let shown = entries.flatMap(\.actions)
        #expect(Set(keyed).subtracting(shown).isEmpty, "단축키 창에 없는 덱 동작: \(Set(keyed).subtracting(shown).map(\.rawValue).sorted())")
        #expect(Set(shown).subtracting(keyed).isEmpty, "키가 없는 동작을 안내하고 있다")
        #expect(shown.count == Set(shown).count, "같은 동작이 두 줄에 나온다")
    }

    @Test func Shift와_함께_누르는_변형도_모두_안내한다() {
        let shiftable = DeckAction.allCases.filter { $0.shiftTitle != nil }
        let shown = entries.flatMap(\.shiftActions)
        #expect(Set(shiftable).subtracting(shown).isEmpty, "Shift 변형이 없는 줄: \(Set(shiftable).subtracting(shown).map(\.rawValue).sorted())")
        #expect(Set(shown).subtracting(shiftable).isEmpty, "Shift 변형이 없는 동작을 안내하고 있다")
        #expect(shown.count == Set(shown).count, "같은 변형이 두 줄에 나온다")
    }

    @Test func 모든_줄에_키와_설명이_있다() {
        for entry in entries {
            #expect(!entry.keys.isEmpty && !entry.text.isEmpty, "빈 줄: \(entry)")
        }
    }

    /// 옛 덱 메뉴는 키 글자를 `DeckShortcuts.standard`에서 만들어 보였다. 창의 글자는 손으로 적은 것이라 기본 표와 어긋나지 않게 묶는다.
    @Test func 줄에_적은_키가_기본_표의_키와_맞다() {
        // 확대·축소 줄은 = 와 - 키를 ⌘+·⌘−와 같은 글자(+, −)로 적는다.
        let aliases = ["=": "+", "-": "−", KeyLabel.name(for: 69): "+", KeyLabel.name(for: 78): "−"]
        for entry in entries {
            let shown = Set(entry.keys).union(Self.numberRange(in: entry.keys))
            for action in entry.actions + entry.shiftActions {
                let labels = DeckShortcuts.standard.keys(for: action).map(KeyLabel.name(for:))
                #expect(labels.contains { shown.contains($0) || shown.contains(aliases[$0] ?? "") },
                        "\(action.rawValue)의 기본 키 \(labels)가 줄 \(entry.keys)에 없다")
            }
        }
    }

    /// 키를 바꾸면 창은 동작마다 지금 키를 보인다. 옛 덱 메뉴 시험(바꾼 키·지운 키)이 지키던 약속이다.
    @Test func 바꾼_표는_바꾼_키를_따르고_키를_지운_동작은_보이지_않는다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(49, with: 35, in: .playPause)
        try shortcuts.replace(18, with: 7, in: .hotCueA)
        shortcuts.remove(17, from: .tapTempo)
        let rows = ShortcutsList.customEntries(shortcuts)
        #expect(rows.first { $0.action == .playPause }?.keys == ["P"])
        #expect(rows.first { $0.action == .hotCueA }?.keys == ["X", "숫자패드 1"])
        #expect(!rows.contains { $0.action == .tapTempo })
        let keyed = DeckAction.allCases.filter { !shortcuts.keys(for: $0).isEmpty }
        #expect(rows.map(\.action) == keyed)
        for row in rows {
            #expect(row.keys == shortcuts.keys(for: row.action).map(KeyLabel.name(for:)))
        }
    }

    /// `["1", "~", "8"]`처럼 `~`로 이은 숫자 범위의 낱글자(1~8)
    private static func numberRange(in keys: [String]) -> Set<String> {
        guard let index = keys.firstIndex(of: "~"), index > 0, index + 1 < keys.count,
              let low = Int(keys[index - 1]), let high = Int(keys[index + 1]), low <= high else { return [] }
        return Set((low...high).map(String.init))
    }
}
