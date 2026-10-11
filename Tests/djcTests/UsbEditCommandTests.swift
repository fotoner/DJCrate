import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `djc usb-edit` 인자·편집 파일 JSON·요약 줄
@Suite("USB 수정 명령")
struct UsbEditCommandTests {
    /// docs/cli.md와 완료 명령에 적은 모양 그대로
    static let json = """
    [ {"removeTracks": {"usbContentIDs": [5]}},
      {"playlist": {"edit": {"create": {"key": "p2", "name": "시험 목록", "isFolder": false, "parent": "root"}}}},
      {"playlist": {"edit": {"addTracks": {"playlist": "new:p2", "contentIDs": ["1","2","3"]}}}},
      {"playlist": {"edit": {"moveTracks": {"playlist": "new:p2", "entries": [{"trackNo": 3, "contentID": "3"}], "to": 1}}}},
      {"playlist": {"edit": {"rename": {"playlist": "1", "name": "시험 이름"}}}},
      {"refreshTracks": {"usbContentIDs": [2], "parts": ["info","cues","grid","artwork"]}} ]
    """

    @Test("목록 동기화 JSON은 로컬 순서·중복을 보존하고 로컬 사본이 필요한 편집으로 판정한다")
    func parsesSyncPlaylistAndRequiresLocal() throws {
        let edits = try UsbCommands.editList(Data(#"[{"syncPlaylist":{"playlist":"new:sync","localContentIDs":["103","101","103"]}}]"#.utf8))
        #expect(edits == [.syncPlaylist(playlist: .new("sync"), localContentIDs: ["103", "101", "103"])])
        #expect(UsbEditSession.needsLocal(edits))
        #expect(UsbEditSession.needsLocal([.syncPlaylist(playlist: .id("1"), localContentIDs: [])]))
    }

    @Test("편집 파일: UsbLibraryEdit 배열(재생 목록은 {\"playlist\":{\"edit\":…}})")
    func parsesEditFile() throws {
        let edits = try UsbCommands.editList(Data(Self.json.utf8))
        #expect(edits == [
            .removeTracks(usbContentIDs: [5]),
            .playlist(edit: .create(key: "p2", name: "시험 목록", isFolder: false, parent: .root)),
            .playlist(edit: .addTracks(playlist: .new("p2"), contentIDs: ["1", "2", "3"])),
            .playlist(edit: .moveTracks(playlist: .new("p2"), entries: [PlaylistEntry(trackNo: 3, contentID: "3")], to: 1)),
            .playlist(edit: .rename(playlist: .id("1"), name: "시험 이름")),
            .refreshTracks(usbContentIDs: [2], parts: [.info, .cues, .grid, .artwork]),
        ])
        #expect(try UsbCommands.editList(Data(#"[{"addTracks":{"localContentIDs":["101"],"playlist":"1"}}]"#.utf8))
            == [.addTracks(localContentIDs: ["101"], playlist: .id("1"))])
        #expect(UsbEditSession.needsLocal(edits))
        #expect(!UsbEditSession.needsLocal(Array(edits.prefix(5))))
        do {
            _ = try UsbCommands.editList(Data(#"[{"playlist":{"_0":{"rename":{"playlist":"1","name":"x"}}}}]"#.utf8))
            Issue.record("받아들임")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["editFileInvalid"])
        }
    }

    @Test("인자: 볼륨·편집 파일 또는 --draft·사본·share·드라이 런·확인·규칙·스냅샷 시각")
    func parsesArguments() throws {
        let request = try UsbCommands.editRequest([
            "usb-edit", "--volume", "/tmp/v", "/tmp/edits.json", "--db", "/tmp/m.db", "--share", "/tmp/share", "--dry-run",
            "--confirm", "DJCTEST", "--snapshot-time", "2026-09-27T21:22:03Z",
        ])
        #expect(request.volume == "/tmp/v" && request.editsFile == "/tmp/edits.json" && !request.draft)
        #expect(request.database == "/tmp/m.db" && request.share == "/tmp/share")
        #expect(request.dryRun && request.confirmName == "DJCTEST")
        #expect(request.snapshotTime == "2026-09-27T21:22:03Z")
        let draft = try UsbCommands.editRequest(["usb-edit", "--draft", "--volume", "/tmp/v"])
        #expect(draft.draft && draft.editsFile == nil && draft.database == nil && draft.snapshotTime == nil)
    }

    @Test("잘못된 인자는 사용법")
    func rejectsBadArguments() {
        for args in [
            ["usb-edit", "/tmp/edits.json"],
            ["usb-edit", "--volume", "/v"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "--draft"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "/tmp/b.json"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "--unknown"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "--snapshot-time"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "--db"],
            ["usb-edit", "--volume", "/v", "/tmp/a.json", "--allow-provisional", "cueVariant"],
        ] {
            #expect(throws: UsageError.self) { try UsbCommands.editRequest(args) }
        }
    }

    @Test("라이브 라이브러리는 USB로 받지 않는다")
    func rejectsLiveLibrary() {
        #expect(throws: UsbError.self) {
            try UsbCommands.editRequest(["usb-edit", "--volume", NSHomeDirectory() + "/Library/Pioneer/rekordbox", "/tmp/a.json"])
        }
    }

    @Test("실물 볼륨이면 관문 막힘을 문구와 함께 보인다")
    func physicalVolumeRefusalMessage() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102"])
        try env.export(tracks: ["101", "102"])
        env.usb.volume = FakeUsbVolume.physicalFAT32()
        let session = UsbEditSession(root: env.usb.usbURL, database: nil, share: nil, guard: env.usb.writeGuard(), paths: env.usb.paths,
                                     engine: .live(fileSystem: env.usb.fileSystem()), device: .testing(),
                                     localCopies: env.usb.home.appending(path: "usb-snapshots"),
                                     drafts: .live(directory: env.usb.home.appending(path: "usb-drafts")), now: { Date() })
        do {
            _ = try session.write([.removeTracks(usbContentIDs: [2])], options: UsbWriteOptions(), progress: { _ in }, isCancelled: { false })
            Issue.record("막히지 않음")
        } catch let UsbError.writeRefused(blocks) {
            let block = try #require(blocks.first { $0.code == "physicalDisabled" })
            #expect(block.message.contains("--allow-physical"))
            let lines = UsbCommands.editLines(result: try #require(session.lastResult), report: nil)
            #expect(lines.contains { $0.hasPrefix("막힘 physicalDisabled:") })
        }
    }

    @Test("요약 줄: 스냅샷 시각·편집별 결과·형식·알림(경로는 수로 묶음)·규칙. 곡 제목·경로는 찍지 않는다")
    func summaryLines() throws {
        let env = try UsbEditFixture()
        try env.addLocal(["101", "102", "103"])
        try env.export(tracks: ["101", "102", "103"])
        env.setPdbFlag(4)
        var result = try env.plan([.removeTracks(usbContentIDs: [2]), .removeTracks(usbContentIDs: [99]),
                                   .refreshTracks(usbContentIDs: [1], parts: [.info])])
        result.snapshotSource = .explicit
        result.notes.append("분석 파일이 다른 곡 것이라 지우지 않았습니다: PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT")
        let lines = UsbCommands.editLines(result: result, report: nil)
        #expect(lines.first == "스냅샷 시각: explicit")
        #expect(lines.contains { $0.hasPrefix("편집 1: deferred") })
        #expect(lines.contains { $0.hasPrefix("편집 2: blocked targetMissing") })
        #expect(lines.contains("편집 3: unchanged"))
        #expect(lines.contains("쓴 형식: OneLibrary"))
        #expect(lines.contains { $0.hasPrefix("막힌 형식 Device Library pdbNotClosed:") })
        #expect(lines.contains("분석 파일이 다른 곡 것이라 지우지 않았습니다 (1개)"))
        #expect(lines.contains { $0.hasPrefix("확인 안 된 규칙: ") && $0.contains("editRemoveTracks") })
        #expect(!lines.joined().contains("합성 곡") && !lines.joined().contains("Contents/"))
    }
}
