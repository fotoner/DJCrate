import CoreGraphics
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 화면 모델이 조립 지점에서 받는 포트(목록 미리 보기 파형·곡 그림·USB 동기화 사본 지문·공유 설정)의 실제 구현이 지키는 약속.
/// 화면 모델은 이 포트로만 파일을 읽는다(#167 H3). 합성 분석 파일·그림·DB 사본만 쓴다.
@Suite("목록 화면·설정 포트 실제 구현의 약속")
struct LibraryDisplayPortTests {
    @Test("USB 동기화 사본: 같은 파일의 지문은 같고, 빌린 사본은 준 폴더에 원본 바이트로 생기며, 지문 뒤 바뀐 사본은 빌리지 않는다")
    func usbSyncSnapshots() throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appending(path: "master-20261008T000000Z.db")
        try Data("합성 A".utf8).write(to: source)
        let stamp = try UsbSyncSnapshots.live.stamp(source)
        #expect(try UsbSyncSnapshots.live.stamp(source) == stamp)
        let copies = folder.url.appending(path: "copies")
        let lease = try UsbSyncSnapshots.live.lease(stamp, copies)
        #expect(lease.database.resolvingSymlinksInPath().path.hasPrefix(copies.resolvingSymlinksInPath().path))
        #expect(try Data(contentsOf: lease.database) == Data("합성 A".utf8) && lease.provenance == stamp)
        try Data("합성 B".utf8).write(to: source, options: .atomic)
        #expect(throws: (any Error).self) { try UsbSyncSnapshots.live.lease(stamp, copies) }
    }

    @Test("미리 보기 파형: 분석 파일에서 400칸을 읽고 판은 파일이 같으면 같으며, 데우면 캐시 파일이 생기고 비우면 사라진다")
    func previewWaveforms() async throws {
        let folder = try TemporaryFolder()
        let share = folder.url.appending(path: "share")
        let dat = share.appending(path: "PIONEER/USBANLZ/a/ANLZ0000.DAT")
        try FileManager.default.createDirectory(at: dat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AnlzBuilder.file([AnlzBuilder.pwav(Array(repeating: 31, count: 1200))]).write(to: dat)
        let cacheFile = folder.url.appending(path: "preview-waveforms.plist")
        let previews = PreviewWaveforms.live(store: PreviewWaveformStore(file: cacheFile))

        let waveform = try #require(await previews.waveform("u", dat))
        #expect(waveform.blueColumns.count == 400)
        #expect(await previews.revision("u", dat) == (await previews.revision("u", dat)))
        #expect(await previews.waveform("없음", nil) == nil)
        await previews.warm([(uuid: "u", analysisPath: "/PIONEER/USBANLZ/a/ANLZ0000.DAT")], share)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
        await previews.clear()
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test("미리 보기 파형: 분석 파일이 없을 때 채울 음원 파형은 400칸이고, 읽지 못하는 음원은 nil")
    func previewWaveformFallback() throws {
        let folder = try TemporaryFolder()
        let audio = try AudioFixture.wav(seconds: 1, in: folder.url)
        let previews = PreviewWaveforms.live(store: PreviewWaveformStore(file: nil))
        let columns = try #require(previews.audioColumns(audio, "fallback-\(UUID().uuidString)"))
        #expect(!columns.isEmpty && columns.count <= 400)
        #expect(previews.audioColumns(folder.url.appending(path: "없는.wav"), "fallback-\(UUID().uuidString)") == nil)
    }

    @Test("곡 그림: rekordbox 그림은 큰 그림부터 줄여 읽고, 목록 칸은 작은 그림(_s)을 64픽셀로 읽는다")
    func artworkThumbnails() throws {
        let folder = try TemporaryFolder()
        let share = folder.url.appending(path: "share")
        let directory = share.appending(path: "PIONEER/Artwork/00001")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ImageFixture.image(width: 500, height: 500).write(to: directory.appending(path: "a1.jpg"))
        try ImageFixture.image(width: 80, height: 80).write(to: directory.appending(path: "a1_s.jpg"))
        let path = "/PIONEER/Artwork/00001/a1.jpg"

        let large = try #require(ArtworkFiles.live.thumbnail(path, share, 240))
        #expect(max(large.width, large.height) == 240)
        let small = try #require(ArtworkFiles.live.listThumbnail(path, share))
        #expect(max(small.width, small.height) == 64)
        #expect(ArtworkFiles.live.thumbnail(nil, share, 240) == nil && ArtworkFiles.live.listThumbnail("/PIONEER/Artwork/없음.jpg", share) == nil)
    }

    /// 곡 목록은 USB DB에 적힌 경로로 USB 파일을 읽는다(#256). 링크를 거치면 열지 않는 자리(SAFE-24)나 이 Mac의 다른 파일에 닿으므로 열지 않는다
    @Test("USB 곡 그림·분석 파일: 볼륨 안 파일만 읽고 링크를 거치거나 열지 않는 자리면 열지 않는다")
    func volumeFilesRefuseLinks() throws {
        let folder = try TemporaryFolder()
        let fm = FileManager.default
        let volume = folder.url.appending(path: "volume")
        let outside = folder.url.appending(path: "outside.jpg")
        try ImageFixture.image(width: 80, height: 80).write(to: outside)
        let artwork = volume.appending(path: "PIONEER/Artwork/00001")
        try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
        try ImageFixture.image(width: 80, height: 80).write(to: artwork.appending(path: "b1.jpg"))
        try fm.createSymbolicLink(at: artwork.appending(path: "b2.jpg"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: volume.appending(path: "PIONEER/Artwork/00002"), withDestinationURL: folder.url)
        let cdp = volume.appending(path: "PIONEER/CDP")
        try fm.createDirectory(at: cdp, withIntermediateDirectories: true)
        try ImageFixture.image(width: 80, height: 80).write(to: cdp.appending(path: "b3.jpg"))

        let small = try #require(ArtworkFiles.live.volumeThumbnail(volume, "PIONEER/Artwork/00001/b1.jpg", 64))
        #expect(max(small.width, small.height) == 64)
        #expect(ArtworkFiles.live.volumeThumbnail(volume, "PIONEER/Artwork/00001/b2.jpg", 64) == nil)
        #expect(ArtworkFiles.live.volumeThumbnail(volume, "PIONEER/Artwork/00002/outside.jpg", 64) == nil)
        #expect(ArtworkFiles.live.volumeThumbnail(volume, "PIONEER/CDP/b3.jpg", 64) == nil)

        let previews = PreviewWaveforms.live(store: PreviewWaveformStore(file: nil))
        func analysis(_ folderName: String) throws -> URL {
            let url = volume.appending(path: "PIONEER/USBANLZ/P016/\(folderName)")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let plain = try analysis("0000875E")
        try Data("DAT".utf8).write(to: plain.appending(path: "ANLZ0000.DAT"))
        try Data("EXT".utf8).write(to: plain.appending(path: "ANLZ0000.EXT"))
        #expect(previews.volumeFile(volume, "PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT")?.path
            == volume.appending(path: "PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT").path)
        // 미리 보기는 옆 .EXT도 연다. .EXT가 링크면 .DAT도 읽지 않는다
        let linkedExt = try analysis("00000001")
        try Data("DAT".utf8).write(to: linkedExt.appending(path: "ANLZ0000.DAT"))
        try fm.createSymbolicLink(at: linkedExt.appending(path: "ANLZ0000.EXT"), withDestinationURL: outside)
        #expect(previews.volumeFile(volume, "PIONEER/USBANLZ/P016/00000001/ANLZ0000.DAT") == nil)
        let linkedDat = try analysis("00000002")
        try fm.createSymbolicLink(at: linkedDat.appending(path: "ANLZ0000.DAT"), withDestinationURL: outside)
        #expect(previews.volumeFile(volume, "PIONEER/USBANLZ/P016/00000002/ANLZ0000.DAT") == nil)
        try fm.createSymbolicLink(at: volume.appending(path: "PIONEER/USBANLZ/P017"), withDestinationURL: plain.deletingLastPathComponent())
        #expect(previews.volumeFile(volume, "PIONEER/USBANLZ/P017/0000875E/ANLZ0000.DAT") == nil)
        #expect(previews.volumeFile(volume, "PIONEER/CDP/ANLZ0000.DAT") == nil)
    }

    @Test("공유 설정: 적는 이름만 파일에 남기고 다른 값은 그대로 둔다(CLI가 같은 파일을 읽는다)")
    func sharedSettings() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "shared-settings.json")
        let shared = SharedSettingsWriter.live(file: file)
        #expect(shared.names == [SettingKeys.pointSnapshotAutoDays.name])
        try shared.set([SettingKeys.pointSnapshotAutoDays.name: 21.0, "다른 설정": true])
        #expect(SharedSettingsFile.value(SettingKeys.pointSnapshotAutoDays, in: file) == 21)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(stored?.keys.sorted() == [SettingKeys.pointSnapshotAutoDays.name])
    }
}
