import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 수정 엔진의 곡 갱신(그림·Device Library 행 미리 보기·로컬 짝)과 곡 더하기 막힘. 합성 USB만 쓴다
extension UsbEditEngineTests {
    static func setArtwork(_ env: UsbEditFixture, _ id: String, small: Data, medium: Data) throws {
        try env.local.local.writeArtwork(track: TrackSpec(id: id), imagePath: "/PIONEER/Artwork/\(id)/artwork.jpg", small: small, medium: medium)
    }

    @Test("로컬 그림이 바뀌면 같은 image id·폴더의 a·b·_m을 덮어쓴다")
    func artworkRefreshOverwritesChangedPicture() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let track = try #require(try env.read().tracks.first { $0.id == 1 })
        let image = try #require(try env.read().images.first { $0.id == track.imageID })
        let small = Data([0xFF, 0xD8, 0x07, 0x07, 0xFF, 0xD9]), medium = Data([0xFF, 0xD8, 0x08, 0x08, 0x08, 0xFF, 0xD9])
        try Self.setArtwork(env, "101", small: small, medium: medium)
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [1], parts: [.artwork])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        let writes = try #require(result.changes?.writes)
        #expect(writes.count == 4 && writes.allSatisfy { $0.disposition == .overwrite && $0.expectedExistingSHA256 != nil })
        let a = String(try #require(image.pdbPath).dropFirst()), b = String(try #require(image.oneLibraryPath).dropFirst())
        #expect(env.usb.data(a) == small && env.usb.data(b) == small)
        #expect(env.usb.data(a.replacingOccurrences(of: ".jpg", with: "_m.jpg")) == medium)
        #expect(try env.read().tracks.first { $0.id == 1 }?.imageID == track.imageID)
        // 같은 그림이면 다시 쓰지 않는다
        try env.updateLocal("101", "TrackInfoUpdated = '3'")
        let again = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.artwork])])
        #expect(again.outcome(1) == .unchanged)
    }

    @Test("USB 그림 행 경로가 아트워크 모양이 아니면(.. 등) 준비 폴더 밖에 만들지 않고 그 곡 그림 갱신을 막는다")
    func artworkRefreshRefusesUnsafeImagePath() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        let track = try #require(try env.read().tracks.first { $0.id == 1 })
        let imageID = try #require(track.imageID)
        // 준비 폴더(임시 폴더/staging-…/edit-1)에서 다섯 단계 위 = 시험 임시 폴더
        let escaped = "/PIONEER/Artwork/00001/../../../../../escaped/b\(imageID).jpg"
        try env.oneLibrarySQL("UPDATE image SET path = ? WHERE image_id = ?", [.text(escaped), .int(imageID)])
        try Self.setArtwork(env, "101", small: Data([0xFF, 0xD8, 0x07, 0xFF, 0xD9]), medium: Data([0xFF, 0xD8, 0x08, 0xFF, 0xD9]))
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.artwork])])
        #expect(!FileManager.default.fileExists(atPath: env.usb.folder.appending(path: "escaped").path))
        #expect(Self.isBlocked(result.outcome(1), "artworkPathRefused"))
        #expect(!(result.changes?.writes.contains { $0.destination.contains("..") } ?? false))
        // 다른 곡과 함께 갱신하면 그 곡만 뺀다
        try env.updateLocal("102", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        let both = try env.plan([.refreshTracks(usbContentIDs: [1, 2], parts: [.info, .artwork])])
        #expect(both.outcome(1) == .written && both.trackBlocks.map(\.code) == ["artworkPathRefused"])
        #expect(!FileManager.default.fileExists(atPath: env.usb.folder.appending(path: "escaped").path))
    }

    @Test("그림이 새로 생긴 곡은 새 image id를 마지막 아트워크 폴더에 둔다")
    func artworkRefreshAddsNewImage() throws {
        let env = try UsbEditFixture()
        try env.local.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try env.local.addTrack(id: "102", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"), artwork: false)
        try env.export(tracks: ["101", "102"])
        let before = try env.read()
        #expect(before.tracks.first { $0.id == 2 }?.imageID == nil)
        try Self.setArtwork(env, "102", small: Data([0xFF, 0xD8, 0x09, 0xFF, 0xD9]), medium: Data([0xFF, 0xD8, 0x0A, 0x0A, 0xFF, 0xD9]))
        try env.updateLocal("102", "TrackInfoUpdated = '2'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [2], parts: [.artwork])])
        #expect(result.outcome(1) == .written && report.outcome == .written)
        let after = try env.read()
        let imageID = try #require(after.tracks.first { $0.id == 2 }?.imageID)
        #expect(imageID > (before.images.map(\.id).max() ?? 0))
        let image = try #require(after.images.first { $0.id == imageID })
        #expect(image.oneLibraryPath?.hasPrefix("/PIONEER/Artwork/00001/b") == true && image.pdbPath?.hasPrefix("/PIONEER/Artwork/00001/a") == true)
        #expect(result.changes?.writes.allSatisfy { $0.disposition == .create } == true)
    }

    @Test("갱신한 곡이 Device Library 행이 되지 않으면(확장자·ISRC·길이·긴 이름) 그 편집만 막는다")
    func refreshDeviceRowBlocks() throws {
        let env = try Self.exported(["101", "102", "103", "104"], playlist: false)
        try env.updateLocal("101", "TrackInfoUpdated = '2', FileType = 5")
        try env.updateLocal("102", "TrackInfoUpdated = '2', ISRC = ?", [.text("ＪＰ－ＡＢＣ")])
        try env.updateLocal("103", "TrackInfoUpdated = '2', Commnt = ?", [.text(String(repeating: "가", count: 3_000))])
        // 긴 이름은 먼 모양으로 쓰므로 빈 쪽에도 안 들어가는 이름만 막힌다
        try env.local.local.addArtist(id: "9", name: String(repeating: "나", count: 2_100))
        try env.updateLocal("104", "TrackInfoUpdated = '2', ArtistID = '9'")
        let result = try env.plan((1...4).map { .refreshTracks(usbContentIDs: [$0], parts: [.info]) })
        #expect(Self.isBlocked(result.outcome(1), "fileTypeMismatchForDeviceLibrary"))
        #expect(Self.isBlocked(result.outcome(2), "isrcNotASCIIForDeviceLibrary"))
        #expect(Self.isBlocked(result.outcome(3), "trackRowTooLarge"))
        #expect(Self.isBlocked(result.outcome(4), "nameTooLongForDeviceLibrary"))
        #expect(result.changes == nil)
    }

    @Test("로컬 짝을 찾지 못한 곡의 갱신과 스냅샷에 없는 곡 더하기는 막는다")
    func localMatchMissing() throws {
        let env = try Self.exported(["101", "102"], playlist: false)
        try env.updateLocal("101", "MasterSongID = '424242'")
        let result = try env.plan([.refreshTracks(usbContentIDs: [1], parts: [.info]), .addTracks(localContentIDs: ["999"], playlist: nil)])
        #expect(Self.isBlocked(result.outcome(1), "localTrackNotFound"))
        #expect(Self.isBlocked(result.outcome(2), "localTrackMissing"))
        #expect(result.trackBlocks.map(\.code) == ["localTrackMissing"])
    }
}
