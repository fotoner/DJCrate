import RekordboxFixtures
@testable import djc
import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("USB 계획 실험(usb-plan)")
struct UsbPlanLabTests {
    func candidate(_ id: String, artist: String, album: String, file: String) -> UsbExportCandidate {
        UsbExportCandidate(localContentID: id, masterSongID: id, masterDBID: "424242", artistName: artist, albumName: album, fileNameL: file,
                           sourcePath: "/music/\(id)/\(file)", isStreaming: false, fileType: 1, fileSize: 10, actualFileSize: 10, analysis: .complete,
                           analysisModifiedAt: nil,
                           artwork: UsbArtworkSource(smallPath: "/s", mediumPath: "/m", smallBytes: 100_000, mediumBytes: 150_000),
                           artworkPathSetButMissing: false, cues: [], metadata: UsbTrackMetadataFlags())
    }

    var plan: UsbExportPlan {
        UsbExportPlanner.plan(UsbExportRequest(
            candidates: [candidate("1", artist: "A", album: "B", file: "x.mp3"), candidate("2", artist: "A", album: "C", file: "y.mp3"),
                         candidate("3", artist: "D", album: "E", file: "z.mp3")],
            snapshotTakenAt: Date(timeIntervalSince1970: 0)))
    }

    @Test("골든과 성분·파일 이름·아트워크 폴더를 비교한다")
    func compareCountsComponentsAndArtwork() {
        let golden: Set<String> = ["Contents/A/B/x.mp3", "Contents/A/Other/y.mp3", "Contents/Q/E/z.mp3"]
        let artwork: Set<String> = ["PIONEER/Artwork/00001/a1.jpg", "PIONEER/Artwork/00001/a2.jpg", "PIONEER/Artwork/00001/a3.jpg"]
        let result = UsbPlanLab.compare(plan, goldenContents: golden, goldenArtwork: artwork)
        // 아티스트 A·A 맞음, D 틀림 / 앨범 A/B 맞음, A/C·D/E 틀림
        #expect(result.components == (3, 6))
        #expect(result.files == (1, 3))
        // 계획은 1·1·2 폴더로 나눈다
        #expect(result.artwork == (2, 3))
    }

    @Test("아트워크 폴더별 image ID 범위")
    func artworkRangesText() {
        #expect(UsbPlanLab.artworkRanges(plan) == "00001: 1–2, 00002: 3")
        #expect(UsbPlanLab.artworkRanges(plan, limit: 1) == "00001: 1–2, 00002: 3, …, 00002: 3 (폴더 2개)")
    }

    @Test("규칙 이름은 알파벳 순으로 · 로 잇는다")
    func ruleListSorted() {
        #expect(UsbPlanLab.ruleList([.playlistSiblingBase, .analysisFolderNaming, .myTagMasterDBID, .artworkFolderSplit])
            == "analysisFolderNaming·artworkFolderSplit·myTagMasterDBID·playlistSiblingBase")
        #expect(UsbPlanLab.ruleList([]) == "없음")
    }

    func run(_ arguments: [String], home: URL) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["lab"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["DJC_HOME": home.path, "DJC_LANG": "ko"]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("합성 사본으로 계획을 세우고 수치만 찍는다")
    func runsOnSyntheticCopy() throws {
        let fixture = try RekordboxFixture()
        try fixture.addArtist(id: "1", name: "Synthetic Artist")
        try fixture.addAlbum(id: "2", name: "Synthetic Album")
        var track = TrackSpec(id: "5001")
        track.title = "SECRET-TITLE"
        track.artistID = "1"
        track.albumID = "2"
        track.folderPath = try fixture.writeAudio(named: "secret-file.mp3", bytes: 64).path
        try fixture.add(track)
        try fixture.setIdentity(track: track, masterSongID: "1", masterDBID: "424242", fileNameL: "secret-file.mp3")
        try fixture.setFileSize(track: track, 64)
        try fixture.setAnalysisPath(track: track, "/PIONEER/USBANLZ/s/t/ANLZ0000.DAT")
        try fixture.writeLocalAnalysis(analysisPath: "/PIONEER/USBANLZ/s/t/ANLZ0000.DAT", dat: Data(count: 4), ext: Data(count: 4),
                                       twoEx: Data(count: 4), modified: Date(timeIntervalSince1970: 1_700_000_000))
        try fixture.writeArtwork(track: track, imagePath: "/PIONEER/Artwork/00/q/artwork.jpg", small: Data(count: 8), medium: Data(count: 9))
        try fixture.addPlaylist(id: "77", name: "Synthetic List", seq: 1, contentIDs: ["5001"])
        let golden = fixture.root.appending(path: "golden")
        try FileManager.default.createDirectory(at: golden.appending(path: "Contents/Synthetic Artist/Synthetic Album"),
                                                withIntermediateDirectories: true)
        try Data().write(to: golden.appending(path: "Contents/Synthetic Artist/Synthetic Album/secret-file.mp3"))
        try FileManager.default.createDirectory(at: golden.appending(path: "PIONEER/Artwork/00001"), withIntermediateDirectories: true)
        try Data().write(to: golden.appending(path: "PIONEER/Artwork/00001/a1.jpg"))

        let (status, output) = try run(["usb-plan", "--db", fixture.database.path, "--share", fixture.shareRoot.path, "--playlist", "77",
                                        "--compare", golden.path, "--summary", "--snapshot-time", "2026-09-27T11:41:08Z"],
                                       home: fixture.root.appending(path: "home"))
        #expect(status == 0, "\(output)")
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.first == "스냅샷 시각: explicit")
        #expect(lines.contains("경로 성분 2/2, 파일 이름 1/1, 아트워크 폴더 1/1(00001: 1), 막힘 0, "
            + "확인 안 된 규칙: myTagMasterDBID·playlistSiblingBase"))
        for secret in ["SECRET-TITLE", "secret-file", "Synthetic", fixture.root.path] {
            #expect(!output.contains(secret), "\(secret)")
        }

        // 분석 뒤 크기가 바뀐 곡은 막지 않고 확인 안 된 규칙으로 싣는다(rekordbox와 같게)
        try fixture.setFileSize(track: track, 65)
        let all = ["usb-plan", "--db", fixture.database.path, "--share", fixture.shareRoot.path, "--all", "--summary",
                   "--snapshot-time", "2026-09-27T11:41:08Z"]
        let (_, changed) = try run(all, home: fixture.root.appending(path: "home"))
        #expect(changed.contains("막힘 0") && changed.contains("audioChangedSinceAnalysis"), "\(changed)")
        // 막힘은 code별 수로만
        try FileManager.default.removeItem(atPath: try #require(track.folderPath))
        let (_, missing) = try run(all, home: fixture.root.appending(path: "home"))
        #expect(missing.contains("audioMissing 1"), "\(missing)")
        #expect(!missing.contains("SECRET-TITLE"))
    }

    @Test("임시 폴더 밖 사본은 받지 않는다")
    func refusesOutsideScratch() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-usbplan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let (status, output) = try run(["usb-plan", "--db", "/etc/hosts", "--share", "/tmp",
                                        "--all", "--snapshot-time", "2026-09-27T11:41:08Z"], home: home)
        #expect(status != 0)
        #expect(!output.contains("스냅샷 시각"))
    }
}
