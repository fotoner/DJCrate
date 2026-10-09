import Foundation

/// 기준선 JPEG 인코더(YCbCr 4:2:0, 허프만 표 최적화). rekordbox 7.2.18 아트워크와 같은 머리를 쓴다:
/// SOI · APP0(JFIF 1.01, 비율 1:1) · DQT 둘 · SOF0 · DHT 넷(DC0·AC0·DC1·AC1) · SOS · EOI.
///
/// macOS ImageIO는 EXIF·APP13·재시작 표식을 붙이고 품질 표가 달라 직접 만든다.
/// 품질 표는 JPEG 표준(ITU T.81 부록 K.1) 예시 표를 IJG 품질 척도로 늘린 값, 허프만 최적화는 부록 K.2 절차를 따른다.
/// DCT·색 변환은 부동소수라 같은 화소라도 rekordbox(libjpeg 정수 DCT로 보임)와 바이트가 같지는 않다.
enum ArtworkJPEG {
    static func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) -> Data {
        let tables = [quantization(luminanceBase, quality: quality), quantization(chrominanceBase, quality: quality)]
        let blocks = quantizedBlocks(rgb: rgb, width: width, height: height, tables: tables)
        // 1차: 기호 빈도 → 표, 2차: 부호화
        var counter = SymbolCounter()
        walk(blocks) { table, symbol, _, _ in counter.count(table, symbol) }
        let huffman = (0..<4).map { HuffmanTable.optimal(frequencies: counter.frequencies[$0]) }
        var writer = BitWriter()
        walk(blocks) { table, symbol, bits, value in
            let code = huffman[table].codes[symbol]
            writer.write(code.code, count: code.length)
            if bits > 0 { writer.write(value, count: bits) }
        }
        writer.flush()

        var out = Data([0xFF, 0xD8])
        func segment(_ marker: UInt8, _ body: [UInt8]) {
            out += [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]
            out += body
        }
        segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        for (id, table) in tables.enumerated() { segment(0xDB, [UInt8(id)] + zigzag.map { UInt8(table[$0]) }) }
        segment(0xC0, [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3,
                       1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        // DC0 · AC0 · DC1 · AC1 (표 번호 = 성분, 부류)
        for (index, header) in [(0, 0x00), (1, 0x10), (2, 0x01), (3, 0x11)] as [(Int, UInt8)] {
            segment(0xC4, [header] + huffman[index].bits + huffman[index].values)
        }
        segment(0xDA, [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0])
        out += writer.bytes
        out += [0xFF, 0xD9]
        return out
    }

    // MARK: - 표

    /// 부록 K.1 휘도·색차 예시 표(자연 순서)
    static let luminanceBase = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
                                14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
                                18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                                49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    static let chrominanceBase = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
                                  24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99]
        + [Int](repeating: 99, count: 32)
    /// 지그재그 순서 k번째 계수의 자연 순서 위치
    static let zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
                         35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

    /// IJG 품질 척도(50 미만 5000/q, 이상 200−2q %)
    static func quantization(_ base: [Int], quality: Int) -> [Int] {
        let q = min(max(quality, 1), 100)
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        return base.map { min(max(($0 * scale + 50) / 100, 1), 255) }
    }

    // MARK: - 블록

    /// 양자화한 블록들(지그재그 순서 계수 64개씩)과 블록마다의 성분(0 = Y, 1 = Cb, 2 = Cr). MCU(16×16)마다 Y 넷, Cb, Cr 순서.
    struct Blocks {
        var components: [Int]
        var coefficients: [Int]
    }

    static func quantizedBlocks(rgb: [UInt8], width: Int, height: Int, tables: [[Int]]) -> Blocks {
        // MCU 배수로 늘리며 가장자리 화소를 되풀이한다
        let paddedWidth = (width + 15) / 16 * 16, paddedHeight = (height + 15) / 16 * 16
        let count = paddedWidth * paddedHeight
        var planes = [Int](repeating: 0, count: count * 3)
        planes.withUnsafeMutableBufferPointer { out in
            rgb.withUnsafeBufferPointer { rgb in
                func sample(_ value: Double) -> Int { min(max(Int(value.rounded()), 0), 255) }
                for y in 0..<paddedHeight {
                    let row = min(y, height - 1) * width
                    for x in 0..<paddedWidth {
                        let i = (row + min(x, width - 1)) * 3, o = y * paddedWidth + x
                        let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
                        // JFIF YCbCr
                        out[o] = sample(0.299 * r + 0.587 * g + 0.114 * b)
                        out[count + o] = sample(-0.168736 * r - 0.331264 * g + 0.5 * b + 128)
                        out[2 * count + o] = sample(0.5 * r - 0.418688 * g - 0.081312 * b + 128)
                    }
                }
            }
        }
        // 색차는 2×2 평균(반올림 치우침을 열마다 1·2로 번갈아)
        let chromaWidth = paddedWidth / 2, chromaHeight = paddedHeight / 2, chromaCount = chromaWidth * chromaHeight
        var chroma = [Int](repeating: 0, count: chromaCount * 2)
        chroma.withUnsafeMutableBufferPointer { out in
            planes.withUnsafeBufferPointer { planes in
                for c in 0..<2 {
                    let source = (c + 1) * count
                    for y in 0..<chromaHeight {
                        for x in 0..<chromaWidth {
                            let top = source + 2 * y * paddedWidth + 2 * x, bottom = top + paddedWidth
                            out[c * chromaCount + y * chromaWidth + x] = (planes[top] + planes[top + 1] + planes[bottom] + planes[bottom + 1] + 1 + x % 2) >> 2
                        }
                    }
                }
            }
        }
        let mcus = (paddedWidth / 16) * (paddedHeight / 16)
        var components: [Int] = []
        components.reserveCapacity(mcus * 6)
        var coefficients = [Int](repeating: 0, count: mcus * 6 * 64)
        var scratch = [Double](repeating: 0, count: 128)
        coefficients.withUnsafeMutableBufferPointer { out in
            planes.withUnsafeBufferPointer { planes in
                chroma.withUnsafeBufferPointer { chroma in
                    scratch.withUnsafeMutableBufferPointer { scratch in
                        var n = 0
                        for my in 0..<paddedHeight / 16 {
                            for mx in 0..<paddedWidth / 16 {
                                for (dx, dy) in [(0, 0), (8, 0), (0, 8), (8, 8)] {
                                    transform(planes, start: (my * 16 + dy) * paddedWidth + mx * 16 + dx, stride: paddedWidth,
                                              table: tables[0], into: out, at: n * 64, scratch: scratch)
                                    components.append(0)
                                    n += 1
                                }
                                for c in 0..<2 {
                                    transform(chroma, start: c * chromaCount + my * 8 * chromaWidth + mx * 8, stride: chromaWidth,
                                              table: tables[1], into: out, at: n * 64, scratch: scratch)
                                    components.append(c + 1)
                                    n += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        return Blocks(components: components, coefficients: coefficients)
    }

    /// cos 표: `[u * 8 + x]` = C(u)/2 · cos((2x+1)uπ/16)
    static let cosines: [Double] = (0..<64).map { i in
        let u = i / 8, x = i % 8
        return (u == 0 ? 1 / 2.0.squareRoot() : 1) / 2 * cos(Double(2 * x + 1) * Double(u) * .pi / 16)
    }

    /// 8×8 블록 → 2차원 DCT(부록 A.3.3) → 양자화(반올림) → 지그재그 순서로 `out[at...]`에
    static func transform(_ plane: UnsafeBufferPointer<Int>, start: Int, stride: Int, table: [Int],
                          into out: UnsafeMutableBufferPointer<Int>, at offset: Int, scratch: UnsafeMutableBufferPointer<Double>) {
        cosines.withUnsafeBufferPointer { cosines in
            table.withUnsafeBufferPointer { table in
                // 가로(scratch 0..<64) → 세로(scratch 64..<128, 자연 순서)
                for row in 0..<8 {
                    let base = start + row * stride
                    for u in 0..<8 {
                        var sum = 0.0
                        for col in 0..<8 { sum += cosines[u * 8 + col] * Double(plane[base + col] - 128) }
                        scratch[row * 8 + u] = sum
                    }
                }
                for u in 0..<8 {
                    for v in 0..<8 {
                        var sum = 0.0
                        for row in 0..<8 { sum += cosines[v * 8 + row] * scratch[row * 8 + u] }
                        scratch[64 + v * 8 + u] = sum / Double(table[v * 8 + u])
                    }
                }
                for k in 0..<64 { out[offset + k] = Int(scratch[64 + zigzag[k]].rounded(.toNearestOrAwayFromZero)) }
            }
        }
    }

    // MARK: - 허프만

    /// 블록을 차례로 부호화 기호로 푼다: (표 번호 0~3, 기호, 덧붙일 비트 수, 그 값)
    static func walk(_ blocks: Blocks, _ emit: (Int, Int, Int, Int) -> Void) {
        var predictors = [0, 0, 0]
        for (index, component) in blocks.components.enumerated() {
            let base = index * 64
            let chroma = component == 0 ? 0 : 1
            let dcTable = chroma * 2, acTable = chroma * 2 + 1
            let dc = blocks.coefficients[base]
            let diff = dc - predictors[component]
            predictors[component] = dc
            let size = magnitude(diff)
            emit(dcTable, size, size, bits(diff, size))
            var run = 0
            for k in 1..<64 {
                let value = blocks.coefficients[base + k]
                if value == 0 { run += 1; continue }
                while run > 15 { emit(acTable, 0xF0, 0, 0); run -= 16 }
                let size = magnitude(value)
                emit(acTable, run << 4 | size, size, bits(value, size))
                run = 0
            }
            if run > 0 { emit(acTable, 0x00, 0, 0) }
        }
    }

    /// 값의 크기 부류(절댓값의 비트 수)
    static func magnitude(_ value: Int) -> Int {
        var v = abs(value), n = 0
        while v > 0 { n += 1; v >>= 1 }
        return n
    }

    /// 부류 뒤에 붙는 비트: 음수는 (값 − 1)의 아래 비트
    static func bits(_ value: Int, _ size: Int) -> Int {
        value >= 0 ? value : (value - 1) & ((1 << size) - 1)
    }

    struct SymbolCounter {
        var frequencies = [[Int]](repeating: [Int](repeating: 0, count: 257), count: 4)
        mutating func count(_ table: Int, _ symbol: Int) { frequencies[table][symbol] += 1 }
    }

    struct HuffmanTable {
        /// 길이 1~16인 부호 수
        var bits: [UInt8]
        /// 부호 길이 순서의 기호
        var values: [UInt8]
        /// 기호 → (부호, 길이)
        var codes: [(code: Int, length: Int)]

        /// 부록 K.2: 빈도로 부호 길이를 정하고(K.1), 16비트로 줄이고(K.3), 길이 순서로 기호를 늘어놓는다(K.4).
        /// 모든 비트가 1인 부호가 생기지 않도록 기호 256을 빈도 1로 넣었다가 뺀다.
        static func optimal(frequencies source: [Int]) -> HuffmanTable {
            var freq = source
            freq[256] = 1
            var codeSize = [Int](repeating: 0, count: 257)
            var others = [Int](repeating: -1, count: 257)
            while true {
                // 가장 작은 빈도 둘(같으면 뒤 기호)
                var c1 = -1, c2 = -1, v1 = Int.max, v2 = Int.max
                for i in 0...256 where freq[i] > 0 && freq[i] <= v1 { v1 = freq[i]; c1 = i }
                for i in 0...256 where freq[i] > 0 && freq[i] <= v2 && i != c1 { v2 = freq[i]; c2 = i }
                if c2 < 0 { break }
                freq[c1] += freq[c2]
                freq[c2] = 0
                codeSize[c1] += 1
                while others[c1] >= 0 { c1 = others[c1]; codeSize[c1] += 1 }
                others[c1] = c2
                codeSize[c2] += 1
                while others[c2] >= 0 { c2 = others[c2]; codeSize[c2] += 1 }
            }
            var counts = [Int](repeating: 0, count: 33)
            for size in codeSize where size > 0 { counts[size] += 1 }
            for i in stride(from: 32, to: 16, by: -1) {
                while counts[i] > 0 {
                    var j = i - 2
                    while counts[j] == 0 { j -= 1 }
                    counts[i] -= 2
                    counts[i - 1] += 1
                    counts[j + 1] += 2
                    counts[j] -= 1
                }
            }
            var longest = 16
            while counts[longest] == 0 { longest -= 1 }
            counts[longest] -= 1
            var values: [UInt8] = []
            for size in 1...32 { for symbol in 0...255 where codeSize[symbol] == size { values.append(UInt8(symbol)) } }
            // 부록 C: 길이 순서로 부호를 매긴다
            var codes = [(code: Int, length: Int)](repeating: (0, 0), count: 256)
            var code = 0, k = 0
            for length in 1...16 {
                for _ in 0..<counts[length] {
                    codes[Int(values[k])] = (code, length)
                    code += 1
                    k += 1
                }
                code <<= 1
            }
            return HuffmanTable(bits: (1...16).map { UInt8(counts[$0]) }, values: values, codes: codes)
        }
    }

    /// 비트를 바이트로 모은다(0xFF 뒤에는 0x00을 넣고, 끝은 1로 채운다).
    struct BitWriter {
        var bytes: [UInt8] = []
        var buffer = 0
        var count = 0

        mutating func write(_ value: Int, count length: Int) {
            buffer = buffer << length | (value & ((1 << length) - 1))
            count += length
            while count >= 8 {
                let byte = UInt8((buffer >> (count - 8)) & 0xFF)
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0) }
                count -= 8
            }
            buffer &= (1 << count) - 1
        }

        mutating func flush() {
            if count > 0 { write((1 << (8 - count)) - 1, count: 8 - count) }
        }
    }
}
