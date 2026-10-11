import DJCDomain
import Testing

/// 덱 제안 줄(게인·그리드·키)의 문구와 목록: 세 제안이 한 규칙(이름 · 값 · [적용] [무시])으로 나오고,
/// 무시한 제안은 줄에서 빠져 "무시한 제안 다시 보기" 하나로 되살린다.
@Suite("덱 제안 줄 문구")
struct DeckSuggestionsTests {
    @Test func 세_제안은_이름과_값만_간결하게_보이고_접두어가_없다() {
        let gain = DeckSuggestion.gain(1.7, rekordbox: -4.0, mismatch: 5.7)
        let grid = DeckSuggestion.grid(bpm: 133.97, phaseMilliseconds: -1, isConfident: true)
        let key = DeckSuggestion.key("8B", fromFileTag: false)
        #expect([gain.title, grid.title, key.title] == ["게인", "그리드", "키"])
        #expect(gain.value == "+1.7 dB (rekordbox -4.0)")
        #expect(grid.value == "133.97 BPM · 위상 -1ms")
        #expect(key.value == "8B")
        for item in [gain, grid, key] {
            #expect(!item.value.contains("DJCrate") && !item.value.contains("제안") && !item.value.contains("추정"), "\(item.value)")
        }
    }

    @Test func 단추는_세_제안_모두_적용과_무시이고_다시_보기는_하나다() {
        #expect(DeckSuggestion.applyTitle == "적용")
        #expect(DeckSuggestion.dismissTitle == "무시")
        #expect(DeckSuggestionList.restoreTitle == "무시한 제안 다시 보기")
    }

    @Test func 적용_도움말은_초안이_된다는_것을_알린다() {
        let items = [
            DeckSuggestion.gain(1.7, rekordbox: -4.0, mismatch: 5.7),
            .grid(bpm: 128, phaseMilliseconds: 12, isConfident: true),
            .grid(bpm: 128, phaseMilliseconds: 12, isConfident: false),
            .grid(bpm: 128, phaseMilliseconds: nil, hasRekordboxGrid: false, isConfident: true),
            .key("8B", fromFileTag: false), .key("8B", fromFileTag: true),
        ]
        for item in items {
            #expect(item.applyHelp.contains("초안"), "\(item.kind): \(item.applyHelp)")
            #expect(item.dismissHelp.contains("제안을 더 보이지 않습니다"), "\(item.kind): \(item.dismissHelp)")
        }
        #expect(items[0].detail == "rekordbox 오토게인이 이 파일의 실제 음량과 5.7dB 다릅니다")
    }

    @Test func 신뢰도가_낮은_그리드는_확인_필요를_짧게_붙인다() {
        let sure = DeckSuggestion.grid(bpm: 128, phaseMilliseconds: 12, isConfident: true)
        let unsure = DeckSuggestion.grid(bpm: 128, phaseMilliseconds: 12, isConfident: false)
        #expect(!sure.needsCheck && unsure.needsCheck)
        #expect(sure.value == unsure.value, "확인 필요는 값이 아니라 따로 붙는 표식이다")
        #expect(DeckSuggestion.checkTitle == "확인 필요")
        #expect(unsure.spokenLabel == "그리드 제안 128.00 BPM · 위상 +12ms, 확인 필요")
        #expect(sure.spokenLabel == "그리드 제안 128.00 BPM · 위상 +12ms")
    }

    @Test func 그리드가_없는_곡과_변속_곡도_같은_모양이다() {
        let missing = DeckSuggestion.grid(bpm: 133.97, phaseMilliseconds: nil, hasRekordboxGrid: false, isConfident: true)
        #expect(missing.value == "133.97 BPM · rekordbox 그리드 없음")
        let flow = DeckSuggestion.grid(bpm: 128, phaseMilliseconds: -3, tempos: [128, 130.4], isConfident: true)
        #expect(flow.value == "128.00 BPM · 위상 -3ms · 변속 128→130")
        let single = DeckSuggestion.grid(bpm: 128, phaseMilliseconds: nil, tempos: [128], isConfident: true)
        #expect(single.value == "128.00 BPM", "구간이 하나면 변속을 적지 않는다")
    }

    @Test func 음원_태그_키는_출처를_짧게_적는다() {
        #expect(DeckSuggestion.key("12B", fromFileTag: true).value == "12B (음원 태그)")
        #expect(DeckSuggestion.key("12B", fromFileTag: false).value == "12B")
        #expect(DeckSuggestion.key("12B", fromFileTag: true).spokenLabel == "키 제안 12B (음원 태그)")
        #expect(DeckSuggestion.gain(1.7, rekordbox: -4.0, mismatch: 5.7).spokenLabel == "게인 제안 +1.7 dB (rekordbox -4.0)")
    }

    // MARK: 목록

    @Test func 줄은_게인_그리드_키_순서로_무시하지_않은_제안만_보인다() {
        let key = DeckSuggestion.key("8B", fromFileTag: false)
        let grid = DeckSuggestion.grid(bpm: 128, phaseMilliseconds: 5, isConfident: true)
        let gain = DeckSuggestion.gain(1.7, rekordbox: -4.0, mismatch: 5.7)
        let list = DeckSuggestionList([key, grid, gain], dismissed: [])
        #expect(list.shown.map(\.kind) == [.gain, .grid, .key])
        #expect(!list.canRestore && list.dismissed.isEmpty)

        let some = DeckSuggestionList([key, grid, gain], dismissed: [.grid])
        #expect(some.shown.map(\.kind) == [.gain, .key])
        #expect(some.dismissed == [.grid] && some.canRestore)

        let all = DeckSuggestionList([key, grid, gain], dismissed: [.gain, .grid, .key])
        #expect(all.shown.isEmpty && all.dismissed == [.gain, .grid, .key] && all.canRestore)
    }

    @Test func 보일_제안이_없는_무시는_되살릴_것이_아니다() {
        // 무시한 곡이어도 지금 보일 제안이 없으면(키를 골랐거나 추정이 없으면) 다시 보기를 보이지 않는다.
        let list = DeckSuggestionList([.key("8B", fromFileTag: false)], dismissed: [.gain, .grid])
        #expect(list.shown.map(\.kind) == [.key] && !list.canRestore)
        #expect(DeckSuggestionList([], dismissed: [.gain]).isEmpty)
        #expect(!DeckSuggestionList([], dismissed: [.gain]).canRestore)
    }
}
