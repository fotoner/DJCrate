import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 곡을 넣을 때 음원 내장 아트워크도 넣기(#4). 기대값은 rekordbox 7.2.x 실험(2026-09-26, 시험 곡 "DJC 실험 아트":
/// 1200×900 JPEG 앞표지가 든 MP3, 라이브러리에 없던 아티스트·앨범)과 같은 날 라이브러리 조사(읽기 전용):
/// - 자동 분석을 끄고 넣으면 아트워크를 만들지 않는다(`ImagePath` 빈 값, 파일 행·파일 없음).
/// - rekordbox가 그 곡을 분석할 때 뽑는다: `artwork.jpg` 파일 행이 먼저 번호를 받고 오토게인 행 → 곡 행(`ImagePath`·분석 칸) →
///   파일 행 .3EX·.2EX·.DAT·.EXT. 파일 셋은 800×600·240·80, 파일 행은 분석 파일 행과 같은 칸, 앨범 행 `ImagePath`는 NULL 그대로.
/// DJCrate는 분석까지 붙여 넣는 곡에만 아트워크를 넣는다. 빼면 파일 셋을 지우고 폴더는 남긴다.
@Suite("rekordbox 곡 넣기 아트워크")
struct RekordboxTrackArtworkTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]
    let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)

    /// 앞표지가 든 MP3의 곡 넣기 계획(새 아티스트·앨범). 기본은 작은 4:3 그림이고, 크기 줄이기를 보는 골든 시험만 실험 곡의 1200×900을 준다
    /// (디버그 빌드의 JPEG 인코딩이 큰 그림 하나에 1초 가까이 든다).
    func plan(_ fixture: RekordboxFixture, name: String = "artwork.mp3", width: Int = 64, height: Int = 48) async throws -> TrackAddPlan {
        let url = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), artwork: ImageFixture.image(width: width, height: height),
                                       in: fixture.audio, name: name)
        var tags = try await AudioTags.read(url: url)
        tags.title = "DJC 실험 아트"
        tags.artist = "DJC 실험 아트 아티스트"
        tags.album = "DJC 실험 아트 앨범"
        return try TrackAddPlan.make(url: url, tags: tags, now: now)
    }

    /// 분석까지 붙여 넣는다(`analyzed` false면 분석 없이). 아트워크 쓰기는 앱과 같은 값(`writesArtwork`)을 따른다.
    func add(_ fixture: RekordboxFixture, _ plans: [TrackAddPlan], analyzed: Bool = true,
             writesArtwork: Bool = RekordboxTrackWriter.writesArtwork) throws -> RekordboxTrackWriter.Report {
        let analyses = analyzed ? Dictionary(plans.map { ($0.path, analysis) }) { a, _ in a } : [:]
        return try RekordboxTrackWriter.add(plans, analyses: analyses, to: fixture.database, shareRoot: fixture.shareRoot,
                                            dryRun: false, now: now, backups: fixture.backups, writesArtwork: writesArtwork)
    }

    func content(_ fixture: RekordboxFixture, _ report: RekordboxTrackWriter.Report) throws -> [String: String] {
        let id = try #require(report.added.first?.contentID)
        return try #require(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(id)]).first)
    }

    func folder(_ fixture: RekordboxFixture, uuid: String) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))")
    }

    @Test func 분석_없이_넣으면_rekordbox처럼_아트워크를_만들지_않는다() async throws {
        // DJC 실험 아트를 자동 분석을 끄고 넣었을 때(2026-09-26): 아티스트 → 앨범 → 곡 행만(카운터 1003994 → 1003997)
        let fixture = try RekordboxFixture(localUpdateCount: 1_003_994)
        try fixture.add(TrackSpec())
        let report = try add(fixture, [try await plan(fixture)], analyzed: false)
        let r = try content(fixture, report)
        #expect(report.added.first?.written == true)
        #expect(r["ImagePath"] == "" && r["Analysed"] == "0" && r["AnalysisDataPath"] == "")
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && report.createdFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
        let artist = try #require(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = ?", [.text(r["ArtistID"] ?? "")]).first)
        let album = try #require(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = ?", [.text(r["AlbumID"] ?? "")]).first)
        #expect(artist["rb_local_usn"] == "1003995" && album["rb_local_usn"] == "1003996" && r["rb_local_usn"] == "1003997")
        #expect(album["ImagePath"] == "NULL")
        #expect(try fixture.localUpdateCount() == 1_003_997)
    }

    @Test func 분석과_함께_넣으면_rekordbox가_분석할_때처럼_아트워크를_넣는다() async throws {
        // DJC 실험 아트를 rekordbox가 분석했을 때(2026-09-26): artwork.jpg 행 → 오토게인 → 곡 행 → .2EX → .DAT → .EXT(.3EX는 만들지 못함)
        let fixture = try RekordboxFixture(localUpdateCount: 4000)
        try fixture.add(TrackSpec())
        let report = try add(fixture, [try await plan(fixture, width: 1200, height: 900)])
        let r = try content(fixture, report)
        let uuid = try #require(r["UUID"]), id = try #require(r["ID"])
        let path = "/PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))/artwork.jpg"
        #expect(r["ImagePath"] == path && r["Analysed"] == "105")
        // 파일 셋: 1200×900 → 800×600, 240·80 정사각(위아래 검은 여백)
        let base = folder(fixture, uuid: uuid)
        let images = try names.map { try #require(ImageFixture.pixels(try Data(contentsOf: base.appending(path: $0)))) }
        #expect(images.map { "\($0.width)x\($0.height)" } == ["800x600", "240x240", "80x80"])
        let medium = images[1]
        #expect(medium.rgb[(10 * 240 + 120) * 3..<(10 * 240 + 120) * 3 + 3].allSatisfy { $0 < 8 }, "위 여백(30px)은 검다")
        #expect(medium.rgb[(120 * 240 + 120) * 3..<(120 * 240 + 120) * 3 + 3].contains { $0 > 100 }, "가운데는 그림")
        #expect(Set(report.createdFiles) == Set(names.map { base.appending(path: $0).path }).union(
            ["DAT", "EXT", "2EX"].map { fixture.shareRoot.appending(path: "PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.\($0)").path }),
            "되돌릴 때 지울 파일")
        let backupPath = try #require(report.backup)
        let backupReport = try #require(RekordboxTrackWriter.report(in: URL(filePath: backupPath)))
        #expect(backupReport.createdFiles.count == 6 && backupReport.createdFiles.allSatisfy { $0.hasPrefix("PIONEER/") })
        // 파일 행은 artwork.jpg 하나(_m·_s는 행이 없다). 칸은 rekordbox가 만든 행과 같다.
        let artworkRows = try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ? AND Path LIKE '%/Artwork/%'", [.text(id)])
        #expect(artworkRows.count == 1)
        let file = try #require(artworkRows.first)
        let data = try Data(contentsOf: base.appending(path: "artwork.jpg"))
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(file["ID"] == "\(uuid)_%2FPIONEER%2FArtwork%2F\(uuid.prefix(3))%2F\(uuid.dropFirst(3))%2Fartwork.jpg")
        #expect(file["Path"] == path && file["Hash"] == md5 && file["Size"] == String(data.count))
        #expect(file["rb_local_path"] == base.appending(path: "artwork.jpg").path && file["rb_priority"] == "50")
        #expect(file["rb_insync_hash"] == "NULL" && file["rb_insync_local_usn"] == "NULL" && file["rb_temp_path"] == "NULL")
        #expect(file["rb_file_hash_dirty"] == "0" && file["rb_local_file_status"] == "0" && file["rb_in_progress"] == "0")
        #expect(file["rb_process_type"] == "0" && file["rb_file_size_dirty"] == "0" && file["UUID"]?.count == 36)
        #expect(file["rb_data_status"] == "0" && file["rb_local_data_status"] == "0" && file["rb_local_deleted"] == "0")
        #expect(file["rb_local_synced"] == "0" && file["usn"] == "NULL" && file["created_at"] == stamp && file["updated_at"] == stamp)
        // 변경 번호: 관련 행(아티스트 → 앨범) → artwork.jpg 행 → 오토게인 → 곡 행 → .2EX → .DAT → .EXT
        let artist = try #require(try fixture.rows("SELECT rb_local_usn FROM djmdArtist WHERE ID = ?", [.text(r["ArtistID"] ?? "")]).first)
        let album = try #require(try fixture.rows("SELECT rb_local_usn, ImagePath FROM djmdAlbum WHERE ID = ?", [.text(r["AlbumID"] ?? "")]).first)
        let mixer = try #require(try fixture.rows("SELECT rb_local_usn FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).first)
        let files = try fixture.rows("SELECT Path, rb_local_usn FROM contentFile WHERE ContentID = ? ORDER BY rb_local_usn", [.text(id)])
        #expect(artist["rb_local_usn"] == "4001" && album["rb_local_usn"] == "4002" && album["ImagePath"] == "NULL")
        #expect(file["rb_local_usn"] == "4003" && mixer["rb_local_usn"] == "4004" && r["rb_local_usn"] == "4005")
        #expect(files.map { $0["Path"]!.components(separatedBy: "/").last! } == ["artwork.jpg", "ANLZ0000.2EX", "ANLZ0000.DAT", "ANLZ0000.EXT"])
        #expect(files.map { $0["rb_local_usn"]! } == ["4003", "4006", "4007", "4008"])
        #expect(try fixture.localUpdateCount() == 4008)
    }

    @Test func 쓰기가_닫혀_있거나_음원에_아트워크가_없으면_ImagePath는_빈_값() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let closed = try add(fixture, [try await plan(fixture, name: "closed.mp3")], writesArtwork: false)
        let bare = try TestResources.url("mp3-notag-cbr.mp3")
        let none = try add(fixture, [try TrackAddPlan.make(url: bare, tags: try await AudioTags.read(url: bare), now: now)])
        for report in [closed, none] {
            #expect(report.added.first?.written == true)
            let r = try content(fixture, report)
            #expect(r["ImagePath"] == "" && r["Analysed"] == "105", "분석은 붙는다")
            #expect(report.createdFiles.count == 3 && report.createdFiles.allSatisfy { $0.contains("/USBANLZ/") })
        }
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE Path LIKE '%/Artwork/%'").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
    }

    @Test func 시험_실행은_파일을_만들지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let report = try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: true, now: now, backups: fixture.backups, writesArtwork: true)
        #expect(report.added.first?.written == true && report.createdFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
        #expect(try fixture.rows("SELECT * FROM djmdContent").count == 1)
    }

    @Test func 넣은_곡을_되돌리면_아트워크_파일과_빈_폴더가_사라진다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let report = try add(fixture, [try await plan(fixture)], writesArtwork: true)
        let uuid = try #require(report.added.first?.uuid)
        let base = folder(fixture, uuid: uuid)
        #expect(names.allSatisfy { FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(!FileManager.default.fileExists(atPath: base.path), "만든 폴더까지 지운다")
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        // 되돌리기 직전 백업으로 다시 되돌리면 살아난다
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(names.allSatisfy { FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
    }

    @Test func 아트워크를_넣은_곡을_빼면_파일과_빈_폴더를_지우고_되돌리면_살아난다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let added = try add(fixture, [try await plan(fixture)], writesArtwork: true)
        let id = try #require(added.added.first?.contentID), uuid = try #require(added.added.first?.uuid)
        let base = folder(fixture, uuid: uuid)
        let original = try names.map { try Data(contentsOf: base.appending(path: $0)) }
        let deleted = try RekordboxTrackWriter.delete(contentIDs: [id], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                                      now: now.addingTimeInterval(60), backups: fixture.backups)
        #expect(deleted.deleted.first?.written == true)
        #expect(!FileManager.default.fileExists(atPath: base.path), "허용한 파일을 뺀 뒤 빈 곡 폴더만 지운다")
        #expect(names.allSatisfy { !FileManager.default.fileExists(atPath: base.appending(path: $0).path) })
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        _ = try RekordboxWriter.restore(URL(filePath: try #require(deleted.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try names.map { try Data(contentsOf: base.appending(path: $0)) } == original)
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ? AND Path LIKE '%/Artwork/%'", [.text(id)]).count == 1)
    }
}

/// share 밖 쓰기 막기(#66 코드 리뷰, 2026-10-04): 그림 폴더 위가 링크면 아직 없는 곡 UUID 폴더를 통해 share 밖에 쓰게 된다.
extension RekordboxTrackArtworkTests {
    @Test func 그림_폴더가_링크면_곡을_넣지_않고_share_밖에_쓰지_않는다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 4000)
        try fixture.add(TrackSpec())
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.shareRoot.appending(path: "PIONEER"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.shareRoot.appending(path: "PIONEER/Artwork"), withDestinationURL: outside)
        let report = try add(fixture, [try await plan(fixture)])
        #expect(report.added.first?.written == false && report.added.first?.reason?.contains("링크") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
