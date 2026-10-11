import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 수정 불변식: 편집 결과 USB를 읽은 모델 = 편집 뒤 모델을 새로 내보낸 모델(형식마다, ID·보존 행·pdb 순번·기존 곡 경로 빼고).
/// `djc lab usb-rebuild` + `usb-diff --ignore-ids`와 같은 비교를 합성 USB에서 편집 조합마다 한다
@Suite("USB 수정 불변식")
struct UsbEditInvariantTests {
    /// 쓴 USB를 읽어 합친 모델을 새 내보내기 모양(OneLibrary 새 파일·pdb fresh)으로 다시 만들어 읽은 모델과 비교하고,
    /// 형식마다 계획의 적용 결과(OneLibrary 투영·pdb 작성기 모델)와도 비교한다
    static func check(_ env: UsbEditFixture, _ result: UsbEditResult) throws {
        // 보존한 기기 행(기록·기기 큐 같은 모르는 표 행)은 새 내보내기가 만들지 않는다(불변식의 예외)
        var read = try env.read()
        read.histories = []
        read.unknownRows = []
        let folder = env.usb.folder.appending(path: "rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appending(path: "exportLibrary.db")
        try OneLibraryWriter.create(read, at: database)
        let files = try PdbWriter.files(read, mode: .fresh)
        let rebuilt = UsbLibrary.merge(oneLibrary: try OneLibraryReader.read(copyAt: database),
                                       deviceLibrary: try PdbReader.read(export: files.export, exportExt: files.exportExt).0).0
        let differences = UsbLibraryDiff.compare(read, rebuilt, options: .init(ignoreIDs: true)).differences
        #expect(differences.isEmpty, "다시 만든 모델과 다름: \(differences.prefix(5))")

        let applied = try #require(result.applied)
        let oneLibrary = try #require(try env.read(.oneLibrary))
        #expect(UsbLibraryDiff.compare(oneLibrary, applied.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary])).differences.isEmpty)
        if let written = result.pdbWritten {
            let device = try #require(try env.read(.deviceLibrary))
            #expect(UsbLibraryDiff.compare(device, written, options: .init(formats: [.deviceLibrary])).differences.isEmpty)
            // 기존 곡만 있는 쪽은 pdb 작성기 모델 = 적용 결과의 Device Library 투영(트랙 행 관찰값·지운 ID 빼고)
            let projected = UsbLibraryDiff.compare(device, applied.projected(to: .deviceLibrary),
                                                   options: .init(skipTables: ["deadIDs", "trackRowExtras"], formats: [.deviceLibrary])).differences
            #expect(projected.isEmpty, "적용 결과와 다름: \(projected.prefix(5))")
        }
        // 두 형식의 곡이 같다(한 형식이 막히지 않았으면)
        if result.formatsBlocked.isEmpty {
            #expect(try env.source().mismatches.filter(\.blocksEditing).isEmpty)
        }
    }

    @Test("곡 빼기 + 목록 만들기·이름 바꾸기·곡 넣기·곡 옮기기")
    func removeAndPlaylistEdits() throws {
        let env = try UsbEditEngineTests.exported(["101", "102", "103", "104", "105"])
        let (result, report) = try env.edit([
            .removeTracks(usbContentIDs: [5]),
            .playlist(edit: .create(key: "p2", name: "합성 새 목록", isFolder: false, parent: .root)),
            .playlist(edit: .addTracks(playlist: .new("p2"), contentIDs: ["1", "2", "3"])),
            .playlist(edit: .moveTracks(playlist: .new("p2"), entries: [PlaylistEntry(trackNo: 3, contentID: "3")], to: 1)),
            .playlist(edit: .rename(playlist: .id("1"), name: "합성 바뀐 이름")),
        ])
        #expect(report.outcome == .written)
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        #expect(try env.read().playlists.first { $0.id == 2 }?.entries[.oneLibrary] == [3, 1, 2])
        try Self.check(env, result)
    }

    @Test("곡 더하기(목록 끝에) + 곡 정보 갱신")
    func addAndRefresh() throws {
        let env = try UsbEditEngineTests.exported(["101", "102"])
        try env.local.addTrack(id: "103", artist: ("5", "합성 새 아티스트"), album: ("35", "합성 새 앨범"))
        try env.updateLocal("101", "TrackInfoUpdated = '2', Title = '합성 새 제목'")
        let (result, report) = try env.edit([
            .addTracks(localContentIDs: ["103"], playlist: .id("1")),
            .refreshTracks(usbContentIDs: [1], parts: [.info]),
        ])
        #expect(report.outcome == .written)
        #expect(result.outcome(1) == .written && result.outcome(2) == .written)
        let after = try env.read()
        #expect(after.tracks.map(\.id) == [1, 2, 3])
        #expect(after.playlists.first?.entries[.deviceLibrary] == [1, 2, 3])
        try Self.check(env, result)
    }

    @Test("가운데 곡 빼기 + 목록 순서·폴더")
    func removeMiddleAndReorder() throws {
        let env = try UsbEditEngineTests.exported(["101", "102", "103"])
        let (result, _) = try env.edit([
            .removeTracks(usbContentIDs: [2]),
            .playlist(edit: .create(key: "f", name: "합성 폴더", isFolder: true, parent: .root)),
            .playlist(edit: .move(playlist: .id("1"), into: .new("f"))),
            .playlist(edit: .create(key: "a", name: "합성 목록 둘", isFolder: false, parent: .root)),
            .playlist(edit: .reorder(playlist: .new("a"), index: 0)),
        ])
        #expect(result.outcomes.allSatisfy { $0.outcome == .written })
        try Self.check(env, result)
        // 한 번 더 고쳐도(지난 쓰기 저널의 highWater) 불변식이 선다
        let (second, _) = try env.edit([.removeTracks(usbContentIDs: [3]), .playlist(edit: .delete(playlist: .id("2")))])
        #expect(second.outcomes.allSatisfy { $0.outcome == .written })
        try Self.check(env, second)
    }
}
