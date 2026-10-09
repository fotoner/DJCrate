import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 분석 전 곡에 분석을 붙일 때 음원 내장 아트워크도 넣기(#87).
/// 기대값은 rekordbox 7.2.18 실험(2026-09-26, 시험 곡 "DJC 실험 아트": 1200×900 JPEG 앞표지가 든 MP3)이다.
/// 자동 분석을 끄고 넣어 분석 전 곡(`Analysed` 0, `ImagePath` 빈 값, 변경 카운터 1003997)이 된 곡을, 다음 세션에서 자동 분석을
/// 켜자 rekordbox가 분석했다(art_after → probe_after 스냅샷 비교):
/// - 변경 번호: `artwork.jpg` 파일 행(1004001) → 오토게인 행(1004015) → 곡 행(1004017, `ImagePath`·분석 칸) → 파일 행 .3EX → .2EX → .DAT → .EXT.
///   사이 빈 번호는 다른 곡 추가·곡 행이 한 번 더 받은 번호다. DJCrate는 .3EX를 만들지 못하고 번호를 이어 받는다.
/// - 파일 셋 800×600·240·80, 파일 행은 `artwork.jpg` 하나(분석 파일 행과 같은 칸), `djmdAlbum.ImagePath`·`imageFile`은 그대로.
/// - 곡 행 분석 칸은 #6 분석 붙이기와 같고, 카운터는 이 실험과 #95에서 확인한 첫 BPM/Grid 분석의 '1'·'1'이다.
@Suite("rekordbox 분석 붙이기 아트워크")
struct RekordboxAnalysisArtworkTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let segments = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
    let names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]

    /// 실험 곡처럼 1200×900 앞표지가 든 MP3(새 아티스트·앨범)의 곡 넣기 계획
    func plan(_ fixture: RekordboxFixture, folder: String = "bare", width: Int = 1200, height: Int = 900) async throws -> TrackAddPlan {
        let directory = fixture.audio.appending(path: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), artwork: ImageFixture.image(width: width, height: height),
                                       in: directory, name: "art.mp3")
        var tags = try await AudioTags.read(url: url)
        tags.title = "DJC 실험 아트"
        tags.artist = "DJC 실험 아트 아티스트"
        tags.album = "DJC 실험 아트 앨범"
        return try TrackAddPlan.make(url: url, tags: tags, now: now)
    }

    /// 분석 없이 넣는다(자동 분석을 끄고 넣은 곡과 같은 행). (ContentID, UUID)
    func addBare(_ fixture: RekordboxFixture, _ plan: TrackAddPlan) throws -> (id: String, uuid: String) {
        let report = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let outcome = try #require(report.added.first)
        return (try #require(outcome.contentID), try #require(outcome.uuid))
    }

    func input(_ plan: TrackAddPlan, artwork: Data?? = .none) -> RekordboxWriter.AnalysisInput {
        .init(duration: plan.duration, loudness: -8, peak: 0.9, artwork: artwork ?? plan.artwork)
    }

    func attach(_ fixture: RekordboxFixture, uuid: String, _ input: RekordboxWriter.AnalysisInput, dryRun: Bool = false,
                writesArtwork: Bool = RekordboxTrackWriter.writesArtwork) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], grids: [GridDraft(trackUUID: uuid, base: [], segments: segments)], gains: [:],
                                  analysisInputs: [uuid: input], to: fixture.database, dryRun: dryRun, now: now, backups: fixture.backups,
                                  shareRoot: fixture.shareRoot, attachesAnalysis: true, writesArtwork: writesArtwork)
    }

    func artworkFolder(_ fixture: RekordboxFixture, _ uuid: String) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))")
    }

    func analysisFile(_ fixture: RekordboxFixture, _ uuid: String, _ ext: String) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.\(ext)")
    }

    func content(_ fixture: RekordboxFixture, _ id: String) throws -> [String: String] {
        try #require(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(id)]).first)
    }

    // MARK: 골든

    @Test func 분석_전_곡에_분석을_붙이면_rekordbox가_분석할_때처럼_아트워크를_넣는다() async throws {
        // 실험 곡을 넣은 직후 카운터(1003994 → 아티스트·앨범·곡 행 → 1003997)부터 시작한다
        let fixture = try RekordboxFixture(localUpdateCount: 1_003_994)
        try fixture.add(TrackSpec())   // 라이브러리 공통값
        let p = try await plan(fixture)
        let (id, uuid) = try addBare(fixture, p)
        let bare = try content(fixture, id)
        #expect(bare["ImagePath"] == "" && bare["Analysed"] == "0" && bare["rb_local_usn"] == "1003997")
        let albumBefore = try fixture.rows("SELECT * FROM djmdAlbum")

        let report = try attach(fixture, uuid: uuid, input(p))
        #expect(report.analysisWritten.map(\.trackUUID) == [uuid] && report.analysisBlocked.isEmpty)
        #expect(report.artworkAdded == [uuid], "확인 창에 앨범아트도 넣는다고 알린다")

        // 곡 행: ImagePath(곡 UUID 폴더의 artwork.jpg)와 #6 분석 칸
        let r = try content(fixture, id)
        let path = "/PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))/artwork.jpg"
        #expect(r["ImagePath"] == path && r["Analysed"] == "105" && r["ContentLink"] == "2885134")
        #expect(r["AnalysisUpdated"] == "1" && r["TrackInfoUpdated"] == "1", "첫 BPM/Grid 분석 카운터")

        // 파일 셋: 1200×900 → 800×600, 240·80 정사각
        let base = artworkFolder(fixture, uuid)
        let images = try names.map { try #require(ImageFixture.pixels(try Data(contentsOf: base.appending(path: $0)))) }
        #expect(images.map { "\($0.width)x\($0.height)" } == ["800x600", "240x240", "80x80"])
        #expect(Set(report.createdFiles ?? []) == Set(names.map { base.appending(path: $0).path } + ["DAT", "EXT", "2EX"].map {
            analysisFile(fixture, uuid, $0).path
        }), "되돌릴 때 지울 파일")

        // 파일 행은 artwork.jpg 하나(_m·_s는 행이 없다). 칸은 실험 곡 행과 같은 모양이다.
        let artworkRows = try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ? AND Path LIKE '%/Artwork/%'", [.text(id)])
        let file = try #require(artworkRows.first)
        let data = try Data(contentsOf: base.appending(path: "artwork.jpg"))
        #expect(artworkRows.count == 1)
        #expect(file["ID"] == "\(uuid)_%2FPIONEER%2FArtwork%2F\(uuid.prefix(3))%2F\(uuid.dropFirst(3))%2Fartwork.jpg")
        #expect(file["Path"] == path && file["Size"] == String(data.count)
                && file["Hash"] == Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(file["rb_local_path"] == base.appending(path: "artwork.jpg").path && file["rb_priority"] == "50")
        #expect(file["rb_insync_hash"] == "NULL" && file["rb_insync_local_usn"] == "NULL" && file["rb_temp_path"] == "NULL" && file["usn"] == "NULL")
        #expect(file["rb_file_hash_dirty"] == "0" && file["rb_local_file_status"] == "0" && file["rb_in_progress"] == "0")
        #expect(file["rb_process_type"] == "0" && file["rb_file_size_dirty"] == "0" && file["UUID"]?.count == 36)
        #expect(file["rb_data_status"] == "0" && file["rb_local_data_status"] == "0" && file["rb_local_deleted"] == "0" && file["rb_local_synced"] == "0")
        #expect(file["created_at"] == stamp && file["updated_at"] == stamp)

        // 변경 번호: artwork.jpg 행 → 오토게인 → 곡 행 → .2EX → .DAT → .EXT(rekordbox는 곡 행 뒤에 .3EX도 넣는다)
        let mixer = try #require(try fixture.rows("SELECT rb_local_usn FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).first)
        let files = try fixture.rows("SELECT Path, rb_local_usn FROM contentFile WHERE ContentID = ? ORDER BY rb_local_usn", [.text(id)])
        #expect(files.map { $0["Path"]!.components(separatedBy: "/").last! } == ["artwork.jpg", "ANLZ0000.2EX", "ANLZ0000.DAT", "ANLZ0000.EXT"])
        #expect(files.map { $0["rb_local_usn"]! } == ["1003998", "1004001", "1004002", "1004003"])
        #expect(mixer["rb_local_usn"] == "1003999" && r["rb_local_usn"] == "1004000")
        #expect(try report.finalUpdateCount == 1_004_003 && fixture.localUpdateCount() == 1_004_003)

        // 앨범 행·imageFile 표는 그대로(실험에서도 바뀌지 않음)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum") == albumBefore)
        #expect(try fixture.rows("SELECT * FROM imageFile").isEmpty)
    }

    @Test func 붙인_아트워크는_분석까지_붙여_넣은_곡과_칸_바이트까지_같다() async throws {
        // 곡 넣기(분석 포함) 아트워크(#4, 같은 실험 순서)와 같은 레시피여야 한다
        let fixture = try RekordboxFixture(localUpdateCount: 5000)
        try fixture.add(TrackSpec())
        let bare = try await plan(fixture, folder: "bare"), reference = try await plan(fixture, folder: "reference")
        let added = try RekordboxTrackWriter.add([reference], analyses: [reference.path: .init(segments: segments, loudness: -8, peak: 0.9)],
                                                 to: fixture.database, shareRoot: fixture.shareRoot, dryRun: false, now: now,
                                                 backups: fixture.backups, writesArtwork: true)
        let refID = try #require(added.added.first?.contentID), refUUID = try #require(added.added.first?.uuid)
        let (id, uuid) = try addBare(fixture, bare)
        _ = try attach(fixture, uuid: uuid, input(bare))
        for name in names {
            #expect(try Data(contentsOf: artworkFolder(fixture, uuid).appending(path: name))
                    == Data(contentsOf: artworkFolder(fixture, refUUID).appending(path: name)), "\(name)")
        }
        let identity: Set = ["ID", "ContentID", "Path", "rb_local_path", "UUID", "rb_local_usn"]
        let sql = "SELECT * FROM contentFile WHERE ContentID = ? AND Path LIKE '%/Artwork/%'"
        let row = try #require(try fixture.rows(sql, [.text(id)]).first), refRow = try #require(try fixture.rows(sql, [.text(refID)]).first)
        for (column, value) in refRow where !identity.contains(column) { #expect(row[column] == value, "contentFile.\(column)") }
    }

    // MARK: 넣지 않는 경우

    @Test func 닫혀_있거나_그림이_없거나_풀지_못하면_아트워크_없이_분석만_붙인다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        for (index, (artwork, writes)) in [(Data?.none, true), (Data("그림 아님".utf8), true), (nil as Data?, false)].enumerated() {
            let p = try await plan(fixture, folder: "case\(index)")
            let (id, uuid) = try addBare(fixture, p)
            let report = try attach(fixture, uuid: uuid, input(p, artwork: writes ? .some(artwork) : .none), writesArtwork: writes)
            #expect(report.analysisWritten.count == 1 && (report.artworkAdded ?? []).isEmpty, "\(index)")
            #expect(try content(fixture, id)["ImagePath"] == "" && content(fixture, id)["Analysed"] == "105", "\(index)")
            #expect((report.createdFiles ?? []).count == 3 && (report.createdFiles ?? []).allSatisfy { $0.contains("/USBANLZ/") }, "\(index)")
        }
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE Path LIKE '%/Artwork/%'").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork").path))
    }

    @Test func 이미_아트워크가_있는_곡은_그대로_두고_분석만_붙인다() async throws {
        // 라이브러리에는 분석 전인데 ImagePath가 있는 곡이 있다. rekordbox가 분석할 때 다시 뽑는지 확인하지 않아 건드리지 않는다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let withPath = try await plan(fixture, folder: "path")
        let (pathID, pathUUID) = try addBare(fixture, withPath)
        let existing = "/PIONEER/Artwork/\(pathUUID.prefix(3))/\(pathUUID.dropFirst(3))/artwork.jpg"
        try fixture.execute("UPDATE djmdContent SET ImagePath = ? WHERE ID = ?", [.text(existing), .text(pathID)])
        // 폴더에 파일만 남은 곡(행 없이)
        let leftover = try await plan(fixture, folder: "leftover")
        let (leftoverID, leftoverUUID) = try addBare(fixture, leftover)
        let folder = artworkFolder(fixture, leftoverUUID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appending(path: "artwork.jpg"))

        let report = try RekordboxWriter.write(drafts: [], grids: [pathUUID, leftoverUUID].map { GridDraft(trackUUID: $0, base: [], segments: segments) },
                                               gains: [:], analysisInputs: [pathUUID: input(withPath), leftoverUUID: input(leftover)],
                                               to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                               shareRoot: fixture.shareRoot, attachesAnalysis: true, writesArtwork: true)
        #expect(report.analysisWritten.count == 2 && (report.artworkAdded ?? []).isEmpty)
        #expect(try content(fixture, pathID)["ImagePath"] == existing && content(fixture, leftoverID)["ImagePath"] == "")
        #expect(try Data(contentsOf: folder.appending(path: "artwork.jpg")) == Data([1, 2, 3]), "남은 파일을 덮지 않는다")
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE Path LIKE '%/Artwork/%'").isEmpty)
    }

    // MARK: 시험 실행·되돌리기·실패

    @Test func 시험_실행은_아트워크_파일을_만들지_않고_넣을_곡만_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let (id, uuid) = try addBare(fixture, p)
        let report = try attach(fixture, uuid: uuid, input(p), dryRun: true)
        #expect(report.analysisWritten.count == 1 && report.artworkAdded == [uuid] && (report.createdFiles ?? []).isEmpty)
        #expect(try content(fixture, id)["ImagePath"] == "" && fixture.rows("SELECT * FROM contentFile").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER").path))
    }

    @Test func 되돌리면_아트워크_파일과_빈_폴더가_사라지고_다시_되돌리면_살아난다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let (id, uuid) = try addBare(fixture, p)
        let report = try attach(fixture, uuid: uuid, input(p))
        let base = artworkFolder(fixture, uuid)
        let original = try names.map { try Data(contentsOf: base.appending(path: $0)) }
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(!FileManager.default.fileExists(atPath: base.path), "만든 폴더까지 지운다")
        #expect(!FileManager.default.fileExists(atPath: base.deletingLastPathComponent().path))
        #expect(try content(fixture, id)["ImagePath"] == "" && fixture.rows("SELECT * FROM contentFile").isEmpty)
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(try names.map { try Data(contentsOf: base.appending(path: $0)) } == original)
        #expect(try content(fixture, id)["ImagePath"]?.hasSuffix("/artwork.jpg") == true)
    }

    @Test func 아트워크_파일을_쓰지_못하면_분석_파일과_DB도_되돌린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let (id, uuid) = try addBare(fixture, p)
        let before = try content(fixture, id)
        let count = try fixture.localUpdateCount()
        // 아트워크 폴더만 만들 수 없게 한다(분석 파일은 쓴 뒤 실패)
        let artwork = fixture.shareRoot.appending(path: "PIONEER/Artwork")
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: artwork.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: artwork.path) }
        let error = try #require(throws: DJCError.self) { try attach(fixture, uuid: uuid, input(p)) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try content(fixture, id) == before && fixture.localUpdateCount() == count)
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && fixture.rows("SELECT * FROM djmdMixerParam").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: analysisFile(fixture, uuid, "DAT").path), "먼저 쓴 분석 파일도 지운다")
        #expect((try FileManager.default.contentsOfDirectory(atPath: artwork.path)).isEmpty)
    }
}

/// share 밖 쓰기 막기(#66 코드 리뷰, 2026-10-04): 그림 폴더 위가 링크면 아직 없는 곡 UUID 폴더를 통해 share 밖에 쓰게 된다.
extension RekordboxAnalysisArtworkTests {
    @Test func 그림_폴더가_링크면_분석을_붙이지_않고_share_밖에_쓰지_않는다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 5000)
        try fixture.add(TrackSpec())
        let p = try await plan(fixture)
        let (_, uuid) = try addBare(fixture, p)
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.shareRoot.appending(path: "PIONEER"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.shareRoot.appending(path: "PIONEER/Artwork"), withDestinationURL: outside)
        let report = try attach(fixture, uuid: uuid, input(p))
        #expect(report.analysisWritten.isEmpty && report.analysisBlocked.first?.reason?.contains("링크") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
