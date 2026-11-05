import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #238: 두 형식에 같은 id로 있는 공유 표 행(artist·album 등)이나 곡의 두 형식 모두의 칸 값이 다른 USB가 있다.
/// 편집이 Device Library를 다시 써도 편집이 건드리지 않은 칸은 그 형식 값을 지킨다(전에는 OneLibrary 값으로 바뀌었다). 값은 모두 지어낸 것이다.
@Suite("USB 두 형식 값이 다른 공유 행")
struct UsbSharedRowValueTests {
    /// 곡 101·102와 목록 900을 내보낸 USB의 Device Library에서만 아티스트·앨범 이름과 곡 1 제목을 바꾼다. 바꾼 뒤 Device Library 읽기를 돌려준다
    static func usbWithDifferingValues() throws -> (UsbEditFixture, UsbLibrary) {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        let report = try #require(try env.source().pdbReport)
        var device = try #require(try env.read(.deviceLibrary))
        device.artists[0].name = "합성 DL 아티스트"
        device.albums[0].name = "합성 DL 앨범"
        device.tracks[0].title = "합성 DL 제목"
        let pdb = try PdbWriter.files(device, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                          previousExtSequence: report.extHeader?.sequence ?? 0))
        env.usb.write(UsbLayout.exportPdb, pdb.export)
        env.usb.write(UsbLayout.exportExtPdb, pdb.exportExt)
        return (env, try #require(try env.read(.deviceLibrary)))
    }

    @Test("편집이 건드리지 않은 공유 행·곡 칸은 Device Library를 다시 써도 칸마다 Device Library 값 그대로다")
    func editKeepsDeviceLibraryValues() throws {
        let (env, deviceBefore) = try Self.usbWithDifferingValues()
        let oneBefore = try #require(try env.read(.oneLibrary))
        let artist = deviceBefore.artists[0].id, album = deviceBefore.albums[0].id, track = deviceBefore.tracks[0].id
        let mismatches = Set(try env.source().mismatches)
        #expect(mismatches.isSuperset(of: [.sharedRowDiffers(table: "artist", id: artist), .sharedRowDiffers(table: "album", id: album),
                                           .trackFieldDiffers(id: track, field: "title")]))

        let (result, report) = try env.edit([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))], withLocal: false)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(result.formatsWritten == UsbFormat.defaultSet)
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        #expect(device.playlists.first { $0.id == 1 }?.name == "합성 바뀐 이름")
        #expect(one.playlists.first { $0.id == 1 }?.name == "합성 바뀐 이름")
        #expect(device.artists.first { $0.id == artist }?.name == "합성 DL 아티스트")
        #expect(device.albums.first { $0.id == album }?.name == "합성 DL 앨범")
        #expect(device.tracks.first { $0.id == track }?.title == "합성 DL 제목")
        // 목록 말고는 칸 단위로 편집 전 Device Library·OneLibrary 그대로다
        for (before, after, format) in [(deviceBefore, device, UsbFormat.deviceLibrary), (oneBefore, one, .oneLibrary)] {
            let differences = UsbLibraryDiff.compare(before, after, options: .init(skipTables: ["playlist"], formats: [format])).differences
            #expect(differences.isEmpty, "\(format): \(differences)")
        }
        #expect(try env.source().mismatches.count == mismatches.count)
    }

    /// 곡 101·102(아티스트·그림·분석 파일이 곡마다 다름)를 내보낸 USB의 Device Library에서만 곡 1이 곡 2의 아티스트·그림·분석 파일을 가리키게 한다.
    /// 바꾼 뒤 Device Library 읽기를 돌려준다
    static func usbWithDeviceOnlyReferences() throws -> (UsbEditFixture, UsbLibrary) {
        let env = try UsbEditFixture()
        try env.local.addTrack(id: "101", artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        try env.local.addTrack(id: "102", artist: ("2", "합성 둘째 아티스트"), album: ("30", "합성 앨범"))
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        let report = try #require(try env.source().pdbReport)
        var device = try #require(try env.read(.deviceLibrary))
        #expect(device.tracks[0].artistID != device.tracks[1].artistID && device.tracks[0].imageID != device.tracks[1].imageID)
        device.tracks[0].artistID = device.tracks[1].artistID
        device.tracks[0].imageID = device.tracks[1].imageID
        device.tracks[0].analysisDataPath = device.tracks[1].analysisDataPath
        let pdb = try PdbWriter.files(device, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                          previousExtSequence: report.extHeader?.sequence ?? 0))
        env.usb.write(UsbLayout.exportPdb, pdb.export)
        env.usb.write(UsbLayout.exportExtPdb, pdb.exportExt)
        return (env, try #require(try env.read(.deviceLibrary)))
    }

    @Test("Device Library 곡이 그 형식 값으로 가리키는 아티스트·그림·분석 파일은 OneLibrary에서 가리키던 곡을 빼도 행과 파일이 남는다")
    func deviceReferencesSurviveRemoval() throws {
        let (env, deviceBefore) = try Self.usbWithDeviceOnlyReferences()
        let first = deviceBefore.tracks[0], second = deviceBefore.tracks[1]
        let image = try #require(deviceBefore.images.first { $0.id == second.imageID })
        let artwork = String(try #require(image.pdbPath).dropFirst()), analysis = String(second.analysisDataPath.dropFirst())
        let (result, report) = try env.edit([.removeTracks(usbContentIDs: [second.id])], withLocal: false)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        let device = try #require(try env.read(.deviceLibrary))
        let track = try #require(device.tracks.first { $0.id == first.id })
        #expect(track.artistID == second.artistID && track.imageID == second.imageID && track.analysisDataPath == second.analysisDataPath)
        #expect(device.artists.contains { $0.id == second.artistID })
        #expect(device.images.contains { $0.id == second.imageID })
        #expect(env.usb.data(artwork) != nil && env.usb.data(analysis) != nil)
        #expect(!(result.changes?.removals.contains { [artwork, analysis].contains($0.path) } ?? false))
    }

    @Test("그림 갱신은 Device Library 곡도 갱신한 그림 파일을 가리키게 하고, 갱신하지 않은 칸(아티스트·분석 파일)은 그 형식 값을 지킨다")
    func refreshedTrackPointsBothFormatsAtNewFiles() throws {
        let (env, deviceBefore) = try Self.usbWithDeviceOnlyReferences()
        let first = deviceBefore.tracks[0], second = deviceBefore.tracks[1]
        let one = try #require(try env.read(.oneLibrary))
        let own = try #require(one.tracks.first { $0.id == first.id }?.imageID)
        let ownArtwork = String(try #require(one.images.first { $0.id == own }?.oneLibraryPath).dropFirst())
        let otherArtwork = String(try #require(deviceBefore.images.first { $0.id == second.imageID }?.pdbPath).dropFirst())
        let otherBefore = env.usb.data(otherArtwork)
        let small = Data([0xFF, 0xD8, 0x09, 0x09, 0xFF, 0xD9])
        try env.local.local.writeArtwork(track: TrackSpec(id: "101"), imagePath: "/PIONEER/Artwork/101/artwork.jpg",
                                         small: small, medium: Data([0xFF, 0xD8, 0x0A, 0x0A, 0xFF, 0xD9]))
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [first.id], parts: [.artwork])])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        #expect(env.usb.data(ownArtwork) == small && env.usb.data(otherArtwork) == otherBefore)
        let device = try #require(try env.read(.deviceLibrary))
        let track = try #require(device.tracks.first { $0.id == first.id })
        #expect(track.imageID == own)
        #expect(track.artistID == second.artistID && track.analysisDataPath == second.analysisDataPath)
        #expect(device.tracks.first { $0.id == second.id }?.imageID == second.imageID)
    }

    @Test("Device Library 파일이 없는 그림을 갱신해도 Device Library 곡은 없는 그림 행을 가리키지 않는다")
    func artworkRefreshWithoutDeviceArtwork() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.export(tracks: ["101", "102"])
        let report = try #require(try env.source().pdbReport)
        var device = try #require(try env.read(.deviceLibrary))
        let first = device.tracks[0]
        device.images.removeAll { $0.id == first.imageID }
        device.tracks[0].imageID = nil
        let pdb = try PdbWriter.files(device, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                          previousExtSequence: report.extHeader?.sequence ?? 0))
        env.usb.write(UsbLayout.exportPdb, pdb.export)
        env.usb.write(UsbLayout.exportExtPdb, pdb.exportExt)
        try env.local.local.writeArtwork(track: TrackSpec(id: "101"), imagePath: "/PIONEER/Artwork/101/artwork.jpg",
                                         small: Data([0xFF, 0xD8, 0x0B, 0x0B, 0xFF, 0xD9]), medium: Data([0xFF, 0xD8, 0x0C, 0x0C, 0xFF, 0xD9]))
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let (result, written) = try env.edit([.refreshTracks(usbContentIDs: [first.id], parts: [.artwork])])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(written.outcome == .written)
        let after = try #require(try env.read(.deviceLibrary))
        let imageID = after.tracks.first { $0.id == first.id }?.imageID
        #expect(imageID == nil || after.images.contains { $0.id == imageID })
    }

    @Test("Device Library 곡이 그 형식 값으로 가리키는 그림은 다른 곡의 그림 갱신이 덮어쓰지 않고 새 그림을 만든다")
    func artworkRefreshKeepsDeviceReferencedImage() throws {
        let (env, deviceBefore) = try Self.usbWithDeviceOnlyReferences()
        let first = deviceBefore.tracks[0], second = deviceBefore.tracks[1]
        let image = try #require(deviceBefore.images.first { $0.id == second.imageID })
        let artwork = String(try #require(image.pdbPath).dropFirst())
        let before = env.usb.data(artwork)
        try env.local.local.writeArtwork(track: TrackSpec(id: "102"), imagePath: "/PIONEER/Artwork/102/artwork.jpg",
                                         small: Data([0xFF, 0xD8, 0x07, 0x07, 0xFF, 0xD9]), medium: Data([0xFF, 0xD8, 0x08, 0x08, 0xFF, 0xD9]))
        try env.updateLocal("102", "TrackInfoUpdated = '2'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [second.id], parts: [.artwork])])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        #expect(result.changes?.writes.allSatisfy { $0.disposition == .create } == true)
        #expect(env.usb.data(artwork) == before)
        let device = try #require(try env.read(.deviceLibrary))
        #expect(device.tracks.first { $0.id == first.id }?.imageID == second.imageID)
        #expect(device.tracks.first { $0.id == second.id }?.imageID != second.imageID)
    }

    @Test("새 곡은 Device Library 값이 다른 이름 행을 이름으로 다시 쓰지 않아 두 형식 모두 로컬 이름을 가리킨다")
    func addedTrackDoesNotReuseDifferingRow() throws {
        let (env, deviceBefore) = try Self.usbWithDifferingValues()
        let artist = deviceBefore.artists[0].id, album = deviceBefore.albums[0].id
        try env.addLocal(["103"])
        let (result, report) = try env.edit([.addTracks(localContentIDs: ["103"], playlist: .id("1"))])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        for library in [one, device] {
            let added = try #require(library.tracks.first { !deviceBefore.tracks.map(\.id).contains($0.id) })
            #expect(library.artists.first { $0.id == added.artistID }?.name == "합성 아티스트")
            #expect(library.albums.first { $0.id == added.albumID }?.name == "합성 앨범")
        }
        #expect(device.artists.first { $0.id == artist }?.name == "합성 DL 아티스트")
        #expect(device.albums.first { $0.id == album }?.name == "합성 DL 앨범")
    }

    @Test("편집이 바꾼 곡 칸은 두 형식 모두 새 값을 쓰고, 같은 곡의 바꾸지 않은 칸과 공유 행은 Device Library 값을 지킨다")
    func refreshedFieldWrittenToBothFormats() throws {
        let (env, deviceBefore) = try Self.usbWithDifferingValues()
        let artist = deviceBefore.artists[0].id, track = deviceBefore.tracks[0].id
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [track], parts: [.info])])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        #expect(one.tracks.first { $0.id == track }?.title == "합성 새 제목")
        #expect(device.tracks.first { $0.id == track }?.title == "합성 새 제목")
        #expect(device.artists.first { $0.id == artist }?.name == "합성 DL 아티스트")
        #expect(one.artists.first { $0.id == artist }?.name == "합성 아티스트")
    }

    @Test("곡 정보 갱신은 로컬 값이 OneLibrary 값과 같아도 Device Library 곡에 같은 정보를 쓴다")
    func infoRefreshRewritesDeviceValuesEqualToOneLibrary() throws {
        let (env, deviceBefore) = try Self.usbWithDifferingValues()
        let track = deviceBefore.tracks[0].id
        try env.updateLocal("101", "TrackInfoUpdated = '2'")
        let (result, report) = try env.edit([.refreshTracks(usbContentIDs: [track], parts: [.info])])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        #expect(one.tracks.first { $0.id == track }?.title == "합성 곡 101")
        #expect(device.tracks.first { $0.id == track }?.title == "합성 곡 101")
        for library in [one, device] {
            let artistID = library.tracks.first { $0.id == track }?.artistID
            #expect(library.artists.first { $0.id == artistID }?.name == "합성 아티스트")
        }
    }
}
