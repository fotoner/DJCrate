import AVFoundation
import DJCDomain
import Foundation

/// rekordbox 파형 태그(PWAV·PWV2 .DAT, PWV3·PWV5·PWV4 .EXT, PWV7·PWV6·PWVC .2EX)를 음원에서 만든다.
///
/// 규칙은 baken(MIT, © 2025 Masanari Higashi, github.com/M-Igashi/baken PR #148)이 rekordbox 7.2 분석 1,070곡과
/// 음원을 비교해 역산한 것을 옮겼다. baken 보고: 흑백 높이·흰 정도(PWV3)는 칸의 99.5%가 바이트까지 같고,
/// 색·3밴드(PWV5·PWV7·PWV4·PWV6)는 근사다.
/// 고지: THIRD_PARTY_NOTICES.md
///
/// 칸: 초당 150칸. 칸 `i`는 모노 `(L + R) / 2`의 샘플 `[round(i·rate/150), round((i+1)·rate/150))`.
/// 시각은 rekordbox 시간축(인코더 지연 포함)이어야 해서, 디코딩한 음원 앞에 `RekordboxTimeline.predictedOffset`만큼 무음을 붙인다.
public struct RekordboxWaveforms: Sendable, Equatable {
    /// 칸마다 흰 정도(3비트) << 5 | 높이(5비트)
    public var pwv3: [UInt8]
    /// 칸마다 rrr ggg bbb hhhhh 00
    public var pwv5: [UInt16]
    /// 칸마다 저·중·고(0~127) 3바이트
    public var pwv7: [UInt8]
    /// 저·중·고 게인(PWVC)
    public var gains: [UInt16]
    /// 400칸 미리 보기
    public var pwav: [UInt8]
    /// 100칸(4비트)
    public var pwv2: [UInt8]
    /// 1200칸 × 저·중·고
    public var pwv6: [UInt8]
    /// 1200칸 × 6바이트
    public var pwv4: [UInt8]

    public var columns: Int { pwv3.count }
    public static let columnsPerSecond = 150.0

    // 흰 정도: 150Hz 저역 통과한 칸 최대 / 칸 최대
    static let whitenessLowpassHz = 150.0
    // 3밴드 나눔
    static let lowHz = 300.0, midLowHz = 250.0, midHighHz = 1500.0, highHz = 2500.0
    /// 칸마다 밴드 포락선이 줄어드는 비율(저·중·고)
    static let release: [Double] = [0.97, 0.93, 0.90]
    static let gainTarget: [Double] = [78, 105, 115]
    static let gainFloor: [UInt16] = [80, 80, 95]
    static let gainCap: [UInt16] = [267, 300, 500]
    static let bandScale: [Double] = [1.25, 1.15, 0.6]
    static let pwv6Scale: [Double] = [0.537, 0.640, 1.052]
    static let pwv4Scale: [Double] = [2.4, 1.6, 1.1]

    /// 2차 버터워스(RBJ, Q = 1/√2)
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(lowpass fc: Double, rate: Double) {
            let w = 2 * Double.pi * fc / rate, s = sin(w), c = cos(w), alpha = s / (2 * 0.5.squareRoot())
            let a0 = 1 + alpha
            (b0, b1, b2) = ((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0)
            (a1, a2) = (-2 * c / a0, (1 - alpha) / a0)
        }

        init(highpass fc: Double, rate: Double) {
            let w = 2 * Double.pi * fc / rate, s = sin(w), c = cos(w), alpha = s / (2 * 0.5.squareRoot())
            let a0 = 1 + alpha
            (b0, b1, b2) = ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0)
            (a1, a2) = (-2 * c / a0, (1 - alpha) / a0)
        }

        @inline(__always) mutating func step(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// 칸 하나의 측정값(최대·저역 최대·3밴드 최대·제곱합)
    public struct Column: Sendable {
        public var peak = 0.0, white = 0.0
        public var band: (Double, Double, Double) = (0, 0, 0)
        public var sumsq = 0.0
        public var samples = 0
    }

    public static func measure(_ mono: [Float], rate: Double) -> [Column] {
        let n = max(1, Int((Double(mono.count) * columnsPerSecond / rate).rounded(.up)))
        var columns = [Column](repeating: Column(), count: n)
        var white = Biquad(lowpass: whitenessLowpassHz, rate: rate)
        var low = Biquad(lowpass: lowHz, rate: rate)
        var midHP = Biquad(highpass: midLowHz, rate: rate)
        var midLP = Biquad(lowpass: midHighHz, rate: rate)
        var high = Biquad(highpass: highHz, rate: rate)
        var col = 0
        var nextEdge = Int((rate / columnsPerSecond).rounded())
        for i in mono.indices {
            while i >= nextEdge, col + 1 < n {
                col += 1
                nextEdge = Int((Double(col + 1) * rate / columnsPerSecond).rounded())
            }
            let x = Double(mono[i])
            columns[col].peak = max(columns[col].peak, abs(x))
            columns[col].white = max(columns[col].white, abs(white.step(x)))
            columns[col].band.0 = max(columns[col].band.0, abs(low.step(x)))
            columns[col].band.1 = max(columns[col].band.1, abs(midLP.step(midHP.step(x))))
            columns[col].band.2 = max(columns[col].band.2, abs(high.step(x)))
            columns[col].sumsq += x * x
            columns[col].samples += 1
        }
        return columns
    }

    /// `n`개를 `parts`개의 이어진 구간으로(각 구간은 적어도 하나, n < parts면 겹친다)
    static func ranges(_ n: Int, _ parts: Int) -> [Range<Int>] {
        (0..<parts).map { k in
            let a = min(k * n / parts, n - 1)
            let b = min(max((k + 1) * n / parts, a + 1), n)
            return a..<b
        }
    }

    public static func analyze(mono: [Float], sampleRate rate: Double) -> RekordboxWaveforms {
        let columns = measure(mono, rate: rate)
        let n = columns.count
        let trackPeak = columns.map(\.peak).max() ?? 0

        // 높이 = floor(31.5 · (칸 최대 / 곡 최대)²), 흰 정도 = 7 − floor(8 · 저역 최대 / 칸 최대)(무음은 7)
        let heights: [UInt8] = columns.map { c in
            guard trackPeak > 0 else { return 0 }
            let q = c.peak / trackPeak
            return UInt8(min(31, (31.5 * q * q).rounded(.down)))
        }
        let whites: [UInt8] = columns.map { c in
            guard c.peak > 0 else { return 7 }
            let r = min(max(c.white / c.peak, 0), 1)
            return UInt8(7 - min(7, Int((8 * r).rounded(.down))))
        }
        let pwv3 = zip(heights, whites).map { h, w in w << 5 | h }

        // 3밴드 포락선(칸마다 줄어듦) → 가장 큰 칸을 목표 크기로 맞추는 게인
        func band(_ c: Column, _ j: Int) -> Double { j == 0 ? c.band.0 : j == 1 ? c.band.1 : c.band.2 }
        var envelope = [Double](repeating: 0, count: n * 3)
        for i in 0..<n {
            for j in 0..<3 {
                let previous = i == 0 ? 0 : envelope[(i - 1) * 3 + j] * release[j]
                envelope[i * 3 + j] = max(band(columns[i], j), previous)
            }
        }
        var gains: [UInt16] = [0, 0, 0]
        for j in 0..<3 {
            let peak = stride(from: j, to: envelope.count, by: 3).map { envelope[$0] }.max() ?? 0
            gains[j] = peak > 0 ? min(max(UInt16(clamping: Int((gainTarget[j] / peak).rounded())), gainFloor[j]), gainCap[j]) : gainFloor[j]
        }
        var pwv7 = [UInt8](repeating: 0, count: n * 3)
        for i in 0..<n {
            for j in 0..<3 {
                pwv7[i * 3 + j] = UInt8(min(127, (bandScale[j] * Double(gains[j]) * envelope[i * 3 + j]).rounded()))
            }
        }

        // 색: 칸에서 가장 센 밴드에 대한 비율의 제곱근(약한 밴드도 물들게)
        let pwv5: [UInt16] = zip(columns, heights).map { c, h in
            let top = max(c.band.0, c.band.1, c.band.2)
            // 2026-09-26 probe 3곡의 완전한 무음은 RGB 모두 7(높이는 0)이다.
            func level(_ b: Double) -> UInt16 { top <= 0 ? 7 : UInt16(min(7, (7 * (b / top).squareRoot()).rounded())) }
            return level(c.band.0) << 13 | level(c.band.1) << 10 | level(c.band.2) << 7 | UInt16(h) << 2
        }

        // 미리 보기: 칸 묶음의 RMS
        func rms(_ r: Range<Int>) -> Double {
            var sum = 0.0, count = 0
            for c in columns[r] { sum += c.sumsq; count += c.samples }
            return count == 0 ? 0 : (sum / Double(count)).squareRoot()
        }
        let rms400 = ranges(n, 400).map(rms)
        let rms400Max = rms400.max() ?? 0
        let white200 = ranges(n, 200).map { r in UInt8((r.map { Double(whites[$0]) }.reduce(0, +) / Double(r.count)).rounded()) }
        let pwav: [UInt8] = rms400.enumerated().map { k, value in
            let h = rms400Max > 0 ? UInt8((24 * value / rms400Max).rounded()) : 0
            return min(white200[k / 2], 7) << 5 | min(h, 31)
        }
        let rms100 = ranges(n, 100).map(rms)
        let rms100Max = rms100.max() ?? 0
        let pwv2: [UInt8] = rms100.map { value in
            rms100Max > 0 ? UInt8(min(15, (15 * (value / rms100Max).squareRoot()).rounded())) : 0
        }

        // 3밴드 미리 보기(1200칸): 칸 구간보다 앞뒤로 넓은 창(시작 −0.7칸, 폭 1.8칸)의 PWV7 평균 × 밴드 배율.
        // rekordbox 자신의 PWV7로 PWV6을 맞춘 값(8곡, r 0.96). 정확한 규칙은 아직 모른다.
        var pwv6 = [UInt8](repeating: 0, count: 1200 * 3)
        let step = Double(n) / 1200
        for k in 0..<1200 {
            let a = min(max(Int((Double(k) - 0.7) * step), 0), n - 1)
            let b = min(max(Int((Double(k) + 1.1) * step), a + 1), n)
            for j in 0..<3 {
                var sum = 0.0
                for i in a..<b { sum += Double(pwv7[i * 3 + j]) }
                pwv6[k * 3 + j] = UInt8(min(127, (pwv6Scale[j] * sum / Double(b - a)).rounded()))
            }
        }
        let previewRanges = mono.isEmpty ? [] : ranges(mono.count, 1200)
        var pwv4 = [UInt8](repeating: 0, count: 1200 * 6)
        var previewLowpass = Biquad(lowpass: 400, rate: rate)
        var filteredIndex = -1, filteredSample = 0.0
        for k in 0..<1200 {
            var b = [UInt8](repeating: 0, count: 6)
            for j in 0..<3 { b[3 + j] = UInt8(min(127, (pwv4Scale[j] * Double(pwv6[k * 3 + j])).rounded())) }
            // 2026-09-26 분석 사본 비교: 앞 두 바이트는 색 밴드가 아니라 PCM의 양·음 피크다.
            // 곡 최대값으로 정규화하지 않고 128배 후 0 쪽으로 버린다(음수는 2의 보수).
            if !previewRanges.isEmpty {
                var positive: Float = 0, negative: Float = 0
                var lowPeak = 0.0
                for index in previewRanges[k] {
                    let sample = mono[index]
                    positive = max(positive, sample)
                    negative = min(negative, sample)
                    // 1200샘플보다 짧으면 창이 겹치므로 필터에는 샘플을 한 번만 넣는다.
                    if index != filteredIndex {
                        filteredSample = previewLowpass.step(Double(sample))
                        filteredIndex = index
                    }
                    lowPeak = max(lowPeak, abs(filteredSample))
                }
                b[0] = UInt8(min(127, Int(positive * 128)))
                b[1] = UInt8(bitPattern: Int8(clamping: Int(negative * 128)))
                // 2026-09-26 probe 3곡: 세 번째 바이트는 400Hz 2차 저역 통과 피크(정규화·release 없음).
                b[2] = UInt8(min(127, Int(lowPeak * 128)))
            }
            pwv4.replaceSubrange(k * 6..<k * 6 + 6, with: b)
        }
        return RekordboxWaveforms(pwv3: pwv3, pwv5: pwv5, pwv7: pwv7, gains: gains, pwav: pwav, pwv2: pwv2, pwv6: pwv6, pwv4: pwv4)
    }

    /// 음원을 모노 `(L + R) / 2`로 읽는다. 앞에 `leadingSeconds`, 끝에 `trailingFrames`만큼 무음을 붙인다(rekordbox 시간축·길이).
    /// rekordbox는 16비트로 디코딩해 ±1을 넘는 샘플이 잘린다. 잘라 두지 않으면 곡 최대가 커져 높이가 한 칸씩 낮아졌다(AAC).
    public static func decodeMono(url: URL, leadingSeconds: Double, trailingFrames: Int = 0) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        let lead = max(0, Int((leadingSeconds * rate).rounded()))
        var mono = [Float](repeating: 0, count: lead)
        mono.reserveCapacity(lead + Int(file.length) + trailingFrames)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw DJCError.invalidAnalysisFile(String(ui: "버퍼")) }
        while file.framePosition < file.length {
            // 압축 음원은 알려 준 길이가 실제보다 조금 길 수 있다: 이미 읽은 뒤 끝에서 실패하면 거기까지.
            do { try file.read(into: buffer, frameCount: chunk) } catch where mono.count > lead { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += min(1, max(-1, data[ch][i])) }
                mono.append(sum / Float(channels))
            }
        }
        mono.append(contentsOf: repeatElement(0, count: max(0, trailingFrames)))
        return (mono, rate)
    }

    /// rekordbox가 읽는 길이·시간축 그대로 모노로 읽는다.
    public static func decodeForRekordbox(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        try decodeMono(url: url, leadingSeconds: RekordboxTimeline.predictedOffset(url: url),
                       trailingFrames: RekordboxTimeline.predictedTrailingFrames(url: url))
    }

    public static func analyze(url: URL) throws -> RekordboxWaveforms {
        let (samples, rate) = try decodeForRekordbox(url: url)
        return analyze(mono: samples, sampleRate: rate)
    }

    // MARK: - 비교

    /// 같은 위치의 바이트 오차. 길이가 다르면 없는 꼬리도 일치율 분모에 넣는다.
    public struct Comparison: Sendable, Codable {
        public let referenceBytes: Int
        public let generatedBytes: Int
        public let comparedBytes: Int
        public let matchingPercent: Double?
        public let meanAbsoluteError: Double?
        public let maxAbsoluteError: Int?
    }

    public static func compare(reference: [UInt8], generated: [UInt8]) -> Comparison {
        let count = min(reference.count, generated.count)
        let total = max(reference.count, generated.count)
        var matching = 0, sum = 0, largest = 0
        for i in 0..<count {
            let difference = abs(Int(reference[i]) - Int(generated[i]))
            if difference == 0 { matching += 1 }
            sum += difference
            largest = max(largest, difference)
        }
        return Comparison(referenceBytes: reference.count, generatedBytes: generated.count, comparedBytes: count,
                          matchingPercent: total == 0 ? nil : 100 * Double(matching) / Double(total),
                          meanAbsoluteError: count == 0 ? nil : Double(sum) / Double(count),
                          maxAbsoluteError: count == 0 ? nil : largest)
    }

    // MARK: - 태그 바이트

    static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
    static func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
    static func be16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

    /// `fourcc · len_header · len_tag · 본문`
    static func section(_ fourcc: String, headerLength: UInt32, _ payload: [UInt8]) -> Data {
        Data(Array(fourcc.utf8) + be32(headerLength) + be32(UInt32(12 + payload.count)) + payload)
    }

    /// PWAV·PWV2: `len_data · 0x00010000 · data`(머리 20바이트)
    static func preview(_ fourcc: String, _ data: [UInt8]) -> Data {
        section(fourcc, headerLength: 0x14, be32(UInt32(data.count)) + be32(0x0001_0000) + data)
    }

    /// PWV3·PWV5·PWV4·PWV7: `칸 바이트 수 · 칸 수 · 모르는 값 · data`(머리 24바이트)
    static func detail(_ fourcc: String, entryBytes: UInt32, unknown: UInt32, _ data: [UInt8]) -> Data {
        section(fourcc, headerLength: 0x18, be32(entryBytes) + be32(UInt32(data.count) / entryBytes) + be32(unknown) + data)
    }

    public var pwavTag: Data { Self.preview("PWAV", pwav) }
    public var pwv2Tag: Data { Self.preview("PWV2", pwv2) }
    public var pwv3Tag: Data { Self.detail("PWV3", entryBytes: 1, unknown: 0x0096_0000, pwv3) }
    public var pwv5Tag: Data { Self.detail("PWV5", entryBytes: 2, unknown: 0x0096_0305, pwv5.flatMap(Self.be16)) }
    public var pwv4Tag: Data { Self.detail("PWV4", entryBytes: 6, unknown: 0, pwv4) }
    public var pwv7Tag: Data { Self.detail("PWV7", entryBytes: 3, unknown: 0x0096_0000, pwv7) }
    public var pwv6Tag: Data { Self.section("PWV6", headerLength: 0x14, Self.be32(3) + Self.be32(UInt32(pwv6.count / 3)) + pwv6) }
    public var pwvcTag: Data { Self.section("PWVC", headerLength: 0x0E, Self.be16(0) + gains.flatMap(Self.be16)) }

    /// 태그에서 칸 데이터만 꺼낸다(비교용). 칸 데이터는 태그 머리(len_header) 바로 뒤에 있다.
    public static func body(of tag: Data) -> [UInt8] {
        let bytes = [UInt8](tag)
        guard bytes.count >= 12 else { return [] }
        return Array(bytes[min(bytes.count, Int(AnlzFile.u32(bytes, 4)))...])
    }

    // MARK: - 파일 조립

    /// 빈 큐 목록(PCO2). `kind` 1 = 핫큐, 0 = 메모리 큐. rekordbox 7.2 파일에서 본 모양 그대로.
    static func emptyPCO2(kind: UInt32) -> Data { section("PCO2", headerLength: 0x14, be32(kind) + be32(0)) }

    /// 곡의 .DAT(경로·큐 목록 태그)를 바탕으로 rekordbox 7.2와 같은 순서의 .EXT·.2EX를 만든다.
    /// - .EXT: PPTH · PWV3 · PCOB(핫) · PCOB(메모리) · PCO2(핫) · PCO2(메모리) · PQT2(빈 형태) · PWV5 · PWV4
    /// - .2EX: PPTH · PWV7 · PWV6 · PWVC
    /// 프레이즈(PSSI)·보컬(PVDI)은 만들지 못해 넣지 않는다.
    /// `extTail`: .EXT 끝에 덧붙일 태그(FLAC의 PVB2)
    public func files(dat: AnlzFile, extTail: [Data] = []) throws -> (ext: Data, twoEx: Data) {
        guard let ppth = dat.tag("PPTH") else { throw DJCError.invalidAnalysisFile(String(ui: ".DAT에 경로(PPTH)가 없음")) }
        let pcob = dat.tags.filter { $0.fourcc == "PCOB" }.map(\.bytes)
        guard pcob.count == 2 else { throw DJCError.invalidAnalysisFile(String(ui: ".DAT의 큐 목록(PCOB)이 두 개가 아님")) }
        let ext = AnlzFile(header: dat.header, tags: [ppth.bytes, pwv3Tag, pcob[0], pcob[1], Self.emptyPCO2(kind: 1), Self.emptyPCO2(kind: 0),
                                                       BeatGridTags.pqt2([], unknown: 0), pwv5Tag, pwv4Tag] + extTail)
        let twoEx = AnlzFile(header: dat.header, tags: [ppth.bytes, pwv7Tag, pwv6Tag, pwvcTag])
        return (ext.serialized(), twoEx.serialized())
    }
}

extension AnlzFile {
    /// 머리와 태그 바이트로 만든다(태그 이름은 바이트 앞 4자).
    init(header: Data, tags: [Data]) {
        self.header = header
        self.tags = tags.map { Tag(fourcc: String(decoding: $0.prefix(4), as: UTF8.self), bytes: $0) }
    }
}
