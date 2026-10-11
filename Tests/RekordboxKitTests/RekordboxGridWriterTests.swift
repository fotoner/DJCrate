import DJCDomain
import DJCTestKit
import CryptoKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 그리드 쓰기(ANLZ). じもとっこスイーツ♪ 이동·つよがるガール 244→245 BPM 실험에서 확인한 모양을 고정한다.
@Suite("rekordbox 그리드 쓰기")
struct RekordboxGridWriterTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let analysisPath = "/PIONEER/USBANLZ/a1b/2c3d4-0000-1111-2222-333344445555/ANLZ0000.DAT"

    /// 128 BPM, 첫 박 500.3ms(소수는 PQT2에), 60초짜리 WAV
    func makeTrack(_ fixture: RekordboxFixture, withEXT: Bool = true, emptyPQT2: Bool = false,
                   beats: [BeatGridTags.Beat]? = nil) throws -> (TrackSpec, [BeatGridTags.Beat]) {
        var track = TrackSpec(uuid: "a1b2c3d4-0000-1111-2222-333344445555")
        track.fileType = 11
        track.bpm100 = 12800
        track.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path
        track.analysisDataPath = analysisPath
        try fixture.add(track)
        let beats = beats ?? AnlzBuilder.beats(bpm: 128, first: 500.3, count: 126)
        let dat = AnlzBuilder.dat(beats: beats)
        let ext: Data? = withEXT ? (emptyPQT2 ? AnlzBuilder.file([BeatGridTags.pqt2([], unknown: 0)]) : AnlzBuilder.ext(beats: beats)) : nil
        try fixture.putAnalysis(for: track, dat: dat, ext: ext)
        try fixture.addContentFile(for: track, hash: md5(dat), size: dat.count)
        return (track, beats)
    }

    func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func draft(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> GridDraft {
        GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
    }

    func write(_ fixture: RekordboxFixture, _ grid: GridDraft) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, now: now,
                                  backups: fixture.backups, shareRoot: fixture.shareRoot)
    }

    /// #159: 편집기(PQTZ 정수 ms)와 writer(PQT2 정밀 시각)의 BPM 역산 차이를 실제 변경으로 보지 않는다.
    @Test func 짧고_빠른_구간은_정밀_소수가_있어도_그리드_충돌이_아니다() throws {
        let fixture = try RekordboxFixture()
        let first = AnlzBuilder.beats(bpm: 244, first: 500.3, count: 9)
        let second = AnlzBuilder.beats(bpm: 128, first: first.last!.time + 60_000 / 244, count: 100)
        let (track, _) = try makeTrack(fixture, beats: first + second)
        var grid = try draft(fixture, track)
        #expect(grid.base.count == 2)
        #expect(abs(grid.base[0].bpm - 244) > 0.01)
        grid.shift(by: 0.01)
        let report = try write(fixture, grid)
        #expect(report.gridWritten.count == 1 && report.gridBlocked.isEmpty)
    }

    @Test func 실제_그리드_변경은_정밀_소수와_관계없이_계속_막는다() throws {
        let fixture = try RekordboxFixture()
        let (track, beats) = try makeTrack(fixture)
        var grid = try draft(fixture, track)
        grid.shift(by: 0.01)
        var changed = beats
        for index in changed.indices { changed[index].time += 20 }
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: changed), ext: AnlzBuilder.ext(beats: changed))
        let before = try Data(contentsOf: fixture.analysisURL(for: track))
        let report = try write(fixture, grid)
        #expect(report.gridWritten.isEmpty && report.gridBlocked.first?.reason?.contains("그리드가 바뀌었습니다") == true)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == before)
    }

    @Test func 이동만_하면_PQTZ만_바뀌고_PQT2는_비고_DB는_그대로() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 700)
        let (track, _) = try makeTrack(fixture)
        let originalDat = try AnlzFile(url: fixture.analysisURL(for: track))
        let originalExt = try AnlzFile(url: fixture.analysisURL(for: track, ext: "EXT"))
        let dbBefore = try fixture.rows("SELECT * FROM contentFile") + fixture.rows("SELECT * FROM djmdContent")
        var grid = try draft(fixture, track)
        grid.shift(by: 0.010)

        let report = try write(fixture, grid)
        #expect(report.gridWritten.count == 1)

        let dat = try AnlzFile(url: fixture.analysisURL(for: track))
        #expect(dat.tags.map(\.fourcc) == originalDat.tags.map(\.fourcc))
        for (a, b) in zip(originalDat.tags, dat.tags) where a.fourcc != "PQTZ" { #expect(a.bytes == b.bytes, "\(a.fourcc)") }
        let beats = BeatGridTags.decode(pqtz: try #require(dat.tag("PQTZ")).bytes, pqt2: nil).beats
        // 원래 정밀 첫 박 500.2998(PQT2 소수 307/1024) + 10ms = 510.2998 → 510ms, 다음 박 979ms(내림).
        // 그리드는 곡 앞쪽으로도 늘인다: 510.2998 − 468.75 = 41.5498 → 41ms
        #expect(beats.prefix(3).map(\.time) == [41, 510, 979])
        #expect(beats.allSatisfy { $0.bpm100 == 12800 })

        let ext = try AnlzFile(url: fixture.analysisURL(for: track, ext: "EXT"))
        for (a, b) in zip(originalExt.tags, ext.tags) where a.fourcc != "PQT2" { #expect(a.bytes == b.bytes, "\(a.fourcc)") }
        let pqt2 = [UInt8](try #require(ext.tag("PQT2")).bytes)
        #expect(pqt2.count == 56 && pqt2[24...].allSatisfy { $0 == 0 }, "rekordbox가 손으로 고친 그리드처럼 빈 PQT2")

        #expect(try fixture.rows("SELECT * FROM contentFile") + fixture.rows("SELECT * FROM djmdContent") == dbBefore)
        #expect(try fixture.localUpdateCount() == 700)
    }

    @Test func BPM을_바꾸면_DAT_해시와_곡_BPM을_고친다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (track, _) = try makeTrack(fixture)
        var grid = try draft(fixture, track)
        grid.setBPM(130, at: 0)
        #expect(try write(fixture, grid).gridWritten.count == 1)

        let newDat = try Data(contentsOf: fixture.analysisURL(for: track))
        let file = try #require(fixture.rows("SELECT * FROM contentFile").first)
        #expect(file["Hash"] == md5(newDat) && file["Size"] == String(newDat.count))
        #expect(file["rb_data_status"] == "257" && file["rb_local_usn"] != "13")
        let content = try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(track.id)]).first)
        #expect(content["BPM"] == "13000" && content["AnalysisUpdated"] == "2" && content["TrackInfoUpdated"] == "2")
        #expect(content["rb_data_status"] == "257")
        let beats = BeatGridTags.decode(pqtz: try #require(AnlzFile(data: newDat).tag("PQTZ")).bytes, pqt2: nil).beats
        #expect(beats.allSatisfy { $0.bpm100 == 13000 })
    }

    @Test func 소수가_없으면_첫_박을_ms_한가운데로_보고_계산한다() throws {
        // つよがるガール 실험: PQT2가 비어 있으면 rekordbox는 첫 박을 ms + 0.5로 본다
        let fixture = try RekordboxFixture()
        let (track, _) = try makeTrack(fixture, emptyPQT2: true)
        let grid = try draft(fixture, track)
        let plan = try RekordboxGridWriter.plan(draft: { var g = grid; g.setBPM(130, at: 0); return g }(), title: track.title,
                                                analysisDataPath: track.analysisDataPath, rekordboxBPM100: track.bpm100,
                                                audioPath: track.folderPath, shareRoot: fixture.shareRoot)
        // 첫 박 PQTZ 500ms → 500.5 기준, 130 BPM 박 간격 461.538…ms(앞쪽으로 늘인 박 하나가 먼저 온다)
        let anchor = try #require(plan.beats.firstIndex { abs($0.time - 500.5) < 1e-6 })
        #expect(anchor == 1 && abs(plan.beats[2].time - (500.5 + 60_000.0 / 130)) < 1e-6)
    }

    @Test func 파형_파일이_없는_곡은_막는다() throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try makeTrack(fixture, withEXT: false)
        var grid = try draft(fixture, track)
        grid.shift(by: 0.01)
        let report = try write(fixture, grid)
        #expect(report.gridBlocked.first?.reason?.contains("파형") == true)
    }

    @Test func 템포_구간이_여러_개여도_BPM을_쓸_수_있다() throws {
        let fixture = try RekordboxFixture()
        let first = AnlzBuilder.beats(bpm: 128, first: 500, count: 60)
        let second = AnlzBuilder.beats(bpm: 140, first: first.last!.time + 60_000 / 128, count: 50)
        let (track, _) = try makeTrack(fixture, beats: first + second)
        var grid = try draft(fixture, track)
        #expect(grid.segments.count == 2)
        grid.setBPM(129, at: 1)
        #expect(try write(fixture, grid).gridWritten.count == 1)
    }

    @Test func 되돌리면_분석_파일이_원래_바이트로() throws {
        let fixture = try RekordboxFixture()
        let (track, _) = try makeTrack(fixture)
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        let ext = try Data(contentsOf: fixture.analysisURL(for: track, ext: "EXT"))
        var grid = try draft(fixture, track)
        grid.setBPM(131, at: 0)
        let report = try write(fixture, grid)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) != dat)
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track, ext: "EXT")) == ext)
    }
}

@Suite("ANLZ 태그")
struct AnlzTagTests {
    @Test func PQTZ와_PQT2로_정밀_시각을_되살린다() {
        let beats = AnlzBuilder.beats(bpm: 150, first: 256.7, count: 20)
        let decoded = BeatGridTags.decode(pqtz: BeatGridTags.pqtz(beats), pqt2: BeatGridTags.pqt2(beats, unknown: 7))
        #expect(decoded.unknown == 7 && decoded.beats.count == 20)
        for (a, b) in zip(beats, decoded.beats) {
            #expect(a.number == b.number && a.bpm100 == b.bpm100)
            #expect(abs(a.time - b.time) < 1.0 / 1024 + 1e-9)
        }
    }

    @Test func 시각은_내림하고_곡_앞_1ms_안은_0() {
        #expect(BeatGridTags.Beat(number: 1, bpm100: 12000, time: 999.9999999).wholeMs == 1000)
        #expect(BeatGridTags.Beat(number: 1, bpm100: 12000, time: 1000.9).wholeMs == 1000)
        // 구간 시작 499.5ms → 곡 앞 −0.5ms 박도 0으로 적는다
        let beats = RekordboxGridWriter.beats(segments: [GridSegment(start: 0.4995, bpm: 120, firstBeatNumber: 2)], duration: 2)
        #expect(beats.first?.time == 0 && beats.first?.number == 1)
        #expect(beats.map(\.wholeMs).prefix(3) == [0, 499, 999])
    }

    @Test func 태그를_바꿔도_나머지는_바이트_그대로() throws {
        let beats = AnlzBuilder.beats(bpm: 128, first: 500, count: 10)
        let original = AnlzBuilder.dat(beats: beats)
        var file = try AnlzFile(data: original)
        #expect(file.serialized() == original)
        file.replace("PQTZ", with: BeatGridTags.pqtz(Array(beats.prefix(3))))
        let changed = try AnlzFile(data: file.serialized())
        #expect(changed.tags.map(\.fourcc) == ["PPTH", "PVBR", "PQTZ", "PWAV"])
        let originalFile = try AnlzFile(data: original)
        #expect(changed.tag("PPTH") == originalFile.tag("PPTH") && changed.tag("PWAV") == originalFile.tag("PWAV"))
    }
}

@Suite("탐색 위치·시간축")
struct SeekAndTimelineTests {
    @Test func FLAC_큐는_그_샘플이_든_프레임을_가리킨다() {
        let frames = [SeekInfo.FlacFrame(startSample: 0, offset: 0, blockSize: 4096),
                      SeekInfo.FlacFrame(startSample: 4096, offset: 3000, blockSize: 4096),
                      SeekInfo.FlacFrame(startSample: 8192, offset: 6100, blockSize: 4096)]
        #expect(SeekInfo.flacSeekInfo(frames: frames, sample: 5000) == "4096,3000,4096")
        #expect(SeekInfo.flacSeekInfo(frames: frames, sample: 8192) == "8192,6100,4096")
        #expect(SeekInfo.flacSeekInfo(frames: frames, sample: 20_000) == nil)
    }

    @Test func 만든_FLAC의_프레임_표() throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.flac(seconds: 3, in: fixture.audio)
        let table = try #require(SeekInfo.flacFrames(url: url))
        #expect(table.sampleRate == 44_100)
        // offset은 파일 안 절대 위치다. 탐색 문자열은 첫 오디오 프레임 위치를 뺀 값을 쓴다.
        #expect(table.frames.first?.startSample == 0)
        let second = table.frames[1]
        #expect(SeekInfo.flacSeekInfo(frames: table.frames, sample: second.startSample + 10)
                == "\(second.startSample),\(second.offset - table.frames[0].offset),\(second.blockSize)")
        let total = table.frames.reduce(0) { $0 + $1.blockSize }
        #expect(total >= 3 * 44_100 && total < 3 * 44_100 + 8192)
        for (a, b) in zip(table.frames, table.frames.dropFirst()) {
            #expect(b.startSample == a.startSample + a.blockSize && b.offset > a.offset)
        }
    }

    @Test func 무손실은_지연_0_AAC는_프라이밍만큼() throws {
        let fixture = try RekordboxFixture()
        #expect(RekordboxTimeline.predictedOffset(url: try AudioFixture.wav(seconds: 1, in: fixture.audio)) == 0)
        let aac = RekordboxTimeline.predictedOffset(url: try AudioFixture.aac(seconds: 2, in: fixture.audio))
        #expect(abs(aac - 2112.0 / 44_100) < 1e-6, "macOS AAC 인코더 프라이밍 2112샘플")
    }
}
