import Testing
@testable import DJCDomain

/// rekordbox가 XML에 적는 표시 모양(#258). rekordbox 7.2.18 내보내기와 견준 결과(2026-11-06)를 규칙으로 둔다.
@Suite("라이브러리 XML 표시 모양")
struct LibraryXMLDisplayTests {
    @Test func 글자는_앞뒤_탭만_뺀다() {
        #expect(LibraryXMLDisplay.text("\t제목\t") == "제목")
        #expect(LibraryXMLDisplay.text("\t\tAnime") == "Anime")
        #expect(LibraryXMLDisplay.text("가운데  \t공백") == "가운데  \t공백")
        #expect(LibraryXMLDisplay.text("\t\t") == "")
        #expect(LibraryXMLDisplay.text("") == "")
        // 앞뒤 스페이스는 rekordbox가 그대로 둔다(7.2.18 내보내기에서 이름·장르·아티스트·앨범·코멘트 모두 확인했다)
        #expect(LibraryXMLDisplay.text(" Anime ") == " Anime ")
        #expect(LibraryXMLDisplay.text("제목 ") == "제목 ")
        #expect(LibraryXMLDisplay.text(" \t제목\t ") == " \t제목\t ", "스페이스가 가장자리면 안쪽 탭까지 닿지 않는다")
    }

    @Test func 키는_Camelot으로_바꾸고_바꿀_수_없는_값은_그대로_둔다() {
        // 확인: G·Em을 rekordbox는 9B·9A로 내보냈다
        #expect(LibraryXMLDisplay.tonality("G") == "9B")
        #expect(LibraryXMLDisplay.tonality("Em") == "9A")
        // Camelot은 그대로
        for name in KeyNotation.camelotNames { #expect(LibraryXMLDisplay.tonality(name) == name, "\(name)") }
        // 추정: 다른 옛 표기도 같은 규칙(Camelot 원 5도권)으로 바꾼다
        #expect(LibraryXMLDisplay.tonality("C") == "8B")
        #expect(LibraryXMLDisplay.tonality("Am") == "8A")
        #expect(LibraryXMLDisplay.tonality("Bb") == "6B")
        #expect(LibraryXMLDisplay.tonality("F#m") == "11A")
        #expect(LibraryXMLDisplay.tonality("Dbm") == "12A")
        // 바꿀 수 없는 값과 빈 값은 그대로
        #expect(LibraryXMLDisplay.tonality("알 수 없는 표기") == "알 수 없는 표기")
        #expect(LibraryXMLDisplay.tonality(" ?? ") == " ?? ")
        #expect(LibraryXMLDisplay.tonality("") == "")
    }

    @Test func 평점은_별_수에_51을_곱한다() {
        #expect((0...5).map(LibraryXMLDisplay.rating(stars:)) == [0, 51, 102, 153, 204, 255])
        // 범위 밖은 0~5로 묶는다
        #expect(LibraryXMLDisplay.rating(stars: -1) == 0)
        #expect(LibraryXMLDisplay.rating(stars: 9) == 255)
    }
}
