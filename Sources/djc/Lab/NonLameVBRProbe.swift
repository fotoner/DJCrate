import Foundation
import RekordboxKit

extension TrackLab {
    /// 미확인 후보식을 비교할 뿐 AudioFacts의 쓰기 허용 조건은 바꾸지 않는다.
    static func nonLameVBRCheck(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(path: String, dat: String, bitRate: Int)] = []
        try db.query("SELECT FolderPath, AnalysisDataPath, BitRate FROM djmdContent WHERE rb_local_deleted = 0 AND FileType = 1 AND Analysed = 105") {
            rows.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2) ?? 0))
        }
        var results = Set<String>()
        var skipped = Set<String>()
        for row in rows {
            let url = URL(filePath: row.path)
            guard FileManager.default.fileExists(atPath: row.path) else { skipped.insert("음원 누락 있음"); continue }
            let header = RekordboxTimeline.mp3Header(url: url)
            guard !header.contains("LAME") else { continue }
            guard let frames = SeekInfo.mp3Frames(url: url) else { skipped.insert("MP3 프레임 판독 실패 있음"); continue }
            guard frames.isVariableBitRate else { continue }
            let counted = SeekInfo.countedMp3Offsets(frames, url: url)
            guard counted.count > 8, let first = counted.first,
                  let datURL = RekordboxShare.analysisURL(row.dat), let dat = try? AnlzFile(url: datURL),
                  let pvbr = dat.tag("PVBR") else { skipped.insert("비LAME VBR 분석 파일 또는 프레임 누락 있음"); continue }
            var candidate = AudioFacts.read(url: url)
            candidate.pvbrEntries = (0..<400).map { UInt32(counted[max(0, ($0 + 1) * counted.count / 400 - 8)] - first) }
            let same = TrackAnalysisFiles.pvbr(candidate) == pvbr.bytes
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            func bitrate(at offset: Int) -> Int {
                guard offset + 3 < data.count else { return -1 }
                let table = (data[offset + 1] >> 3) & 3 == 3
                    ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
                    : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
                return table[Int(data[offset + 2] >> 4)]
            }
            let rates = Set(counted.map { bitrate(at: $0) }).sorted()
            let average = frames.xingBytes.map { Double($0) * 8 * Double(frames.sampleRate) / Double(counted.count * frames.samplesPerFrame) / 1000 }
            var wave = "비교 불가"
            if let ext = try? AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT")),
               let tag = ext.tag("PWV3"), tag.bytes.count >= 24 {
                let expected = Int(ceil(Double(counted.count * frames.samplesPerFrame) * 150 / Double(frames.sampleRate)))
                let stored = tag.bytes[16..<20].reduce(0) { ($0 << 8) | Int($1) }
                wave = String(stored - expected)
            } else { skipped.insert("비LAME VBR 파형 누락 있음") }
            // 같은 관찰은 합쳐 곡 수·식별자·경로를 출력하지 않는다.
            results.insert("\(header) · BitRate rb=\(row.bitRate) 정보프레임=\(bitrate(at: frames.offsets[0])) 첫소리=\(bitrate(at: first)) 프레임범위=\(rates.first ?? -1)…\(rates.last ?? -1) Xing평균=\(average.map { String(format: "%.3f", $0) } ?? "없음") · PVBR=\(same ? "같음" : "다름") · PWV3길이차=\(wave)")
        }
        for line in results.sorted() { print(line) }
        for line in skipped.sorted() { print("제외: \(line)") }
        print(results.isEmpty ? "비교 가능한 비LAME VBR 표본 없음(일치로 세지 않음)" : "읽기 전용 후보식 비교 완료(쓰기 차단 유지)")
    }
}
