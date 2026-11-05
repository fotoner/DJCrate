@testable import DJCrate
import CoreGraphics
import DJCDomain
import Foundation
import Testing

/// #309: 설정 창의 짧아진 문구가 말해야 할 것만 남기는지. 화면이 값으로 만드는 문구만 본다.
@MainActor
@Suite("설정 창 문구")
struct SettingsTextTests {
    @Test func 겹친_키_안내는_겹친_동작과_할_일만_말한다() {
        let text = ShortcutSettingsView.conflictMessage(with: [.playPause, .cue])
        #expect(text.contains("‘재생 / 정지’") && text.contains("‘CUE’"))
        #expect(text.contains("한쪽을 바꾸세요"))
        #expect(!text.contains("목록 위쪽"), "규칙 설명은 위 배너에만 둔다")
    }

    @Test func 키를_기다리는_칩이_취소_키를_말한다() {
        let text = ShortcutSettingsView.recordingChipText
        #expect(text.contains("Esc") && text.contains("키를 누르세요"), "안내 줄을 없앤 대신 칩이 취소 키를 말한다: \(text)")
    }

    @Test func 키_없음_칩은_키가_없고_새_키를_기다리지_않을_때만_보인다() {
        #expect(ShortcutSettingsView.showsEmptyChip(keys: [], recordingNewKey: false))
        #expect(!ShortcutSettingsView.showsEmptyChip(keys: [], recordingNewKey: true), "기다리는 칩이 그 자리를 차지한다")
        #expect(!ShortcutSettingsView.showsEmptyChip(keys: [49], recordingNewKey: false))
    }

    @Test func 코멘트_프리셋_항목은_고르면_켜지는_것을_이름에_단다() {
        #expect(CommentPreset.none.pickerTitle == CommentPreset.none.title)
        #expect(CommentPreset.anisong.pickerTitle == String(ui: "애니송 — 분류·필터·현황·형식 검사"))
    }

    @Test func 파형_견본은_모드마다_다른_그림이다() throws {
        let images = try WaveformColorMode.allCases.map { try #require(WaveformSwatch.image(for: $0)) }
        #expect(images.allSatisfy { $0.width > 0 && $0.height > 0 })
        let data = images.map { $0.dataProvider?.data as Data? }
        #expect(Set(data.compactMap { $0 }).count == WaveformColorMode.allCases.count)
    }
}
