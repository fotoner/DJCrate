import DJCAnalysis
import DJCDomain
import Foundation
import RekordboxKit
import Testing
@testable import djc

/// 프레이즈 비교 실험(`djc lab phrase-eval`)의 개인정보·입력 보존. 알고리즘 시험은 두지 않는다(연구 도구)
@Suite("프레이즈 비교 실험")
struct PhraseEvaluationTests {
    func tag(starts: [Int] = [1, 17, 33], end: Int = 49) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32 + starts.count * 24)
        bytes.replaceSubrange(0..<4, with: "PSSI".utf8)
        func put(_ value: Int, _ offset: Int, _ width: Int = 2) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (width - i - 1))) }
        }
        put(32, 4, 4); put(bytes.count, 8, 4); put(24, 12, 4)
        put(starts.count, 16); put(2, 18); put(end, 26); bytes[30] = 4
        for (i, beat) in starts.enumerated() {
            put(i + 1, 32 + 24 * i); put(beat, 34 + 24 * i); put(i + 1, 36 + 24 * i)
        }
        return Data(bytes)
    }

    func grid() -> [BeatGridTags.Beat] {
        (0..<64).map { .init(number: $0 % 4 + 1, bpm100: 12_000, time: Double($0) * 500) }
    }

    func anlz(_ tags: [Data]) -> Data {
        var data = Data("PMAI".utf8)
        for value in [UInt32(12), UInt32(12 + tags.reduce(0) { $0 + $1.count })] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        for tag in tags { data.append(tag) }
        return data
    }

    @Test func 코퍼스_결과는_익명이며_누락을_분리하고_입력을_보존한다() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "phrase-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 1...2 {
            let folder = root.appending(path: "sample-\(i)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try anlz(i == 1 ? [tag()] : []).write(to: folder.appending(path: "ANLZ0000.EXT"))
            try anlz([BeatGridTags.pqtz(grid())]).write(to: folder.appending(path: "ANLZ0000.DAT"))
            try Data().write(to: folder.appending(path: "audio.wav"))
        }
        let before = try Data(contentsOf: root.appending(path: "sample-1/ANLZ0000.EXT"))
        let json = """
        {"duration":32,"beats":[],"bars":[],"sections":[{"start":0,"end":8},{"start":8,"end":16},{"start":16,"end":32}],
        "segments":[],"phrases":[],"keys":[],"pace":[],"vocal":[],"drum":[],"loudness":[]}
        """
        let report = try await PhraseEvaluation.evaluate(corpus: root, limit: 2) { _ in
            try JSONDecoder().decode(PartAnalysis.self, from: Data(json.utf8))
        }
        #expect(report.rows.count == 2 && report.rows[1].failure?.contains("PSSI") == true)
        #expect(report.exact.reference == 2 && report.exact.matched == 2)
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!output.contains(root.path) && !output.contains("audio.wav") && !output.contains("PMAI"))
        #expect(output.contains("precision"))
        #expect(try Data(contentsOf: root.appending(path: "sample-1/ANLZ0000.EXT")) == before)
        let failed = try await PhraseEvaluation.evaluate(corpus: root, limit: 1) { _ in
            throw NSError(domain: "민감한_음원_경로", code: 1)
        }
        #expect(failed.rows[0].failure != nil)
        #expect(!String(decoding: try JSONEncoder().encode(failed), as: UTF8.self).contains("민감한"))
        #expect(failed.exact.f1 == nil)
    }
}
