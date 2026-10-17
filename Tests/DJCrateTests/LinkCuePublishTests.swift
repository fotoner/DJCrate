import DJCApplication
@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// LINK 연결 중 DJCrate에서 바뀐 큐를 내어 주는 큐에 옮긴다(#281). 저장소가 LINK 막대에 보낼 곡과 큐를 고른다.
@MainActor
@Suite("LINK 큐 보내기")
struct LinkCuePublishTests {
    static func row(_ cues: [Cue]) -> TrackRow {
        TrackRow(track: Track(id: "10", uuid: "u10", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60, folderPath: "/Users/dj/Music/10.mp3",
                              comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                 cues: cues, playCount: 0)
    }

    static func cue(_ ms: Int) -> Cue { Cue(id: "\(ms)", contentID: "10", kind: 0, inMsec: ms, name: "", colorTableIndex: nil) }

    @Test func 쓰는_동안에는_보내지_않고_다시_읽은_뒤_쓴_곡의_새_큐를_보낸다() {
        // 쓰기는 초안을 먼저 지우고 나중에 다시 읽는다. 지울 때 보내면 쓰기 전 큐가 CDJ에 남았다
        let store = LibraryStore.test()
        store.rowsByUUID["u10"] = Self.row([Self.cue(1_000)])
        var sent: [(String, [Cue])] = []
        store.isLinkServing = { true }
        store.onLinkCuesChanged = { sent.append(($0, $1)) }
        store.isWritingRekordbox = true
        store.draftChanged(trackUUID: "u10", kind: .cue, exists: false)
        #expect(sent.isEmpty)
        store.isWritingRekordbox = false
        store.rowsByUUID["u10"] = Self.row([Self.cue(1_000), Self.cue(2_000)])
        store.writtenAwaitingReload = ["u10"]
        store.deliverWrittenAfterReload()
        #expect(sent.map(\.0) == ["10"])
        #expect(sent.first?.1.map(\.inMsec) == [1_000, 2_000])
    }

    @Test func LINK가_꺼져_있으면_읽지도_보내지도_않는다() {
        let store = LibraryStore.test()
        store.rowsByUUID["u10"] = Self.row([Self.cue(1_000)])
        var sent = 0
        store.onLinkCuesChanged = { _, _ in sent += 1 }
        store.draftChanged(trackUUID: "u10", kind: .cue, exists: false)
        store.isLinkServing = { true }
        store.draftChanged(trackUUID: "u10", kind: .cue, exists: false)
        #expect(sent == 1)
    }
}
