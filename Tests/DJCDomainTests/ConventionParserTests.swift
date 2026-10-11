@testable import DJCDomain
import Foundation
import Testing

@Suite("애니송 프리셋 · 컨벤션 파서 — 실제 라이브러리 코멘트")
struct ConventionParserTests {
    @Test func 약칭과_기수_순서가_뒤집힌_작품() throws {
        let c = try #require(ConventionParser.parse("TVA 내 여동생이 이렇게 귀여울 리가 없어(내여귀, 오레이모) 1기 OP"))
        #expect(c.prefix == .tva)
        #expect(c.workName == "내 여동생이 이렇게 귀여울 리가 없어")
        #expect(c.abbreviations == ["내여귀", "오레이모"])
        #expect(c.season == 1)
        #expect(c.seasonStyle == .plain)
        #expect(c.usages == [.init(kind: .op, numbers: [])])
    }

    @Test func 회차형_IN과_TVSIZE() throws {
        let c = try #require(ConventionParser.parse("TVA 러브라이브 2기 IN 3 TVSIZE"))
        #expect(c.workName == "러브라이브")
        #expect(c.season == 2)
        #expect(c.usages == [.init(kind: .insert, numbers: [3])])
        #expect(c.isTVSize)
    }

    @Test func 붙여_쓴_IN과_괄호_기수() throws {
        let c = try #require(ConventionParser.parse("TVA 좀비랜드사가R(2기) IN9"))
        #expect(c.workName == "좀비랜드사가R")
        #expect(c.season == 2)
        #expect(c.seasonStyle == .parenthesized)
        #expect(c.usages == [.init(kind: .insert, numbers: [9])])
    }

    @Test func ED_CS_복합과_약칭() throws {
        let c = try #require(ConventionParser.parse("TVA 주문은 토끼입니까? BLOOM (주문토끼, 고치우사) ED CS"))
        #expect(c.workName == "주문은 토끼입니까? BLOOM")
        #expect(c.abbreviations == ["주문토끼", "고치우사"])
        #expect(c.usages == [.init(kind: .ed, numbers: [])])
        #expect(c.isCharacterSong)
    }

    @Test func 번호_있는_ED와_TVSIZE() throws {
        let c = try #require(ConventionParser.parse("TVA 소드아트온라인 2기 ED 1 TVSIZE"))
        #expect(c.workName == "소드아트온라인")
        #expect(c.usages == [.init(kind: .ed, numbers: [1])])
        #expect(c.isTVSize)
    }

    @Test func 복수_회차_IN() throws {
        let c = try #require(ConventionParser.parse("TVA 러브라이브 2기 IN 3 7 11 23"))
        #expect(c.usages == [.init(kind: .insert, numbers: [3, 7, 11, 23])])
    }

    @Test func 부제_뒤_괄호_기수() throws {
        let c = try #require(ConventionParser.parse("TVA 마사무네의 리벤지 R (2기) OP"))
        #expect(c.workName == "마사무네의 리벤지 R")
        #expect(c.season == 2)
    }

    @Test func 물음표_두_개_뒤_괄호_기수와_CS_단독() throws {
        let c = try #require(ConventionParser.parse("TVA 주문은 토끼입니까??(2기) CS"))
        #expect(c.workName == "주문은 토끼입니까??")
        #expect(c.season == 2)
        #expect(c.usages.isEmpty)
        #expect(c.isCharacterSong)
    }

    @Test func 시즌_표기() throws {
        let c = try #require(ConventionParser.parse("TVA 우마무스메 프리티 더비 시즌 1"))
        #expect(c.workName == "우마무스메 프리티 더비")
        #expect(c.season == 1)
        #expect(c.seasonStyle == .season)
    }

    @Test func GM_괄호_약칭() throws {
        let c = try #require(ConventionParser.parse("GM 디제이맥스 리스펙트(디맥)"))
        #expect(c.prefix == .gm)
        #expect(c.workName == "디제이맥스 리스펙트")
        #expect(c.abbreviations == ["디맥"])
    }

    @Test func 프랜차이즈만_있는_GM과_VT() throws {
        #expect(ConventionParser.parse("GM 아이마스 신데렐라 걸즈")?.workName == "아이마스 신데렐라 걸즈")
        #expect(ConventionParser.parse("VT 홀로라이브")?.workName == "홀로라이브")
    }

    @Test func NT_단독과_아티스트() throws {
        #expect(ConventionParser.parse("NT")?.workName == "")
        #expect(ConventionParser.parse("NT 나나히라")?.workName == "나나히라")
    }

    @Test func 툴_꼬리_방영과_붐박스() throws {
        let c = try #require(ConventionParser.parse("TVA 주문은 토끼입니까? BLOOM (주문토끼, 고치우사) ED CS 2020 4분기 BB05 BB13"))
        #expect(c.workName == "주문은 토끼입니까? BLOOM")
        #expect(c.isCharacterSong)
        #expect(c.tail.airingYear == 2020)
        #expect(c.tail.airingQuarter == 4)
        #expect(c.tail.boomboxVolumes == [5, 13])
    }

    @Test func 한국_변형_토큰() throws {
        let c = try #require(ConventionParser.parse("TVA 명탐정 코난 ED 35(한국)"))
        #expect(c.usages == [.init(kind: .ed, numbers: [35])])
        #expect(c.variants == ["(한국)"])
    }

    @Test func 제어문자와_이중_공백_정규화() throws {
        let c = try #require(ConventionParser.parse("TVA  마크로스 델타\u{0009} IN"))
        #expect(c.workName == "마크로스 델타")
        #expect(c.usages == [.init(kind: .insert, numbers: [])])
    }
}

@Suite("애니송 프리셋 · 코멘트 분류")
struct CommentClassifierTests {
    @Test func 분류() {
        #expect(CommentClassifier.classify("") == .empty)
        #expect(CommentClassifier.classify("GM 방도리") == .convention)
        #expect(CommentClassifier.classify("JASRAC / Lantis") == .residue)
        #expect(CommentClassifier.classify("ExactAudioCopy v1.3") == .residue)
        #expect(CommentClassifier.classify("神様のメモ帳 OP, 하느님의 메모장, 카미메모") == .legacy)
        #expect(CommentClassifier.classify("오빠는 끝! ED, 오니마이, TS [CS]") == .legacy)
        #expect(CommentClassifier.classify("TCSLCD-0003") == .other)
        // 접두어처럼 보이지만 단어 경계가 아니면 컨벤션이 아니다.
        #expect(CommentClassifier.classify("TVSIZE only") == .other)
    }
}

@Suite("애니송 프리셋 · 정규식 없는 파서 — 경계 사례")
struct ConventionParserEdgeTests {
    @Test func 붙여_쓴_회차_목록() throws {
        let c = try #require(ConventionParser.parse("TVA 작품 OP 3화,5화"))
        #expect(c.episodes == [3, 5])
        #expect(c.usages == [.init(kind: .op, numbers: [])])
    }

    @Test func 쉼표_띄어쓴_회차_목록() throws {
        let c = try #require(ConventionParser.parse("TVA 작품 ED 3화, 5화"))
        #expect(c.episodes == [3, 5])
    }

    @Test func 붙여_쓴_용도_번호_뒤_공백_번호() throws {
        let c = try #require(ConventionParser.parse("TVA 작품 IN5 8"))
        #expect(c.usages == [.init(kind: .insert, numbers: [5, 8])])
    }

    @Test func 구형_BB_목록과_EP() throws {
        let c = try #require(ConventionParser.parse("TVA 작품 OP EP12 BB13,19"))
        #expect(c.tail.boomboxVolumes == [13, 19])
        #expect(c.episodes == [12])
    }

    @Test func 제목_끝_숫자는_용도가_아니다() throws {
        let c = try #require(ConventionParser.parse("TVA 슈타인즈 게이트 0"))
        #expect(c.workName == "슈타인즈 게이트 0")
        #expect(c.usages.isEmpty)
    }

    @Test func 쉼표로_끝나는_번호는_받지_않는다() throws {
        let c = try #require(ConventionParser.parse("TVA 작품 IN 8,"))
        #expect(c.usages.isEmpty)
        #expect(c.workName == "작품 IN 8,")
    }
}
