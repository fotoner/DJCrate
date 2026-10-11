import DJCAnalysis
import DJCDomain
import Foundation
import RekordboxKit

enum PhraseEvaluation {
    struct Options {
        let corpus: URL
        let limit: Int
        let output: URL?

        init(_ args: [String]) throws {
            var values: [String: String] = [:]
            var i = 1
            while i < args.count {
                let flag = args[i]
                guard ["--corpus", "--limit", "--out"].contains(flag), values[flag] == nil,
                      i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw UsageError() }
                values[flag] = args[i + 1]; i += 2
            }
            guard let path = values["--corpus"], !path.isEmpty,
                  let count = Int(values["--limit"] ?? "16"), (1...1000).contains(count) else { throw UsageError() }
            corpus = URL(filePath: path); limit = count
            output = values["--out"].map { URL(filePath: $0) }
        }
    }

    struct Metrics: Encodable {
        var reference: Int
        var predicted: Int
        var matched: Int
        var precision: Double? { predicted > 0 ? Double(matched) / Double(predicted) : nil }
        var recall: Double? { reference > 0 ? Double(matched) / Double(reference) : nil }
        var f1: Double? { reference + predicted > 0 ? 2 * Double(matched) / Double(reference + predicted) : nil }

        enum CodingKeys: String, CodingKey { case reference, predicted, matched, precision, recall, f1 }
        func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(reference, forKey: .reference); try box.encode(predicted, forKey: .predicted)
            try box.encode(matched, forKey: .matched); try box.encode(precision, forKey: .precision)
            try box.encode(recall, forKey: .recall); try box.encode(f1, forKey: .f1)
        }
    }

    struct Comparison: Encodable {
        let exact: Metrics
        let withinOneBar: Metrics
        let outsideReference: Int
    }

    struct Row: Encodable {
        let sample: Int
        var mood: Int?
        var comparison: Comparison?
        var failure: String?
    }

    struct Report: Encodable {
        let rows: [Row]
        let exact: Metrics
        let withinOneBar: Metrics
    }

    /// 첫 섹션 시작과 PSSI 마지막 끝은 평가하지 않는다. 내부 경계만 공통 그리드의 가까운 마디로 반올림한다.
    static func compare(phrase: PhraseStructure, grid: [BeatGridTags.Beat], sectionStarts: [Double], offset: Double) throws -> Comparison {
        let invalid = DJCError.invalidAnalysisFile("PSSI·4박 그리드·섹션 경계가 유효한 사본으로 다시 평가하세요")
        guard grid.count >= 2, let first = phrase.entries.first, phrase.endBeat <= grid.count,
              !sectionStarts.isEmpty, sectionStarts.allSatisfy(\.isFinite), offset.isFinite,
              zip(sectionStarts, sectionStarts.dropFirst()).allSatisfy({ $0 <= $1 }),
              grid.allSatisfy({ (1...4).contains($0.number) && $0.time.isFinite }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.time < $1.time && $1.number == $0.number % 4 + 1 })
        else { throw invalid }
        let phase = Double(grid[0].number - 1)
        func bar(_ index: Double) -> Int { Int(((index + phase) / 4).rounded()) }
        let reference = phrase.entries.dropFirst().map { bar(Double($0.beat - 1)) }
        let start = grid[first.beat - 1].time / 1000, end = grid[phrase.endBeat - 1].time / 1000
        var predicted: [Int] = [], outside = 0
        for time in sectionStarts.dropFirst().map({ $0 + offset }) {
            guard time > start, time < end else { outside += 1; continue }
            let ms = time * 1000
            var lo = 0, hi = grid.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if grid[mid].time <= ms { lo = mid } else { hi = mid }
            }
            let position = Double(lo) + (ms - grid[lo].time) / (grid[hi].time - grid[lo].time)
            predicted.append(bar(position))
        }
        func match(_ tolerance: Int) -> Metrics {
            // 왼쪽부터 서로 가장 이른 가능한 경계를 짝지으면 구간 허용오차의 최대 일대일 매칭이 된다.
            var r = 0, p = 0, matched = 0
            while r < reference.count && p < predicted.count {
                if predicted[p] < reference[r] - tolerance { p += 1 }
                else if reference[r] < predicted[p] - tolerance { r += 1 }
                else { matched += 1; r += 1; p += 1 }
            }
            return Metrics(reference: reference.count, predicted: predicted.count, matched: matched)
        }
        return Comparison(exact: match(0), withinOneBar: match(1), outsideReference: outside)
    }

    /// sample-번호/ 아래의 audio.확장자, ANLZ0000.DAT·EXT 사본만 읽고 캐시를 쓰지 않는다.
    static func evaluate(corpus: URL, limit: Int,
                         analyze: (URL) async throws -> PartAnalysis = { try await PartAnalyzer.analyze(fileAt: $0) }) async throws -> Report {
        let fm = FileManager.default
        let folders: [URL]
        do {
            folders = try fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.lastPathComponent.hasPrefix("sample-") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { throw DJCError.invalidAnalysisFile("읽을 수 있는 분석·음원 사본 폴더를 지정하세요") }
        guard !folders.isEmpty else { throw DJCError.invalidAnalysisFile("sample-번호 폴더에 음원·분석 사본을 넣고 다시 평가하세요") }
        var rows: [Row] = []
        for (index, folder) in folders.prefix(limit).enumerated() {
            try Task.checkCancellation()
            var row = Row(sample: index + 1)
            do {
                let ext = try AnlzFile(url: folder.appending(path: "ANLZ0000.EXT"))
                guard let tag = ext.tag("PSSI") else {
                    row.failure = "PSSI가 없어 프레이즈 분석이 끝난 사본을 준비하세요"
                    rows.append(row); continue
                }
                let phrase = try PhraseStructure(data: tag.bytes)
                row.mood = phrase.mood
                let dat = try AnlzFile(url: folder.appending(path: "ANLZ0000.DAT"))
                guard let pqtz = dat.tag("PQTZ") else { throw UsageError() }
                let grid = BeatGridTags.decode(pqtz: pqtz.bytes, pqt2: ext.tag("PQT2")?.bytes).beats
                let audio = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.deletingPathExtension().lastPathComponent == "audio" }
                guard audio.count == 1 else { throw UsageError() }
                let analysis = try await analyze(audio[0])
                row.comparison = try compare(phrase: phrase, grid: grid, sectionStarts: analysis.sections.map(\.start),
                                             offset: RekordboxTimeline.predictedOffset(url: audio[0]))
            } catch is CancellationError { throw CancellationError() }
            catch {
                // 파일·디코더 오류에는 음원 경로가 포함될 수 있어 오류 원문을 남기지 않는다.
                row.failure = "사본의 음원 한 개·PSSI·4박 그리드·섹션 분석을 확인한 뒤 다시 평가하세요"
            }
            rows.append(row)
        }
        func total(_ key: KeyPath<Comparison, Metrics>) -> Metrics {
            rows.compactMap(\.comparison).map { $0[keyPath: key] }.reduce(Metrics(reference: 0, predicted: 0, matched: 0)) {
                Metrics(reference: $0.reference + $1.reference, predicted: $0.predicted + $1.predicted, matched: $0.matched + $1.matched)
            }
        }
        return Report(rows: rows, exact: total(\.exact), withinOneBar: total(\.withinOneBar))
    }

    static func run(_ args: [String]) async throws {
        let options = try Options(args)
        let report = try await evaluate(corpus: options.corpus, limit: options.limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let output = options.output {
            do { try data.write(to: output, options: .withoutOverwriting) }
            catch { throw DJCError.invalidAnalysisFile("결과를 저장할 수 없어 기존 파일과 겹치지 않는 출력 위치를 지정하세요") }
        }
        print(String(decoding: data, as: UTF8.self))
        guard report.rows.allSatisfy({ $0.failure == nil }) else {
            throw DJCError.invalidAnalysisFile("실패한 익명 표본의 사본을 확인한 뒤 다시 평가하세요")
        }
    }
}
