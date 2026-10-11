import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// FLAC을 분석까지 붙여 넣을 때의 음원 정보와 탐색표(PVB2). 규칙은 라이브러리 FLAC 1,083곡 중 1,081곡과 바이트까지 확인(2026-09-26).
@Suite("FLAC 분석 음원 정보")
struct FlacAnalysisTests {
    @Test func STREAMINFO를_읽는다() throws {
        let folder = try TemporaryFolder()
        let url = try AudioFixture.flac(seconds: 1.5, in: folder.url)
        let info = try #require(SeekInfo.flacStreamInfo(url: url))
        #expect(info.sampleRate == 44_100 && info.channels == 2 && info.bitsPerSample == 24, "macOS 인코더는 float 입력을 24비트로 적는다: \(info)")
        let frames = try #require(SeekInfo.flacFrames(url: url)?.frames)
        #expect(info.totalSamples == frames.last!.startSample + frames.last!.blockSize)
    }

    @Test func 탐색표는_k_곱하기_floor_전체의_400분의_1이_든_프레임() throws {
        let folder = try TemporaryFolder()
        let url = try AudioFixture.flac(seconds: 3, in: folder.url)
        let frames = try #require(SeekInfo.flacFrames(url: url)?.frames)
        let total = frames.last!.startSample + frames.last!.blockSize
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported == nil && facts.bitRate == 0 && facts.bitDepth == 24 && facts.pvbrTotalSamples == 0)
        #expect(facts.flacTotalSamples == UInt64(total) && facts.flacEntries.count == 400)
        let step = total / 400
        for (k, entry) in facts.flacEntries.enumerated() {
            let frame = try #require(frames.last { $0.startSample <= k * step })
            #expect(entry.startSample == frame.startSample && entry.blockSize == frame.blockSize)
            #expect(entry.offset == frame.offset - frames[0].offset, "첫 프레임 기준 바이트 위치")
        }
        // 바이트: 머리 12 + (u32 0 · u64 전체 · u32 400 · u32 20) + 400칸 × 20
        let tag = try #require(TrackAnalysisFiles.pvb2(facts))
        #expect(tag.count == 32 + 400 * 20)
        #expect(Array(tag.prefix(12)) == Array("PVB2".utf8) + [0, 0, 0, 0x20, 0, 0, 0x1F, 0x60])
        #expect(tag.subdata(in: 16..<24).reduce(0) { $0 << 8 | UInt64($1) } == UInt64(total))
        #expect(Array(tag.subdata(in: 24..<32)) == [0, 0, 1, 0x90, 0, 0, 0, 20])
    }

    @Test func CRC_16이_맞지_않는_프레임이_있으면_분석을_붙이지_않는다() throws {
        // #14 곡 D(rekordbox 7.2.18, 2026-10-03, 96kHz/24비트 FLAC): 가운데 프레임 하나가 14바이트 짧아 CRC-16이 맞지 않는다.
        // rekordbox는 PVB2에서 그 프레임을 빼고 이어서 번호를 매겼지만(400칸 일치), 큐 SeekInfo는 프레임 머리 번호를 따랐다(13개 일치).
        // CRC-16만 틀린 프레임이 12개인 다른 곡은 머리 번호 규칙이었다. 손상 모양에 따라 갈리므로 PVB2 규칙은 열지 않고 막는다.
        let folder = try TemporaryFolder()
        let source = try AudioFixture.flac(seconds: 3, in: folder.url)
        let frames = try #require(SeekInfo.flacFrames(url: source)?.frames)
        let next = frames[frames.count / 2 + 1]
        var bytes = try Data(contentsOf: source)
        // 프레임 본문 끝의 14바이트만 지운다(머리·CRC-16 자리·다음 프레임은 그대로)
        bytes.removeSubrange(next.offset - 16 ..< next.offset - 2)
        let url = folder.url.appending(path: "damaged.flac")
        try bytes.write(to: url)
        let damaged = try #require(SeekInfo.flacFrames(url: url)?.frames)
        #expect(damaged.map(\.startSample) == frames.map(\.startSample), "큐 SeekInfo용 표는 머리 번호 그대로")
        let facts = AudioFacts.read(url: url)
        #expect(facts.unsupported != nil && facts.flacEntries.isEmpty)
        #expect(AudioFacts.read(url: source).unsupported == nil)
    }

    @Test func 마지막_프레임_뒤의_태그로는_막지_않는다() throws {
        let folder = try TemporaryFolder()
        let url = try AudioFixture.flac(seconds: 3, in: folder.url)
        var bytes = try Data(contentsOf: url)
        bytes.append(Data("TAG".utf8) + Data(count: 125))   // ID3v1
        try bytes.write(to: url)
        #expect(AudioFacts.read(url: url).unsupported == nil)
    }

    @Test func FLAC이_아니면_PVB2가_없다() throws {
        #expect(TrackAnalysisFiles.pvb2(AudioFacts.read(url: try TestResources.url("mp3-lame-cbr.mp3"))) == nil)
    }
}
