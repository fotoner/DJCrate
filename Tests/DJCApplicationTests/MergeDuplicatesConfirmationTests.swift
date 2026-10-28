import DJCApplication
import DJCDomain
import Testing

/// 중복 합치기 확인 창(#328): 쓰기 단축키를 되풀이하는 안심 문구는 빼고, 보정 범위와 쓸 때 알리는 손실 안내는 남긴다.
@Suite("중복 합치기: 확인 문구")
struct MergeDuplicatesConfirmationTests {
    private func draft() -> DuplicateMergeDraft {
        DuplicateMergeDraft(
            keeping: .init(contentID: "1", trackUUID: "u1", title: "남길 곡", duration: 1, offset: 0, cues: []),
            removing: [.init(contentID: "2", trackUUID: "u2", title: "뺄 곡", duration: 1, offset: 0, cues: [])], base: "")
    }

    @Test func 확인_문구는_쓰기_단축키를_되풀이하지_않는다() {
        let prompt = MergeDuplicates.confirmation(draft(), paths: ["1": "/a.mp3", "2": "/b.mp3"])
        #expect(!prompt.text.contains("⇧⌘E"))
        #expect(!prompt.text.contains("초안은"))
    }

    @Test func 보정_범위와_쓸_때의_손실_안내는_남긴다() {
        let prompt = MergeDuplicates.confirmation(draft(), paths: ["1": "/a.mp3", "2": "/b.mp3"])
        #expect(prompt.text.contains("인코더 지연만 보정하며, 곡 앞뒤의 편집 차이는 보정하지 않습니다."))
        #expect(prompt.text.contains("쓸 때 옮기지 않는 정보를 알립니다."))
        #expect(prompt.details.count == 2)
    }
}
