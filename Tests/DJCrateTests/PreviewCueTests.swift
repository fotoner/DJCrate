import AppKit
import Foundation
import Testing
import DJCDomain
import RekordboxKit
@testable import DJCrate

struct PreviewCueTests {
    @Test func positionsAndLoopsAreClippedToThePreview() {
        let marks = [PreviewCueMark(EditableCue(kind: .hot(0), time: 25)),
                     PreviewCueMark(EditableCue(kind: .memory, time: 75, loop: .init(end: 90))),
                     PreviewCueMark(EditableCue(kind: .memory, time: -1)),
                     PreviewCueMark(EditableCue(kind: .memory, time: .nan)),
                     PreviewCueMark(EditableCue(kind: .memory, time: 120))]
        let shapes = PreviewCueMark.shapes(marks, duration: 100, width: 400, height: 40)
        #expect(shapes.count == 3)
        #expect(shapes[0].color == .hot)
        #expect(shapes[0].rect.minX == 100)
        #expect(shapes[0].rect.minY < 10)
        #expect(shapes[1].color == .memory)
        // 메모리 큐는 아래쪽 끝에 붙는다(눈금 높이는 칸 높이에 따라 정한다, #121).
        #expect(shapes[1].rect.minY >= 20 && shapes[1].rect.maxY == 39)
        #expect(shapes[2].color == .loop)
        #expect(shapes.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 400 })
        #expect(PreviewCueMark.shapes(marks, duration: 0, width: 400, height: 40).isEmpty)
        #expect(PreviewCueMark.shapes(marks, duration: .nan, width: 400, height: 40).isEmpty)
    }

    @Test func cueTicksRemainVisibleInEveryWaveformModeAndAppearance() throws {
        let preview = AnlzPreviewWaveform(blue: [WaveformColumn(low: 1, mid: 1, high: 1)],
                                          color: [WaveformColumn(low: 1, mid: 1, high: 1)])
        let marks = [PreviewCueMark(EditableCue(kind: .hot(0), time: 25)),
                     PreviewCueMark(EditableCue(kind: .memory, time: 75))]
        for mode in WaveformColorMode.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let image = try #require(PreviewWaveformRenderer.image(preview, mode: mode, appearance: appearance.rawValue, cues: marks, duration: 100))
                let bitmap = NSBitmapImageRep(cgImage: image)
                let hot = try #require(bitmap.colorAt(x: 100, y: 4))
                let memory = try #require(bitmap.colorAt(x: 300, y: 35))
                let expectedHot = UIColors.hot.variants.resolved(for: appearance).usingColorSpace(.sRGB)!
                let expectedMemory = UIColors.memory.variants.resolved(for: appearance).usingColorSpace(.sRGB)!
                #expect(abs(hot.greenComponent - expectedHot.greenComponent) < 0.01)
                #expect(abs(memory.redComponent - expectedMemory.redComponent) < 0.01)
            }
        }
        #expect(PreviewWaveformRenderer.image(nil, mode: .blue, appearance: NSAppearance.Name.aqua.rawValue,
                                              cues: marks, duration: 100) != nil)
    }

    @Test @MainActor func movingACueWithSameCountsRefreshesOnlyItsDraftMarkers() {
        let store = LibraryStore.test()
        var first = CueDraft(trackUUID: "first")
        first.cues = [EditableCue(kind: .hot(0), time: 10)]
        var second = CueDraft(trackUUID: "second")
        second.cues = [EditableCue(kind: .memory, time: 20)]
        store.cueDraftChanged(first); store.cueDraftChanged(second)
        let other = store.draftPreviewCues["second"]
        let counts = store.draftCueCounts["first"]
        first.cues[0].time = 30
        store.cueDraftChanged(first)
        #expect(store.draftCueCounts["first"] == counts)
        #expect(store.draftPreviewCues["first"]?.first?.time == 30)
        #expect(store.draftPreviewCues["second"] == other)
        store.draftChanged(trackUUID: "first", kind: .cue, exists: false)
        #expect(store.draftPreviewCues["first"] == nil)
    }

    /// #145: rekordbox 자동 큐도 메모리 큐로 보인다(덱 목록과 같다).
    @Test func savedAutoCuesAreShownAsMemoryCues() {
        let auto = Cue(id: "auto", contentID: "track", kind: 0, inMsec: 350, name: "1.1Bars", colorTableIndex: 0, color: 255)
        #expect(PreviewCueMark.current(saved: [auto], draft: nil) == [PreviewCueMark(EditableCue(kind: .memory, time: 0.35))])
    }

    @Test func removingAllCuesInDraftDoesNotShowSavedCuesAgain() {
        let cue = Cue(id: "cue", contentID: "track", kind: 1, inMsec: 1000, name: "", colorTableIndex: nil)
        #expect(PreviewCueMark.current(saved: [cue], draft: nil).count == 1)
        #expect(PreviewCueMark.current(saved: [cue], draft: []).isEmpty)
        let plain = PreviewWaveformRequest(url: nil, revision: "one", appearance: NSAppearance.Name.aqua.rawValue)
        var moved = plain
        moved.cues = [PreviewCueMark(EditableCue(kind: .hot(0), time: 2))]
        moved.duration = 100
        #expect(plain.cacheKey != moved.cacheKey)
    }
}
