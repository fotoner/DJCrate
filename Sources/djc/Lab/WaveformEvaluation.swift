import DJCDomain
import Foundation
import RekordboxKit

extension AudioLab {
    struct WaveformEvaluationRow: Codable {
        var sample: Int
        var format: String
        var genreGroup: Int?
        var metrics: [String: RekordboxWaveforms.Comparison] = [:]
        var missingTags: [String] = []
        var failure: String?
    }

    static let waveformTags = ["PWAV", "PWV2", "PWV3", "PWV4", "PWV5", "PWV6", "PWV7", "PWVC"]

    /// 사본 폴더 형식: sample-01/audio.wav, ANLZ0000.DAT·EXT·2EX. --copy-to로 같은 입력을 보존할 수 있다.
    static func waveformEval(_ args: [String]) async throws {
        let fm = FileManager.default
        let limit = Int(value(after: "--limit", in: args) ?? "12") ?? 0
        guard limit > 0 else { throw UsageError() }
        let corpus = value(after: "--corpus", in: args), copyTo = value(after: "--copy-to", in: args)
        guard corpus == nil || (copyTo == nil && !args.contains("--db") && !args.contains("--title")
            && !args.contains("--exclude-title")) else { throw UsageError() }
        let root = (corpus ?? copyTo).map { URL(filePath: $0) }
            ?? fm.temporaryDirectory.appending(path: "djc-waveform-\(UUID().uuidString)")
        let temporary = corpus == nil && copyTo == nil
        // 이 명령이 만든 임시 사본만 정리한다.
        defer { if temporary { try? fm.removeItem(at: root) } }
        let dumpRoot = value(after: "--dump-to", in: args).map { URL(filePath: $0) }
        if let dumpRoot {
            guard !fm.fileExists(atPath: dumpRoot.path) else {
                throw DJCError.invalidAnalysisFile("기존 자료를 덮어쓰지 않도록 새 출력 폴더를 지정하세요")
            }
            try fm.createDirectory(at: dumpRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if corpus == nil { try copyWaveformCorpus(args, to: root, limit: limit) }
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("sample-") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rows: [WaveformEvaluationRow] = []
        for (index, folder) in folders.prefix(limit).enumerated() {
            var row = WaveformEvaluationRow(sample: index + 1, format: "unknown")
            do {
                let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                let audioFiles = files.filter { $0.deletingPathExtension().lastPathComponent == "audio" }
                guard audioFiles.count == 1, let audio = audioFiles.first else { throw UsageError() }
                row.format = audio.pathExtension.lowercased()
                if let data = try? Data(contentsOf: folder.appending(path: "metadata.json")),
                   let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    row.genreGroup = metadata["genreGroup"] as? Int
                }
                let ours = try RekordboxWaveforms.analyze(url: audio)
                let generated = ["PWAV": ours.pwavTag, "PWV2": ours.pwv2Tag, "PWV3": ours.pwv3Tag, "PWV4": ours.pwv4Tag,
                                 "PWV5": ours.pwv5Tag, "PWV6": ours.pwv6Tag, "PWV7": ours.pwv7Tag, "PWVC": ours.pwvcTag]
                var reference: [String: Data] = [:]
                for ext in ["DAT", "EXT", "2EX"] {
                    let url = folder.appending(path: "ANLZ0000." + ext)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    for tag in try AnlzFile(url: url).tags where waveformTags.contains(tag.fourcc) { reference[tag.fourcc] = tag.bytes }
                }
                for tag in waveformTags {
                    guard let expected = reference[tag], let actual = generated[tag] else { row.missingTags.append(tag); continue }
                    let a = RekordboxWaveforms.body(of: expected), b = RekordboxWaveforms.body(of: actual)
                    row.metrics[tag] = RekordboxWaveforms.compare(reference: a, generated: b)
                    for (field, values) in waveformFields(tag, a) {
                        row.metrics["\(tag).\(field)"] = RekordboxWaveforms.compare(reference: values, generated: waveformFields(tag, b)[field] ?? [])
                    }
                }
                if let dumpRoot {
                    // 제목·경로(PPTH)를 빼고 비교 대상인 파형 본문만 저장한다.
                    let json = ["reference": reference.mapValues { RekordboxWaveforms.body(of: $0) },
                                "generated": generated.mapValues { RekordboxWaveforms.body(of: $0) }]
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(json).write(to: dumpRoot.appending(path: String(format: "sample-%03d.json", index + 1)), options: .withoutOverwriting)
                }
            } catch {
                // 디코더·파일 오류에는 개인 경로가 들어갈 수 있어 그대로 출력하지 않는다.
                row.failure = "사본의 음원 한 개와 분석 파일 형식을 확인한 뒤 다시 평가하세요"
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw DJCError.invalidAnalysisFile("sample-번호 폴더에 음원·분석 사본을 넣고 다시 평가하세요") }
        print("표본 | 형식 | 태그 | 원본/생성 바이트 | 일치율 | 평균 오차 | 최대 오차")
        for row in rows {
            if let failure = row.failure { print("표본 \(row.sample): \(failure)"); continue }
            for tag in waveformTags {
                guard let m = row.metrics[tag] else { print("표본 \(row.sample) | \(tag) | 원본 태그 없음"); continue }
                func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "N/A" }
                print("\(row.sample) | \(row.format) | \(tag) | \(m.referenceBytes)/\(m.generatedBytes) | \(number(m.matchingPercent)) | \(number(m.meanAbsoluteError)) | \(m.maxAbsoluteError.map(String.init) ?? "N/A")")
            }
        }
        if let out = value(after: "--out", in: args) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(filePath: out), options: .withoutOverwriting)
        }
        if rows.contains(where: { $0.failure != nil }) {
            throw DJCError.invalidAnalysisFile("실패한 표본의 사본을 확인하고 다시 평가하세요")
        }
    }

    /// 포장한 바이트 오차만으로 색 차이를 판단하지 않도록 성분별 값도 남긴다.
    static func waveformFields(_ tag: String, _ bytes: [UInt8]) -> [String: [UInt8]] {
        switch tag {
        case "PWAV", "PWV3":
            return ["height": bytes.map { $0 & 31 }, "white": bytes.map { $0 >> 5 }]
        case "PWV5":
            let words = stride(from: 0, to: max(0, bytes.count - 1), by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            return ["red": words.map { UInt8(($0 >> 13) & 7) }, "green": words.map { UInt8(($0 >> 10) & 7) },
                    "blue": words.map { UInt8(($0 >> 7) & 7) }, "height": words.map { UInt8(($0 >> 2) & 31) }]
        case "PWV4", "PWV6", "PWV7":
            let width = tag == "PWV4" ? 6 : 3
            let names = tag == "PWV4" ? ["positive", "negative", "energy", "low", "mid", "high"] : ["low", "mid", "high"]
            return Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
                let values = stride(from: index, to: bytes.count, by: width).map { bytes[$0] }
                // 음 피크는 부호를 복원해 비교한다(0과 255의 차이는 1).
                return (name, name == "negative" ? values.map { $0 ^ 0x80 } : values)
            })
        default: return [:]
        }
    }

    /// DB는 스냅샷에서, 평가할 음원·분석은 임시 사본에서만 읽는다. 출력에는 제목·경로·ID를 넣지 않는다.
    static func copyWaveformCorpus(_ args: [String], to root: URL, limit: Int) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw DJCError.invalidAnalysisFile("기존 자료를 덮어쓰지 않도록 새 사본 폴더를 지정하세요") }
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        guard snapshot.resolvingSymlinksInPath() != LibrarySnapshot.rekordboxDirectory.appending(path: "master.db").resolvingSymlinksInPath() else {
            throw DJCError.invalidAnalysisFile("라이브 DB 대신 djc snapshot으로 만든 사본을 지정하세요")
        }
        let title = value(after: "--title", in: args)
        let excludeTitle = value(after: "--exclude-title", in: args)
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let candidates = library.tracks.filter { !$0.isStreaming && fm.fileExists(atPath: $0.folderPath)
            && RekordboxShare.hasWaveformAnalysis($0.analysisDataPath) && (title == nil || $0.title.contains(title!))
            && (excludeTitle == nil || !$0.title.contains(excludeTitle!)) }
        let byFormat = Dictionary(grouping: candidates, by: \.fileExtension)
        var groups: [[Track]] = []
        for format in byFormat.keys.sorted() {
            let byGenre = Dictionary(grouping: byFormat[format]!, by: { $0.genre ?? "" })
            let genres = byGenre.keys.sorted().map { byGenre[$0]!.sorted { $0.uuid < $1.uuid } }
            var ordered: [Track] = []
            for index in 0..<(genres.map(\.count).max() ?? 0) {
                for group in genres where index < group.count { ordered.append(group[index]) }
            }
            groups.append(ordered)
        }
        var picked: [Track] = [], index = 0
        while picked.count < limit {
            let next = groups.compactMap { index < $0.count ? $0[index] : nil }
            if next.isEmpty { break }
            picked.append(contentsOf: next.prefix(limit - picked.count)); index += 1
        }
        let genres = Array(Set(picked.map { $0.genre ?? "" })).sorted()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (index, track) in picked.enumerated() {
            let folder = root.appending(path: String(format: "sample-%03d", index + 1))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let dat = RekordboxShare.analysisURL(track.analysisDataPath) else { continue }
            do {
                try fm.copyItem(at: URL(filePath: track.folderPath), to: folder.appending(path: "audio." + track.fileExtension))
                for ext in ["DAT", "EXT", "2EX"] {
                    let source = dat.deletingPathExtension().appendingPathExtension(ext)
                    if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: folder.appending(path: "ANLZ0000." + ext)) }
                }
                let metadata = ["genreGroup": genres.firstIndex(of: track.genre ?? "") ?? 0]
                try JSONEncoder().encode(metadata).write(to: folder.appending(path: "metadata.json"))
            } catch { throw DJCError.invalidAnalysisFile("표본 \(index + 1)의 음원·분석 파일을 복사할 수 없어 파일 접근 권한을 확인하세요") }
        }
    }
}
