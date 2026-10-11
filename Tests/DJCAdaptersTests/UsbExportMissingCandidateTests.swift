import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

extension UsbExportSessionTests {
    @Test("목록 모델의 없는 곡·삭제된 곡을 막힘으로 알리고 정상 곡의 반복 순서는 유지한다")
    func layoutReportsMissingAndDeletedCandidateIDs() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        try db.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '102'")
        db.close()
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "999"),
            .init(trackNo: 3, contentID: "101"), .init(trackNo: 4, contentID: "102"),
        ]), 1)])
        let preview = try env.session().preview(selection: .playlists(["itunes:A"]), options: Self.options { $0.playlistLayout = layout })
        let missing = preview.blocks.filter { $0.code == "localTrackMissing" }
        #expect(Set(missing.map(\.scope)) == [.track("999"), .track("102")])
        #expect(preview.blockedTrackCount == 2)
        let id = try #require(preview.plan.tracks.first { $0.localContentID == "101" }?.contentID)
        #expect(preview.plan.playlists.first?.contentIDs == [id, id])
        #expect(env.usb.tree().isEmpty && env.usb.backupFolders().isEmpty)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    @Test("native 새 내보내기의 누락은 선택 파일까지 전체 묶음을 막는다")
    func nativeExportCannotMarkIncompleteLayoutAsSynced() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        try db.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '102'")
        db.close()
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "999"),
            .init(trackNo: 3, contentID: "102"), .init(trackNo: 4, contentID: "101"),
        ]), 1)])
        let options = Self.options {
            $0.playlistLayout = layout
            $0.syncSelection = .init(localDBID: 42, sourceNodes: [.init(id: "itunes:A", parentID: nil, isFolder: false)],
                                     selection: .init(selectedIDs: ["itunes:A"]), enabled: true, playlistRefs: [:], baseFiles: [:])
        }
        let session = env.session()
        let preview = try session.preview(selection: .playlists(["itunes:A"]), options: options)
        #expect(preview.blocks.filter { $0.code == "localTrackMissing" }.count == 2)
        #expect(preview.blocks.contains { $0.code == "syncSelectionIncomplete" })
        #expect(preview.changes == nil)
        #expect(throws: UsbError.self) {
            try session.write(selection: .playlists(["itunes:A"]), options: options, progress: { _ in }, isCancelled: { false })
        }
        #expect(env.usb.tree().isEmpty && env.usb.backupFolders().isEmpty && env.usb.journal() == nil)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    /// 2026-10-08 빈 USB 실험: rekordbox의 첫 SYNC는 DB와 두 선택 파일을 함께 만들었다. 같은 쓰기 묶음에서 만들고 되돌리면 함께 지운다.
    @Test("빈 USB의 native 내보내기는 같은 쓰기에서 두 형식의 선택 파일을 새로 만들고 되돌리면 지운다")
    func nativeExportCreatesSelectionFilesOnBlankUsb() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        let local = try UsbLocalSource(database: db).localDBID()
        db.close()
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "102"),
        ]), 1)])
        let options = Self.options {
            $0.playlistLayout = layout
            $0.syncSelection = .init(localDBID: local, sourceNodes: [.init(id: "itunes:A", parentID: nil, isFolder: false, timestamp: 0)],
                                     selection: .init(selectedIDs: ["itunes:A"]), enabled: true, playlistRefs: [:], baseFiles: [:])
        }
        let session = env.session()
        let report = try session.write(selection: .playlists(["itunes:A"]), options: options, progress: { _ in }, isCancelled: { false })
        #expect(report.outcome == .written)
        let written = try #require(session.lastPreview?.changes?.syncSelection)
        #expect(written.formats == UsbFormat.defaultSet)
        for format in UsbFormat.allCases {
            let usbID = try #require(written.playlistIDs[format]?["itunes:A"])
            let expected = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n"
                + "<Sync DBID=\"\(dbid)\" AutomaticSync=\"1\" AllPlaylists=\"0\" IncludeCue=\"1\" ForcedSync=\"0\" Timestamp=\"0\">\r\n"
                + "  <Playlists>\r\n"
                + "    <NODE Id=\"0\" ParentId=\"0\" Attribute=\"1\" Lib_Type=\"1\" Dev_ID=\"0\" Timestamp=\"0\" CheckType=\"2\"/>\r\n"
                + "    <NODE Id=\"A\" ParentId=\"0\" Attribute=\"0\" Lib_Type=\"1\" Dev_ID=\"\(usbID)\" Timestamp=\"0\" CheckType=\"1\"/>\r\n"
                + "  </Playlists>\r\n</Sync>\r\n"
            #expect(env.usb.data(UsbSyncSelectionFile.relativePath(for: format)) == Data(expected.utf8))
        }
        #expect(try env.usb.restore().outcome == .restored)
        for format in UsbFormat.allCases { #expect(!env.usb.exists(UsbSyncSelectionFile.relativePath(for: format))) }
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }

    /// 2026-10-08 실제 동기화: rekordbox는 분석 파일이 없는 곡을 내보내기 기록에 남기고 나머지를 동기화했다
    @Test("빈 USB의 native 내보내기는 넣지 못한 곡만 빼고 선택 파일까지 쓰고, 건너뛴 곡을 알린다")
    func nativeExportSkipsUnexportableTracksAndReportsThem() throws {
        let env = try Env(tracks: 2)
        let db = try env.local.local.open()
        let local = try UsbLocalSource(database: db).localDBID()
        try db.execute("UPDATE djmdContent SET AnalysisDataPath = NULL WHERE ID = '102'")
        db.close()
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "102"), .init(trackNo: 2, contentID: "101"), .init(trackNo: 4, contentID: "101"),
        ]), 1)])
        let skipped = UsbBlock(code: "iTunes.protectedFile", scope: .track("itunes:synthetic"), message: "합성: 보호된 음원")
        let options = Self.options {
            $0.playlistLayout = layout
            $0.syncSelection = .init(localDBID: local, sourceNodes: [.init(id: "itunes:A", parentID: nil, isFolder: false, timestamp: 0)],
                                     selection: .init(selectedIDs: ["itunes:A"]), enabled: true, playlistRefs: [:], baseFiles: [:],
                                     skippedTracks: [skipped])
        }
        let session = env.session()
        let preview = try session.preview(selection: .playlists(["itunes:A"]), options: options)
        #expect(!preview.blocks.contains { $0.code == "syncSelectionIncomplete" })
        #expect(preview.blocks.contains(skipped))
        #expect(preview.blockedTrackCount == 2)
        #expect(preview.changes != nil)
        let report = try session.write(selection: .playlists(["itunes:A"]), options: options, progress: { _ in }, isCancelled: { false })
        #expect(report.outcome == .written)
        let id = try #require(session.lastPreview?.plan.tracks.first { $0.localContentID == "101" }?.contentID)
        #expect(session.lastPreview?.plan.tracks.map(\.localContentID) == ["101"])
        #expect(session.lastPreview?.plan.playlists.first?.contentIDs == [id, id])
        for format in UsbFormat.allCases { #expect(env.usb.exists(UsbSyncSelectionFile.relativePath(for: format))) }
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }
}
