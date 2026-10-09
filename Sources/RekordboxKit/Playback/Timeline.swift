import DJCDomain
import AudioToolbox
import AVFoundation
import Foundation

/// rekordbox 시간축과 DJCrate(AVFoundation) 시간축의 차이.
///
/// 압축 음원(AAC·MP3)은 인코더가 앞에 넣은 지연 샘플(프라이밍)이 있다. AVFoundation은 이를 잘라 내
/// 실제 소리 시작을 0초로 두지만 rekordbox는 잘라 내지 않는 경우가 있어, 같은 박이 rekordbox에서
/// 수십 ms 늦게 찍힌다. rekordbox의 큐·그리드를 DJCrate에서 그리거나 재생할 때, 그리고 DJCrate에서
/// 만든 큐·그리드를 rekordbox로 보낼 때 이 차이를 더하고 빼야 한다.
///
/// `rekordboxTime = djcTime + offset`
public enum RekordboxTimeline {
    /// rekordbox 상세 파형(ANLZ .EXT의 PWV3). 초당 150칸, 칸마다 높이 0~31.
    public static func detailWaveform(ext url: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= data.count else { return 0 }
            return data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func tag(_ offset: Int) -> String {
            String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4], as: UTF8.self)
        }
        guard data.count > 12, tag(0) == "PMAI" else { throw DJCError.invalidAnalysisFile(url.path) }
        var offset = u32(4)
        while offset + 12 <= data.count {
            let headerLength = u32(offset + 4), tagLength = u32(offset + 8)
            guard tagLength > 0 else { break }
            if tag(offset) == "PWV3", headerLength >= 24, tagLength >= headerLength {
                let start = offset + headerLength
                let end = min(offset + tagLength, data.count)
                let count = min(u32(offset + 16), max(0, end - start))
                return data[data.startIndex + start..<data.startIndex + start + count].map { $0 & 0x1F }
            }
            offset += tagLength
        }
        return []
    }

    /// ANLZ .DAT 경로 옆의 .EXT(상세 파형이 들어 있다).
    public static func extURL(forAnalysis url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("EXT")
    }

    /// 파일 컨테이너에 적힌 프라이밍·패딩 프레임 수(AVFoundation이 잘라 내는 앞뒤 샘플).
    public struct PacketInfo: Sendable {
        public var primingFrames: Int
        public var remainderFrames: Int
        public var sampleRate: Double
        public var formatID: String
    }

    public static func packetInfo(url: URL) -> PacketInfo? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &description)
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let status = AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo, &size, &table)
        let id = description.mFormatID
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        return PacketInfo(primingFrames: status == noErr ? Int(table.mPrimingFrames) : 0,
                          remainderFrames: status == noErr ? Int(table.mRemainderFrames) : 0,
                          sampleRate: description.mSampleRate, formatID: fourcc)
    }

    /// MP3 첫 프레임의 정보 태그(Xing/Info/VBRI)와 인코더 문자열(LAME3.100, Lavf 등). 규칙을 다듬는 진단용.
    public static func mp3Header(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "?" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 16) else { return "?" }
        let bytes = [UInt8](head)
        var start = 0
        // ID3v2 태그 건너뛰기
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
            start = 10 + size
            if start >= bytes.count, let more = try? { () throws -> Data? in
                try handle.seek(toOffset: UInt64(start)); return try handle.read(upToCount: 4096) }() {
                return describeFrame([UInt8](more), from: 0)
            }
        }
        return describeFrame(bytes, from: start)
    }

    /// MP4 컨테이너의 프라이밍 표기 방식(iTunSMPB 태그 · elst 편집 목록)과 인코더 이름. 진단용.
    public static func mp4Header(url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "?" }
        func contains(_ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }
        var parts: [String] = []
        if contains("iTunSMPB") { parts.append("iTunSMPB") }
        if contains("elst") { parts.append("elst") }
        if let range = data.range(of: Data("\u{A9}too".utf8)) ?? data.range(of: Data([0xA9, 0x74, 0x6F, 0x6F])) {
            let start = range.upperBound + 16
            if start < data.count {
                let slice = data[start..<min(data.count, start + 24)].prefix { $0 >= 0x20 && $0 < 0x7F }
                parts.append(String(decoding: slice, as: UTF8.self))
            }
        }
        return parts.isEmpty ? "표기 없음" : parts.joined(separator: " ")
    }

    /// MPEG 1·2 Layer III 프레임 길이(바이트)
    static func mpegFrameLength(_ b: [UInt8], at i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        let version = (b[i + 1] >> 3) & 0x3, index = Int(b[i + 2] >> 4), rateIndex = Int((b[i + 2] >> 2) & 0x3)
        guard index > 0, index < 15, rateIndex < 3 else { return nil }
        let mpeg1 = version == 3
        let kbps = (mpeg1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])[index]
        let rate = (mpeg1 ? [44_100, 48_000, 32_000] : version == 2 ? [22_050, 24_000, 16_000] : [11_025, 12_000, 8_000])[rateIndex]
        return (mpeg1 ? 144 : 72) * kbps * 1000 / rate + Int((b[i + 2] >> 1) & 1)
    }

    static func describeFrame(_ bytes: [UInt8], from start: Int) -> String {
        var i = start
        while i + 4 < bytes.count, !(bytes[i] == 0xFF && bytes[i + 1] & 0xE0 == 0xE0) { i += 1 }
        guard i + 200 < bytes.count else { return "프레임 없음" }
        // 정보 태그·인코더 문자열은 첫 프레임 안에서만 찾는다. 다음 오디오 프레임에 LAME 문자열이 들어 있는
        // ffmpeg 파일이 있어서(2026-09-26 花になって 등), 400바이트를 보면 LAME로 잘못 읽었다.
        let window = Array(bytes[i..<min(bytes.count, i + (mpegFrameLength(bytes, at: i) ?? 400))])
        func find(_ text: String) -> Int? {
            let needle = Array(text.utf8)
            guard window.count >= needle.count else { return nil }
            return (0...(window.count - needle.count)).first { Array(window[$0..<$0 + needle.count]) == needle }
        }
        let tag = find("Xing") != nil ? "Xing" : find("Info") != nil ? "Info" : find("VBRI") != nil ? "VBRI" : "태그없음"
        var encoder = ""
        for name in ["LAME", "Lavf", "Lavc", "GOGO", "L3.99"] {
            if let at = find(name) {
                encoder = String(decoding: window[at..<min(window.count, at + 9)].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                break
            }
        }
        return "\(tag) \(encoder)"
    }

    /// 파일 형식으로 예측한 차이(초). rekordbox는 압축 음원 앞의 지연 샘플을 잘라 내지 않는다.
    /// - PCM·FLAC·ALAC: 0
    /// - AAC: 컨테이너에 적힌 프라이밍(보통 2112샘플 = 44.1kHz에서 47.9ms)
    /// - MP3: LAME 태그가 있으면 인코더 지연 + 디코더 지연(529) + 태그 프레임(1152), 없으면 디코더 지연만
    public static func predictedOffset(url: URL) -> Double {
        guard let info = packetInfo(url: url), info.sampleRate > 0 else { return 0 }
        switch info.formatID {
        case "aac ", "aach", "aacp":
            return Double(info.primingFrames) / info.sampleRate
        case ".mp3", ".mp2", ".mp1":
            // LAME가 만든 정보 태그가 있으면 rekordbox는 그 프레임까지 소리로 센다(측정: +51ms).
            // ffmpeg(Lavf·Lavc) 태그는 그 프레임을 세지 않는다(측정: +16~26ms). 태그가 없으면 디코더 지연만.
            guard info.primingFrames > 0 else { return 529 / info.sampleRate }
            let lame = mp3Header(url: url).contains("LAME")
            return Double(info.primingFrames + 529 + (lame ? 1152 : 0)) / info.sampleRate
        default:
            return 0
        }
    }

    /// rekordbox가 곡 끝에서 AVFoundation보다 더 읽는 샘플 수(파형 칸 수를 맞출 때). 2026-09-26 파형 비교로 맞춤.
    /// - AAC: 끝 패딩(remainder)까지 센다
    /// - MP3: MPEG 프레임 전체(정보 프레임 포함 × 1152)라 끝 패딩에서 디코더 지연(529)을 뺀 만큼
    /// - FLAC: 약 4,096샘플 더(2곡: 3,840~4,116 범위, 블록 하나로 추정)
    public static func predictedTrailingFrames(url: URL) -> Int {
        guard let info = packetInfo(url: url) else { return 0 }
        switch info.formatID {
        case "aac ", "aach", "aacp": return info.remainderFrames
        case ".mp3", ".mp2", ".mp1": return info.primingFrames > 0 ? max(0, info.remainderFrames - 529) : 0
        case "flac": return 4096
        default: return 0
        }
    }

    /// rekordbox 파형(PWV3)과 AVFoundation 디코딩의 소리 크기 곡선을 맞대어 차이(초)를 잰다.
    /// 그리드와 무관한 순수한 시간축 차이다. 반환: (offset, 상관계수). 상관이 0.8 미만이면 믿지 않는다.
    public static func measureOffset(audio url: URL, rekordboxHeights: [UInt8],
                                     searchRange: ClosedRange<Int> = -150...150) throws -> (offset: Double, correlation: Double) {
        let envelope = try millisecondPeaks(url: url)
        let rb = rekordboxHeights.map(Double.init)
        guard rb.count > 300, envelope.peaks.count > 2000 else { return (0, 0) }
        var scores: [Int: Double] = [:]
        for lag in searchRange {
            scores[lag] = correlation(rb, binned(envelope, lagMs: Double(lag), bins: rb.count))
        }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return (0, 0) }
        // 이웃 두 점으로 포물선 보간(1ms보다 곱게)
        var refined = Double(best.key)
        if let left = scores[best.key - 1], let right = scores[best.key + 1] {
            let denominator = left - 2 * best.value + right
            if denominator < 0 { refined += 0.5 * (left - right) / denominator }
        }
        return (refined / 1000, best.value)
    }

    public struct Peaks: Sendable {
        public var peaks: [Float]
        /// 초당 칸 수(44.1kHz면 44샘플 칸이라 1002.27)
        public var rate: Double
    }

    /// 약 1ms마다 절대값 최대(모노). 실제 칸 속도를 함께 돌려준다.
    public static func millisecondPeaks(url: URL) throws -> Peaks {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let hop = max(1, Int((format.sampleRate / 1000).rounded()))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return Peaks(peaks: [], rate: 1000) }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / Double(hop)) + 10)
        var current: Float = 0, filled = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let channels = buffer.floatChannelData else { break }
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<Int(format.channelCount) { v = max(v, abs(channels[c][i])) }
                current = max(current, v)
                filled += 1
                if filled == hop { peaks.append(current); current = 0; filled = 0 }
            }
        }
        return Peaks(peaks: peaks, rate: format.sampleRate / Double(hop))
    }

    /// rekordbox 칸 j(1/150초)가 음원 시간 [j/150 − lag, (j+1)/150 − lag)에 해당한다고 보고 칸별 최대를 모은다.
    public static func binned(_ envelope: Peaks, lagMs: Double, bins: Int) -> [Double] {
        let peaks = envelope.peaks, rate = envelope.rate, lag = lagMs / 1000
        return (0..<bins).map { j in
            let from = Int(((Double(j) / 150 - lag) * rate).rounded(.down))
            let to = Int(((Double(j + 1) / 150 - lag) * rate).rounded(.down))
            var peak: Float = 0
            if to > 0, from < peaks.count {
                for i in max(0, from)..<min(peaks.count, max(to, from + 1)) { peak = max(peak, peaks[i]) }
            }
            return Double(peak)
        }
    }

    public static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let ma = a.prefix(n).reduce(0, +) / Double(n), mb = b.prefix(n).reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<n {
            let x = a[i] - ma, y = b[i] - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }
}
