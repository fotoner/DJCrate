import CoreGraphics
import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import ImageIO
import RekordboxFixtures
@testable import RekordboxKit
import Testing
import UniformTypeIdentifiers

/// 곡 정보에서 그림을 넣기·바꾸기·지우기(#66). 기대값은 rekordbox 7.2.18 실험이다(docs/rekordbox-internals.md "그림 편집").
/// - 묶음 2(2026-10-04, 상태 0 곡, 자동 분석 끔): S1 넣기 "DJC 시험 08"(1500×1500 JPEG), S2 바꾸기 "DJC 시험 07"(1200×675 PNG),
///   S3 지우기 "DJC 시험 08".
/// - #173(2026-10-04, 동기화 곡): S1 X2·X3 바꾸기, S2 U08 넣기(삭제 표시 262 행 되살리기)·U09 지우기(256 → 258)·U03 그림 지우기 뒤 아티스트
///   비우기, S3 V04 넣기(파일 행 INSERT).
/// - #173 S5(2026-10-04, 동기화 곡): W1 지우기, W2a 바꾸기 → W2b 지우기(257 → 258), W3a 지우기 → W3b 넣기(258 행 되살리기).
/// 세 동작 모두 `TrackInfoUpdated`와 재생 목록 XML을 바꾸지 않고, 음원 파일은 쓰지 않는다.
@Suite("rekordbox 그림 쓰기")
struct RekordboxArtworkWriterTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]
    /// 실험 그림과 같은 크기의 합성 그림. 시험마다 새 인스턴스를 만들므로 프로세스에서 한 번만 만든다(#167).
    static let square = ImageFixture.image(width: 1500, height: 1500, type: .jpeg)
    static let wide = ImageFixture.image(width: 1200, height: 675, type: .png, blue: 40)
    var square: Data { Self.square }
    var wide: Data { Self.wide }

    // MARK: 도움

    /// 분석한 곡 하나(그림 없음, `ImagePath` ''). 상태는 `state`. 실험 곡처럼 `TrackInfoUpdated` '1'.
    func library(state: Int = 0, count: Int = 1_006_078) throws -> (RekordboxFixture, TrackSpec) {
        let fixture = try RekordboxFixture(localUpdateCount: count)
        var track = TrackSpec(id: "213376017", uuid: "cb5ad1c8-1abf-49d1-b44c-63805c9286a1")
        track.analysisDataPath = "/PIONEER/USBANLZ/cb5/ad1c8-1abf-49d1-b44c-63805c9286a1/ANLZ0000.DAT"
        track.imagePath = ""
        try fixture.add(track)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ?, usn = 5, rb_local_synced = 1 WHERE ID = ?", [.int(state), .text(track.id)])
        return (fixture, track)
    }

    func path(_ track: TrackSpec) -> String { "/PIONEER/Artwork/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))/artwork.jpg" }
    func fileID(_ track: TrackSpec) -> String {
        "\(track.uuid)_%2FPIONEER%2FArtwork%2F\(track.uuid.prefix(3))%2F\(track.uuid.dropFirst(3))%2Fartwork.jpg"
    }
    func folder(_ fixture: RekordboxFixture, _ track: TrackSpec) -> URL {
        fixture.shareRoot.appending(path: "PIONEER/Artwork/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))")
    }
    func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// rekordbox가 만든 것처럼 그림 셋·파일 행·`ImagePath`를 둔다. 동기화 행은 rekordbox처럼 `usn`이 있고 `rb_priority` 0이다.
    @discardableResult
    func putArtwork(_ fixture: RekordboxFixture, _ track: TrackSpec, status: Int = 0, deleted: Bool = false, image: Data? = nil,
                    imagePath: String? = nil) throws -> TrackArtwork.Files {
        let files = try #require(TrackArtwork.make(image ?? ImageFixture.image(width: 600, height: 600, blue: 200)))
        let directory = folder(fixture, track)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !deleted {
            for (name, data) in zip(names, [files.full, files.medium, files.small]) { try data.write(to: directory.appending(path: name)) }
        }
        try fixture.insert("contentFile", [
            "ID": .text(fileID(track)), "ContentID": .text(track.id), "Path": .text(path(track)), "Hash": .text(md5(files.full)),
            "Size": .int(files.full.count), "rb_local_path": .text("/live/share" + path(track)), "rb_file_hash_dirty": .int(0),
            "rb_local_file_status": .int(0), "rb_in_progress": .int(0), "rb_process_type": .int(0), "rb_priority": .int(status == 0 ? 50 : 0),
            "rb_file_size_dirty": .int(0), "UUID": .text("old-file-uuid"), "rb_data_status": .int(status), "rb_local_data_status": .int(0),
            "rb_local_deleted": .int(deleted ? 1 : 0), "rb_local_synced": .int(status == 0 ? 0 : 1), "usn": status == 0 ? .null : .int(231_164),
            "rb_local_usn": .int(869_242), "created_at": .text("2020-04-14 07:55:28.306 +00:00"), "updated_at": .text("2024-08-31 15:30:27.162 +00:00"),
        ])
        if !deleted { try fixture.execute("UPDATE djmdContent SET ImagePath = ? WHERE ID = ?", [.text(imagePath ?? path(track)), .text(track.id)]) }
        return files
    }

    func base(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> ArtworkBase {
        let db = try fixture.open()
        defer { db.close() }
        return try #require(try RekordboxWriter.artworkBase(db: db, contentID: track.id))
    }

    func edit(_ fixture: RekordboxFixture, _ track: TrackSpec, image: Data?) throws -> ArtworkEdit {
        let draft = ArtworkDraft(trackUUID: track.uuid, change: image == nil ? .delete : .set, base: try base(fixture, track),
                                 imageName: image == nil ? nil : "그림.jpg")
        return ArtworkEdit(draft: draft, image: image)
    }

    func write(_ fixture: RekordboxFixture, _ edits: [ArtworkEdit], tags: [TagDraft] = [], drafts: [CueDraft] = [], grids: [GridDraft] = [],
               dryRun: Bool = false, shareRoot: URL?? = .none, at time: Date? = nil) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: grids, gains: [:], tags: tags, artworks: edits, analysisInputs: [:], to: fixture.database,
                                  dryRun: dryRun, now: time ?? now, backups: fixture.backups, shareRoot: shareRoot ?? fixture.shareRoot,
                                  attachesAnalysis: RekordboxWriter.attachesAnalysis, tagKeys: RekordboxWriter.writableTagKeys)
    }

    func content(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [String: String] {
        try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(track.id)]).first)
    }

    func fileRows(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [[String: String]] {
        try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ? AND Path LIKE '/PIONEER/Artwork/%'", [.text(track.id)])
    }

    func changed(_ before: [String: String], _ after: [String: String]) -> Set<String> {
        Set(after.keys.filter { after[$0] != before[$0] })
    }

    func images(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [(width: Int, height: Int, rgb: [UInt8])] {
        try names.map { try #require(ImageFixture.pixels(try Data(contentsOf: folder(fixture, track).appending(path: $0)))) }
    }

    func exists(_ fixture: RekordboxFixture, _ track: TrackSpec) -> [Bool] {
        names.map { FileManager.default.fileExists(atPath: folder(fixture, track).appending(path: $0).path) }
    }

    // MARK: 넣기

    @Test func 상태_0_곡에_그림을_넣으면_곡_행_다음에_파일_행을_넣는다() throws {
        // 묶음 2 S1 "DJC 시험 08": 곡 행 1006079(`ImagePath`·번호·시각) → 파일 행 1006080(INSERT, #4와 같은 칸 모양). TIU '1' 그대로.
        let (fixture, track) = try library()
        let before = try content(fixture, track)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        #expect(report.artworkWritten.map(\.trackUUID) == [track.uuid] && report.artworkBlocked.isEmpty)
        #expect(report.artworkWritten.first?.artwork == .add)

        let after = try content(fixture, track)
        #expect(changed(before, after) == ["ImagePath", "rb_local_usn", "updated_at"], "상태 0은 그대로, TIU 그대로")
        #expect(after["ImagePath"] == path(track) && after["rb_local_usn"] == "1006079" && after["updated_at"] == stamp)

        let full = try Data(contentsOf: folder(fixture, track).appending(path: "artwork.jpg"))
        let rows = try fileRows(fixture, track)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row["ID"] == fileID(track) && row["Path"] == path(track) && row["Hash"] == md5(full) && row["Size"] == String(full.count))
        #expect(row["rb_local_path"] == folder(fixture, track).appending(path: "artwork.jpg").path && row["rb_priority"] == "50")
        #expect(row["rb_insync_hash"] == "NULL" && row["rb_insync_local_usn"] == "NULL" && row["rb_temp_path"] == "NULL" && row["usn"] == "NULL")
        #expect(row["rb_data_status"] == "0" && row["rb_local_deleted"] == "0" && row["rb_local_synced"] == "0" && row["rb_local_data_status"] == "0")
        #expect(row["rb_local_usn"] == "1006080" && row["created_at"] == stamp && row["updated_at"] == stamp && row["UUID"]?.count == 36)
        #expect(try fixture.localUpdateCount() == 1_006_080 && report.finalUpdateCount == 1_006_080)

        // 1500×1500 → 800×800·240·80, 셋 다 그림 전체(자르기·여백 없음)
        #expect(try images(fixture, track).map { "\($0.width)x\($0.height)" } == ["800x800", "240x240", "80x80"])
        #expect(Set(report.createdFiles ?? []) == Set(names.map { folder(fixture, track).appending(path: $0).path }), "되돌릴 때 지울 파일")
    }

    @Test func 동기화_곡에_그림_행이_없으면_상태_0_행을_넣고_곡은_257() throws {
        // #173 S3 V04: 곡 행 `ImagePath`·256 → 257, 파일 행 INSERT(상태 0, `fileRow`와 같은 모양), TIU·XML 그대로.
        let (fixture, track) = try library(state: 256)
        let before = try content(fixture, track)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        #expect(report.artworkWritten.first?.artwork == .add)
        let after = try content(fixture, track)
        #expect(changed(before, after) == ["ImagePath", "rb_data_status", "rb_local_usn", "updated_at"])
        #expect(after["rb_data_status"] == "257" && after["usn"] == "5" && after["rb_local_synced"] == "1")
        let row = try #require(try fileRows(fixture, track).first)
        #expect(row["rb_data_status"] == "0" && row["usn"] == "NULL" && row["rb_local_usn"] == "1006080")
    }

    @Test func 지운_동기화_그림_행이_262로_남은_곡에_넣으면_그_행을_되살린다() throws {
        // #173 S2 U08: 같은 ID의 삭제 표시 행(262·`rb_local_deleted` 1·`rb_local_synced` 0)을 Hash·Size·262 → 257·삭제 0·번호·시각만 바꿔
        // 되살렸다. ID·UUID·`created_at`·Path·`rb_local_path`·`usn`·`rb_local_synced`·`rb_priority`는 그대로. 곡 행 → 파일 행 순서.
        let (fixture, track) = try library(state: 256)
        try putArtwork(fixture, track, status: 262, deleted: true)
        try fixture.execute("UPDATE contentFile SET rb_local_synced = 0, rb_priority = 50, usn = 283121 WHERE ID = ?", [.text(fileID(track))])
        let old = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        #expect(report.artworkWritten.first?.artwork == .add && report.artworkBlocked.isEmpty)
        let rows = try fileRows(fixture, track)
        let row = try #require(rows.first)
        let full = try Data(contentsOf: folder(fixture, track).appending(path: "artwork.jpg"))
        #expect(rows.count == 1)
        #expect(changed(old, row) == ["Hash", "Size", "rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(row["Hash"] == md5(full) && row["Size"] == String(full.count) && row["rb_data_status"] == "257" && row["rb_local_deleted"] == "0")
        #expect(row["rb_local_usn"] == "1006080" && row["updated_at"] == stamp && row["rb_local_path"] == "/live/share" + path(track))
        let after = try content(fixture, track)
        #expect(after["ImagePath"] == path(track) && after["rb_data_status"] == "257" && after["rb_local_usn"] == "1006079")
    }

    @Test func 지운_동기화_그림_행이_258이어도_그_행을_되살린다() throws {
        // #173 S5 W3a → W3b: 지우기로 258·삭제 표시가 된 행이 있는 곡에 넣으면 같은 행을 257·삭제 0·새 Hash·Size로 되살렸다(262 U08과 같은 모양).
        // 곡 행(116, `ImagePath`가 같은 경로로 돌아옴) → 파일 행(117), 새 파일은 남아 있던 폴더에.
        let (fixture, track) = try library(state: 257)
        try putArtwork(fixture, track, status: 258, deleted: true)
        let old = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        #expect(report.artworkWritten.first?.artwork == .add && report.artworkBlocked.isEmpty)
        let row = try #require(try fileRows(fixture, track).first)
        #expect(changed(old, row) == ["Hash", "Size", "rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(row["rb_data_status"] == "257" && row["rb_local_deleted"] == "0" && row["rb_local_usn"] == "1006080")
        let after = try content(fixture, track)
        #expect(after["ImagePath"] == path(track) && after["rb_data_status"] == "257" && after["rb_local_usn"] == "1006079")
        #expect(try exists(fixture, track) == [true, true, true])
    }

    // MARK: 바꾸기

    @Test func 그림을_바꾸면_곡_행은_그대로_두고_파일_행만_고친다() throws {
        // 묶음 2 S2 "DJC 시험 07"(1200×675 PNG): `djmdContent` 행 전혀 안 바뀜. `artwork.jpg` 행 제자리 UPDATE(Hash·Size·번호·시각),
        // 번호 하나. 파일 셋 800×450·240·80(위아래 검은 여백 52.5·17.5행).
        let (fixture, track) = try library()
        let oldFiles = try putArtwork(fixture, track)
        let before = try content(fixture, track), oldRow = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: wide)])
        #expect(report.artworkWritten.first?.artwork == .replace)
        #expect(try content(fixture, track) == before, "곡 행은 칸 하나 바뀌지 않는다")
        let row = try #require(try fileRows(fixture, track).first)
        let full = try Data(contentsOf: folder(fixture, track).appending(path: "artwork.jpg"))
        #expect(changed(oldRow, row) == ["Hash", "Size", "rb_local_usn", "updated_at"], "상태 0은 그대로")
        #expect(row["Hash"] == md5(full) && row["Size"] == String(full.count) && row["rb_local_usn"] == "1006079")
        #expect(try fixture.localUpdateCount() == 1_006_079)
        let pictures = try images(fixture, track)
        #expect(pictures.map { "\($0.width)x\($0.height)" } == ["800x450", "240x240", "80x80"])
        #expect(ImageFixture.rowBrightness(pictures[1], row: 30) < 3 && ImageFixture.rowBrightness(pictures[1], row: 120) > 40, "_m 위 여백")
        #expect(ImageFixture.rowBrightness(pictures[2], row: 8) < 3 && ImageFixture.rowBrightness(pictures[2], row: 40) > 40, "_s 위 여백")
        #expect(report.createdFiles == nil, "있던 파일을 바꿨다(백업의 옛 파일로 되돌린다)")

        // 쓰기 전으로 복원하면 옛 파일 세 개·파일 행이 돌아온다
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(try fileRows(fixture, track).first == oldRow)
        #expect(try names.map { try Data(contentsOf: folder(fixture, track).appending(path: $0)) } == [oldFiles.full, oldFiles.medium, oldFiles.small])
    }

    @Test(arguments: [256, 257]) func 동기화_그림을_바꾸면_파일_행만_256에서_257(trackState: Int) throws {
        // #173 S1 X3(곡 256 그대로)·X2(곡 257 그대로): 곡 행 0칸. 파일 행 Hash·Size·256 → 257·번호·시각. usn·`rb_local_synced` 그대로.
        let (fixture, track) = try library(state: trackState)
        try putArtwork(fixture, track, status: 256)
        let before = try content(fixture, track), oldRow = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        #expect(report.artworkWritten.first?.artwork == .replace)
        #expect(try content(fixture, track) == before)
        let row = try #require(try fileRows(fixture, track).first)
        #expect(changed(oldRow, row) == ["Hash", "Size", "rb_data_status", "rb_local_usn", "updated_at"])
        #expect(row["rb_data_status"] == "257" && row["usn"] == "231164" && row["rb_local_synced"] == "1" && row["rb_priority"] == "0")
    }

    // MARK: 지우기

    @Test func 상태_0_곡의_그림을_지우면_파일_행을_지우고_폴더는_남긴다() throws {
        // 묶음 2 S3 "DJC 시험 08": 곡 행 `ImagePath` ''(NULL 아님)·번호·시각, 파일 행 실제 DELETE(번호 없음), 그림 셋 지우고 폴더 남김.
        let (fixture, track) = try library()
        let oldFiles = try putArtwork(fixture, track)
        let before = try content(fixture, track), oldRow = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: nil)])
        #expect(report.artworkWritten.first?.artwork == .delete)
        let after = try content(fixture, track)
        #expect(changed(before, after) == ["ImagePath", "rb_local_usn", "updated_at"])
        #expect(after["ImagePath"] == "" && after["rb_local_usn"] == "1006079")
        #expect(try fileRows(fixture, track).isEmpty && fixture.localUpdateCount() == 1_006_079)
        #expect(exists(fixture, track) == [false, false, false])
        #expect(FileManager.default.fileExists(atPath: folder(fixture, track).path), "폴더는 남긴다")

        // 쓰기 전으로 복원하면 세 파일·행·`ImagePath`가 돌아온다
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(try content(fixture, track) == before && fileRows(fixture, track).first == oldRow)
        #expect(try names.map { try Data(contentsOf: folder(fixture, track).appending(path: $0)) } == [oldFiles.full, oldFiles.medium, oldFiles.small])
    }

    @Test func 동기화_그림을_지우면_파일_행은_258_삭제_표시() throws {
        // #173 S2 U09: 곡 행 `ImagePath` ''·256 → 257(134), 파일 행 256 → 258·`rb_local_deleted` 1·번호·시각 네 칸(135).
        let (fixture, track) = try library(state: 256)
        try putArtwork(fixture, track, status: 256)
        let oldRow = try #require(try fileRows(fixture, track).first)
        let report = try write(fixture, [try edit(fixture, track, image: nil)])
        #expect(report.artworkWritten.first?.artwork == .delete)
        let after = try content(fixture, track)
        #expect(after["ImagePath"] == "" && after["rb_data_status"] == "257" && after["rb_local_usn"] == "1006079")
        let row = try #require(try fileRows(fixture, track).first)
        #expect(changed(oldRow, row) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(row["rb_data_status"] == "258" && row["rb_local_deleted"] == "1" && row["rb_local_usn"] == "1006080" && row["updated_at"] == stamp)
        #expect(exists(fixture, track) == [false, false, false])
    }

    @Test func 바꾼_뒤_257이_된_그림_행을_지우면_258_삭제_표시() throws {
        // #173 S5 W2a → W2b: 바꾸기로 257이 된 파일 행(Hash·Size는 바꾼 그림 값)을 지우면 256과 같은 네 칸으로 258·삭제 1. Hash·Size 그대로.
        let (fixture, track) = try library(state: 256)
        try putArtwork(fixture, track, status: 256)
        _ = try write(fixture, [try edit(fixture, track, image: square)])
        let replaced = try #require(try fileRows(fixture, track).first)
        #expect(replaced["rb_data_status"] == "257")
        let report = try write(fixture, [try edit(fixture, track, image: nil)], at: now.addingTimeInterval(60))
        #expect(report.artworkWritten.first?.artwork == .delete)
        let row = try #require(try fileRows(fixture, track).first)
        #expect(changed(replaced, row) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(row["rb_data_status"] == "258" && row["rb_local_deleted"] == "1" && row["Hash"] == replaced["Hash"])
        #expect(try content(fixture, track)["ImagePath"] == "" && exists(fixture, track) == [false, false, false])
        #expect(FileManager.default.fileExists(atPath: folder(fixture, track).path), "빈 폴더는 남긴다")
    }

    // MARK: 같은 쓰기의 다른 초안

    @Test func 같은_곡의_그림과_태그는_그림_먼저_쓰고_하나씩_쓴_것과_같다() throws {
        // #173 S2 U03: 그림 지우기(곡 행 114·파일 행 258 115)를 먼저 저장하고 아티스트 비우기(앨범 257 117·아티스트 258 118·곡 행 119).
        func prepared() throws -> (RekordboxFixture, TrackSpec) {
            let (fixture, track) = try library(state: 256)
            try fixture.insert("djmdArtist", ["ID": .text("11"), "Name": .text("月下"), "UUID": .text("a-11"), "rb_data_status": .int(256),
                                              "rb_local_deleted": .int(0), "rb_local_usn": .int(5), "usn": .int(7)])
            try fixture.insert("djmdAlbum", ["ID": .text("31"), "Name": .text("SHOW UP"), "UUID": .text("al-31"), "rb_data_status": .int(256),
                                             "rb_local_deleted": .int(0), "rb_local_usn": .int(7)])
            try fixture.execute("UPDATE djmdContent SET ArtistID = '11', AlbumID = '31' WHERE ID = ?", [.text(track.id)])
            try putArtwork(fixture, track, status: 256)
            return (fixture, track)
        }
        func tag(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> TagDraft {
            let db = try fixture.open()
            defer { db.close() }
            var draft = TagDraft(trackUUID: track.uuid, base: try #require(try RekordboxWriter.currentTags(db: db, contentID: track.id)))
            draft.fields.artist = ""
            return draft
        }
        let (batch, track) = try prepared()
        let report = try write(batch, [try edit(batch, track, image: nil)], tags: [try tag(batch, track)])
        #expect(report.artworkWritten.count == 1 && report.tagWritten.count == 1)

        let (sequential, _) = try prepared()
        _ = try write(sequential, [try edit(sequential, track, image: nil)])
        _ = try write(sequential, [], tags: [try tag(sequential, track)])
        for table in ["djmdContent", "contentFile", "djmdArtist", "djmdAlbum", "agentRegistry"] {
            #expect(try batch.rows("SELECT * FROM \(table) ORDER BY 1") == sequential.rows("SELECT * FROM \(table) ORDER BY 1"), "\(table)")
        }
        let content = try content(batch, track), file = try #require(try fileRows(batch, track).first)
        #expect(Int(file["rb_local_usn"]!)! < Int(content["rb_local_usn"]!)!, "곡 행이 마지막 번호")
        #expect(content["ImagePath"] == "" && content["ArtistID"] == "" && content["TrackInfoUpdated"] == "2")
    }

    @Test func 같은_곡의_큐와_BPM과_그림을_함께_써도_커밋_뒤_확인을_통과한다() throws {
        // 큐·BPM이 먼저 곡 행 번호를 받고 그림 넣기가 곡 행·파일 행을 한 번 더 고친다. 커밋 뒤 확인은 마지막 값을 봐야 한다.
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        try fixture.execute("UPDATE djmdContent SET ImagePath = '' WHERE ID = ?", [.text(track.id)])
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(130, at: 0)
        var cues = CueDraft(trackUUID: track.uuid)
        cues.place(EditableCue(kind: .memory, time: 30))
        let report = try write(fixture, [try edit(fixture, track, image: square)], drafts: [cues], grids: [grid])
        #expect(report.written.count == 1 && report.artworkWritten.count == 1 && report.gridWritten.count == 1)
        let content = try content(fixture, track)
        #expect(content["ImagePath"] == path(track) && content["BPM"] == "13000" && content["rb_data_status"] == "257")
        let file = try #require(try fileRows(fixture, track).first)
        #expect(Int(content["rb_local_usn"]!)! + 1 == Int(file["rb_local_usn"]!)!, "그림 넣기는 곡 행 → 파일 행")
        #expect(try Int(file["rb_local_usn"]!) == fixture.localUpdateCount())
    }

    @Test func 미리_보기는_아무것도_바꾸지_않는다() throws {
        let (fixture, track) = try library()
        try putArtwork(fixture, track)
        let before = try fixture.rows("SELECT * FROM contentFile"), content = try content(fixture, track)
        let files = try names.map { try Data(contentsOf: folder(fixture, track).appending(path: $0)) }
        let report = try write(fixture, [try edit(fixture, track, image: wide)], dryRun: true)
        #expect(report.artworkWritten.first?.artwork == .replace && report.backup == nil)
        #expect(try fixture.rows("SELECT * FROM contentFile") == before && self.content(fixture, track) == content)
        #expect(try names.map { try Data(contentsOf: folder(fixture, track).appending(path: $0)) } == files)
    }

    @Test func 넣은_그림은_쓰기_전으로_복원하면_지워진다() throws {
        let (fixture, track) = try library()
        let before = try content(fixture, track)
        let report = try write(fixture, [try edit(fixture, track, image: square)])
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(try content(fixture, track) == before && fileRows(fixture, track).isEmpty)
        #expect(exists(fixture, track) == [false, false, false])
    }

    @Test func 쓴_그림_초안과_그림_사본을_백업에_둔다() throws {
        let (fixture, track) = try library()
        let edit = try edit(fixture, track, image: square)
        let report = try write(fixture, [edit])
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        #expect(RekordboxWriter.artworkDrafts(in: backup) == [edit])
    }

    // MARK: 재생 목록 XML

    @Test(arguments: [ArtworkWriteKind.add, .replace, .delete])
    func 그림을_써도_곡이_든_재생_목록의_XML은_그대로다(kind: ArtworkWriteKind) throws {
        // #173 S1 X2(바꾸기)·S3 V04(넣기)·S5 W1·W2b·W3a(지우기): 그림 저장은 그 곡이 든 살아 있는 목록의 Timestamp를 바꾸지 않았다.
        let (fixture, track) = try library()
        if kind != .add { try putArtwork(fixture, track) }
        let list = PlaylistSpec(id: "1000", name: "목록", seq: 1, contentIDs: [track.id])
        try fixture.add(list)
        var document = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try document.append(id: list.id, parentID: list.parentID, isFolder: false, timestamp: 1_000)
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try document.text.write(to: url, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: url)
        let report = try write(fixture, [try edit(fixture, track, image: kind == .delete ? nil : wide)])
        #expect(report.artworkWritten.first?.artwork == kind)
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: 막기

    @Test func 막는_곡은_이유와_할_일을_알리고_바꾸지_않는다() throws {
        typealias Case = (name: String, setUp: (RekordboxFixture, TrackSpec) throws -> Void, image: Data?)
        let cases: [Case] = [
            ("곡 상태 0·256·257 밖", { f, t in try f.execute("UPDATE djmdContent SET rb_data_status = 262 WHERE ID = ?", [.text(t.id)]) }, square),
            ("분석 전 곡", { f, t in try f.execute("UPDATE djmdContent SET AnalysisDataPath = '' WHERE ID = ?", [.text(t.id)]) }, square),
            ("지운 곡", { f, t in try f.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = ?", [.text(t.id)]) }, square),
            ("ImagePath는 있는데 파일 행 없음", { f, t in try f.execute("UPDATE djmdContent SET ImagePath = ? WHERE ID = ?", [.text(path(t)), .text(t.id)]) }, square),
            ("곡 폴더가 아닌 ImagePath", { f, t in try putArtwork(f, t, imagePath: "/PIONEER/Artwork/000/other/artwork.jpg") }, square),
            ("파일 행이 여럿", { f, t in
                try putArtwork(f, t)
                try f.insert("contentFile", ["ID": .text("dup"), "ContentID": .text(t.id), "Path": .text(path(t)), "rb_local_deleted": .int(0),
                                              "rb_data_status": .int(0)])
            }, square),
            ("확인하지 않은 파일 행 상태", { f, t in try putArtwork(f, t, status: 2) }, square),
            ("그림 없이 ImagePath만 빈 곡에 남은 파일 행", { f, t in
                try putArtwork(f, t)
                try f.execute("UPDATE djmdContent SET ImagePath = '' WHERE ID = ?", [.text(t.id)])
            }, square),
            ("그림 폴더에 파일이 이미 있음", { f, t in
                try FileManager.default.createDirectory(at: folder(f, t), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: folder(f, t).appending(path: "artwork.jpg"))
            }, square),
            ("JPEG·PNG가 아닌 그림", { _, _ in }, ImageFixture.image(width: 300, height: 300, type: .gif)),
            ("풀지 못하는 그림", { _, _ in }, Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])),
            ("지울 그림이 없음", { _, _ in }, nil),
        ]
        for (name, setUp, image) in cases {
            let (fixture, track) = try library()
            try setUp(fixture, track)
            let db = try fixture.open()
            let base = try RekordboxWriter.artworkBase(db: db, contentID: track.id) ?? ArtworkBase(imagePath: "")
            db.close()
            let draft = ArtworkDraft(trackUUID: track.uuid, change: image == nil ? .delete : .set, base: base)
            let before = try fixture.rows("SELECT * FROM contentFile"), content = try content(fixture, track)
            let report = try write(fixture, [ArtworkEdit(draft: draft, image: image)])
            let blocked = report.artworkBlocked.first
            #expect(report.artworkWritten.isEmpty && blocked != nil, "\(name)")
            #expect(blocked?.reason?.isEmpty == false && blocked?.reason?.hasSuffix(".") == false, "\(name): 할 일까지 적은 한 문장")
            #expect(try fixture.rows("SELECT * FROM contentFile") == before && self.content(fixture, track) == content, "\(name)")
            #expect(try fixture.localUpdateCount() == 1_006_078, "\(name)")
        }
    }

    @Test func 초안을_만든_뒤_rekordbox에서_그림이_바뀌면_쓰지_않는다() throws {
        // 바꾸기는 곡 행을 건드리지 않으므로 파일 행 Hash로 알아챈다.
        let (fixture, track) = try library(state: 256)
        try putArtwork(fixture, track, status: 256)
        let edit = try edit(fixture, track, image: wide)
        try fixture.execute("UPDATE contentFile SET Hash = 'rekordbox-changed', rb_data_status = 257 WHERE ID = ?", [.text(fileID(track))])
        let report = try write(fixture, [edit])
        #expect(report.artworkWritten.isEmpty && report.artworkBlocked.first?.reason?.contains("초안을 만든 뒤") == true)
    }

    @Test func 그림_사본이_없거나_초안과_다르면_막는다() throws {
        let (fixture, track) = try library()
        var missing = try edit(fixture, track, image: square)
        missing.image = nil
        var other = try edit(fixture, track, image: square)
        other.draft.imageSHA256 = String(repeating: "0", count: 64)
        for item in [missing, other] {
            let report = try write(fixture, [item])
            #expect(report.artworkWritten.isEmpty && report.artworkBlocked.count == 1)
        }
    }

    @Test func 사본_DB에_share를_주지_않으면_막는다() throws {
        let (fixture, track) = try library()
        let report = try write(fixture, [try edit(fixture, track, image: square)], shareRoot: .some(nil))
        #expect(report.artworkWritten.isEmpty && report.artworkBlocked.first?.reason?.contains("share") == true)
    }

    @Test func 확인하지_않은_그림_모양은_막는다() throws {
        // 투명한 PNG(검은 바탕에 그림)·EXIF 회전(무시)은 rekordbox 결과를 확인하지 않았다(#4 문서의 미확인).
        #expect(TrackArtwork.unsupportedReason(square) == nil && TrackArtwork.unsupportedReason(wide) == nil)
        #expect(TrackArtwork.unsupportedReason(ImageFixture.image(width: 64, height: 64, type: .tiff)) != nil)
        #expect(TrackArtwork.unsupportedReason(Self.transparentPNG()) != nil)
        #expect(TrackArtwork.unsupportedReason(Self.rotatedJPEG()) != nil)
        #expect(TrackArtwork.unsupportedReason(Data("not an image".utf8)) != nil)
    }

    // MARK: 커밋 뒤 실패

    @Test func 그림_파일을_못_쓰면_DB와_옛_그림을_되돌린다() throws {
        let (fixture, track) = try library(state: 256)
        let oldFiles = try putArtwork(fixture, track, status: 256)
        let before = try fixture.rows("SELECT * FROM contentFile ORDER BY 1"), content = try content(fixture, track)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder(fixture, track).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder(fixture, track).path) }
        let error = try #require(throws: DJCError.self) { try write(fixture, [try edit(fixture, track, image: wide)]) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try fixture.rows("SELECT * FROM contentFile ORDER BY 1") == before && self.content(fixture, track) == content)
        #expect(try names.map { try Data(contentsOf: folder(fixture, track).appending(path: $0)) } == [oldFiles.full, oldFiles.medium, oldFiles.small])
    }

    @Test func 넣을_폴더를_만들지_못하면_DB를_되돌린다() throws {
        let (fixture, track) = try library()
        let parent = fixture.shareRoot.appending(path: "PIONEER/Artwork/\(track.uuid.prefix(3))")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let content = try content(fixture, track)
        let error = try #require(throws: DJCError.self) { try write(fixture, [try edit(fixture, track, image: square)]) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try self.content(fixture, track) == content && fileRows(fixture, track).isEmpty)
    }

    @Test(arguments: ["UPDATE contentFile SET Hash = 'x' WHERE Path LIKE '/PIONEER/Artwork/%'",
                      "UPDATE djmdContent SET ImagePath = 'x'",
                      "UPDATE djmdContent SET rb_data_status = 256"])
    func 커밋_뒤_다시_읽어_다르면_되돌린다(tamper: String) throws {
        let (fixture, track) = try library(state: 256)
        try putArtwork(fixture, track, status: 256)
        let edit = try edit(fixture, track, image: nil)
        let before = try fixture.rows("SELECT * FROM contentFile ORDER BY 1")
        try fixture.execute("CREATE TRIGGER djc_test_tamper AFTER UPDATE OF int_1 ON agentRegistry BEGIN \(tamper); END")
        let error = try #require(throws: DJCError.self) { try write(fixture, [edit]) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try fixture.rows("SELECT * FROM contentFile ORDER BY 1") == before && exists(fixture, track) == [true, true, true])
    }

    // MARK: 합성 그림

    /// 가운데가 투명한 PNG
    static func transparentPNG() -> Data {
        let size = 32
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) where (i / 4) % size > 8 { rgba[i] = 0 }
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// EXIF 방향 6(90도 회전)이 붙은 JPEG
    static func rotatedJPEG() -> Data {
        let source = CGImageSourceCreateWithData(ImageFixture.image(width: 40, height: 20) as CFData, nil)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
