import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #234: rekordbox가 동기화한 USB에는 공유 표(key·image 등) 행이 한 형식에만 있는 경우가 있다(2026-10-08 실물 USB 사본:
/// 아무 곡도 가리키지 않는 key 행이 Device Library에만, image 행이 OneLibrary에만 하나씩).
/// 이런 행은 USB에 원래 있던 차이로 두고, 편집이 그 행을 쓰게 될 때만 다른 형식에도 넣는다. 값은 모두 지어낸 것이다.
@Suite("USB 한 형식에만 있는 공유 표 행")
struct UsbSharedRowFormatTests {
    /// 곡 101·102와 목록 900을 내보낸 USB에 Device Library에만 있는 key 99, OneLibrary에만 있는 key 98을 더한다
    static func usbWithOneFormatKeys() throws -> UsbEditFixture {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "102"])
        try env.export(tracks: [], playlists: ["900"])
        let report = try #require(try env.source().pdbReport)
        var device = try #require(try env.read(.deviceLibrary))
        device.keys.append(UsbNamedRow(id: 99, name: "합성 DL 조성"))
        let pdb = try PdbWriter.files(device, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                          previousExtSequence: report.extHeader?.sequence ?? 0))
        env.usb.write(UsbLayout.exportPdb, pdb.export)
        env.usb.write(UsbLayout.exportExtPdb, pdb.exportExt)
        try env.oneLibrarySQL("INSERT INTO key (key_id, name) VALUES (98, '합성 OL 조성')")
        return env
    }

    @Test("한 형식에만 있는 공유 표 행은 그 형식 투영에만 있고, 다른 형식 곡이 가리키면 그 형식 투영에도 넣는다")
    func projectionKeepsFormatOfOneFormatRows() throws {
        let env = try Self.usbWithOneFormatKeys()
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: one, deviceLibrary: device)
        #expect(Set(mismatches) == [.sharedRowDiffers(table: "key", id: 98), .sharedRowDiffers(table: "key", id: 99)])
        #expect(merged.keys.map(\.id).contains(98) && merged.keys.map(\.id).contains(99))
        #expect(merged.projected(to: .oneLibrary) == one)
        #expect(merged.projected(to: .deviceLibrary) == device)

        // OneLibrary 곡이 Device Library에만 있던 행을 가리키게 되면 OneLibrary 투영에도 그 행이 있어야 한다(가리키는 곳 없는 번호를 쓰지 않게)
        var edited = merged
        edited.tracks[0].keyID = 99
        #expect(edited.projected(to: .oneLibrary).keys.map(\.id).contains(99))
        #expect(!edited.projected(to: .deviceLibrary).keys.map(\.id).contains(98))
    }

    @Test("편집이 건드리지 않은 한 형식 행은 다시 읽기 검증에서 차이로 세지 않고, 두 형식 모두 그대로 둔 채 쓴다")
    func editKeepsOneFormatRows() throws {
        let env = try Self.usbWithOneFormatKeys()
        let (result, report) = try env.edit([.playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름"))], withLocal: false)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(result.formatsWritten == UsbFormat.defaultSet)
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        #expect(one.keys.map(\.id).contains(98) && !one.keys.map(\.id).contains(99))
        #expect(device.keys.map(\.id).contains(99) && !device.keys.map(\.id).contains(98))
        #expect(one.playlists.first { $0.id == 1 }?.name == "합성 바뀐 이름")
        #expect(device.playlists.first { $0.id == 1 }?.name == "합성 바뀐 이름")
    }

    @Test("새 곡이 한 형식에만 있던 key 행을 쓰면 다른 형식에도 그 행을 넣어 두 형식이 같은 번호를 가리킨다")
    func addedTrackUsingOneFormatRowCopiesIt() throws {
        let env = try Self.usbWithOneFormatKeys()
        try env.addLocal(["103"])
        try env.local.local.insert("djmdKey", ["ID": .text("7"), "ScaleName": .text("합성 DL 조성"), "Seq": .int(1), "rb_local_deleted": .int(0)])
        try env.local.local.execute("UPDATE djmdContent SET KeyID = ? WHERE ID = ?", [.text("7"), .text("103")])
        let (result, report) = try env.edit([.addTracks(localContentIDs: ["103"], playlist: .id("1"))])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(report.outcome == .written)
        let one = try #require(try env.read(.oneLibrary)), device = try #require(try env.read(.deviceLibrary))
        let added = try #require(one.tracks.first { $0.id == 3 })
        #expect(added.keyID == 99)
        #expect(device.tracks.first { $0.id == 3 }?.keyID == 99)
        #expect(one.keys.contains { $0.id == 99 && $0.name == "합성 DL 조성" })
        #expect(!device.keys.map(\.id).contains(98))
    }
}
