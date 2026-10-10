@testable import DJCrate
import AppKit
import Testing
import UniformTypeIdentifiers

/// 덱 위에 놓은 것 고르기(#255). SwiftUI(macOS 27)의 `DropInfo.itemProviders(for:)`는 요청한 형식이 없는 항목에도
/// 형식 없는 빈 제공자를 돌려준다. 그래서 USB 곡만 끌어도 로컬 곡 제공자가 하나 있는 것처럼 보여 덱에 오르지 않았다.
@Suite("덱 놓기 — 놓은 것 고르기")
struct DeckDropTests {
    /// SwiftUI가 형식 없이 돌려주는 제공자
    private func empty() -> NSItemProvider { NSItemProvider() }

    private func provider(_ type: UTType, _ text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        return provider
    }

    @Test func USB_곡만_끌면_빈_제공자를_건너뛰고_USB_곡을_고른다() {
        let usb = provider(PlaylistDragType.usbTracks, "{}")
        #expect(DeckDropPayload.read([empty(), usb]) == .usbTrack(usb))
        #expect(DeckDropPayload.read([usb]) == .usbTrack(usb))
    }

    @Test func 로컬_곡은_음원_파일보다_먼저_고른다() {
        let track = provider(DeckDragType.track, "7")
        let file = provider(.fileURL, "file:///tmp/a.mp3")
        #expect(DeckDropPayload.read([track, file]) == .track(track))
    }

    @Test func 음원_파일만_놓으면_파일을_모두_고른다() {
        let a = provider(.fileURL, "file:///tmp/a.mp3"), b = provider(.fileURL, "file:///tmp/b.mp3")
        #expect(DeckDropPayload.read([empty(), a, b]) == .files([a, b]))
    }

    @Test func 형식_없는_제공자만_있으면_받지_않는다() {
        #expect(DeckDropPayload.read([empty(), empty()]) == .none)
        #expect(DeckDropPayload.read([]) == .none)
    }
}
