@testable import DJCrate
import DJCDomain
import Testing

/// '재생 목록에 넣기…' 시트의 화면 모델(#249): 찾는 말·고른 줄을 들고, 고른 목록(없으면 맨 위 목록)에 연 때의 곡을 넣는다.
@Suite("재생 목록 고르기 화면 모델")
@MainActor
struct PlaylistPickerModelTests {
    static let tracks = [ReflectionPresenterTests.row("1"), ReflectionPresenterTests.row("2")]
    static let playlists: [(item: PlaylistLayout.Item, path: [String])] = [
        (PlaylistLayout.Item(id: "A", name: "Warm Up"), []),
        (PlaylistLayout.Item(id: "B", name: "Peak"), []),
    ]

    final class Added {
        var calls: [(tracks: [String], playlist: String)] = []
    }

    func model(recent: [String] = ["B"], added: Added = Added()) -> PlaylistPickerModel {
        PlaylistPickerModel(tracks: Self.tracks,
                            choices: { PlaylistChoices(playlists: Self.playlists, recentIDs: recent) },
                            add: { rows, id in added.calls.append((rows.map(\.id), id)) })
    }

    @Test func 찾는_말에_따라_고를_목록이_바뀐다() {
        let model = model()
        #expect(model.trackCount == 2)
        #expect(model.choices.map(\.id) == ["B", "A"])
        model.query = "warm"
        #expect(model.choices.map(\.id) == ["A"])
        model.query = "없음"
        #expect(model.choices.isEmpty && !model.canAdd)
    }

    @Test func 넣기는_고른_줄_없으면_맨_위_목록에_연_때의_곡을_넣는다() {
        let added = Added()
        let model = model(added: added)
        #expect(model.addSelection())
        model.selection = "A"
        #expect(model.addSelection())
        #expect(added.calls.map(\.playlist) == ["B", "A"])
        #expect(added.calls.allSatisfy { $0.tracks == ["1", "2"] })
    }

    @Test func 넣을_목록이_없으면_넣지_않고_시트를_닫지_않는다() {
        let added = Added()
        let model = model(added: added)
        model.query = "없음"
        #expect(!model.addSelection())
        #expect(!model.add(nil))
        #expect(added.calls.isEmpty)
        // 두 번 누르기(목록 줄)는 그 줄 목록에 넣는다
        #expect(model.add("A"))
        #expect(added.calls.map(\.playlist) == ["A"])
    }

    @Test func 저장소에서_열면_고른_곡과_최근_목록을_쓴다() {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }))
        store.playlistPickerTracks = Self.tracks
        let picker = store.playlistPicker
        #expect(picker?.trackCount == 2)
        // 다시 열면 찾는 말을 처음부터 쓴다(새 화면 모델)
        picker?.query = "x"
        store.playlistPickerTracks = Self.tracks
        #expect(store.playlistPicker !== picker && store.playlistPicker?.query == "")
    }
}
