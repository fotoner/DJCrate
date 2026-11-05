import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

/// #238 후속: 두 형식 값이 다른 USB를 고칠 때 두 곳이 새지 않게 막는다. 값은 모두 지어낸 것이다.
/// - 계획이 다시 쓴 pdb가 편집이 건드리지 않은 행의 Device Library 값을 바꾸면 USB에 쓰기 전에 멈춘다(`pdb untouched`).
/// - 새 곡의 분석 파일 번호는 Device Library 값에만 남은 분석 경로의 번호도 피한다.
@Suite("USB 두 형식 값 보존의 틈")
struct UsbDeviceLibraryGuardTests {
    private static let write: Set<FaultyUsbFileSystem.Op> = [.makeDirectory, .writeNew, .copyDataNew, .setModificationDate, .rename, .remove,
                                                             .removeDirectoryIfEmpty]

    @Test("편집이 건드리지 않은 Device Library 값을 다시 쓴 pdb가 바꾸면 USB에 쓰기 전에 pdb untouched로 멈춘다")
    func untouchedCheckStopsBeforeWriting() throws {
        let (env, deviceBefore) = try UsbSharedRowValueTests.usbWithDifferingValues()
        let one = try #require(try env.read(.oneLibrary))
        var source = try env.source()
        #expect(source.deviceLibrary == deviceBefore, "읽기가 합치기 전 Device Library를 계획에 넘긴다")
        // 합치기가 Device Library 값을 잃은 회귀를 흉내 낸다: 그 값이 OneLibrary 값과 같은 채로 합치면 투영이 되돌릴 값이 없다.
        // 계획이 다시 쓰는 pdb는 OneLibrary 값이 되고, 원래 Device Library 값(source.deviceLibrary)과 달라진다
        var aligned = deviceBefore
        aligned.artists[0].name = try #require(one.artists.first { $0.id == aligned.artists[0].id }).name
        aligned.albums[0].name = try #require(one.albums.first { $0.id == aligned.albums[0].id }).name
        aligned.tracks[0].title = try #require(one.tracks.first { $0.id == aligned.tracks[0].id }).title
        source.current = UsbLibrary.merge(oneLibrary: one, deviceLibrary: aligned).0

        let before = env.usb.tree(), session = env.usb.journal()?.changes.session, backups = env.usb.backupFolders().count
        let fileSystem = env.usb.fileSystem()
        let usbPrefix = env.usb.usbURL.path + "/"
        let usbWrites = Mutex<[String]>([])
        fileSystem.onOperation = { op, url in
            if Self.write.contains(op), url.path.hasPrefix(usbPrefix) { usbWrites.withLock { $0.append("\(op.rawValue) \(url.path)") } }
        }
        var failure: UsbError?
        do {
            _ = try env.plan([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))], withLocal: false, source: source,
                             fileSystem: fileSystem)
            Issue.record("pdb untouched로 멈추지 않고 계획이 끝났다")
        } catch let error as UsbError {
            failure = error
        }
        guard case let .planCheckFailed(detail)? = failure else {
            Issue.record("planCheckFailed가 아니다: \(String(describing: failure))")
            return
        }
        #expect(detail.hasPrefix("pdb untouched: "), "\(detail)")
        for table in ["artist.name", "album.name", "content.title"] { #expect(detail.contains(table), "\(detail)") }
        #expect(usbWrites.withLock { $0 }.isEmpty)
        #expect(env.usb.tree() == before)
        // 쓰기를 시작하지 않았으니 저널·백업도 그대로다
        #expect(env.usb.journal()?.changes.session == session && env.usb.backupFolders().count == backups)
    }

    @Test("두 형식의 분석 경로가 다르고 Device Library 쪽 파일이 없어도 새 곡은 그 번호를 받지 않아 쓴 뒤 검증에 걸리지 않고 끝까지 쓴다")
    func addedTrackAvoidsDeviceOnlyAnalysisSlot() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        try env.addLocal(["103"])
        let edit = UsbLibraryEdit.addTracks(localContentIDs: ["103"], playlist: .id("1"))
        // 새 곡이 받을 분석 폴더를 지금 USB로 계획해 알아낸다(곡 경로로 정해진다)
        let known = Set(try env.read().tracks.map(\.id))
        let probe = try env.plan([edit])
        let probed = try #require(probe.applied?.tracks.first { !known.contains($0.id) })
        let stem = (probed.analysisDataPath as NSString).deletingPathExtension
        #expect(stem.hasSuffix("/ANLZ0000"))
        let folder = (probed.analysisDataPath as NSString).deletingLastPathComponent
        let contested = folder + "/ANLZ0000.DAT", next = folder + "/ANLZ0001.DAT"

        // Device Library에서만 곡 1이 그 폴더의 번호 0을 가리키게 한다(그 파일은 USB에 없다). OneLibrary는 자기 파일을 가리킨 채다
        let report = try #require(try env.source().pdbReport)
        var device = try #require(try env.read(.deviceLibrary))
        let first = device.tracks[0]
        device.tracks[0].analysisDataPath = contested
        let pdb = try PdbWriter.files(device, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                          previousExtSequence: report.extHeader?.sequence ?? 0))
        env.usb.write(UsbLayout.exportPdb, pdb.export)
        env.usb.write(UsbLayout.exportExtPdb, pdb.exportExt)
        let oneBefore = try #require(try env.read(.oneLibrary))
        let ownPath = try #require(oneBefore.tracks.first { $0.id == first.id }?.analysisDataPath)
        #expect(ownPath != contested && !env.usb.exists(String(contested.dropFirst())) && env.usb.exists(String(ownPath.dropFirst())))
        #expect(try env.source().mismatches.contains(.trackFieldDiffers(id: first.id, field: "analysisDataPath")))

        let (result, written) = try env.edit([edit])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(written.outcome == .written, "\(written.outcome)")
        let one = try #require(try env.read(.oneLibrary)), after = try #require(try env.read(.deviceLibrary))
        for library in [one, after] {
            let added = try #require(library.tracks.first { !known.contains($0.id) })
            #expect(added.analysisDataPath == next)
        }
        // 있던 곡의 두 형식 경로는 그대로, 새 곡은 번호 1에 파일을 만든다
        #expect(one.tracks.first { $0.id == first.id }?.analysisDataPath == ownPath)
        #expect(after.tracks.first { $0.id == first.id }?.analysisDataPath == contested)
        #expect(env.usb.exists(String(next.dropFirst())) && !env.usb.exists(String(contested.dropFirst())))
    }
}
