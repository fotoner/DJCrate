import AudioToolbox
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// rekordbox 7.2.18, 2026-09-27: DJC 실험 ALAC 16/24bit 44100/48000Hz·VBR ffmpeg q2/q8/q5.
/// 실험 음원은 저장소 밖에 두고 합성 파일로 확인한 칸 규칙을 고정한다.
@Suite("ALAC·ffmpeg VBR 분석 골든")
struct AnalysisFormatGoldenTests {
    @Test(arguments: [16, 24], [44_100.0, 48_000.0])
    func ALAC은_코덱으로_형식_6을_고르고_압축_비트레이트를_적는다(bits: Int, rate: Double) async throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.alac(seconds: 2.375, sampleRate: rate, bitDepth: bits, in: fixture.audio)
        let tags = try await AudioTags.read(url: url)
        let plan = try TrackAddPlan.make(url: url, tags: tags)
        let facts = AudioFacts.read(url: url)
        #expect(plan.fileType == 6, "같은 m4a 확장자의 AAC(4)와 구분")
        #expect(facts.unsupported == nil)
        #expect(facts.bitDepth == bits && facts.sampleRate == Int(rate))

        var fileID: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr)
        let file = try #require(fileID)
        defer { AudioFileClose(file) }
        var bytes: UInt64 = 0, packets: UInt64 = 0
        var size: UInt32 = 8
        #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr)
        size = 8
        #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr)
        // 실험 4개: 195046·234701·901640·984708 bps → 195·234·901·984 kbps.
        // 이 afconvert/macOS ALAC 표본은 패딩까지 포함한 4096샘플 패킷의 평균이다.
        let expected = Int(Double(bytes) * 8 * rate / Double(packets * 4096)) / 1000
        #expect(facts.bitRate == expected)
        #expect(TrackAnalysisFiles.pvbr(facts).dropFirst(12).allSatisfy { $0 == 0 })
        #expect(TrackAnalysisFiles.pvb2(facts) == nil)
        #expect(RekordboxTimeline.predictedOffset(url: url) == 0)
        #expect(RekordboxTimeline.predictedTrailingFrames(url: url) == 0)
        let waves = try RekordboxWaveforms.analyze(url: url)
        #expect(waves.columns == 357, "유효 샘플 길이만 사용하며 ALAC 끝 패딩을 붙이지 않는다")
    }

    @Test func AAC의_m4a_형식_4는_유지한다() async throws {
        let fixture = try RekordboxFixture()
        let url = try AudioFixture.aac(seconds: 1, in: fixture.audio)
        #expect(try await TrackAddPlan.make(url: url, tags: AudioTags.read(url: url)).fileType == 4)
    }

    /// 2026-10-03 묶음 1: "DJC VBR 32kHz 128BPM" 160·"DJC VBR 48kHz 128BPM" 256(대조 "DJC VBR 44.1kHz 대조 128BPM" 256)
    @Test(arguments: [(44_100, 256), (44_100, 192), (48_000, 224), (48_000, 256), (32_000, 160)])
    func ffmpeg_Xing은_정보_프레임을_빼고_첫_음성_비트레이트를_쓴다(sample: (Int, Int)) throws {
        let fixture = try RekordboxFixture()
        let url = try mp3(in: fixture.audio, rate: sample.0, firstBitRate: sample.1, encoder: "Lavc62.28")
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil)
        #expect(facts.bitRate == sample.1)
        #expect(facts.bitDepth == 16 && facts.sampleRate == sample.0)
        #expect(facts.pvbrTotalSamples == 40 * 1152, "Xing 프레임은 제외")
        #expect(facts.pvbrEntries.count == 400)
        #expect(facts.pvbrEntries.first == 0)
        let counted = try #require(SeekInfo.mp3Frames(url: url)).offsets.dropFirst()
        let last = Array(counted)[32] - counted.first!
        #expect(facts.pvbrEntries.last == UInt32(last), "마지막 탐색 칸은 끝에서 8프레임 앞")
    }

    @Test func Lavf도_첫_음성_프레임_규칙을_쓴다() throws {
        let fixture = try RekordboxFixture()
        let url = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 160, encoder: "Lavf56.4.")
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil && facts.bitRate == 160 && facts.pvbrEntries.count == 400)
    }

    @Test func L3_99와_알_수_없는_인코더는_계속_막는다() throws {
        let fixture = try RekordboxFixture()
        for encoder in ["L3.99r1", "unknown"] {
            let url = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 32, encoder: encoder)
            #expect(AudioFacts.read(url: url).unsupported != nil)
        }
    }

    @Test func L3_99r1_정보_프레임은_LAME처럼_소리로_센다() throws {
        // #14 곡 F(rekordbox 7.2.18, 2026-10-03): 첫 Xing 프레임의 인코더 칸이 "L3.99r1"인 VBR.
        // 정보 프레임까지 세면 새로 찍은 큐·옛 큐의 InMpegAbs, PVBR 400칸·끝값, PWV3 길이가 모두 맞는다
        // (빼면 큐가 한 프레임 뒤를 가리켜 313바이트 어긋났다).
        let fixture = try RekordboxFixture()
        let url = try mp3(in: fixture.audio, rate: 44_100, firstBitRate: 32, encoder: "L3.99r1")
        let frames = try #require(SeekInfo.mp3Frames(url: url))
        let counted = SeekInfo.countedMp3Offsets(frames, url: url)
        #expect(counted == frames.offsets)
        let cue = try #require(SeekInfo.mp3CuePosition(msec: 557, counted: counted, sampleRate: 44_100, samplesPerFrame: 1152))
        #expect(cue.mpegFrame == 41 && cue.abs == frames.offsets[12] - frames.offsets[0])
        let facts = AudioFacts.read(url: url)
        #expect(facts.pvbrTotalSamples == UInt32(frames.offsets.count * 1152))
        #expect(facts.unsupported != nil, "분석 쓰기는 사본 재현 전까지 막는다")
    }

    @Test(arguments: [false, true])
    func 확인한_형식의_첫_분석은_두_경로_모두_글자형_1_1이다(attach: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        var urls: [URL] = []
        for bits in [16, 24] {
            for rate in [44_100.0, 48_000.0] {
                urls.append(try AudioFixture.alac(seconds: 1, sampleRate: rate, bitDepth: bits,
                    in: fixture.audio, name: "alac-\(bits)-\(Int(rate)).m4a"))
            }
        }
        // 32·48kHz ffmpeg VBR은 2026-10-03 묶음 1의 128 BPM 클릭으로 연다(행·PQTZ 12800, 정밀 박 간격 468.75ms).
        for (rate, bitRate) in [(44_100, 256), (48_000, 256), (32_000, 160)] {
            urls.append(try mp3(in: fixture.audio, rate: rate, firstBitRate: bitRate, encoder: "Lavc62.28", name: "ffmpeg-vbr-\(rate).mp3"))
        }
        for url in urls {
            let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
            let segments = [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]
            let input = RekordboxTrackWriter.Analysis(segments: segments, loudness: -10, peak: 1)
            let added = try RekordboxTrackWriter.add([plan], analyses: attach ? [:] : [plan.path: input],
                to: fixture.database, shareRoot: fixture.shareRoot, dryRun: false, now: .now, backups: fixture.backups)
            #expect(added.added.first?.written == true)
            let uuid = try #require(added.added.first?.uuid)
            if attach {
                let report = try RekordboxWriter.write(drafts: [], grids: [.init(trackUUID: uuid, base: [], segments: segments)], gains: [:],
                    analysisInputs: [uuid: .init(duration: plan.duration, loudness: -10, peak: 1)], to: fixture.database,
                    dryRun: false, now: .now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: true)
                #expect(report.analysisWritten.count == 1 && report.analysisBlocked.isEmpty)
                #expect(report.createdFiles?.count == 3)
            }
            let row = try #require(fixture.rows("SELECT quote(AnalysisUpdated) AS a, quote(TrackInfoUpdated) AS t, Analysed FROM djmdContent WHERE UUID = ?", [.text(uuid)]).first)
            #expect(row["a"] == "'1'" && row["t"] == "'1'" && row["Analysed"] == "105")
            #expect(try fixture.rows("SELECT ID FROM contentFile WHERE ContentID = (SELECT ID FROM djmdContent WHERE UUID = ?)", [.text(uuid)]).count == 3)
        }
    }

    @Test(arguments: [false, true])
    func ffmpeg_MPEG2_샘플레이트는_두_경로를_막는다(attach: Bool) async throws {
        // 실험한 ffmpeg VBR은 MPEG-1(32·44.1·48kHz, 1152샘플 프레임)뿐이다. 576샘플 프레임의 칸 규칙은 확인하지 않았다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())
        let url = try mp3(in: fixture.audio, rate: 24_000, firstBitRate: 64, encoder: "Lavc62.28")
        let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
        let segments = [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]
        let before = try Data(contentsOf: fixture.database)
        if attach {
            let bare = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: .now, backups: fixture.backups)
            let uuid = try #require(bare.added.first?.uuid)
            let report = try RekordboxWriter.write(drafts: [], grids: [.init(trackUUID: uuid, base: [], segments: segments)], gains: [:],
                analysisInputs: [uuid: .init(duration: plan.duration, loudness: -10, peak: 1)], to: fixture.database,
                dryRun: false, now: .now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: true)
            #expect(report.analysisWritten.isEmpty && report.analysisBlocked.first?.reason?.contains("샘플레이트") == true)
            #expect((report.createdFiles ?? []).isEmpty)
            #expect(try fixture.rows("SELECT Analysed FROM djmdContent WHERE UUID = ?", [.text(uuid)]).first?["Analysed"] == "0")
        } else {
            let report = try RekordboxTrackWriter.add([plan], analyses: [plan.path: .init(segments: segments, loudness: -10, peak: 1)],
                to: fixture.database, shareRoot: fixture.shareRoot, dryRun: false, now: .now, backups: fixture.backups)
            #expect(report.added.first?.written == false && report.added.first?.reason?.contains("샘플레이트") == true)
            #expect(try Data(contentsOf: fixture.database) == before)
        }
        #expect(try fixture.rows("SELECT ID FROM contentFile").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdMixerParam").isEmpty)
    }

    /// 정보 프레임·서로 다른 길이의 MPEG 프레임을 칸 단위로 만든다(음원 바이트를 옮기지 않는다).
    /// MPEG-1(32·44.1·48kHz, 1152샘플)과 MPEG-2(16·22.05·24kHz, 576샘플). Xing 머리는 스테레오 사이드 정보 뒤에 둔다.
    private func mp3(in directory: URL, rate: Int, firstBitRate: Int, encoder: String, name: String = "ffmpeg-vbr.mp3") throws -> URL {
        let mpeg1 = [44_100, 48_000, 32_000].contains(rate)
        let bitrates = mpeg1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let rateIndex = (mpeg1 ? [44_100, 48_000, 32_000] : [22_050, 24_000, 16_000]).firstIndex(of: rate)!
        let rates = [64, firstBitRate] + (0..<39).map { $0.isMultiple(of: 2) ? (mpeg1 ? 32 : 8) : (mpeg1 ? 320 : 160) }
        let tag = mpeg1 ? 36 : 21
        var bytes = Data()
        for (index, bitrate) in rates.enumerated() {
            var frame = [UInt8](repeating: 0, count: (mpeg1 ? 144 : 72) * bitrate * 1000 / rate)
            frame[0] = 0xFF; frame[1] = mpeg1 ? 0xFB : 0xF3
            frame[2] = UInt8(bitrates.firstIndex(of: bitrate)! << 4 | rateIndex << 2)
            if index == 0 {
                frame.replaceSubrange(tag..<tag + 4, with: "Xing".utf8)
                frame[tag + 7] = 15
                frame[tag + 11] = 40
                frame.replaceSubrange(tag + 120..<tag + 120 + encoder.utf8.count, with: encoder.utf8)
            }
            bytes.append(contentsOf: frame)
        }
        let total = UInt32(bytes.count)
        for i in 0..<4 { bytes[tag + 12 + i] = UInt8(truncatingIfNeeded: total >> (24 - 8 * i)) }
        let url = directory.appending(path: name)
        try bytes.write(to: url)
        return url
    }
}
