import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AVFoundation
import Foundation

/// 소리 분석 실험과 시간 측정.
enum AudioLab {
    static let all: [Command] = [
        Command("phrase-eval", "--corpus 사본 폴더 [--limit N] [--out 결과.json]", "PSSI와 섹션 경계를 마디 단위로 익명 비교(읽기 전용)", PhraseEvaluation.run),
        Command("mockup-data", nil, "디자인 시안용 실데이터(JSON)", AudioLab.mockupData),
        Command("bench-load", nil, "DB 읽기·분류·파싱 시간", AudioLab.benchLoad),
        Command("bench-waveform", nil, "파형 분석 시간", AudioLab.benchWaveform),
        Command("loudness", nil, "파일의 BS.1770 통합 음량·피크·클리핑 흔적(개발용)", AudioLab.loudness),
        Command("waveform-eval", "[--limit N] [--title 제목] [--exclude-title 제목] [--db 사본] [--copy-to 새 폴더 | --corpus 사본 폴더] [--out 결과.json] [--dump-to 새 폴더]", "음원·분석 사본을 익명 표본으로 비교(태그별 일치율·평균/최대 오차·칸 데이터)", AudioLab.waveformEval),
        Command("waveform-probe", "--out 새 폴더 [--suite 1|2]", "rekordbox 파형 실험용 합성 WAV(2: 경계·혼합·정규화·버스트, 44.1/48kHz)를 만든다", AudioLab.waveformProbe),
        Command("waveform-dump", "<제목> --out <파일.json> [--db PATH]", "한 곡의 rekordbox 파형 태그와 DJCrate 칸 측정값을 JSON으로(규칙 맞추기용)", AudioLab.waveformDump),
        Command("waveform-build", "<ContentID> --out <폴더> [--compare <ContentID>]", "곡의 .EXT·.2EX를 DJCrate가 만들어 폴더에 쓰고 같은 음원의 rekordbox 분석과 비교", AudioLab.waveformBuild),
        Command("key-eval", nil, "조표 흐름 추정의 주 조표를 rekordbox 키와 비교(읽기 전용)", AudioLab.keyEval),
    ]

    static func mockupData(_ args: [String]) async throws {
        guard args.count > 1, let out = value(after: "--out", in: args) else { throw UsageError() }
        try await exportMockupData(args[1], to: URL(filePath: out), snapshotPath: value(after: "--db", in: args))
    }

    static func benchLoad(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let clock = ContinuousClock()
        var library: RekordboxLibrary!
        let tLoad = try clock.measure { library = try RekordboxLibrary.load(snapshot: snapshot) }
        var classified = 0
        let tClassify = clock.measure { for t in library.tracks { if CommentClassifier.classify(t.comment) == .convention { classified += 1 } } }
        let tParse = clock.measure { for t in library.tracks { _ = ConventionParser.parse(t.comment) } }
        let tReport = clock.measure { _ = LibraryReport(library: library) }
        let tTree = clock.measure { _ = PlaylistNode.tree(library.playlists) }
        print("DB 읽기 \(tLoad) · 분류 \(tClassify) · 파싱 \(tParse) · 현황 집계 \(tReport) · 플레이리스트 트리 \(tTree) · 곡 \(library.tracks.count)")
    }

    static func benchWaveform(_ args: [String]) async throws {
        guard args.count > 1 else { return }
        let clock = ContinuousClock()
        var w: Waveform!
        let t = try clock.measure { w = try WaveformAnalyzer.analyze(fileAt: URL(filePath: args[1])) }
        print("파형 \(t) · \(w.count)칸 · \(Int(w.duration))초")
        if let out = value(after: "--out", in: args) { try JSONEncoder().encode(w).write(to: URL(filePath: out)) }
    }

    /// 파일의 BS.1770 통합 음량·피크·클리핑 흔적(개발용)
    static func loudness(_ args: [String]) async throws {
        for path in args.dropFirst() {
            let file = try AVAudioFile(forReading: URL(filePath: path))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames) }
            let started = Date()
            let l = Loudness.measure(channels: channels, sampleRate: buffer.format.sampleRate)
            print(String(format: "%.2f LUFS · 피크 %.2f dBFS · 클리핑 %d · %.0fms · %@", l.integrated ?? -999, l.peak, l.clippedRuns,
                         Date().timeIntervalSince(started) * 1000, (path as NSString).lastPathComponent))
        }
    }

    /// 조표 흐름 추정의 주 조표를 rekordbox 키와 비교(읽기 전용). --penalty로 전환 벌점 조정
    static func keyEval(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest())
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 40
        let penalties = (value(after: "--penalty", in: args) ?? "2").split(separator: ",").compactMap { Double($0) }
        var candidates = library.tracks.filter { !$0.isStreaming && KeyAnalyzer.signature(camelot: $0.key ?? "") != nil && FileManager.default.fileExists(atPath: $0.folderPath) }
        candidates.shuffle()
        var exact = [Int](repeating: 0, count: penalties.count), fifth = exact, modulated = exact, total = 0, examples: [String] = []
        // --train N: 앞 N곡으로 음 분포를 학습하고 나머지로 평가한다.
        let trainCount = Int(value(after: "--train", in: args) ?? "") ?? 0
        if trainCount > 0 {
            var majorSum = [Double](repeating: 0, count: 12), minorSum = majorSum, counts = [0, 0]
            for track in candidates.prefix(trainCount) {
                guard let rb = KeyAnalyzer.signature(camelot: track.key ?? ""),
                      let file = try? AVAudioFile(forReading: URL(filePath: track.folderPath)),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { continue }
                let frames = Int(buffer.frameLength)
                let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
                let chroma = KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
                let tonic = rb.minor ? (rb.signature + 9) % 12 : rb.signature
                let v = KeyAnalyzer.rotatedTotal(chroma: chroma, tonic: tonic)
                if rb.minor { for i in 0..<12 { minorSum[i] += v[i] }; counts[1] += 1 } else { for i in 0..<12 { majorSum[i] += v[i] }; counts[0] += 1 }
            }
            let learned = KeyAnalyzer.Profiles(major: majorSum.map { $0 / Double(max(counts[0], 1)) }, minor: minorSum.map { $0 / Double(max(counts[1], 1)) })
            KeyAnalyzer.profiles = learned
            print("학습: 장조 \(counts[0])곡 · 단조 \(counts[1])곡")
            print("  장조:", learned.major.map { String(format: "%.4f", $0) }.joined(separator: ", "))
            print("  단조:", learned.minor.map { String(format: "%.4f", $0) }.joined(separator: ", "))
            candidates.removeFirst(min(trainCount, candidates.count))
        }
        for track in candidates.prefix(limit) {
            guard let file = try? AVAudioFile(forReading: URL(filePath: track.folderPath)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { continue }
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
            let chroma = KeyAnalyzer.chroma(channels: channels, sampleRate: buffer.format.sampleRate)
            let grid = RekordboxShare.analysisURL(track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
            let windows = KeyAnalyzer.windows(grid: grid, duration: Double(frames) / buffer.format.sampleRate)
            guard let rb = KeyAnalyzer.signature(camelot: track.key ?? "") else { continue }
            total += 1
            for (i, penalty) in penalties.enumerated() {
                let result = KeyAnalyzer.segments(chroma: chroma, windows: windows, switchPenalty: penalty,
                                                  minWindows: Int(value(after: "--min", in: args) ?? "") ?? 12)
                guard let main = result.main else { continue }
                let diff = (KeyAnalyzer.camelotNumber(signature: main) - KeyAnalyzer.camelotNumber(signature: rb.signature) + 12) % 12
                if diff == 0 { exact[i] += 1 }
                if diff == 1 || diff == 11 { fifth[i] += 1 }
                if result.segments.count > 1 {
                    modulated[i] += 1
                    if i == 0, examples.count < 12 {
                        let flow = result.segments.map { String(format: "%@ %.0f~%.0f초", KeyAnalyzer.camelot(signature: $0.signature, minor: rb.minor), $0.start, $0.end) }
                        examples.append("\(track.title.prefix(24)) (rekordbox \(track.key ?? "")): " + flow.joined(separator: " → "))
                    }
                }
            }
        }
        for (i, penalty) in penalties.enumerated() {
            print(String(format: "벌점 %.1f · %d곡 · 주 조표 일치 %d (%.0f%%) · 5도 이웃 %d · 전조 있음 %d곡", penalty, total, exact[i],
                         Double(exact[i]) / Double(max(total, 1)) * 100, fifth[i], modulated[i]))
        }
        examples.forEach { print("  ", $0) }
    }

    /// 한 곡의 rekordbox 파형 태그 본문과 DJCrate 칸 측정값(규칙 맞추기용, 읽기 전용)
    static func waveformDump(_ args: [String]) async throws {
        guard args.count > 1, let out = value(after: "--out", in: args) else { throw UsageError() }
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        guard let track = library.tracks.first(where: { $0.title == args[1] && RekordboxShare.hasWaveformAnalysis($0.analysisDataPath) })
            ?? library.tracks.first(where: { $0.title.contains(args[1]) && RekordboxShare.hasWaveformAnalysis($0.analysisDataPath) }),
            let datURL = RekordboxShare.analysisURL(track.analysisDataPath) else { print("곡을 찾지 못함"); return }
        let url = URL(filePath: track.folderPath)
        let offset = RekordboxTimeline.predictedOffset(url: url)
        let (mono, rate) = try RekordboxWaveforms.decodeForRekordbox(url: url)
        let columns = RekordboxWaveforms.measure(mono, rate: rate)
        var rb: [String: [Int]] = [:]
        for (ext, tags) in [("DAT", ["PWAV", "PWV2"]), ("EXT", ["PWV3", "PWV5", "PWV4"]), ("2EX", ["PWV7", "PWV6", "PWVC"])] {
            let file = try AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension(ext))
            for name in tags { if let tag = file.tag(name) { rb[name] = RekordboxWaveforms.body(of: tag.bytes).map(Int.init) } }
        }
        let json: [String: Any] = [
            "title": track.title, "format": track.fileExtension, "rate": rate, "frames": mono.count, "offset": offset,
            "rawMax": Double(mono.map { abs($0) }.max() ?? 0), "rb": rb,
            "peak": columns.map(\.peak), "white": columns.map(\.white), "sumsq": columns.map(\.sumsq), "samples": columns.map(\.samples),
            "b0": columns.map(\.band.0), "b1": columns.map(\.band.1), "b2": columns.map(\.band.2),
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(filePath: out))
        print("\(track.title) · \(track.fileExtension) · 칸 \(columns.count) · rekordbox \(rb["PWV3"]?.count ?? 0) · 최대 \(json["rawMax"]!) → \(out)")
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let ma = a.prefix(n).reduce(0, +) / Double(n), mb = b.prefix(n).reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; sab += x * y; saa += x * x; sbb += y * y }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : (saa == sbb ? 1 : 0)
    }

    static func share(_ n: Int, _ ok: (Int) -> Bool) -> Double { n == 0 ? 0 : Double((0..<n).filter(ok).count) / Double(n) * 100 }

    /// rekordbox 분석 파일과 DJCrate 파형을 태그마다 비교한 수치
    static func waveformMetrics(dat: AnlzFile, ext: AnlzFile, two: AnlzFile, ours: RekordboxWaveforms) -> [String: Double] {
        var v: [String: Double] = [:]
        let rbPWV3 = ext.tag("PWV3").map { RekordboxWaveforms.body(of: $0.bytes) } ?? []
        let n = min(rbPWV3.count, ours.pwv3.count)
        v["칸 차이"] = Double(ours.pwv3.count - rbPWV3.count)
        // 시간축 확인: 높이 곡선이 가장 잘 맞는 어긋남(칸)
        let rbH = rbPWV3.map { Double($0 & 31) }, ourH = ours.pwv3.map { Double($0 & 31) }
        var bestLag = 0, best = -2.0
        for lag in -8...8 {
            let a = lag >= 0 ? Array(rbH.dropFirst(lag)) : rbH, b = lag >= 0 ? ourH : Array(ourH.dropFirst(-lag))
            let c = correlation(a, b)
            if c > best { best = c; bestLag = lag }
        }
        v["어긋남"] = Double(bestLag)
        v["PWV3 높이"] = share(n) { rbPWV3[$0] & 31 == ours.pwv3[$0] & 31 }
        v["PWV3 높이±1"] = share(n) { abs(Int(rbPWV3[$0] & 31) - Int(ours.pwv3[$0] & 31)) <= 1 }
        v["PWV3 흰"] = share(n) { rbPWV3[$0] >> 5 == ours.pwv3[$0] >> 5 }
        if let tag = ext.tag("PWV5") {
            let b = RekordboxWaveforms.body(of: tag.bytes)
            let rb = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
            let m = min(rb.count, ours.pwv5.count)
            v["PWV5 높이"] = share(m) { (rb[$0] >> 2) & 31 == (ours.pwv5[$0] >> 2) & 31 }
            var colour = 0.0
            for i in 0..<m { for shift in [13, 10, 7] { colour += abs(Double((rb[i] >> UInt16(shift)) & 7) - Double((ours.pwv5[i] >> UInt16(shift)) & 7)) } }
            v["PWV5 색 차이"] = m == 0 ? 0 : colour / Double(m * 3)
        }
        if let tag = two.tag("PWV7") {
            let b = RekordboxWaveforms.body(of: tag.bytes)
            for (j, name) in ["저", "중", "고"].enumerated() {
                let rb = stride(from: j, to: b.count, by: 3).map { Double(b[$0]) }
                let us = stride(from: j, to: ours.pwv7.count, by: 3).map { Double(ours.pwv7[$0]) }
                v["PWV7 \(name)"] = correlation(rb, us)
            }
        }
        if let tag = two.tag("PWVC") {
            let b = RekordboxWaveforms.body(of: tag.bytes)
            let rb = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
            v["PWVC 같음"] = rb == ours.gains ? 100 : 0
            if rb != ours.gains { print("  PWVC rekordbox \(rb) · DJCrate \(ours.gains)") }
        }
        if let tag = dat.tag("PWAV") {
            let rb = RekordboxWaveforms.body(of: tag.bytes)
            v["PWAV 높이±1"] = share(min(rb.count, 400)) { abs(Int(rb[$0] & 31) - Int(ours.pwav[$0] & 31)) <= 1 }
            v["PWAV 흰"] = share(min(rb.count, 400)) { rb[$0] >> 5 == ours.pwav[$0] >> 5 }
        }
        if let tag = dat.tag("PWV2") {
            let rb = RekordboxWaveforms.body(of: tag.bytes)
            v["PWV2 ±1"] = share(min(rb.count, 100)) { abs(Int(rb[$0]) - Int(ours.pwv2[$0])) <= 1 }
        }
        if let tag = two.tag("PWV6") {
            v["PWV6 상관"] = correlation(RekordboxWaveforms.body(of: tag.bytes).map(Double.init), ours.pwv6.map(Double.init))
        }
        if let tag = ext.tag("PWV4") {
            v["PWV4 상관"] = correlation(RekordboxWaveforms.body(of: tag.bytes).map(Double.init), ours.pwv4.map(Double.init))
        }
        return v
    }

    /// 곡의 .EXT·.2EX를 DJCrate가 만들어 지정한 폴더에 쓴다(rekordbox 폴더는 건드리지 않음). 같은 음원의 다른 곡과 비교할 수 있다.
    static func waveformBuild(_ args: [String]) async throws {
        guard args.count > 1, let out = value(after: "--out", in: args) else { throw UsageError() }
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        guard let track = library.tracks.first(where: { $0.id == args[1] }), let datURL = RekordboxShare.analysisURL(track.analysisDataPath) else {
            print("곡을 찾지 못함"); return
        }
        let dat = try AnlzFile(url: datURL)
        let ours = try RekordboxWaveforms.analyze(url: URL(filePath: track.folderPath))
        let (extData, twoData) = try ours.files(dat: dat)
        let folder = URL(filePath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try extData.write(to: folder.appending(path: "ANLZ0000.EXT"))
        try twoData.write(to: folder.appending(path: "ANLZ0000.2EX"))
        let ext = try AnlzFile(data: extData), two = try AnlzFile(data: twoData)
        func list(_ f: AnlzFile) -> String { f.tags.map { "\($0.fourcc)(\($0.bytes.count))" }.joined(separator: " ") }
        print("\(track.title) · 칸 \(ours.columns)\n만든 .EXT \(extData.count)바이트: \(list(ext))\n만든 .2EX \(twoData.count)바이트: \(list(two))")
        guard let refID = value(after: "--compare", in: args), let ref = library.tracks.first(where: { $0.id == refID }),
              let refDat = RekordboxShare.analysisURL(ref.analysisDataPath) else { return }
        let refExt = try AnlzFile(url: refDat.deletingPathExtension().appendingPathExtension("EXT"))
        let refTwo = try AnlzFile(url: refDat.deletingPathExtension().appendingPathExtension("2EX"))
        print("rekordbox .EXT(\(ref.title)): \(list(refExt))\nrekordbox .2EX: \(list(refTwo))")
        for name in ["PCOB", "PCO2"] {
            print("\(name) 같음: \(ext.tags.filter { $0.fourcc == name }.map(\.bytes) == refExt.tags.filter { $0.fourcc == name }.map(\.bytes))")
        }
        let v = waveformMetrics(dat: try AnlzFile(url: refDat), ext: refExt, two: refTwo, ours: ours)
        print(v.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: " · "))
    }

    // MARK: - 도움

    /// 디자인 시안에 넣을 실제 데이터. 앨범 커버 이미지는 넣지 않는다.
    static func exportMockupData(_ id: String, to out: URL, snapshotPath: String?) async throws {
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        guard let track = library.tracks.first(where: { $0.id == id }) else { print("트랙 없음: \(id)"); return }
        let url = URL(filePath: track.folderPath)
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: track.uuid)
        let waveform = try WaveformAnalyzer.analyze(fileAt: url)
        let cues = library.cues(for: track).sorted { $0.inMsec < $1.inMsec }
        let hotA = cues.first { $0.hotCueSlot == "A" }.map { Double($0.inMsec) / 1000 } ?? 60
        let zoomStart = max(0, hotA - 12), zoomEnd = zoomStart + 24

        func row(_ t: Track) -> [String: Any] {
            let manual = library.cues(for: t).filter { !$0.isAutoGenerated }.count
            // 목록용 미니 개요 파형(160칸)과 큐 위치
            var mini: [String: Any] = [:]
            if !t.isStreaming, let w = try? WaveformAnalyzer.analyze(fileAt: URL(filePath: t.folderPath)).downsampled(to: 160) {
                mini = ["low": w.low, "mid": w.mid, "high": w.high, "duration": w.duration]
            }
            let cuePoints = library.cues(for: t).filter { !$0.isAutoGenerated }.map {
                ["time": Double($0.inMsec) / 1000, "slot": $0.hotCueSlot.map(String.init) ?? ""] as [String: Any]
            }
            return ["mini": mini, "cuePoints": cuePoints, "title": t.title, "artist": t.artist ?? "", "album": t.album ?? "", "comment": t.comment,
                    "class": CommentClassifier.classify(t.comment).rawValue, "imported": t.importedOn ?? "",
                    "plays": library.playCounts[t.id, default: 0], "bpm": t.bpm ?? 0, "key": t.key ?? "",
                    "cues": library.cues(for: t).isEmpty ? "none" : (manual > 0 ? "manual \(manual)" : "auto"),
                    "length": t.lengthSeconds]
        }
        // 목록: 선택 곡 + 규칙 코멘트 곡 + 2025~26 빈 코멘트 로컬 파일
        let local = library.tracks.filter { !$0.isStreaming }
        let convention = local.filter { CommentClassifier.classify($0.comment) == .convention && library.playCounts[$0.id, default: 0] > 3 }
            .sorted { $0.uuid < $1.uuid }.prefix(8)
        let backlog = local.filter { $0.comment.isEmpty && ["2025", "2026"].contains($0.importYear ?? "") }
            .sorted { $0.uuid < $1.uuid }.prefix(8)
        let parsed = ConventionParser.parse(track.comment)

        let energies = PartLabeler.energies(analysis)
        let lo = energies.map(\.score).filter(\.isFinite).min() ?? 0, hi = energies.map(\.score).filter(\.isFinite).max() ?? 1
        let overview = waveform.downsampled(to: 900)
        let zoom = waveform.slice(from: zoomStart, to: zoomEnd)
        let payload: [String: Any] = [
            "track": row(track).merging([
                "parsed": [
                    "prefix": parsed?.prefix.rawValue ?? "", "work": parsed?.workName ?? "",
                    "usage": parsed?.usages.map { $0.kind.rawValue + ($0.numbers.isEmpty ? "" : " " + $0.numbers.map(String.init).joined(separator: ",")) } ?? [],
                ],
                "duration": analysis.duration,
            ]) { a, _ in a },
            "library": [row(track)] + convention.map(row) + backlog.map(row),
            "counts": ["live": library.tracks.count, "backlog": backlog.count],
            "analysis": [
                "bpm": analysis.bpm ?? 0, "bars": analysis.bars.count,
                "key": analysis.keys.first?.name ?? "",
                "sections": energies.map { ["start": $0.span.start, "end": $0.span.end,
                                            "energy": hi > lo && $0.score.isFinite ? ($0.score - lo) / (hi - lo) : 0,
                                            "vocal": $0.vocal] },
                "barTimes": analysis.bars,
                "labels": PartLabeler.label(analysis).map { ["label": $0.label.rawValue, "time": $0.time] },
                "suggestions": MemoryCueSuggester.suggestions(analysis, existing: cues.map { Double($0.inMsec) / 1000 }),
            ],
            "cues": cues.map { ["slot": $0.hotCueSlot.map(String.init) ?? "", "time": Double($0.inMsec) / 1000,
                                "memory": $0.isMemoryCue, "auto": $0.isAutoGenerated] },
            "waveform": [
                "overview": ["rate": overview.rate, "low": overview.low, "mid": overview.mid, "high": overview.high],
                "zoom": ["start": zoomStart, "rate": zoom.rate, "low": zoom.low, "mid": zoom.mid, "high": zoom.high],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: out)
        print("\(out.path) (\(data.count / 1024)KB) · 파형 \(waveform.count)칸 · 확대 \(Int(zoomStart))~\(Int(zoomEnd))초")
    }
}
