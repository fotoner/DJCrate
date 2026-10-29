@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 쓸 수 없는 라이브러리(#327): 읽은 사본으로 미리 본 쓰기 막힘(지원 밖 버전·DB 구조·백업 폴더)을 상태 줄 칩이 편집 전에 알린다.
/// 앞서는 차례는 쓰는 중 > 쓸 수 없음 > 켜짐·꺼짐 이유(#326) > 쓰기 대기·없음이다. 쓰기 대기 수와 Dock 배지는 그대로 센다.
/// 표시만 바꾼다: 칩의 [쓰기]만 숨기고, 팝오버·메뉴 막대의 「rekordbox에 쓰기」는 지금 판단(`LibraryMenuAction.isEnabled`) 그대로다.
@MainActor
@Suite("상태 줄 쓰기 상태 — 쓸 수 없음")
struct ReflectionStatusBlockTests {
    typealias Harness = ReflectionStatusModelTests.Harness

    @Test func 쓸_수_없으면_쓰기_대기가_없어도_칩이_쓸_수_없음과_이유를_보인다() {
        let h = Harness()
        h.model.refresh()
        h.store.readScreen.apply(.writeBlock(.schema))
        h.model.refresh()

        #expect(h.store.writeBlock == .schema)
        #expect(h.model.chip == .blocked(.schema, items: 0, playlistEdits: 0))
        #expect(h.model.chip.title == "rekordbox에 쓸 수 없음")
        // 이유 한 문장은 칩 툴팁과 팝오버 맨 위에 보인다
        #expect(h.model.chip.blockReason == LibraryWriteBlock.schema.reason)
        #expect(h.model.popoverLines.first == LibraryWriteBlock.schema.reason)
        #expect(!h.model.showsWriteButton)
        #expect(h.dock.labels.isEmpty, "쓰기 대기가 없으면 Dock 배지도 없다")
    }

    @Test func 쓸_수_없어도_쓰기_대기_수와_Dock_배지는_그대로_세고_칩의_쓰기_단추만_숨긴다() throws {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        try h.addPlaylistEdit()
        h.store.readScreen.apply(.writeBlock(.unsupportedVersion("7.3.1")))
        h.model.refresh()

        #expect(h.model.chip == .blocked(.unsupportedVersion("7.3.1"), items: 1, playlistEdits: 1))
        #expect(h.model.chip.title == "rekordbox에 쓸 수 없음 · 쓰기 대기 1건")
        #expect(h.model.popoverLines == [LibraryWriteBlock.unsupportedVersion("7.3.1").reason, "재생 목록 편집 1건"])
        #expect(h.dock.labels == ["1"])
        #expect(!h.model.showsWriteButton && !h.model.emphasizesWrite)

        // 재생 목록 편집만 있어도 수를 함께 보인다
        h.store.setDraftMarks(cue: [], grid: [], gain: [])
        h.model.refresh()
        #expect(h.model.chip.title == "rekordbox에 쓸 수 없음 · 재생 목록 편집 1건")
    }

    @Test func 팝오버와_메뉴의_쓰기_항목은_막힘으로_바뀌지_않는다() {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        let before = h.model.items
        let canWrite = h.model.canWrite

        h.store.readScreen.apply(.writeBlock(.backupFolder))
        h.model.refresh()

        #expect(h.model.chip == .blocked(.backupFolder, items: 1, playlistEdits: 0))
        #expect(h.model.items == before)
        #expect(h.model.canWrite == canWrite && canWrite == LibraryMenuAction.reflect.isEnabled(in: h.window))
        for item in h.model.items {
            #expect(item.isEnabled == item.action.isEnabled(in: h.window) && item.disabledReason == item.action.disabledReason(in: h.window))
        }
    }

    @Test func 쓸_수_없음은_켜짐_이유보다_앞서고_쓰는_중은_쓸_수_없음보다_앞선다() async {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.run.state = .running
        h.model.refresh()
        #expect(h.model.chip.reason == .rekordboxRunning)

        h.store.readScreen.apply(.writeBlock(.counters))
        h.model.refresh()
        #expect(h.model.chip == .blocked(.counters, items: 1, playlistEdits: 0))
        #expect(h.model.todoLine == nil && h.model.popoverLines.first == LibraryWriteBlock.counters.reason)

        h.store.isWritingRekordbox = true
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.chip == .writing })
        h.store.isWritingRekordbox = false
        h.model.refresh()
        #expect(h.model.chip == .blocked(.counters, items: 1, playlistEdits: 0))
    }

    @Test func 막힘이_풀리면_다시_쓰기_대기와_쓰기_단추를_보인다() {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.store.readScreen.apply(.writeBlock(.schema))
        h.model.refresh()
        #expect(!h.model.showsWriteButton)

        h.store.readScreen.apply(.writeBlock(nil))
        h.model.refresh()
        #expect(h.store.writeBlock == nil)
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && h.model.showsWriteButton)
        #expect(h.model.chip.blockReason == nil && h.model.popoverLines.isEmpty)
    }

    @Test func 저장소의_막힘이_바뀌면_모델이_관찰해_스스로_고친다() async {
        let h = Harness()
        h.model.start()
        #expect(h.model.chip == .clean)

        h.store.readScreen.apply(.writeBlock(.backupFolder))
        #expect(await waitForState { h.model.chip == .blocked(.backupFolder, items: 0, playlistEdits: 0) })

        h.store.readScreen.apply(.writeBlock(nil))
        #expect(await waitForState { h.model.chip == .clean })
    }
}
