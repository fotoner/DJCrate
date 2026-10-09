import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing
@testable import DJCrate

@Suite("Apple Music 가져오기 선택 창")
@MainActor
struct AppleMusicImportModelTests {
    func model() -> AppleMusicImportModel {
        AppleMusicImportModel(store: LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }))
    }

    @Test func 보관함_ID가_없는_XML도_같은_파일이면_출처를_유지한다() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-library-\(UUID()).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["Tracks": [:]], format: .xml, options: 0)
        try data.write(to: url)
        let first = model(), second = model()
        await first.load(url)
        await second.load(url)
        #expect(first.library?.id != nil)
        #expect(first.library?.id == second.library?.id)
    }

    @Test func 목록을_바꾸어도_선택을_유지하고_제외한_곡은_선택하지_않는다() throws {
        let model = model()
        model.library = try AppleMusicLibrary.parse(AppleMusicXMLFixture.xml(tracks: [
            "1": AppleMusicXMLFixture.track(1), "2": AppleMusicXMLFixture.track(2), "3": AppleMusicXMLFixture.track(3, ["Protected": true])
        ], playlists: [["Playlist ID": 1, "Name": "합성 목록", "Playlist Items": [["Track ID": 2], ["Track ID": 2], ["Track ID": 3]]]]),
            isReadableFile: { _ in true })
        model.playlistID = "1"
        #expect(model.visibleTracks.map(\.id) == [2, 3])
        model.selectVisible(true)
        #expect(model.selected == [2])
        model.playlistID = ""
        model.selectVisible(true)
        #expect(model.selected == [1, 2])
        model.playlistID = "1"
        model.selectVisible(false)
        #expect(model.selectedTracks.map(\.id) == [1])
    }

    @Test func 다른_XML을_열다_실패하면_앞의_보관함을_잘못_추가하지_않는다() async throws {
        let model = model()
        model.library = try AppleMusicLibrary.parse(AppleMusicXMLFixture.xml(tracks: ["1": AppleMusicXMLFixture.track(1)]), isReadableFile: { _ in true })
        model.selected = [1]
        await model.load(URL(filePath: "/nonexistent-djc-fixture/\(UUID()).xml"))
        #expect(model.library == nil && model.selected.isEmpty)
        #expect(model.message != nil && !model.isBusy)
    }

    @Test func XML을_연_뒤_사라진_파일은_추가하기_전에_제외한다() async throws {
        let model = model()
        model.library = try AppleMusicLibrary.parse(AppleMusicXMLFixture.xml(tracks: ["1": AppleMusicXMLFixture.track(1, [
            "Location": "file:///nonexistent-djc-fixture/\(UUID()).mp3"
        ])]), isReadableFile: { _ in true })
        model.selected = [1]
        await model.addSelected()
        #expect(model.library?.tracks.first?.exclusion == .unavailableFile)
        #expect(model.selected.isEmpty && model.store.staged.isEmpty && !model.isBusy)
        #expect(model.message != nil)
    }

    @Test func 반영_중에는_가져오기를_시작하지_않는다() async throws {
        let model = model()
        model.library = try AppleMusicLibrary.parse(AppleMusicXMLFixture.xml(tracks: ["1": AppleMusicXMLFixture.track(1)]), isReadableFile: { _ in true })
        model.selected = [1]
        model.store.isWritingRekordbox = true
        await model.addSelected()
        #expect(model.library?.tracks.first?.exclusion == nil)
        #expect(model.store.staged.isEmpty && model.message == nil)
    }
}
