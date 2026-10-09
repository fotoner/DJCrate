@testable import DJCDomain
import Foundation
import Testing

@Suite("키 표기(#124)")
struct KeyNotationTests {
    @Test(arguments: [
        // 음이름(ID3 TKEY 권장 형식) — 단조는 소문자 m
        ("Am", "8A"), ("C", "8B"), ("Fm", "4A"), ("C#m", "12A"), ("Dbm", "12A"), ("F#", "2B"), ("Gb", "2B"),
        ("Bb", "6B"), ("Ebm", "2A"), ("E", "12B"), ("B", "1B"), ("G#m", "1A"),
        // 긴 이름·유니코드 기호·대소문자
        ("A minor", "8A"), ("A Minor", "8A"), ("Amin", "8A"), ("A min", "8A"), ("C major", "8B"), ("Cmaj", "8B"),
        ("F♯m", "11A"), ("B♭", "6B"), ("am", "8A"),
        // Camelot·Open Key
        ("8A", "8A"), ("08B", "8B"), ("12a", "12A"), ("1m", "8A"), ("1d", "8B"), ("6d", "1B"), ("12m", "7A"),
        // 두 표기를 함께 적은 태그
        ("8A - Am", "8A"), ("Am/8A", "8A"), (" Fm ", "4A"),
    ])
    func 태그_키를_Camelot으로(tag: String, camelot: String) {
        #expect(KeyNotation.camelot(from: tag) == camelot)
    }

    @Test(arguments: ["", "o", "Off", "H", "13A", "0B", "X#m", "key", "minor"])
    func 읽을_수_없는_태그는_nil(tag: String) {
        #expect(KeyNotation.camelot(from: tag) == nil)
    }

    @Test func 조표와_장단으로_Camelot() {
        #expect(KeyNotation.camelot(signature: 0, minor: false) == "8B")
        #expect(KeyNotation.camelot(signature: 0, minor: true) == "8A")
        #expect(KeyNotation.camelot(signature: 7, minor: false) == "9B")
        #expect(KeyNotation.camelot(signature: 8, minor: true) == "4A")
    }

    @Test func 추가한_곡은_키가_목록_모양에_들어가고_옛_기록도_읽는다() throws {
        var staged = StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/a.wav", title: "합성 곡", duration: 60, addedOn: "2026-09-28")
        #expect(staged.needsKey && staged.track.key == nil)
        staged.key = "8A"
        staged.keySource = .estimate
        #expect(!staged.needsKey && staged.track.key == "8A" && staged.keyEstimated)
        staged.keySource = .tag
        #expect(!staged.keyEstimated)
        // 추정했지만 조성을 찾지 못한 곡은 다시 추정하지 않는다.
        staged.key = nil
        staged.keySource = .estimate
        #expect(!staged.needsKey && staged.track.key == nil)
        // 키 칸이 없던 staged.json
        let old = #"[{"uuid":"u","path":"/a.wav","title":"t","comment":"","duration":1,"addedOn":"2026-09-01"}]"#
        let decoded = try JSONDecoder().decode([StagedTrack].self, from: Data(old.utf8))
        #expect(decoded.first?.key == nil && decoded.first?.needsKey == true)
    }
}
