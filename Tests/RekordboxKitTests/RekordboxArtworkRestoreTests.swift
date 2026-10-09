import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 그림 쓰기 뒤의 복원과 share 밖 쓰기 막기(#66 코드 리뷰, 2026-10-04).
/// - 넣은 그림 파일은 복원 때 지운다. 그 뒤 그림을 지워 파일이 없거나 `ImagePath`가 비었어도 복원이 막히지 않아야 한다(쓰기의 큐·태그도 함께 되돌리므로).
/// - share 아래 `PIONEER/Artwork`나 `Artwork/<3자>`가 링크면 아직 없는 곡 UUID 폴더를 통해 share 밖에 쓰게 된다. 그런 곳에는 쓰지 않는다.
extension RekordboxArtworkWriterTests {
    func restore(_ fixture: RekordboxFixture, _ report: RekordboxWriter.Report, after seconds: Double = 600) throws {
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(seconds), backups: fixture.backups,
                                    shareRoot: fixture.shareRoot)
    }

    /// rekordbox의 동기화 곡 그림 지우기 모양(#173 S2 U09): `ImagePath` ''·256 → 257, 파일 행 258·삭제 1. `files`면 그림 셋도 지운다.
    func rekordboxDelete(_ fixture: RekordboxFixture, _ track: TrackSpec, files: Bool) throws {
        try fixture.execute("UPDATE djmdContent SET ImagePath = '', rb_data_status = 257 WHERE ID = ?", [.text(track.id)])
        try fixture.execute("UPDATE contentFile SET rb_data_status = 258, rb_local_deleted = 1 WHERE ID = ?", [.text(fileID(track))])
        if files { for name in names { try? FileManager.default.removeItem(at: folder(fixture, track).appending(path: name)) } }
    }

    // MARK: 복원 (리뷰 1)

    @Test func 넣은_뒤_DJCrate로_지운_곡도_넣기_백업으로_복원한다() throws {
        // 1A: 넣기 → DJCrate 지우기 → 넣기 백업 복원. 넣은 파일은 이미 없으니 건너뛴다(소유권 실패가 아니다).
        let (fixture, track) = try library()
        let before = try content(fixture, track)
        let added = try write(fixture, [try edit(fixture, track, image: small)])
        _ = try write(fixture, [try edit(fixture, track, image: nil)], at: now.addingTimeInterval(60))
        try restore(fixture, added)
        #expect(try content(fixture, track) == before && fileRows(fixture, track).isEmpty)
        #expect(try exists(fixture, track) == [false, false, false])
    }

    @Test(arguments: [true, false]) func rekordbox에서_그림을_지운_곡도_넣기_백업으로_복원한다(filesGone: Bool) throws {
        // 1B: 넣기 → rekordbox 지우기(`ImagePath` ''·파일 행 258) → 넣기 백업 복원. 파일이 남았으면 넣은 곡 UUID 폴더 규칙으로 지운다.
        let (fixture, track) = try library(state: 256)
        let before = try content(fixture, track)
        let added = try write(fixture, [try edit(fixture, track, image: small)])
        try rekordboxDelete(fixture, track, files: filesGone)
        try restore(fixture, added)
        #expect(try content(fixture, track) == before && fileRows(fixture, track).isEmpty)
        #expect(try exists(fixture, track) == [false, false, false])
    }

    @Test func 없던_파일을_만든_바꾸기도_지운_뒤에_복원한다() throws {
        // 3c: `artwork_m.jpg`가 없던 곡을 바꾸면 그 파일은 새로 만든 파일이다. 그 뒤 지워도 바꾸기 백업으로 복원한다.
        let (fixture, track) = try library()
        let old = try putArtwork(fixture, track)
        try FileManager.default.removeItem(at: folder(fixture, track).appending(path: "artwork_m.jpg"))
        let before = try content(fixture, track), oldRow = try #require(try fileRows(fixture, track).first)
        let replaced = try write(fixture, [try edit(fixture, track, image: smallWide)])
        #expect(replaced.createdFiles == [folder(fixture, track).appending(path: "artwork_m.jpg").path])
        _ = try write(fixture, [try edit(fixture, track, image: nil)], at: now.addingTimeInterval(60))
        try restore(fixture, replaced)
        #expect(try content(fixture, track) == before && fileRows(fixture, track).first == oldRow)
        #expect(try Data(contentsOf: folder(fixture, track).appending(path: "artwork.jpg")) == old.full)
        #expect(try Data(contentsOf: folder(fixture, track).appending(path: "artwork_s.jpg")) == old.small)
        #expect(try exists(fixture, track) == [true, false, true], "없던 _m은 없는 채로")
    }

    @Test func 보고서에_없는_곡의_그림_파일은_여전히_복원을_막는다() throws {
        // UUID 폴더 규칙은 그 백업이 그림을 쓴 곡에만 연다. 다른 곡 폴더를 가리키게 고친 보고서는 소유권 실패다.
        let (fixture, track) = try library()
        var other = TrackSpec(id: "300", uuid: "aa11bb22-0000-4000-8000-000000000300")
        other.analysisDataPath = "/PIONEER/USBANLZ/aa1/1bb22-0000-4000-8000-000000000300/ANLZ0000.DAT"
        other.imagePath = ""
        try fixture.add(other)
        let otherFile = folder(fixture, other).appending(path: "artwork.jpg")
        try FileManager.default.createDirectory(at: otherFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("다른 곡".utf8).write(to: otherFile)
        let added = try write(fixture, [try edit(fixture, track, image: small)])
        let backup = try #require(added.backup.map { URL(filePath: $0) })
        let reportURL = backup.appending(path: "report.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        json["createdFiles"] = (json["createdFiles"] as? [String] ?? []) + ["PIONEER/Artwork/aa1/1bb22-0000-4000-8000-000000000300/artwork.jpg"]
        try JSONSerialization.data(withJSONObject: json).write(to: reportURL)
        #expect(throws: DJCError.self) { try restore(fixture, added) }
        #expect(try FileManager.default.fileExists(atPath: otherFile.path) && fileRows(fixture, track).count == 1, "아무것도 바꾸지 않는다")
    }

    // MARK: share 밖 쓰기 막기 (리뷰 2)

    /// share 아래 `link`(share 기준 경로)를 share 밖 폴더를 가리키는 링크로 바꾼다. 그 밖 폴더를 돌려준다.
    func linkOutside(_ fixture: RekordboxFixture, _ link: String) throws -> URL {
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let url = fixture.shareRoot.appending(path: link)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        return outside
    }

    @Test(arguments: ["PIONEER/Artwork", "PIONEER/Artwork/cb5"])
    func 그림_폴더_위가_링크면_share_밖에_쓰지_않는다(link: String) throws {
        let (fixture, track) = try library()
        let outside = try linkOutside(fixture, link)
        let before = try content(fixture, track)
        let report = try write(fixture, [try edit(fixture, track, image: small)])
        #expect(report.artworkWritten.isEmpty && report.artworkBlocked.first?.reason?.contains("링크") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "share 밖에 아무것도 만들지 않는다")
        #expect(try content(fixture, track) == before && fileRows(fixture, track).isEmpty && report.backup == nil)
    }

    @Test func share_아래_링크_조각을_찾는다() throws {
        let (fixture, track) = try library()
        let file = folder(fixture, track).appending(path: "artwork.jpg")
        #expect(!RekordboxWriter.hasSymlinkComponent(file, under: fixture.shareRoot), "아직 없는 경로는 링크가 아니다")
        _ = try linkOutside(fixture, "PIONEER/Artwork")
        #expect(RekordboxWriter.hasSymlinkComponent(file, under: fixture.shareRoot))
        #expect(RekordboxWriter.hasSymlinkComponent(URL(filePath: "/elsewhere/artwork.jpg"), under: fixture.shareRoot), "share 밖 경로도 막는다")
    }

    // MARK: 보고서 저장 실패 (리뷰 2)

    @Test func 보고서를_저장하지_못하면_경고로_알린다() throws {
        let (fixture, _) = try library()
        let backup = fixture.root.appending(path: "backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var report = RekordboxWriter.Report(outcomes: [], backup: backup.path, dryRun: false, createdAt: stamp, finalUpdateCount: nil)
        #expect(RekordboxWriter.saveReport(report, in: backup, shareRoot: fixture.shareRoot) == nil)
        report.createdFiles = ["/elsewhere/artwork.jpg"]
        let warning = try #require(RekordboxWriter.saveReport(report, in: backup, shareRoot: fixture.shareRoot))
        #expect(warning.contains("report.json") && warning.contains("복원"))
    }
}
