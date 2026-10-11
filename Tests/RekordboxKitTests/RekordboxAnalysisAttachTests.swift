import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 분석 전 곡(분석 파일 없음)에 DJCrate가 분석을 붙이기(#6).
/// 첫 BPM/Grid 분석 카운터는 2026-09-27, rekordbox 7.2.18의 합성 곡 "DJC 실험 카운터 auto/manual-grid"에서 확인했다.
/// 같은 음원·그리드·음량이면 곡 넣기와 분석 붙이기의 분석 칸·파일·오토게인 값이 같다.
/// 기존 곡의 변경 번호 순서(오토게인 → 곡 → .2EX·.DAT·.EXT)는 2026-09-26 #6 실험을 따른다.
@Suite("rekordbox 분석 붙이기")
struct RekordboxAnalysisAttachTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let segments = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    /// 같은 음원 두 벌(파일 이름이 같아야 .DAT의 PPTH가 같다)
    func copies(_ resource: String, in fixture: RekordboxFixture) throws -> (URL, URL) {
        let source = try TestResources.url(resource)
        let urls = ["bare", "reference"].map { fixture.audio.appending(path: $0).appending(path: source.lastPathComponent) }
        for url in urls {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url)
        }
        return (urls[0], urls[1])
    }

    func plan(_ url: URL) async throws -> TrackAddPlan {
        try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url), now: now)
    }

    /// 분석 없이 곡을 넣는다(rekordbox에서 자동 분석을 끄고 넣은 곡과 같은 행). (ContentID, UUID)
    func addBare(_ fixture: RekordboxFixture, _ plan: TrackAddPlan) throws -> (id: String, uuid: String) {
        let report = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let outcome = try #require(report.added.first)
        return (try #require(outcome.contentID), try #require(outcome.uuid))
    }

    func attach(_ fixture: RekordboxFixture, _ grids: [GridDraft], inputs: [String: RekordboxWriter.AnalysisInput],
                drafts: [CueDraft] = [], gains: [String: Double] = [:], dryRun: Bool = false,
                enabled: Bool = true) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: grids, gains: gains, analysisInputs: inputs, to: fixture.database, dryRun: dryRun,
                                  now: now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: enabled)
    }

    /// 칸 이름 → SQL 값(quote: 글자·정수·실수·NULL 형식까지 드러난다)
    func quoted(_ fixture: RekordboxFixture, _ table: String, _ clause: String, _ values: [CipherDatabase.Value]) throws -> [[String: String]] {
        let columns = try fixture.rows("SELECT name FROM pragma_table_info('\(table)')").compactMap { $0["name"] }
        return try fixture.rows("SELECT \(columns.map { "quote(\"\($0)\") AS \"\($0)\"" }.joined(separator: ", ")) FROM \(table) WHERE \(clause)", values)
    }

    func folder(_ uuid: String) -> String { "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))" }

    func analysisFile(_ fixture: RekordboxFixture, _ uuid: String, _ ext: String) -> URL {
        fixture.shareRoot.appending(path: String(folder(uuid).dropFirst()) + "/ANLZ0000.\(ext)")
    }

    // MARK: 골든

    @Test func 분석_전_곡에_붙인_분석은_곡_넣기_결과와_칸_단위로_같다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 5000)
        try fixture.add(TrackSpec())   // 라이브러리 공통값
        let (bareURL, referenceURL) = try copies("mp3-tagged.mp3", in: fixture)
        let bare = try await plan(bareURL), reference = try await plan(referenceURL)
        // 기준: 같은 음원을 분석까지 붙여 넣은 곡
        let added = try RekordboxTrackWriter.add([reference], analyses: [reference.path: .init(segments: segments, loudness: -8, peak: 0.9)],
                                                 to: fixture.database, shareRoot: fixture.shareRoot, dryRun: false, now: now,
                                                 backups: fixture.backups)
        let refID = try #require(added.added.first?.contentID), refUUID = try #require(added.added.first?.uuid)
        // 대상: 분석 없이 넣은 곡에 붙인다
        let (id, uuid) = try addBare(fixture, bare)
        let before = try fixture.localUpdateCount()
        let report = try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                                inputs: [uuid: .init(duration: bare.duration, loudness: -8, peak: 0.9)])
        #expect(report.analysisWritten.map(\.trackUUID) == [uuid] && report.analysisBlocked.isEmpty && report.gridOutcomes == nil)

        // 곡 행: 신원·경로·파일 inode·분석 경로(곡 UUID 폴더)·변경 번호 말고는 칸 값과 형식이 같다
        let identity: Set = ["ID", "UUID", "FolderPath", "MasterSongID", "rb_file_id", "AnalysisDataPath", "rb_local_usn"]
        let row = try #require(try quoted(fixture, "djmdContent", "ID = ?", [.text(id)]).first)
        let refRow = try #require(try quoted(fixture, "djmdContent", "ID = ?", [.text(refID)]).first)
        for (column, value) in refRow where !identity.contains(column) { #expect(row[column] == value, "djmdContent.\(column)") }
        #expect(row["AnalysisDataPath"] == "'\(folder(uuid))/ANLZ0000.DAT'" && row["Analysed"] == "105" && row["BPM"] == "12000")
        // 첫 BPM/Grid 분석은 두 경로 모두 글자형 1·1이다(2026-09-27 #95).
        #expect(row["AnalysisUpdated"] == "'1'" && row["TrackInfoUpdated"] == "'1'" && refRow["AnalysisUpdated"] == "'1'")

        // 파일 행(.2EX·.DAT·.EXT): 곡 UUID가 든 칸 말고는 같다(해시·크기 = 같은 바이트)
        let fileIdentity: Set = ["ID", "ContentID", "Path", "rb_local_path", "UUID", "rb_local_usn"]
        let files = try quoted(fixture, "contentFile", "ContentID = ? ORDER BY Path", [.text(id)])
        let refFiles = try quoted(fixture, "contentFile", "ContentID = ? ORDER BY Path", [.text(refID)])
        #expect(files.count == 3 && refFiles.count == 3)
        for (file, refFile) in zip(files, refFiles) {
            for (column, value) in refFile where !fileIdentity.contains(column) { #expect(file[column] == value, "contentFile.\(column)") }
        }
        #expect(files.map { $0["Path"] } == ["2EX", "DAT", "EXT"].map { "'\(folder(uuid))/ANLZ0000.\($0)'" })
        #expect(files[1]["ID"] == "'\(uuid)_\(folder(uuid).replacingOccurrences(of: "/", with: "%2F"))%2FANLZ0000.DAT'")

        // 오토게인 행
        let mixer = try quoted(fixture, "djmdMixerParam", "ContentID = ?", [.text(id)])
        let refMixer = try quoted(fixture, "djmdMixerParam", "ContentID = ?", [.text(refID)])
        #expect(mixer.count == 1 && refMixer.count == 1)
        for (column, value) in refMixer.first ?? [:] where !["ID", "ContentID", "UUID", "rb_local_usn"].contains(column) {
            #expect(mixer.first?[column] == value, "djmdMixerParam.\(column)")
        }

        // 분석 파일은 바이트까지 같다
        for ext in ["DAT", "EXT", "2EX"] {
            #expect(try Data(contentsOf: analysisFile(fixture, uuid, ext)) == Data(contentsOf: analysisFile(fixture, refUUID, ext)), "\(ext)")
        }
        #expect(Set(report.createdFiles ?? []) == Set(["DAT", "EXT", "2EX"].map { analysisFile(fixture, uuid, $0).path }))
        let backupPath = try #require(report.backup)
        let backupReport = try #require(RekordboxWriter.contents(of: URL(filePath: backupPath)).report)
        #expect(backupReport.createdFiles?.count == 3)
        #expect(backupReport.createdFiles?.allSatisfy { $0.hasPrefix("PIONEER/USBANLZ/") } == true)

        // 변경 번호: rekordbox가 분석 전 곡을 분석한 순서(오토게인 행 → 곡 행 → 파일 행 .2EX·.DAT·.EXT), 카운터는 마지막 번호
        let mixerUSN = try fixture.rows("SELECT rb_local_usn FROM djmdMixerParam WHERE ContentID = ?", [.text(id)])
        let contentUSN = try fixture.rows("SELECT rb_local_usn FROM djmdContent WHERE ID = ?", [.text(id)])
        let fileUSNs = try fixture.rows("SELECT rb_local_usn FROM contentFile WHERE ContentID = ? ORDER BY Path", [.text(id)])   // 2EX·DAT·EXT
        let usns = (mixerUSN + contentUSN + fileUSNs).compactMap { $0["rb_local_usn"].flatMap { Int($0) } }
        #expect(usns == Array(before + 1...before + 5), "\(usns)")
        let final = try fixture.localUpdateCount()
        #expect(report.finalUpdateCount == before + 5 && final == before + 5)
    }

    @Test func XML로_들어와_동기화된_곡도_붙이고_상태는_257() async throws {
        // XML로 들어온 곡(Analysed 41, BPM·비트레이트는 XML 값, 분석 경로 없음), 클라우드 동기화 상태 256
        let fixture = try RekordboxFixture(localUpdateCount: 700)
        var track = TrackSpec()
        track.fileType = 11
        track.analysed = 41
        track.bitRate = 1411
        track.bpm100 = 12400
        track.length = 20
        track.cueUpdated = nil
        track.folderPath = try AudioFixture.wav(seconds: 20.6, in: fixture.audio).path
        try fixture.add(track)
        try fixture.execute("UPDATE djmdContent SET AnalysisUpdated = NULL, TrackInfoUpdated = NULL WHERE ID = ?", [.text(track.id)])
        let report = try attach(fixture, [GridDraft(trackUUID: track.uuid, base: [], segments: segments)],
                                inputs: [track.uuid: .init(duration: 20.6, loudness: nil, peak: 1)])
        #expect(report.analysisWritten.count == 1)
        let row = try #require(try quoted(fixture, "djmdContent", "ID = ?", [.text(track.id)]).first)
        #expect(row["rb_data_status"] == "257" && row["rb_local_usn"] == "702" && row["updated_at"] == "'2026-09-25 12:00:00.000 +00:00'")
        #expect(row["Analysed"] == "105" && row["BPM"] == "12000" && row["Length"] == "20" && row["BitRate"] == "1411"
                && row["BitDepth"] == "16" && row["SampleRate"] == "44100" && row["ContentLink"] == "2885134")
        #expect(row["AnalysisUpdated"] == "'1'" && row["TrackInfoUpdated"] == "'1'" && row["KeyID"] == "NULL", "키는 쓰지 않는다(실험에서도 KeyID 그대로)")
        // 오토게인: 음량을 모르면 0dB
        let mixer = try #require(try fixture.rows("SELECT GainHigh, GainLow, rb_local_usn FROM djmdMixerParam WHERE ContentID = ?", [.text(track.id)]).first)
        #expect(RekordboxAutoGain.float(high: Int(mixer["GainHigh"]!)!, low: Int(mixer["GainLow"]!)!) == 1 && mixer["rb_local_usn"] == "701")
        let files = try fixture.rows("SELECT rb_local_usn FROM contentFile WHERE ContentID = ? ORDER BY Path", [.text(track.id)])
        #expect(files.map { $0["rb_local_usn"] } == ["703", "704", "705"])
        #expect(try fixture.localUpdateCount() == 705)
    }

    // MARK: 막힘

    @Test func 닫아_두면_쓰지_않고_이유를_알린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let wav = try AudioFixture.wav(seconds: 20, in: fixture.audio)
        let p = try await plan(wav)
        let (id, uuid) = try addBare(fixture, p)
        let before = try quoted(fixture, "djmdContent", "ID = ?", [.text(id)])
        let count = try fixture.localUpdateCount()
        let report = try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                                inputs: [uuid: .init(duration: p.duration, loudness: -9, peak: 1)], enabled: false)
        #expect(report.analysisWritten.isEmpty && report.analysisBlocked.first?.reason?.contains("rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요") == true)
        #expect(try quoted(fixture, "djmdContent", "ID = ?", [.text(id)]) == before && fixture.localUpdateCount() == count)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER").path))
        #expect(RekordboxWriter.attachesAnalysis, "2026-09-26 실험으로 칸을 확인해 앱에서도 연다")
    }

    @Test(arguments: ["AnalysisUpdated", "TrackInfoUpdated"])
    func 분석_카운터가_있는_분석_전_곡은_막는다(column: String) async throws {
        // 어느 카운터든 이미 있으면 이번 첫 분석 규칙을 적용하지 않는다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (id, uuid) = try addBare(fixture, p)
        try fixture.execute("UPDATE djmdContent SET \(column) = '3' WHERE ID = ?", [.text(id)])
        let report = try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                                inputs: [uuid: .init(duration: p.duration, loudness: nil, peak: 1)])
        #expect(report.analysisWritten.isEmpty && report.analysisBlocked.first?.reason?.contains("rekordbox에서 트랙 분석을 하세요") == true,
                "\(report.analysisBlocked)")
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && fixture.rows("SELECT * FROM djmdMixerParam").isEmpty)
    }

    @Test func 반쪽_분석_곡은_막는다() throws {
        // rekordbox 분석이 실패한 곡: .DAT(0박·파형 0)만 있고 .EXT·.2EX가 없다(라이브러리에서 본 모양)
        let fixture = try RekordboxFixture()
        var track = TrackSpec()
        track.fileType = 11
        track.bpm100 = 0
        track.folderPath = try AudioFixture.wav(seconds: 20, in: fixture.audio).path
        track.analysisDataPath = "/PIONEER/USBANLZ/abc/d0000-1111-2222-3333-444455556666/ANLZ0000.DAT"
        try fixture.add(track)
        let dat = AnlzBuilder.dat(beats: [])
        try fixture.putAnalysis(for: track, dat: dat, ext: nil)
        let report = try attach(fixture, [GridDraft(trackUUID: track.uuid, base: [], segments: segments)],
                                inputs: [track.uuid: .init(duration: 20, loudness: nil, peak: 1)])
        #expect(report.analysisWritten.isEmpty && report.gridWritten.isEmpty)
        #expect(report.gridBlocked.first?.reason?.contains("rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요") == true)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat)
        #expect(!FileManager.default.fileExists(atPath: fixture.analysisURL(for: track, ext: "EXT").path))
    }

    @Test func 분석을_붙일_수_없는_곡은_이유와_함께_막는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        func bare(_ url: URL) async throws -> (id: String, uuid: String, duration: Double) {
            let p = try await plan(url)
            let (id, uuid) = try addBare(fixture, p)
            return (id, uuid, p.duration)
        }
        let alac = try await bare(try AudioFixture.alac(seconds: 2, sampleRate: 96_000, in: fixture.audio))
        let mixer = try await bare(try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "mixer.wav"))
        try fixture.insert("djmdMixerParam", ["ID": .text("m1"), "ContentID": .text(mixer.id), "GainHigh": .int(16256), "GainLow": .int(0),
                                              "UUID": .text("u"), "rb_local_deleted": .int(0)])
        let unmeasured = try await bare(try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "unmeasured.wav"))
        let based = try await bare(try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "based.wav"))
        let gone = try await bare(try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "gone.wav"))
        try FileManager.default.removeItem(at: fixture.audio.appending(path: "gone.wav"))
        let grids = [alac, mixer, unmeasured, gone].map { GridDraft(trackUUID: $0.uuid, base: [], segments: segments) }
            + [GridDraft(trackUUID: based.uuid, base: [GridSegment(start: 0.2, bpm: 128, firstBeatNumber: 1)], segments: segments)]
        var inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for track in [alac, mixer, based, gone] { inputs[track.uuid] = .init(duration: track.duration, loudness: nil, peak: 1) }
        let report = try attach(fixture, grids, inputs: inputs)
        let reasons = Dictionary(uniqueKeysWithValues: report.analysisBlocked.map { ($0.trackUUID, $0.reason ?? "") })
        #expect(report.analysisWritten.isEmpty && reasons.count == 5)
        #expect(reasons[alac.uuid]?.contains("ALAC") == true, "\(reasons[alac.uuid] ?? "")")
        #expect(reasons[mixer.uuid]?.contains("오토게인") == true, "\(reasons[mixer.uuid] ?? "")")
        #expect(reasons[unmeasured.uuid]?.contains("길이") == true, "\(reasons[unmeasured.uuid] ?? "")")
        #expect(reasons[based.uuid]?.contains("초안을 만든 뒤") == true, "\(reasons[based.uuid] ?? "")")
        #expect(reasons[gone.uuid]?.contains("음원 파일") == true, "\(reasons[gone.uuid] ?? "")")
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER").path))
    }

    // MARK: 함께 쓰기·시험 실행·되돌리기

    @Test func 큐_초안과_게인_초안은_분석을_붙인_뒤에_쓴다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        try fixture.add(TrackSpec())
        let p = try await plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (id, uuid) = try addBare(fixture, p)
        var cues = CueDraft(trackUUID: uuid)
        cues.place(EditableCue(kind: .memory, time: 1.373))
        cues.place(EditableCue(kind: .hot(0), time: 10.973))
        let report = try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                                inputs: [uuid: .init(duration: p.duration, loudness: -10, peak: 1)], drafts: [cues], gains: [uuid: 1.5])
        #expect(report.analysisWritten.count == 1 && report.written.count == 1 && report.gainWritten.count == 1, "\(report.gainBlocked)")
        let content = try #require(try fixture.rows("SELECT CueUpdated, rb_local_usn, Analysed FROM djmdContent WHERE ID = ?", [.text(id)]).first)
        let mixer = try #require(try fixture.rows("SELECT GainHigh, GainLow, rb_local_usn FROM djmdMixerParam WHERE ContentID = ?", [.text(id)]).first)
        let final = try fixture.localUpdateCount()
        #expect(content["Analysed"] == "105" && content["CueUpdated"] == "2")
        #expect(mixer["rb_local_usn"] == "\(final)" && Int(content["rb_local_usn"] ?? "") ?? 0 < final, "게인은 마지막에 새 오토게인 행에")
        let gain = RekordboxAutoGain.float(high: Int(mixer["GainHigh"]!)!, low: Int(mixer["GainLow"]!)!)
        #expect(abs(20 * log10(Double(gain)) - 1.5) < 1e-3)
        #expect(try fixture.rows("SELECT * FROM djmdCue WHERE ContentID = ?", [.text(id)]).count == 2)
    }

    @Test func 시험_실행은_아무것도_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (id, uuid) = try addBare(fixture, p)
        let before = try quoted(fixture, "djmdContent", "ID = ?", [.text(id)])
        let report = try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                                inputs: [uuid: .init(duration: p.duration, loudness: nil, peak: 1)], dryRun: true)
        #expect(report.analysisWritten.count == 1 && report.backup == nil && (report.createdFiles ?? []).isEmpty)
        #expect(try quoted(fixture, "djmdContent", "ID = ?", [.text(id)]) == before)
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && fixture.rows("SELECT * FROM djmdMixerParam").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: analysisFile(fixture, uuid, "DAT").path))
    }

    @Test func 되돌리면_분석_칸과_행과_만든_파일이_사라진다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (id, uuid) = try addBare(fixture, p)
        let before = try quoted(fixture, "djmdContent", "ID = ?", [.text(id)])
        let grid = GridDraft(trackUUID: uuid, base: [], segments: segments)
        let report = try attach(fixture, [grid], inputs: [uuid: .init(duration: p.duration, loudness: -9, peak: 1)])
        let created = (report.createdFiles ?? []).map { URL(filePath: $0) }
        #expect(created.count == 3 && created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let backup = URL(filePath: try #require(report.backup))
        #expect(RekordboxWriter.gridDrafts(in: backup).map(\.trackUUID) == [uuid], "되돌리면 그리드 초안을 다시 살린다")
        #expect(RekordboxWriter.backups(in: fixture.backups).first?.titles.isEmpty == false)

        let saved = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try quoted(fixture, "djmdContent", "ID = ?", [.text(id)]) == before)
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && fixture.rows("SELECT * FROM djmdMixerParam").isEmpty)
        #expect(created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "만든 분석 파일을 지운다")
        #expect(!FileManager.default.fileExists(atPath: created[0].deletingLastPathComponent().path), "빈 분석 폴더도 지운다")
        // 되돌리기 직전 백업으로 다시 되돌리면 파일도 돌아온다
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(created.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func 분석_파일을_쓰지_못하면_DB도_되돌린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let p = try await plan(try AudioFixture.wav(seconds: 20, in: fixture.audio))
        let (id, uuid) = try addBare(fixture, p)
        let before = try quoted(fixture, "djmdContent", "ID = ?", [.text(id)])
        let count = try fixture.localUpdateCount()
        // 분석 폴더를 만들 수 없게 한다(DB는 이미 커밋한 뒤 실패)
        let usbanlz = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        try FileManager.default.createDirectory(at: usbanlz, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: usbanlz.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usbanlz.path) }
        let error = try #require(throws: DJCError.self) {
            try attach(fixture, [GridDraft(trackUUID: uuid, base: [], segments: segments)],
                       inputs: [uuid: .init(duration: p.duration, loudness: nil, peak: 1)])
        }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try quoted(fixture, "djmdContent", "ID = ?", [.text(id)]) == before && fixture.localUpdateCount() == count)
        #expect(try fixture.rows("SELECT * FROM contentFile").isEmpty && fixture.rows("SELECT * FROM djmdMixerParam").isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(atPath: usbanlz.path)).isEmpty)
    }
}
