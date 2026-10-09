import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

extension UsbExportSessionTests {
    @Test("빈 USB에 iTunes 부분 선택과 로컬 목록을 두 형식으로 내보내고 원본 DB는 그대로다")
    func emptyUsbExportsITunesAndLocalLayout() throws {
        let env = try Env(tracks: 3)
        try env.local.local.addPlaylist(id: "800", name: "합성 로컬", seq: 1, contentIDs: ["103", "101"])
        func list(_ id: String, name: String, parent: String = PlaylistLayout.root, tracks: [String]) -> PlaylistLayout.Item {
            .init(id: id, name: name, parentID: parent, entries: tracks.enumerated().map {
                PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element)
            })
        }
        // iTunes 폴더의 선택하지 않은 자식은 미리 잘라낸 모델을 받는다.
        let selected = PlaylistLayout([
            (item: list("800", name: "합성 로컬", tracks: ["103", "101"]), seq: 1),
            (item: .init(id: "itunes:F", name: "합성 iTunes 폴더", isFolder: true), seq: 2),
            (item: list("itunes:A", name: "합성 iTunes 가", parent: "itunes:F", tracks: ["102", "101", "102"]), seq: 1),
            (item: list("itunes:C", name: "합성 iTunes 다", parent: "itunes:F", tracks: ["101", "103"]), seq: 3),
        ])
        let sourceBefore = try Data(contentsOf: env.local.database)
        let selection = UsbSelection.playlists(selected.childIDs(of: PlaylistLayout.root))
        let options = Self.options { $0.playlistLayout = selected }
        let session = env.session()
        let preview = try session.preview(selection: selection, options: options)
        #expect(preview.blocks.isEmpty)
        #expect(env.usb.tree().isEmpty)
        #expect(preview.plan.playlists.map(\.localID) == ["800", "itunes:F", "itunes:A", "itunes:C"])
        #expect(preview.plan.tracks.map(\.localContentID) == ["103", "101", "102"])
        let report = try session.write(selection: selection, options: options, progress: { _ in }, isCancelled: { false })
        #expect(report.outcome == .written)
        let plan = try #require(session.lastPreview).plan
        let contentIDs = Dictionary(uniqueKeysWithValues: plan.tracks.map { ($0.localContentID, $0.contentID) })
        let first = try #require(contentIDs["101"])
        let second = try #require(contentIDs["102"])
        let third = try #require(contentIDs["103"])
        #expect(plan.playlists.map(\.contentIDs) == [
            [third, first], [], [second, first, second], [first, third],
        ])
        // USB DB는 Mac 쪽 사본으로만 열고 두 형식의 순서·중복이 계획과 같은지 본다.
        let copies = env.usb.folder.appending(path: "read-copies")
        let snapshot = try UsbSnapshot.take(root: env.usb.root, into: copies)
        let one = try OneLibraryReader.read(copyAt: #require(snapshot.oneLibrary))
        let device = try #require(try PdbReader.read(snapshot: snapshot)).0
        for library in [one, device] {
            let format = try #require(library.formats.first)
            #expect(library.playlists.count == plan.playlists.count)
            for expected in plan.playlists {
                let actual = try #require(library.playlists.first { $0.id == expected.playlistID })
                #expect(actual.name == expected.name)
                #expect(actual.parentID == expected.parentID)
                #expect(actual.entries[format] == expected.contentIDs)
                #expect(actual.sortOrder[format] == expected.sortOrder)
            }
        }
        #expect(try Data(contentsOf: env.local.database) == sourceBefore)
        #expect(env.leftoverCopies.isEmpty)
        #expect(env.leftoverStaging.isEmpty)
    }

    @Test("목록 모델이 있어도 없는 음원은 기존 곡 검사를 우회하지 못한다")
    func layoutDoesNotBypassLocalTrackValidation() throws {
        let env = try Env(tracks: 1)
        let source = try RekordboxLibrary.load(snapshot: env.local.database)
        let path = try #require(source.tracks.first?.folderPath)
        try FileManager.default.removeItem(at: URL(filePath: path))
        let selected = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [.init(trackNo: 1, contentID: "101")]), 1)])
        let preview = try env.session().preview(selection: .playlists(["itunes:A"]), options: Self.options { $0.playlistLayout = selected })
        #expect(preview.blockedTrackCount == 1)
        #expect(preview.changes == nil)
        #expect(env.usb.tree().isEmpty)
    }

    @Test("미반영·잘못된 목록 모델은 미리 보기에 막힘을 남기고 USB에는 쓰지 않는다", arguments: [false, true])
    func invalidLayoutReportedWithoutWriting(pending: Bool) throws {
        let env = try Env(tracks: 1)
        let item = PlaylistLayout.Item(id: pending ? "new:pending" : "itunes:A", name: "합성 목록",
                                       parentID: pending ? PlaylistLayout.root : "missing",
                                       entries: [.init(trackNo: 1, contentID: "101")])
        let layout = PlaylistLayout([(item, 1)])
        let selection = UsbSelection.playlists([item.id])
        let options = Self.options { $0.playlistLayout = layout }
        let preview = try env.session().preview(selection: selection, options: options)
        #expect(preview.blocks.map(\.code) == [pending ? "pendingPlaylist" : "invalidPlaylistLayout"])
        #expect(preview.changes == nil)
        #expect(throws: UsbError.self) {
            try env.session().write(selection: selection, options: options, progress: { _ in }, isCancelled: { false })
        }
        #expect(env.usb.tree().isEmpty)
        #expect(env.leftoverCopies.isEmpty)
        #expect(env.leftoverStaging.isEmpty)
    }
}
