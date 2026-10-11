import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 합성 MP3(1초, 44.1kHz, lame 3.100·ffmpeg)로 rekordbox 시간축 보정과 MP3 프레임 읽기를 고정한다.
/// 규칙(150곡 실측, 2026-09-25): LAME 정보 태그 = 프라이밍 + 529 + 1152, ffmpeg 태그 = 프라이밍 + 529, 태그 없음 = 529.
@Suite("MP3 시간축·프레임")
struct Mp3TimelineTests {
    @Test func LAME_태그는_정보_프레임까지_센다() throws {
        let offset = RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-lame-cbr.mp3"))
        #expect(abs(offset - Double(576 + 529 + 1152) / 44_100) < 1e-9, "\(offset * 1000)ms, 실측 규칙 51.2ms")
    }

    @Test func ffmpeg_태그는_정보_프레임을_세지_않는다() throws {
        let offset = RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-ffmpeg-cbr.mp3"))
        let priming = try #require(RekordboxTimeline.packetInfo(url: try TestResources.url("mp3-ffmpeg-cbr.mp3"))?.primingFrames)
        #expect(abs(offset - Double(priming + 529) / 44_100) < 1e-9)
        #expect(offset > 0.015 && offset < 0.027, "실측 +16~26ms")
    }

    @Test func 태그_없는_MP3는_디코더_지연만() throws {
        #expect(abs(RekordboxTimeline.predictedOffset(url: try TestResources.url("mp3-notag-cbr.mp3")) - 529.0 / 44_100) < 1e-9)
    }

    @Test func VBR_MP3는_Xing_TOC를_읽는다() throws {
        let vbr = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-lame-vbr.mp3")))
        #expect(vbr.sampleRate == 44_100 && vbr.samplesPerFrame == 1152)
        #expect(vbr.hasInfoFrame && vbr.toc?.count == 100)
        // offsets 첫 칸은 정보(Xing) 프레임 자신이다. Xing이 적은 오디오 프레임 수 = 나머지
        #expect(vbr.xingFrames == vbr.offsets.count - 1)
        #expect(vbr.headerTag == "Xing" && vbr.isVariableBitRate)
        let cbr = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-lame-cbr.mp3")))
        #expect(cbr.hasInfoFrame && cbr.offsets.count > 30)
        #expect(cbr.headerTag == "Info" && !cbr.isVariableBitRate)
        let notag = try #require(SeekInfo.mp3Frames(url: try TestResources.url("mp3-notag-cbr.mp3")))
        #expect(notag.headerTag == nil && !notag.isVariableBitRate, "머리가 없는 CBR은 프레임 길이가 일정하다")
        // CBR은 프레임 간격이 일정하다(128kbps: 417 또는 418바이트)
        let gaps = Set(zip(cbr.offsets.dropFirst(), cbr.offsets).map { $0 - $1 })
        #expect(gaps.isSubset(of: [417, 418]))
    }
}

/// 곡을 분석까지 붙여 넣을 때의 MP3 음원 정보(PVBR). 규칙은 라이브러리 VBR 451곡·CBR 2291곡으로 확인(2026-09-26).
@Suite("MP3 분석 음원 정보")
struct Mp3AudioFactsTests {
    @Test func 끝이_잘린_CBR_프레임은_PVBR_샘플에_세지_않는다() throws {
        // #14 곡 A(2026-09-26): 끝 프레임의 헤더만 남으면 rekordbox는 완전한 프레임까지만 센다.
        let folder = try TemporaryFolder()
        let source = try TestResources.url("mp3-lame-cbr.mp3")
        let original = try #require(SeekInfo.mp3Frames(url: source))
        let last = try #require(original.offsets.last)
        let url = folder.url.appending(path: "truncated.mp3")
        try Data(contentsOf: source).prefix(last + 4).write(to: url)
        let frames = try #require(SeekInfo.mp3Frames(url: url))
        #expect(frames.offsets == Array(original.offsets.dropLast()))
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil)
        let expected = UInt32((original.offsets.count - 1) * original.samplesPerFrame)
        #expect(facts.pvbrTotalSamples == expected)
        let dat = try AnlzFile(data: AnlzBuilder.file([TrackAnalysisFiles.pvbr(facts)]))
        #expect(dat.tag("PVBR")?.bytes.suffix(4).reduce(0) { $0 << 8 | UInt32($1) } == expected)
    }

    @Test func LAME_VBR은_8프레임_앞_위치로_탐색표를_채운다() throws {
        let url = try TestResources.url("mp3-lame-vbr.mp3")
        let frames = try #require(SeekInfo.mp3Frames(url: url))
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil && facts.bitRate == 0, "LAME VBR은 비트레이트 칸이 0")
        // LAME 정보 프레임은 소리로 센다
        let counted = frames.offsets
        #expect(facts.pvbrTotalSamples == UInt32(counted.count * 1152))
        #expect(facts.pvbrEntries.count == 400)
        #expect(facts.pvbrEntries.first == 0)
        #expect(facts.pvbrEntries.last == UInt32(counted[counted.count - 8] - counted[0]), "마지막 칸 = 끝에서 8번째 프레임")
        #expect(zip(facts.pvbrEntries, facts.pvbrEntries.dropFirst()).allSatisfy { $0 <= $1 })
        let tag = TrackAnalysisFiles.pvbr(facts)
        #expect(tag.count == 0x10 + 1600 + 4, "머리 12바이트 + u32 0 · 400칸 · 끝값")
        let lastEntry = tag.subdata(in: 0x10 + 399 * 4 ..< 0x10 + 400 * 4)
        #expect(lastEntry.reduce(0) { $0 << 8 | UInt32($1) } == facts.pvbrEntries[399], "빅엔디언")
    }

    @Test func CBR은_탐색표가_비고_비트레이트를_적는다() throws {
        let lame = try TestResources.url("mp3-lame-cbr.mp3")
        let facts = AudioFacts.read(url: lame)
        let frames = try #require(SeekInfo.mp3Frames(url: lame))
        #expect(facts.unsupported == nil && facts.bitRate == 128 && facts.pvbrEntries.isEmpty)
        #expect(facts.pvbrTotalSamples == UInt32(frames.offsets.count * 1152))
        #expect(TrackAnalysisFiles.pvbr(facts).subdata(in: 0x10 ..< 0x10 + 1600).allSatisfy { $0 == 0 })
    }

    @Test func VBR_큐_MPEG_칸은_ms_올림_뒤_8프레임_앞() {
        // 1152샘플·44.1kHz 프레임 100개(바이트 위치 = 번호 × 400)
        let counted = (0..<100).map { $0 * 400 }
        func position(_ msec: Int) -> (Int, Int)? {
            SeekInfo.mp3CuePosition(msec: msec, counted: counted, sampleRate: 44_100, samplesPerFrame: 1152).map { ($0.mpegFrame, $0.abs) }
        }
        #expect(position(10)! == (0, 0), "InFrame 1 → MPEG 칸 0")
        #expect(position(200)! == (15, 0), "앞쪽은 0번째 프레임으로 붙는다")
        // 80,622ms: InFrame 12093 → 6046(1/75초) → 80,613.3ms 올림 80,614ms → 3086.005 → 3086 − 8
        // (버림 80,613ms면 3085가 되어 rekordbox와 달라진다: いーあるふぁんくらぶ 등 실측)
        #expect(SeekInfo.mp3CuePosition(msec: 80_622, counted: Array(0..<4000), sampleRate: 44_100, samplesPerFrame: 1152)!.abs == 3078)
        #expect(position(3_000) == nil, "파일 끝을 넘으면 계산하지 않는다")
    }

    @Test func ffmpeg_정보_프레임은_세지_않는다() throws {
        let url = try TestResources.url("mp3-ffmpeg-cbr.mp3")
        let frames = try #require(SeekInfo.mp3Frames(url: url))
        #expect(frames.hasInfoFrame)
        #expect(!RekordboxTimeline.mp3Header(url: url).contains("LAME"), "LAME은 첫 프레임 안에서만 찾는다")
        #expect(AudioFacts.read(url: url).pvbrTotalSamples == UInt32((frames.offsets.count - 1) * 1152))
    }
}
