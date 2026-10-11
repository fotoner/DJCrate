import Foundation

/// 덱 제안 줄의 제안 하나(게인·그리드·키). 세 제안은 한 규칙으로 보인다: 이름 · 값 · (확인 필요) · [적용] [무시].
/// "DJCrate 제안:"·"추정" 같은 접두어 없이 값만 짧게 적고, 적용하면 무엇이 되는지는 도움말(`applyHelp`)이 알린다.
/// 단추 이름은 세 제안 모두 같다(`applyTitle`·`dismissTitle`).
public struct DeckSuggestion: Equatable, Sendable, Identifiable {
    /// 줄에 보이는 순서이기도 하다(게인 → 그리드 → 키).
    public enum Kind: String, CaseIterable, Sendable { case gain, grid, key }

    public let kind: Kind
    /// 이름(게인·그리드·키)
    public let title: String
    /// 제안 값. 숫자는 로캘 소수점을 따른다.
    public let value: String
    /// 신뢰도가 낮아 소리로 확인해야 하는 제안(그리드). 값과 따로 "확인 필요" 표식으로 붙는다.
    public let needsCheck: Bool
    /// [적용] 도움말: 무엇이 초안이 되는지
    public let applyHelp: String
    /// [무시] 도움말
    public let dismissHelp: String
    /// 값에 대는 도움말(왜 제안하는지). 없으면 nil.
    public let detail: String?

    public var id: Kind { kind }

    public init(kind: Kind, title: String, value: String, needsCheck: Bool, applyHelp: String, dismissHelp: String, detail: String?) {
        self.kind = kind
        self.title = title
        self.value = value
        self.needsCheck = needsCheck
        self.applyHelp = applyHelp
        self.dismissHelp = dismissHelp
        self.detail = detail
    }

    /// VoiceOver 이름: "게인 제안 +1.7 dB (rekordbox -4.0)"
    public var spokenLabel: String {
        needsCheck ? String(ui: "\(title) 제안 \(value), 확인 필요") : String(ui: "\(title) 제안 \(value)")
    }

    public static var applyTitle: String { String(ui: "적용") }
    public static var dismissTitle: String { String(ui: "무시") }
    public static var checkTitle: String { String(ui: "확인 필요") }
    public static var checkHelp: String { String(ui: "박이 흔들리거나 템포가 바뀌는 곡입니다. 적용 뒤 메트로놈으로 확인하고 고쳐 주세요.") }

    /// rekordbox 오토게인이 DJCrate 측정과 크게 다를 때: DJCrate 계산값(dB)을 제안한다.
    /// - Parameter mismatch: rekordbox 값과 DJCrate 계산의 차이(dB)
    public static func gain(_ suggested: Double, rekordbox: Double, mismatch: Double) -> DeckSuggestion {
        DeckSuggestion(
            kind: .gain, title: String(ui: "게인"),
            value: String(ui: "\(suggested, specifier: "%+.1f") dB (rekordbox \(rekordbox, specifier: "%+.1f"))"),
            needsCheck: false,
            applyHelp: String(ui: "DJCrate가 잰 음량으로 계산한 게인을 이 곡의 게인 초안으로 넣습니다. rekordbox에는 쓰기 전까지 들어가지 않습니다(실행 취소 가능)."),
            dismissHelp: String(ui: "이 곡에서는 rekordbox 값을 그대로 쓰고 제안을 더 보이지 않습니다"),
            detail: String(ui: "rekordbox 오토게인이 이 파일의 실제 음량과 \(abs(mismatch), specifier: "%.1f")dB 다릅니다"))
    }

    /// DJCrate가 추정한 그리드.
    /// - Parameters:
    ///   - phaseMilliseconds: 지금 그리드와 박 위치 차이(지금 그리드가 없으면 nil)
    ///   - tempos: 변속 곡이면 구간별 BPM(구간이 하나면 적지 않는다)
    ///   - hasRekordboxGrid: false면 rekordbox 그리드가 없는 곡이다(적용하면 새 그리드 초안이 된다).
    public static func grid(bpm: Double, phaseMilliseconds: Double?, tempos: [Double] = [], hasRekordboxGrid: Bool = true,
                            isConfident: Bool) -> DeckSuggestion {
        var parts = [bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never)) + " BPM"]
        if let phaseMilliseconds { parts.append(String(ui: "위상 \(phaseMilliseconds, specifier: "%+.0f")ms")) }
        if tempos.count > 1 {
            let flow = tempos.map { String(format: "%.0f", $0) }.joined(separator: "→")
            parts.append(String(ui: "변속 \(flow)"))
        }
        if !hasRekordboxGrid { parts.append(String(ui: "rekordbox 그리드 없음")) }
        let apply = !hasRekordboxGrid
            ? String(ui: "추정한 템포·박 위치를 그리드 초안으로 넣습니다. 적용 뒤 그리드 편집으로 고칠 수 있습니다.")
            : isConfident
            ? String(ui: "추정 그리드로 초안을 바꿉니다(실행 취소 가능).")
            : String(ui: "추정 그리드로 초안을 바꿉니다. 신뢰도가 낮으니 소리로 확인하세요(실행 취소 가능).")
        return DeckSuggestion(kind: .grid, title: String(ui: "그리드"), value: parts.joined(separator: " · "), needsCheck: !isConfident,
                              applyHelp: apply, dismissHelp: String(ui: "이 곡에서는 제안을 더 보이지 않습니다"), detail: nil)
    }

    /// 키가 빈 곡의 키: DJCrate 추정, 추가한 곡이면 음원 태그의 키(태그에 없으면 추가할 때 추정한 키).
    public static func key(_ name: String, fromFileTag: Bool) -> DeckSuggestion {
        DeckSuggestion(
            kind: .key, title: String(ui: "키"), value: fromFileTag ? String(ui: "\(name) (음원 태그)") : name, needsCheck: false,
            applyHelp: fromFileTag
                ? String(ui: "음원 파일 태그에 적힌 키입니다. 누르면 이 키로 초안을 만들고, 곡을 rekordbox에 넣을 때 함께 씁니다. 음원 파일은 바꾸지 않습니다.")
                : String(ui: "DJCrate가 곡을 분석해 추정한 키입니다. 누르면 이 키로 초안을 만들고, rekordbox에는 쓰기 전까지 들어가지 않습니다."),
            dismissHelp: String(ui: "이 곡에서는 제안을 더 보이지 않습니다"), detail: nil)
    }
}

/// 덱 제안 줄에 보일 것: 보류 중인 제안(게인 → 그리드 → 키)과, 무시해서 가린 제안.
/// 무시한 제안은 줄에서 빠지고, 지금 보일 제안이 있었던 것만 "무시한 제안 다시 보기" 하나로 되살린다.
public struct DeckSuggestionList: Equatable, Sendable {
    public private(set) var shown: [DeckSuggestion]
    /// 무시해서 가린 제안(되살릴 수 있는 것)
    public private(set) var dismissed: [DeckSuggestion.Kind]

    public static var restoreTitle: String { String(ui: "무시한 제안 다시 보기") }
    public static var restoreHelp: String { String(ui: "이 곡에서 무시한 제안을 다시 보이게 합니다") }

    /// - Parameters:
    ///   - candidates: 무시 여부와 관계없이 지금 보일 수 있는 제안
    ///   - dismissed: 이 곡에서 무시한 제안 종류
    public init(_ candidates: [DeckSuggestion], dismissed: Set<DeckSuggestion.Kind>) {
        let order = DeckSuggestion.Kind.allCases
        let sorted = candidates.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        shown = sorted.filter { !dismissed.contains($0.kind) }
        self.dismissed = sorted.map(\.kind).filter { dismissed.contains($0) }
    }

    public var canRestore: Bool { !dismissed.isEmpty }
    /// 보일 제안도 되살릴 제안도 없다.
    public var isEmpty: Bool { shown.isEmpty && dismissed.isEmpty }
}
