import AudioToolbox
import DJCDomain
import Foundation

/// 곡을 분석까지 붙여 넣을 때 rekordbox 7.2.18과 같게 적는 음원 정보(2026-09-26 라이브러리·실험으로 확인).
/// - BitRate: CBR MP3는 프레임 비트레이트, AAC는 파일 머리(esds)에 적힌 평균 비트레이트(없으면 0), WAV는 샘플레이트×비트×채널.
/// - PVBR 끝값: MP3는 rekordbox가 세는 프레임 수×1152, AAC·WAV는 0(7.2.18이 오늘 분석한 곡 기준).
///   LAME 정보 프레임은 소리로 세고, 다른 인코더(ffmpeg 등)의 정보 프레임은 세지 않는다(`SeekInfo.countedMp3Offsets`, L3.99r1은 센다).
/// - VBR MP3 탐색표: 칸 k = rekordbox가 세는 프레임 중 `floor((k+1)·n/400) − 8`번째의 바이트 위치(그 첫 프레임 기준).
///   LAME·ffmpeg Xing(Lavc/Lavf)에서 400칸 일치. 8프레임 앞은 디코더 비트 저장소 몫으로 보인다.
///   VBR 비트레이트는 LAME이면 0, ffmpeg Xing은 첫 음성 프레임 비트레이트(2026-09-27 합성 3곡·기존 표본).
/// - FLAC: 비트레이트 0, PVBR은 모두 0. 대신 .EXT 끝에 PVB2(400칸 탐색표)를 붙인다.
///   칸 k = 샘플 `k · floor(전체 샘플/400)`이 든 FLAC 프레임의 (시작 샘플, 첫 프레임 기준 바이트 위치, 블록 크기).
///   라이브러리 FLAC 1,083곡 중 1,081곡이 바이트까지 같다(2026-09-26). 나머지 2곡은 재분석(2026-10-03)으로 가렸다:
///   1곡은 분석 뒤 파일이 바뀌었고, 1곡은 CRC-16이 맞지 않는 프레임이 있다(rekordbox는 PVB2에서 그 프레임을 빼고 번호를 이어 매긴다).
///   CRC-16이 맞지 않는 프레임이 12개인 다른 곡은 머리 번호 규칙이었다. 손상 모양에 따라 갈리므로 그런 프레임이 있으면 분석을 붙이지 않는다.
/// - ALAC: AudioToolbox 압축 비트레이트를 kbps로 버림, 원본 비트 깊이, PVBR 모두 0·PVB2 없음.
///   2026-09-27 합성 4곡으로 스테레오 16/24비트·44.1/48kHz를 확인했다.
///   #95 첫 BPM/Grid 카운터 사본 재현으로 ALAC·44.1kHz ffmpeg VBR 쓰기를 확인했다.
///   32·48kHz ffmpeg VBR은 2026-10-03 128 BPM 클릭(묶음 1)으로 음원 칸·PVBR·파형 길이·BPM 칸을 확인해 연다.
///   MPEG-2 샘플레이트(576샘플 프레임)는 확인하지 않아 막는다.
public struct AudioFacts: Sendable, Equatable {
    public var sampleRate: Int
    public var bitDepth: Int
    public var bitRate: Int
    public var pvbrTotalSamples: UInt32
    /// VBR MP3 탐색표(400칸, 첫 프레임 기준 바이트 위치). CBR·다른 형식은 모두 0.
    public var pvbrEntries: [UInt32] = []
    /// FLAC 탐색표(PVB2)의 전체 샘플과 400칸(첫 프레임 기준 바이트 위치). 다른 형식은 비어 있다.
    public var flacTotalSamples: UInt64 = 0
    public var flacEntries: [SeekInfo.FlacFrame] = []
    /// 분석을 붙일 수 없는 이유(nil이면 붙인다)
    public var unsupported: String?

    public static func read(url: URL) -> AudioFacts {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            return AudioFacts(sampleRate: 0, bitDepth: 0, bitRate: 0, pvbrTotalSamples: 0, unsupported: String(ui: "음원 형식을 읽지 못했습니다"))
        }
        defer { AudioFileClose(fileID) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &format)
        let rate = Int(format.mSampleRate)
        switch format.mFormatID {
        case kAudioFormatMPEGLayer3:
            guard let frames = SeekInfo.mp3Frames(url: url), let first = frames.offsets.first else {
                return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: 0, pvbrTotalSamples: 0, unsupported: String(ui: "MP3 프레임을 읽지 못했습니다"))
            }
            // 중간에 깨진 프레임이 있으면 rekordbox와 프레임 수가 달라진다(끝까지 읽혀야 한다)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard let last = frames.offsets.last, size - last < 16_384 else {
                return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: 0, pvbrTotalSamples: 0,
                                  unsupported: String(ui: "MP3 프레임이 중간에 끊겨 있어(깨진 프레임) 분석을 붙일 수 없으니 rekordbox에서 먼저 분석하세요"))
            }
            let counted = SeekInfo.countedMp3Offsets(frames, url: url)
            let header = RekordboxTimeline.mp3Header(url: url)
            let lame = header.contains("LAME")
            let ffmpeg = header.hasPrefix("Xing Lavc") || header.hasPrefix("Xing Lavf")
            let total = UInt32(counted.count * frames.samplesPerFrame)
            let audioFrame = frames.hasInfoFrame && frames.offsets.count > 1 ? frames.offsets[1] : first
            guard frames.isVariableBitRate else {
                return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: mp3BitRate(url: url, at: audioFrame) ?? 0,
                                  pvbrTotalSamples: total, unsupported: nil)
            }
            guard lame || ffmpeg, counted.count > 8 else {
                return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: 0, pvbrTotalSamples: total,
                                  unsupported: String(ui: "이 VBR MP3 인코더의 분석 규칙은 확인되지 않았으니 rekordbox에서 먼저 분석하세요"))
            }
            let n = counted.count
            let entries = (0..<400).map { k in UInt32(counted[max(0, (k + 1) * n / 400 - 8)] - counted[0]) }
            return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: lame ? 0 : (mp3BitRate(url: url, at: audioFrame) ?? 0),
                              pvbrTotalSamples: total, pvbrEntries: entries,
                              unsupported: !lame && ![32_000, 44_100, 48_000].contains(rate)
                                ? String(ui: "이 샘플레이트의 ffmpeg VBR MP3는 분석 규칙이 확인되지 않았으니 rekordbox에서 먼저 분석하세요") : nil)
        case kAudioFormatMPEG4AAC:
            return AudioFacts(sampleRate: rate, bitDepth: 16, bitRate: aacAverageBitRate(fileID) / 1000, pvbrTotalSamples: 0, unsupported: nil)
        case kAudioFormatLinearPCM:
            let bits = Int(format.mBitsPerChannel)
            return AudioFacts(sampleRate: rate, bitDepth: bits, bitRate: rate * bits * Int(format.mChannelsPerFrame) / 1000,
                              pvbrTotalSamples: 0, unsupported: nil)
        case kAudioFormatFLAC:
            return flac(url: url)
        case kAudioFormatAppleLossless:
            // ALAC의 mBitsPerChannel은 0이다. 원본 비트 깊이는 format flags에 있다.
            let bits = format.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData ? 16
                : format.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData ? 24 : 0
            var bitrate: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard bits > 0, [44_100, 48_000].contains(rate), format.mChannelsPerFrame == 2,
                  AudioFileGetProperty(fileID, kAudioFilePropertyBitRate, &size, &bitrate) == noErr else {
                return AudioFacts(sampleRate: rate, bitDepth: bits, bitRate: 0, pvbrTotalSamples: 0,
                                  unsupported: String(ui: "이 ALAC 형식의 분석 규칙은 확인되지 않았으니 rekordbox에서 먼저 분석하세요"))
            }
            return AudioFacts(sampleRate: rate, bitDepth: bits, bitRate: Int(bitrate / 1000), pvbrTotalSamples: 0,
                              unsupported: nil)
        default:
            return AudioFacts(sampleRate: rate, bitDepth: 0, bitRate: 0, pvbrTotalSamples: 0,
                              unsupported: String(ui: "이 형식의 분석 규칙은 확인되지 않았으니 rekordbox에서 먼저 분석하세요"))
        }
    }

    static func flac(url: URL) -> AudioFacts {
        guard let info = SeekInfo.flacStreamInfo(url: url), let table = SeekInfo.flacFrames(url: url),
              let last = table.frames.last else {
            return AudioFacts(sampleRate: 0, bitDepth: 0, bitRate: 0, pvbrTotalSamples: 0, unsupported: String(ui: "FLAC 프레임을 읽지 못했습니다"))
        }
        let total = last.startSample + last.blockSize
        guard info.totalSamples == 0 || info.totalSamples == total else {
            return AudioFacts(sampleRate: info.sampleRate, bitDepth: info.bitsPerSample, bitRate: 0, pvbrTotalSamples: 0,
                              unsupported: String(ui: "FLAC에 깨진 프레임이 있어 분석을 붙일 수 없으니 rekordbox에서 먼저 분석하세요"))
        }
        // 머리 번호는 이어져도 본문이 잘린 프레임이 있으면 rekordbox의 PVB2가 달라진다(#14 곡 D)
        guard SeekInfo.flacFramesPassCRC(url: url, frames: table.frames) else {
            return AudioFacts(sampleRate: info.sampleRate, bitDepth: info.bitsPerSample, bitRate: 0, pvbrTotalSamples: 0,
                              unsupported: String(ui: "FLAC에 깨진 프레임이 있어 분석을 붙일 수 없으니 rekordbox에서 먼저 분석하세요"))
        }
        return AudioFacts(sampleRate: info.sampleRate, bitDepth: info.bitsPerSample, bitRate: 0, pvbrTotalSamples: 0,
                          flacTotalSamples: UInt64(total), flacEntries: pvb2Entries(frames: table.frames, total: total), unsupported: nil)
    }

    /// PVB2 400칸: 칸 k = 샘플 `k · floor(total/400)`이 든 프레임(시작이 그 샘플 이하인 마지막 프레임)
    public static func pvb2Entries(frames: [SeekInfo.FlacFrame], total: Int) -> [SeekInfo.FlacFrame] {
        guard let first = frames.first else { return [] }
        let starts = frames.map(\.startSample)
        let step = total / 400
        return (0..<400).map { k -> SeekInfo.FlacFrame in
            var lo = 0, hi = starts.count
            while hi - lo > 1 { let mid = (lo + hi) / 2; if starts[mid] <= k * step { lo = mid } else { hi = mid } }
            let frame = frames[lo]
            return SeekInfo.FlacFrame(startSample: frame.startSample, offset: frame.offset - first.offset, blockSize: frame.blockSize)
        }
    }

    static func with(_ facts: AudioFacts, _ reason: String) -> AudioFacts {
        var copy = facts
        copy.unsupported = reason
        return copy
    }

    /// MPEG 오디오 프레임 머리의 비트레이트(kbps)
    static func mp3BitRate(url: URL, at offset: Int) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return nil }
        let b = [UInt8](bytes)
        let version = (b[1] >> 3) & 0x3   // 3 = MPEG1
        let index = Int(b[2] >> 4)
        let mpeg1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        let mpeg2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
        return (version == 3 ? mpeg1 : mpeg2)[index]
    }

    /// AAC 파일 머리(esds DecoderConfigDescriptor)의 평균 비트레이트(bps). 없으면 0.
    static func aacAverageBitRate(_ fileID: AudioFileID) -> Int {
        var size: UInt32 = 0
        guard AudioFileGetPropertyInfo(fileID, kAudioFilePropertyMagicCookieData, &size, nil) == noErr, size > 0 else { return 0 }
        var cookie = [UInt8](repeating: 0, count: Int(size))
        guard AudioFileGetProperty(fileID, kAudioFilePropertyMagicCookieData, &size, &cookie) == noErr else { return 0 }
        // DecoderConfigDescriptor(태그 0x04): 길이(가변 1~4바이트) · objectType(AAC 0x40) · streamType(오디오 0x15)
        //   · bufferSize(3) · maxBitrate(4) · avgBitrate(4). streamType 바이트가 0x14인 파일도 있다(예약 비트 0).
        for i in cookie.indices where cookie[i] == 0x04 {
            var j = i + 1
            while j < cookie.count, j - i <= 4, cookie[j] & 0x80 != 0 { j += 1 }
            j += 1
            guard j + 13 <= cookie.count, cookie[j] == 0x40, cookie[j + 1] >> 2 == 0x05 else { continue }   // streamType 5(오디오), 아래 2비트는 무시
            let avg = j + 9
            return Int(cookie[avg]) << 24 | Int(cookie[avg + 1]) << 16 | Int(cookie[avg + 2]) << 8 | Int(cookie[avg + 3])
        }
        return 0
    }
}

/// 새 곡의 분석 파일(.DAT·.EXT·.2EX) 바이트. rekordbox 7.2.18이 새로 분석한 곡과 같은 태그 순서.
/// - .DAT: PPTH · PVBR · PQTZ · PWAV · PWV2 · PCOB(핫) · PCOB(메모리)
/// - .EXT·.2EX: `RekordboxWaveforms.files(dat:extTail:)`(PQT2는 빈 형태: rekordbox는 ms+0.5를 정밀 시각으로 본다). FLAC은 .EXT 끝에 PVB2.
/// 프레이즈(PSSI)·보컬(PVDI)·AI 특징(.3EX)은 만들지 못한다. 필요하면 rekordbox에서 Phrase만 분석하면 우리 태그는 그대로 두고 덧붙인다.
public enum TrackAnalysisFiles {
    /// PMAI 머리 뒤 16바이트(rekordbox 7이 쓰는 값)
    static let headerTail: [UInt8] = [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]

    static var header: Data { Data(Array("PMAI".utf8) + RekordboxWaveforms.be32(0x1C) + RekordboxWaveforms.be32(0) + headerTail) }

    /// PPTH: "?/파일 이름"을 UTF-16BE로(끝 NULL 포함)
    static func ppth(fileName: String) -> Data {
        ppth(path: "?/" + fileName)
    }

    /// PPTH: 경로 그대로(USB는 "/Contents/…")
    static func ppth(path: String) -> Data {
        AnlzPathTag.encode(path)
    }

    /// PVBR: 머리 u32 0 · 탐색표 400칸(CBR은 0) · 끝값(전체 샘플)
    public static func pvbr(_ facts: AudioFacts) -> Data {
        let table = facts.pvbrEntries.count == 400 ? facts.pvbrEntries.flatMap(RekordboxWaveforms.be32) : [UInt8](repeating: 0, count: 1600)
        return RekordboxWaveforms.section("PVBR", headerLength: 0x10, RekordboxWaveforms.be32(0) + table + RekordboxWaveforms.be32(facts.pvbrTotalSamples))
    }

    /// PVB2(FLAC 탐색표): 머리 u32 0 · 전체 샘플 u64 · 칸 수 400 · 칸 크기 20, 칸마다 시작 샘플 u64 · 바이트 위치 u64 · 블록 크기 u32
    public static func pvb2(_ facts: AudioFacts) -> Data? {
        guard facts.flacEntries.count == 400 else { return nil }
        var body = RekordboxWaveforms.be32(0) + RekordboxWaveforms.be64(facts.flacTotalSamples) + RekordboxWaveforms.be32(400) + RekordboxWaveforms.be32(20)
        for entry in facts.flacEntries {
            body += RekordboxWaveforms.be64(UInt64(entry.startSample)) + RekordboxWaveforms.be64(UInt64(entry.offset))
                + RekordboxWaveforms.be32(UInt32(entry.blockSize))
        }
        return RekordboxWaveforms.section("PVB2", headerLength: 0x20, body)
    }

    /// 빈 큐 목록(PCOB). kind 1 = 핫큐, 0 = 메모리 큐.
    static func emptyPCOB(kind: UInt32) -> Data {
        RekordboxWaveforms.section("PCOB", headerLength: 0x18, RekordboxWaveforms.be32(kind) + RekordboxWaveforms.be32(0) + [0xFF, 0xFF, 0xFF, 0xFF])
    }

    public static func make(fileName: String, beats: [BeatGridTags.Beat], waveforms: RekordboxWaveforms,
                            facts: AudioFacts) throws -> (dat: Data, ext: Data, twoEx: Data) {
        let dat = AnlzFile(header: header, tags: [ppth(fileName: fileName), pvbr(facts),
                                                  BeatGridTags.pqtz(beats), waveforms.pwavTag, waveforms.pwv2Tag,
                                                  emptyPCOB(kind: 1), emptyPCOB(kind: 0)])
        let (ext, twoEx) = try waveforms.files(dat: dat, extTail: pvb2(facts).map { [$0] } ?? [])
        return (dat.serialized(), ext, twoEx)
    }
}
