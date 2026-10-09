import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 곡 추가·삭제. rekordbox 7.2.18이 직접 한 결과(2026-09-26 묶음 1·2 실험)를 기대값으로 둔다.
/// 첫 BPM/Grid 카운터는 2026-09-27 합성 곡 "DJC 실험 카운터 auto/manual-grid"의 1·1로 고정한다.
@Suite("rekordbox 곡 추가·삭제")
struct RekordboxTrackWriterTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"

    func plan(_ resource: String) async throws -> TrackAddPlan {
        let url = try TestResources.url(resource)
        return try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url), now: now)
    }

    func add(_ fixture: RekordboxFixture, _ plans: [TrackAddPlan]) throws -> RekordboxTrackWriter.Report {
        try RekordboxTrackWriter.add(plans, to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
    }

    func row(_ fixture: RekordboxFixture, _ id: String) throws -> [String: String] {
        try #require(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(id)]).first)
    }

    // MARK: 태그

    @Test func 태그를_읽는다() async throws {
        let tags = try await AudioTags.read(url: try TestResources.url("mp3-tagged.mp3"))
        #expect(tags.title == "시험 제목" && tags.artist == "시험 아티스트" && tags.album == "시험 앨범")
        #expect(tags.albumArtist == "시험 앨범 아티스트" && tags.genre == "Anison" && tags.composer == "시험 작곡가")
        #expect(tags.comment == "시험 코멘트" && tags.year == 2024 && tags.trackNumber == 3 && tags.discNumber == 2)
        #expect(tags.isrc == "JPTEST000001" && abs(tags.duration - 2) < 0.1, "\(tags.duration)")
    }

    @Test func 태그가_없으면_파일_이름이_제목() async throws {
        let p = try await plan("mp3-notag-cbr.mp3")
        #expect(p.title == "mp3-notag-cbr" && p.artist == nil && p.comment == "" && p.fileType == 1)
    }

    // MARK: 추가

    @Test func 분석_전_곡_행은_rekordbox_7이_넣은_모양과_같다() async throws {
        // O-Ku-Ri-Mo-No Sunday!를 자동 분석을 끄고 넣었을 때(2026-09-26)의 칸 값·형식
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        try fixture.add(TrackSpec())   // 라이브러리 공통값을 가져올 기존 곡
        try fixture.insert("djmdArtist", ["ID": .text("111"), "Name": .text("시험 아티스트"), "UUID": .text("u"), "rb_local_deleted": .int(0)])
        let p = try await plan("mp3-tagged.mp3")
        let report = try add(fixture, [p])
        let id = try #require(report.added.first?.contentID)
        #expect(report.added.first?.written == true && (Int(id) ?? 0) > 0 && (Int(id) ?? 0) < 1 << 28)
        let r = try row(fixture, id)
        // 분석 전 칸
        #expect(r["BPM"] == "0" && r["BitRate"] == "0" && r["BitDepth"] == "0" && r["SampleRate"] == "0")
        #expect(r["KeyID"] == "0" && r["AnalysisDataPath"] == "" && r["Analysed"] == "0" && r["ContentLink"] == "14")
        #expect(r["AnalysisUpdated"] == "NULL" && r["TrackInfoUpdated"] == "NULL" && r["CueUpdated"] == "NULL")
        // 태그·파일
        #expect(r["Title"] == "시험 제목" && r["FileNameL"] == "mp3-tagged.mp3" && r["FileNameS"] == "" && r["FileType"] == "1")
        #expect(r["Commnt"] == "시험 코멘트" && r["ReleaseYear"] == "2024" && r["TrackNo"] == "3" && r["DiscNo"] == "2")
        #expect(r["ISRC"] == "JPTEST000001" && r["Length"] == "2" && r["FolderPath"] == p.path && r["FileSize"] == String(p.fileSize))
        #expect(r["rb_file_id"] == p.fileID && r["DateCreated"] == p.dateCreated && r["StockDate"] == "2026-09-25")
        // 고정값
        #expect(r["MasterDBID"] == RekordboxFixture.masterDBID && r["DeviceID"] == RekordboxFixture.deviceID && r["MasterSongID"] == id)
        #expect(r["HotCueAutoLoad"] == "on" && r["DeliveryControl"] == "on" && r["ExtInfo"] == "null" && r["ColorID"] == "0")
        #expect(r["ImagePath"] == "" && r["Rating"] == "0" && r["DJPlayCount"] == "0" && r["SamplerGain"] == "0.0")
        #expect(r["rb_data_status"] == "0" && r["usn"] == "NULL" && r["created_at"] == stamp && r["updated_at"] == stamp)
        let types = try #require(try fixture.rows("""
            SELECT typeof(KeyID) k, typeof(ColorID) c, typeof(VideoAssociate) v, typeof(rb_file_id) f, typeof(SamplerGain) g, typeof(Length) l
            FROM djmdContent WHERE ID = ?
            """, [.text(id)]).first)
        #expect(types == ["k": "text", "c": "text", "v": "text", "f": "text", "g": "real", "l": "integer"])
        // 아티스트는 있던 행을 쓰고, 앨범 아티스트·앨범·장르·작곡가는 새 행
        #expect(r["ArtistID"] == "111")
        let album = try #require(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = ?", [.text(r["AlbumID"] ?? "")]).first)
        #expect(album["Name"] == "시험 앨범" && album["Compilation"] == "0" && album["ImagePath"] == "NULL")
        #expect(try fixture.rows("SELECT Name FROM djmdArtist WHERE ID = ?", [.text(album["AlbumArtistID"] ?? "")]).first?["Name"] == "시험 앨범 아티스트")
        #expect(try fixture.rows("SELECT Name FROM djmdGenre WHERE ID = ?", [.text(r["GenreID"] ?? "")]).first?["Name"] == "Anison")
        #expect(try fixture.rows("SELECT Name FROM djmdArtist WHERE ID = ?", [.text(r["ComposerID"] ?? "")]).first?["Name"] == "시험 작곡가")
        // 변경 번호: 관련 행 4개가 먼저, 곡 행이 마지막
        #expect(r["rb_local_usn"] == "1005" && album["rb_local_usn"] == "1002")
        #expect(try fixture.localUpdateCount() == 1005)
        // 분석 파일·파일 행·오토게인 행은 없다
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ?", [.text(id)]).isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).isEmpty)
    }

    @Test func 이미_컬렉션에_있는_파일은_막는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan("mp3-tagged.mp3")
        #expect(try add(fixture, [p]).added.first?.written == true)
        let again = try add(fixture, [p])
        #expect(again.added.first?.written == false && again.added.first?.reason?.contains("이미") == true)
        #expect(try fixture.rows("SELECT * FROM djmdContent WHERE FolderPath = ?", [.text(p.path)]).count == 1)
    }

    @Test func rekordbox가_켜져_있으면_넣지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        let p = try await plan("mp3-tagged.mp3")
        #expect(throws: DJCError.self) {
            try RekordboxTrackWriter.add([p], to: fixture.database, dryRun: false, now: now, backups: fixture.backups, guard: running)
        }
        #expect(try fixture.rows("SELECT * FROM djmdContent").count == 1)
    }

    // MARK: 분석까지 붙여 넣기

    @Test func 분석을_붙이면_분석_파일_3개와_파일_행_오토게인_행까지() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let p = try await plan("mp3-tagged.mp3")
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        let report = try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: false, now: now, backups: fixture.backups)
        let id = try #require(report.added.first?.contentID)
        let r = try row(fixture, id)
        #expect(r["BPM"] == "12000" && r["Length"] == "2" && r["BitRate"] == "128" && r["SampleRate"] == "44100" && r["BitDepth"] == "16")
        #expect(r["Analysed"] == "105" && r["ContentLink"] == "2885134" && r["AnalysisUpdated"] == "1" && r["TrackInfoUpdated"] == "1")
        let uuid = try #require(r["UUID"])
        #expect(r["AnalysisDataPath"] == "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.DAT")
        // 분석 파일: rekordbox 7.2.18과 같은 태그 순서
        let dat = try AnlzFile(url: try #require(RekordboxShare.analysisURL(r["AnalysisDataPath"], root: fixture.shareRoot)))
        #expect(dat.tags.map(\.fourcc) == ["PPTH", "PVBR", "PQTZ", "PWAV", "PWV2", "PCOB", "PCOB"])
        let beats = BeatGridTags.decode(pqtz: try #require(dat.tag("PQTZ")).bytes, pqt2: nil).beats
        #expect(beats.prefix(2).map(\.time) == [0, 500] && beats[1].number == 1 && beats.allSatisfy { $0.bpm100 == 12000 })
        #expect(report.createdFiles.count == 3)
        // 파일 행 3개(해시·크기가 실제 파일과 같다)
        let files = try fixture.rows("SELECT Path, Hash, Size, rb_local_path, ID FROM contentFile WHERE ContentID = ? ORDER BY Path", [.text(id)])
        #expect(files.map { String($0["Path"]!.suffix(3)) } == ["2EX", "DAT", "EXT"])
        for file in files {
            let data = try Data(contentsOf: URL(filePath: file["rb_local_path"]!))
            #expect(file["Size"] == String(data.count) && file["ID"]!.hasPrefix("\(uuid)_%2FPIONEER%2FUSBANLZ%2F"))
        }
        // 오토게인: −10 LUFS 목표 → −8 LUFS 곡은 −2dB
        let mixer = try #require(try fixture.rows("SELECT * FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).first)
        let gain = RekordboxAutoGain.float(high: Int(mixer["GainHigh"]!)!, low: Int(mixer["GainLow"]!)!)
        #expect(abs(20 * log10(Double(gain)) + 2) < 1e-4)
        #expect(abs(Double(RekordboxAutoGain.float(high: Int(mixer["PeakHigh"]!)!, low: Int(mixer["PeakLow"]!)!)) - 0.9) < 1e-6)
        // 지우면 분석 폴더도 사라진다
        _ = try RekordboxTrackWriter.delete(contentIDs: [id], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                            now: now.addingTimeInterval(1), backups: fixture.backups)
        #expect(!FileManager.default.fileExists(atPath: dat.tags.isEmpty ? "" : try #require(RekordboxShare.analysisURL(r["AnalysisDataPath"], root: fixture.shareRoot)).path))
        #expect(try fixture.rows("SELECT * FROM contentFile WHERE ContentID = ?", [.text(id)]).isEmpty)
    }

    @Test func 큐_초안도_같은_트랜잭션에서_함께_넣는다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let wav = try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "cue.wav")
        let p = try TrackAddPlan.make(url: wav, tags: try await AudioTags.read(url: wav), now: now)
        let cues = [EditableCue(kind: .memory, time: 1.373), EditableCue(kind: .hot(0), time: 10.973)]
        let report = try RekordboxTrackWriter.add([p], cues: [p.path: cues], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.cuesWritten == 2 && outcome.cueReason == nil)
        let id = try #require(outcome.contentID)
        let rows = try fixture.rows("SELECT Kind, InMsec FROM djmdCue WHERE ContentID = ? ORDER BY InMsec", [.text(id)])
        #expect(rows == [["Kind": "0", "InMsec": "1373"], ["Kind": "1", "InMsec": "10973"]])
        let record = try #require(try fixture.rows("SELECT rb_cue_count, rb_local_usn FROM contentCue WHERE ContentID = ?", [.text(id)]).first)
        #expect(record["rb_cue_count"] == "2")
        // 곡 행은 큐를 쓴 모양(CueUpdated·변경 번호)이고 변경 카운터가 마지막 번호다
        let content = try row(fixture, id)
        let final = try fixture.localUpdateCount()
        #expect(content["CueUpdated"] == "2" && content["rb_local_usn"] == "\(final)" && record["rb_local_usn"] == "\(final - 1)",
                "큐 기록 다음 번호를 곡 행이 받는다(큐 쓰기와 같은 순서)")
        #expect(report.finalUpdateCount == final)
        // 되돌리면 곡과 큐가 함께 사라진다
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try fixture.rows("SELECT * FROM djmdCue").isEmpty && fixture.rows("SELECT * FROM contentCue").isEmpty)
    }

    @Test func 큐가_막혀도_곡은_넣고_이유를_남긴다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let wav = try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "many.wav")
        let p = try TrackAddPlan.make(url: wav, tags: try await AudioTags.read(url: wav), now: now)
        let cues = (0..<11).map { EditableCue(kind: .memory, time: Double($0) + 0.5) }   // 메모리 큐 한도 10
        let report = try RekordboxTrackWriter.add([p], cues: [p.path: cues], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let outcome = try #require(report.added.first)
        #expect(outcome.written && outcome.cuesWritten == nil && outcome.cueReason?.isEmpty == false)
        #expect(try fixture.rows("SELECT * FROM djmdCue").isEmpty && fixture.rows("SELECT * FROM djmdContent").count == 2)
    }

    @Test func 규칙을_모르는_형식은_분석을_붙이지_않고_막는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let alac = try AudioFixture.alac(seconds: 1, sampleRate: 96_000, in: fixture.audio)
        let p = try TrackAddPlan.make(url: alac, tags: try await AudioTags.read(url: alac), now: now)
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)], loudness: -10, peak: 1)
        let report = try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: false, now: now, backups: fixture.backups)
        #expect(report.added.first?.written == false && report.added.first?.reason?.contains("ALAC") == true)
        #expect(try fixture.rows("SELECT * FROM djmdContent").count == 1)
    }

    @Test func FLAC은_EXT_끝에_탐색표_PVB2를_붙인다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let flac = try AudioFixture.flac(seconds: 2, in: fixture.audio)
        let p = try TrackAddPlan.make(url: flac, tags: try await AudioTags.read(url: flac), now: now)
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)], loudness: -10, peak: 1)
        let report = try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: false, now: now, backups: fixture.backups)
        let id = try #require(report.added.first?.contentID)
        let r = try row(fixture, id)
        #expect(r["FileType"] == "5" && r["BitRate"] == "0" && r["BitDepth"] == "24" && r["SampleRate"] == "44100" && r["Analysed"] == "105")
        let datURL = try #require(RekordboxShare.analysisURL(r["AnalysisDataPath"], root: fixture.shareRoot))
        let pvbr = try #require(try AnlzFile(url: datURL).tag("PVBR"))
        #expect(pvbr.bytes.dropFirst(12).allSatisfy { $0 == 0 }, "FLAC의 PVBR은 탐색표·끝값 모두 0")
        let ext = try AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT"))
        #expect(ext.tags.map(\.fourcc) == ["PPTH", "PWV3", "PCOB", "PCOB", "PCO2", "PCO2", "PQT2", "PWV5", "PWV4", "PVB2"])
        #expect(ext.tag("PVB2")?.bytes == TrackAnalysisFiles.pvb2(AudioFacts.read(url: flac)))
    }

    // MARK: 삭제

    /// A(지울 곡)·B가 재생 목록·이력에 A, B 순으로 있다. A만 쓰는 아티스트·앨범, 둘이 같이 쓰는 아티스트.
    /// A는 동기화 상태 0(곡 빼기 규칙은 상태 0 곡으로만 확인했다, #196). B는 동기화를 마친 곡(256)이라 빼지 않는 곡이다.
    func deleteFixture() throws -> (RekordboxFixture, TrackSpec, TrackSpec) {
        let fixture = try RekordboxFixture(localUpdateCount: 2000)
        for (id, name) in [("1", "A만"), ("2", "같이"), ("3", "앨범 아티스트")] {
            try fixture.insert("djmdArtist", ["ID": .text(id), "Name": .text(name), "UUID": .text("u\(id)"), "rb_local_deleted": .int(0)])
        }
        try fixture.insert("djmdAlbum", ["ID": .text("10"), "Name": .text("A 앨범"), "AlbumArtistID": .text("3"), "UUID": .text("ua"), "rb_local_deleted": .int(0)])
        var a = TrackSpec(id: "100", uuid: "aaa00000-0000-4000-8000-000000000001")
        a.dataStatus = 0
        a.artistID = "1"; a.composerID = "2"; a.albumID = "10"
        a.analysisDataPath = "/PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.DAT"
        a.imagePath = "/PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001/artwork.jpg"
        a.cues = [CueSpec(kind: 1, inMsec: 1000)]
        a.gain = (high: 16256, low: 0)
        var b = TrackSpec(id: "200")
        b.artistID = "2"
        try fixture.add(a); try fixture.add(b)
        try fixture.addContentFile(for: a, hash: "h", size: 1)
        for (table, list) in [("djmdSongPlaylist", "PlaylistID"), ("djmdSongHistory", "HistoryID")] {
            for (n, track) in [a, b].enumerated() {
                try fixture.insert(table, ["ID": .text("\(table)-\(n)"), list: .text("L"), "ContentID": .text(track.id), "TrackNo": .int(n + 1),
                                           "UUID": .text("u-\(table)-\(n)"), "rb_local_deleted": .int(0), "rb_local_usn": .int(5)])
            }
        }
        let files = [fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001"), fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001")]
        for folder in files { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("dat".utf8).write(to: files[0].appending(path: "ANLZ0000.DAT"))
        try Data("ext".utf8).write(to: files[0].appending(path: "ANLZ0000.EXT"))
        try Data("jpg".utf8).write(to: files[1].appending(path: "artwork.jpg"))
        return (fixture, a, b)
    }

    func delete(_ fixture: RekordboxFixture, _ ids: [String]) throws -> RekordboxTrackWriter.Report {
        try RekordboxTrackWriter.delete(contentIDs: ids, from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                        now: now, backups: fixture.backups)
    }

    @Test func 곡을_지우면_딸린_행을_지우고_뒤_순번을_당긴다() throws {
        let (fixture, a, b) = try deleteFixture()
        let report = try delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        for table in ["djmdContent WHERE ID", "djmdCue WHERE ContentID", "contentCue WHERE ContentID", "contentFile WHERE ContentID",
                      "djmdMixerParam WHERE ContentID", "djmdSongPlaylist WHERE ContentID", "djmdSongHistory WHERE ContentID"] {
            #expect(try fixture.rows("SELECT * FROM \(table) = ?", [.text(a.id)]).isEmpty, "\(table)")
        }
        // B는 1번으로 당겨지고 새 변경 번호 하나를 받는다
        for table in ["djmdSongPlaylist", "djmdSongHistory"] {
            let entry = try #require(try fixture.rows("SELECT TrackNo, rb_local_usn, updated_at FROM \(table) WHERE ContentID = ?", [.text(b.id)]).first)
            #expect(entry == ["TrackNo": "1", "rb_local_usn": "2001", "updated_at": stamp], "\(table)")
        }
        #expect(try fixture.localUpdateCount() == 2001)
        // A만 쓰던 아티스트·앨범(과 그 앨범 아티스트)은 지우고, B도 쓰는 아티스트는 남긴다
        #expect(try fixture.rows("SELECT ID FROM djmdArtist ORDER BY ID").map { $0["ID"] } == ["2"])
        #expect(try fixture.rows("SELECT * FROM djmdAlbum").isEmpty)
        // 허용한 파일을 지우고 비어 있는 곡 폴더만 지운다. 지운 파일은 백업에 있다.
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001/artwork.jpg").path))
        #expect(report.removedFiles.count == 3)
    }

    @Test func 지운_곡은_백업으로_되돌리면_행과_파일이_돌아온다() throws {
        let (fixture, a, _) = try deleteFixture()
        let before = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID")
        let report = try delete(fixture, [a.id])
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID") == before)
        #expect(try Data(contentsOf: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.EXT")) == Data("ext".utf8))
        #expect(try Data(contentsOf: fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001/artwork.jpg")) == Data("jpg".utf8))
    }

    @Test func 넣은_곡은_백업으로_되돌리면_행과_만든_분석_파일이_사라진다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let before = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID")
        let p = try await plan("mp3-tagged.mp3")
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        let report = try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                                  dryRun: false, now: now, backups: fixture.backups)
        #expect(report.finalUpdateCount == (try fixture.localUpdateCount()) && report.finalUpdateCount! > 3000, "쓴 직후 변경 카운터")
        let created = report.createdFiles.map { URL(filePath: $0) }
        #expect(created.count == 3 && created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(report.added.first?.uuid.map { created[0].path.contains("/\($0.prefix(3))/\($0.dropFirst(3))/") } == true)
        let saved = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try fixture.rows("SELECT * FROM djmdContent ORDER BY ID") == before)
        #expect(created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "만든 분석 파일을 지운다")
        #expect(!FileManager.default.fileExists(atPath: created[0].deletingLastPathComponent().path), "빈 분석 폴더도 지운다")
        // 되돌리기 직전 상태 백업에 그 파일들이 있어 다시 되돌리면 살아난다
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try fixture.rows("SELECT * FROM djmdContent").count == 2)
    }

    @Test func 곡_추가_삭제_백업도_되돌리기_목록에_곡_이름과_함께_나온다() async throws {
        let (fixture, a, _) = try deleteFixture()
        _ = try delete(fixture, [a.id])
        _ = try RekordboxTrackWriter.add([try await plan("mp3-tagged.mp3")], to: fixture.database, dryRun: false,
                                         now: now.addingTimeInterval(60), backups: fixture.backups)
        let backups = RekordboxWriter.backups(in: fixture.backups)
        #expect(backups.count == 2 && backups.allSatisfy(\.isWrite))
        #expect(backups[0].titles == ["시험 제목"] && backups[1].titles == [a.title])
        #expect(backups.allSatisfy { $0.finalUpdateCount != nil })
    }

    @Test func 확인하지_않은_표에_걸린_곡은_지우지_않는다() throws {
        let (fixture, a, _) = try deleteFixture()
        try fixture.insert("djmdSongMyTag", ["ID": .text("t1"), "MyTagID": .text("m"), "ContentID": .text(a.id), "TrackNo": .int(1),
                                             "UUID": .text("u"), "rb_local_deleted": .int(0)])
        let report = try delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason?.contains("djmdSongMyTag") == true)
        #expect(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(a.id)]).count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.DAT").path))
    }
}
