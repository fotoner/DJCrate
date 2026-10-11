import Foundation

/// 글자 대신 고르기로 고치는 태그 칸(키·평점·곡 색)의 규칙: 고를 수 있는 값, 보일 글자, 붙여넣기에서 받는 값.
/// 곡 목록·태그 시트·인스펙터가 함께 쓴다. 키의 고르기 규칙은 앱의 `KeyPicker`, 평점·곡 색은 #65.
/// 고르기 메뉴·색 점(AppKit)과 곡 행을 받는 규칙은 앱의 `TagChoice+Menu.swift`에 있다.
public enum TagChoice {
    public static let keys: Set<TagFields.Key> = [.musicalKey, .rating, .color]

    public struct Option: Equatable, Sendable {
        /// 초안에 넣을 값(빈칸 = 없음)
        public let value: String
        public let title: String
        /// 고를 수 없는 현재 값(옛 표기 키 등)은 보이기만 한다
        public var enabled = true

        public init(value: String, title: String, enabled: Bool = true) {
            self.value = value
            self.title = title
            self.enabled = enabled
        }
    }

    /// 고르기 목록: 맨 앞은 없음. 키는 Camelot 24개(옛 표기 현재값은 맨 앞에 고를 수 없게), 평점은 별 1~5개, 곡 색은 rekordbox 색 순서.
    public static func options(_ key: TagFields.Key, current: String, colors: [TrackColor]) -> [Option] {
        var options: [Option] = []
        switch key {
        case .musicalKey:
            if !current.isEmpty, !KeyNotation.camelotNames.contains(current) { options.append(Option(value: current, title: current, enabled: false)) }
            options.append(Option(value: "", title: String(ui: "없음")))
            options += KeyNotation.camelotNames.map { Option(value: $0, title: $0) }
        case .rating:
            options.append(Option(value: "", title: String(ui: "없음")))
            options += TrackRating.choices.map { Option(value: $0, title: TrackRating.stars($0)) }
        case .color:
            // 읽은 값이 rekordbox 여덟 색 밖이면(모르는 번호) 맨 앞에 고를 수 없게 보인다
            if !current.isEmpty, !TrackColor.ids.contains(current) {
                options.append(Option(value: current, title: TrackColor.name(of: current, in: colors), enabled: false))
            }
            options.append(Option(value: "", title: String(ui: "없음")))
            options += colors.filter { TrackColor.ids.contains($0.id) }.map { Option(value: $0.id, title: $0.name) }
        default: break
        }
        return options
    }

    /// 칸·시트에 보일 글자(평점은 별, 곡 색은 이름). 다른 칸은 값 그대로다.
    public static func display(_ key: TagFields.Key, _ value: String, colors: [TrackColor]) -> String {
        switch key {
        case .rating: TrackRating.stars(value)
        case .color: TrackColor.name(of: value, in: colors)
        default: value
        }
    }

    /// VoiceOver가 읽을 글자(별 대신 "별 3개")
    public static func spoken(_ key: TagFields.Key, _ value: String, colors: [TrackColor]) -> String {
        guard key == .rating else { return display(key, value, colors: colors) }
        return Int(value).map { String(ui: "별 \($0)개") } ?? String(ui: "없음")
    }

    /// 시트 붙여넣기·채우기에서 받는 값(키: Camelot 이름, 평점: "3"·"★★★", 곡 색: 번호·색 이름). 받지 못하면 nil(그 칸은 건너뛴다).
    public static func accepted(_ key: TagFields.Key, _ text: String, colors: [TrackColor]) -> String? {
        switch key {
        case .musicalKey: acceptedKey(text)
        case .rating: TrackRating.accepted(text)
        case .color: TrackColor.accepted(text, in: colors)
        default: text
        }
    }

    /// 키 칸이 받는 값. 비웠으면 "", Camelot 이름이면 정확한 이름, 아니면 nil(건너뛴다).
    public static func acceptedKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : KeyNotation.normalizedCamelotName(trimmed)
    }

    /// 건너뛴 칸 안내(시트 붙여넣기·채우기)
    public static func skippedMessage(_ key: TagFields.Key, count: Int) -> String {
        switch key {
        case .rating: String(ui: "평점 칸 \(count)칸은 별 1~5개가 아니어서 건너뜀")
        case .color: String(ui: "곡 색 칸 \(count)칸은 rekordbox 색이 아니어서 건너뜀")
        default: String(ui: "키 칸 \(count)칸은 1A~12B가 아니어서 건너뜀")
        }
    }
}
