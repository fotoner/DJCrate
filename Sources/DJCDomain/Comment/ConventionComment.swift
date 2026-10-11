import Foundation

/// 사용자가 써 온 코멘트 컨벤션의 구조화 결과.
///
/// `PREFIX 작품명[ N기|(N기)][ (약칭…)][ OP|ED|IN[ 번호]][ N화][ CS][ TVSIZE][ 꼬리]`
public struct ConventionComment: Sendable, Hashable {
    public enum Prefix: String, Sendable, CaseIterable {
        case tva = "TVA", ova = "OVA", mv = "MV"
        case gm = "GM", pcGame = "PC Game"
        case vt = "VT", vd = "VD", nt = "NT", adv = "ADV"

        /// 방영 분기 꼬리를 붙이는 분류.
        public var isAnime: Bool { self == .tva || self == .ova || self == .mv }
    }

    public enum SeasonStyle: Sendable, Hashable {
        /// `좀비랜드사가R(2기)`, `마사무네의 리벤지 R (2기)`
        case parenthesized
        /// `러브라이브 2기`
        case plain
        /// `우마무스메 프리티 더비 시즌 1`
        case season
    }

    public enum UsageKind: String, Sendable, Hashable {
        case op = "OP", ed = "ED", insert = "IN"
    }

    public struct Usage: Sendable, Hashable {
        public var kind: UsageKind
        /// OP·ED는 순번, IN은 방송 회차 목록.
        public var numbers: [Int]

        public init(kind: UsageKind, numbers: [Int]) {
            self.kind = kind
            self.numbers = numbers
        }
    }

    public struct Tail: Sendable, Hashable {
        public var airingYear: Int?
        public var airingQuarter: Int?
        /// MV(극장판) 개봉 연도: `YYYY 영화`
        public var movieYear: Int?
        /// 본인이 튼 OTAKU BOOMBOX Vol.
        public var boomboxVolumes: [Int] = []

        public init() {}

        public var isEmpty: Bool {
            airingYear == nil && movieYear == nil && boomboxVolumes.isEmpty
        }
    }

    public var prefix: Prefix
    /// 사용자가 쓴 work_ref 원문(작품명 + 기수 + 약칭). R2 템플릿 복사에 쓴다.
    public var workRef: String = ""
    public var workName: String = ""
    public var season: Int?
    public var seasonStyle: SeasonStyle?
    public var abbreviations: [String] = []
    public var usages: [Usage] = []
    public var episodes: [Int] = []
    public var isCharacterSong = false
    public var isTVSize = false
    /// 의미 미확인 토큰(CV, RM, MX, …). 보존만 한다.
    public var variants: [String] = []
    /// VT의 `(구)`: 옛 소속·옛 이름.
    public var isFormerAffiliation = false
    public var tail = Tail()

    public init(prefix: Prefix) {
        self.prefix = prefix
    }

    /// 작품 비교 키 (R11).
    public var workKey: String { CommentText.matchKey(workName) }
}
