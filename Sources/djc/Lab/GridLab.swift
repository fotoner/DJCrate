import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import AVFoundation
import Foundation

/// 그리드·템포·시간축 실험(읽기 전용이거나 사본에만 쓴다).
enum GridLab {
    static let all: [Command] = [
        Command("grid-check", nil, "템포 구간으로 다시 만든 그리드와 rekordbox 원본(PQTZ) 오차", GridLab.gridCheck),
        Command("grid-estimate-eval", nil, "추정 그리드를 rekordbox 그리드와 비교", GridLab.gridEstimateEval),
        Command("grid", nil, "제목으로 rekordbox 그리드 앞부분과 형식별 시간축 차이를 본다(개발용)", GridLab.grid),
        Command("uncached", nil, "분석 캐시가 없는 로컬 곡 ContentID(개발용)", GridLab.uncached),
        Command("import-check-sim", nil, "라이브러리 곡을 추가한 곡처럼 보고 추정 그리드를 rekordbox 그리드와 비교", GridLab.importCheckSim),
        Command("anlz-roundtrip", "<USBANLZ 폴더>", "분석 파일을 읽고 다시 써서 바이트까지 같은지(읽기 전용)", GridLab.anlzRoundtrip),
        Command("grid-repro", nil, "rekordbox가 직접 고친 그리드를 우리 생성기로 바이트까지 재현하는지(읽기 전용)", GridLab.gridRepro),
        Command("make-grid-drafts", nil, "시험용: 분석된 곡 몇 개에 그리드 초안(이동·½박·1박 위치)을 만든다", GridLab.makeGridDrafts),
        Command("grid-write-test", nil, "사본 DB·사본 분석 폴더에 BPM 변경 그리드를 써 본다", GridLab.gridWriteTest),
        Command("tempo-scan", nil, "라이브러리 전체 그리드에서 변속 곡을 찾는다(시간 측정용)", GridLab.tempoScan),
        Command("tempo-estimate-check", nil, "rekordbox가 변속으로 잡은 곡에서 DJCrate 추정도 구간을 나누는지(읽기 전용, MU 분석은 캐시 사용)", GridLab.tempoEstimateCheck),
        Command("tempo-debug", nil, "한 곡의 BPM 후보별 어택 점수(위상 ±25ms 최적화 포함)와 히스토그램 봉우리를 본다", GridLab.tempoDebug),
        Command("timeline-debug", nil, "한 곡의 rekordbox 파형 길이·상관 곡선을 본다", GridLab.timelineDebug),
        Command("bpm-histogram", nil, "라이브러리 BPM 분포", GridLab.bpmHistogram),
        Command("timeline-check", nil, "형식별 시간축 차이 예측과 rekordbox 파형 비교", GridLab.timelineCheck),
    ]

    static func gridCheck(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 500
        try gridCheck(limit: limit, snapshotPath: value(after: "--db", in: args))
    }

    static func gridEstimateEval(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 40
        try await evaluateGridEstimates(limit: limit, snapshotPath: value(after: "--db", in: args))
    }

    /// 제목으로 rekordbox 그리드 앞부분과 형식별 시간축 차이를 본다(개발용).
    static func grid(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        guard args.count > 1 else { return }
        for track in library.tracks where track.title.contains(args[1]) && !track.isStreaming {
            guard let dat = RekordboxShare.analysisURL(track.analysisDataPath), let grid = try? BeatGrid.load(anlz: dat) else { continue }
            let offset = RekordboxTimeline.predictedOffset(url: URL(filePath: track.folderPath))
            let head = grid.beats.prefix(3).map { String(format: "%.3f(%d박)", $0.time, $0.number) }.joined(separator: " ")
            print(String(format: "%@ · %.2f BPM · 시간축 차이 %.1fms · 앞 박 %@", (track.folderPath as NSString).lastPathComponent, grid.beats.first?.bpm ?? 0, offset * 1000, head))
        }
    }

    /// 분석 캐시가 없는 로컬 곡 ContentID(개발용)
    static func uncached(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        let cached = Set((try? FileManager.default.contentsOfDirectory(atPath: PartAnalyzer.cacheDirectory.path)) ?? [])
            .compactMap { $0.split(separator: "-").first.map(String.init) }
        let skip = Int(value(after: "--skip", in: args) ?? "") ?? 0
        let candidates = library.tracks.sorted(by: { $0.uuid > $1.uuid }).filter { !$0.isStreaming && !cached.contains($0.uuid)
            && FileManager.default.fileExists(atPath: $0.folderPath) && ["mp3", "m4a"].contains($0.fileExtension) }
        if candidates.indices.contains(skip) { print("\(candidates[skip].id)\t\(candidates[skip].title)") }
    }

    /// 가져오기 흉내: 라이브러리 곡을 "추가한 곡"으로 보고 추정 그리드(보낼 값)를 rekordbox 그리드와 비교한다.
    static func importCheckSim(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        guard args.count > 1 else { return }
        for track in library.tracks where track.title.contains(args[1]) && !track.isStreaming {
            let url = URL(filePath: track.folderPath)
            guard var estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: track.uuid) else { continue }
            let offset = RekordboxTimeline.predictedOffset(url: url)
            for i in estimate.segments.indices { estimate.segments[i].start += offset }
            let imported = RekordboxShare.analysisURL(track.analysisDataPath).flatMap { try? BeatGrid.load(anlz: $0) }
            let check = StagedTrack.ImportCheck.compare(sent: estimate.segments, imported: imported,
                                                        duration: Double(track.lengthSeconds), checkedOn: "sim")
            print(String(format: "%@ · 보낼 %.2f BPM · rekordbox %.2f · 결과 %@ · 최대 차이 %.1fms",
                         (track.folderPath as NSString).lastPathComponent, estimate.bpm, check.rekordboxBPM ?? 0,
                         check.result.rawValue, check.maxDeviationMs ?? -1))
        }
    }

    /// 분석 파일을 읽고 다시 써서 바이트까지 같은지, 그리드 태그를 풀었다 다시 만들면 같은지(읽기 전용, 사본 폴더)
    static func anlzRoundtrip(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        let root = URL(filePath: args[1])
        var files = 0, same = 0, tagSame = [0, 0], tagTotal = [0, 0], emptyPQT2 = 0, failures: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var dats: [URL] = []
        while let url = walker?.nextObject() as? URL { if url.lastPathComponent == "ANLZ0000.DAT" { dats.append(url) } }
        for dat in dats {
            let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
            for url in [dat, ext] where FileManager.default.fileExists(atPath: url.path) {
                files += 1
                guard let data = try? Data(contentsOf: url), let file = try? AnlzFile(data: data) else {
                    if failures.count < 5 { failures.append("못 읽음 \(url.path.suffix(50))") }
                    continue
                }
                if file.serialized() == data { same += 1 } else if failures.count < 5 { failures.append("다시 쓰기 다름 \(url.path.suffix(50))") }
            }
            guard let datFile = try? AnlzFile(url: dat), let z = datFile.tag("PQTZ") else { continue }
            let extFile = try? AnlzFile(url: ext)
            let q = extFile?.tag("PQT2")
            let decoded = BeatGridTags.decode(pqtz: z.bytes, pqt2: q?.bytes)
            tagTotal[0] += 1
            if BeatGridTags.pqtz(decoded.beats) == z.bytes { tagSame[0] += 1 } else if failures.count < 8 { failures.append("PQTZ 다름 \(dat.path.suffix(50))") }
            if let q {
                tagTotal[1] += 1
                let rebuilt = decoded.unknown == nil ? BeatGridTags.pqt2([], unknown: 0) : BeatGridTags.pqt2(decoded.beats, unknown: decoded.unknown ?? 0)
                if decoded.unknown == nil { emptyPQT2 += 1 }
                if rebuilt == q.bytes { tagSame[1] += 1 } else if failures.count < 8 { failures.append("PQT2 다름 \(ext.path.suffix(50))") }
            }
        }
        print("분석 파일 \(files)개 · 그대로 다시 쓰기 같음 \(same)")
        print("PQTZ 다시 만들기 같음 \(tagSame[0])/\(tagTotal[0]) · PQT2 같음 \(tagSame[1])/\(tagTotal[1]) (빈 PQT2 \(emptyPQT2))")
        failures.forEach { print("  ", $0) }
    }

    /// rekordbox가 직접 고친 그리드를 우리 생성기로 바이트까지 재현하는지(읽기 전용)
    static func gridRepro(_ args: [String]) async throws {
        // DJCrate grid-repro <전 폴더> <후 폴더> <음원> <첫 박 초> <BPM> <첫 박 번호>
        guard args.count > 6, let bpm = Double(args[5]), let number = Int(args[6]) else { return }
        let before = URL(filePath: args[1]), after = URL(filePath: args[2]), audioURL = URL(filePath: args[3])
        // "auto": 편집 전 그리드의 정밀 첫 박(PQTZ + PQT2 소수)
        let beforeDat = try AnlzFile(url: before.appending(path: "ANLZ0000.DAT"))
        let beforeExt = try? AnlzFile(url: before.appending(path: "ANLZ0000.EXT"))
        let precise = BeatGridTags.decode(pqtz: beforeDat.tag("PQTZ")!.bytes, pqt2: beforeExt?.tag("PQT2")?.bytes).beats
        guard let start = args[4] == "auto" ? precise.first.map({ $0.time / 1000 }) : Double(args[4]) else { return }
        print("첫 박", start)
        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate + RekordboxTimeline.predictedOffset(url: audioURL)
        let beats = RekordboxGridWriter.beats(segments: [GridSegment(start: start, bpm: bpm, firstBeatNumber: number)], duration: duration)
        var dat = try AnlzFile(url: before.appending(path: "ANLZ0000.DAT"))
        dat.replace("PQTZ", with: BeatGridTags.pqtz(beats))
        var ext = try AnlzFile(url: before.appending(path: "ANLZ0000.EXT"))
        if ext.tag("PQT2") != nil { ext.replace("PQT2", with: BeatGridTags.pqt2([], unknown: 0)) }
        let wantDat = try Data(contentsOf: after.appending(path: "ANLZ0000.DAT")), wantExt = try Data(contentsOf: after.appending(path: "ANLZ0000.EXT"))
        print(String(format: "곡 길이 %.3f초 · 박 %d개 · 앞 %@ · 끝 %.0f", duration, beats.count,
                     beats.prefix(4).map { String(Int($0.time)) }.joined(separator: ","), beats.last?.time ?? 0))
        print(".DAT 바이트까지 같음:", dat.serialized() == wantDat, "· .EXT 바이트까지 같음:", ext.serialized() == wantExt)
    }

    /// 시험용: 분석된 곡 몇 개에 그리드 초안(이동·½박·1박 위치)을 만든다. DJC_HOME을 사본으로 줘야 한다.
    static func makeGridDrafts(_ args: [String]) async throws {
        guard ProcessInfo.processInfo.environment["DJC_HOME"]?.isEmpty == false else { print("DJC_HOME을 사본 폴더로 주세요"); return }
        let library = try RekordboxLibrary.load(snapshot: value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest())
        var made = 0
        for track in library.tracks.shuffled() where !track.isStreaming && (track.bpm ?? 0) > 0 && made < 3 {
            guard let url = RekordboxShare.analysisURL(track.analysisDataPath),
                  FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("EXT").path),
                  let grid = try? BeatGrid.load(anlz: url), grid.beats.count > 64, FileManager.default.fileExists(atPath: track.folderPath) else { continue }
            var draft = GridDraft(trackUUID: track.uuid, grid: grid)
            guard draft.base.count == 1 else { continue }
            switch made {
            case 0: draft.shift(by: 0.012)
            case 1: draft.shift(by: 30 / draft.segments[0].bpm)          // ½박
            default: draft.segments[0].firstBeatNumber = draft.segments[0].firstBeatNumber % 4 + 1   // 1박 위치
            }
            try GridDraftStore.save(draft)
            print("초안: \(track.title.prefix(30)) · \(["+12ms", "½박", "1박 위치"][made])")
            made += 1
        }
        // 분석 전 곡(분석 파일 없음) 하나: 추정 그리드로 초안을 만든다(반영하면 분석 파일을 붙인다)
        if let track = library.tracks.shuffled().first(where: { !$0.isStreaming && RekordboxWriter.needsAnalysis($0.analysisDataPath)
            && FileManager.default.fileExists(atPath: $0.folderPath) }) {
            let url = URL(filePath: track.folderPath)
            if let estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: "attach-\(track.uuid)") {
                try GridDraftStore.save(GridDraft(trackUUID: track.uuid, base: [], segments: estimate.segments)
                    .shifted(by: RekordboxTimeline.predictedOffset(url: url)))
                print("초안: \(track.title.prefix(30)) · 분석 전 곡(분석 붙이기)")
            }
        }
    }

    /// 사본 DB·사본 분석 폴더에 BPM 변경 그리드를 써 본다. djc grid-write-test <사본.db> <사본 share 뿌리> <UUID> <BPM>
    static func gridWriteTest(_ args: [String]) async throws {
        guard args.count > 4, let bpm = Double(args[4]) else { return }
        let db = URL(filePath: args[1]), root = URL(filePath: args[2]), uuid = args[3]
        try CLIGuards.refuseLiveDatabase(db)
        try CLIGuards.refuseLiveShare(root)
        let library = try RekordboxLibrary.load(snapshot: db)
        guard let track = library.tracks.first(where: { $0.uuid == uuid }),
              let path = track.analysisDataPath else { print("곡 없음"); return }
        let datURL = root.appending(path: String(path.drop(while: { $0 == "/" })))
        let grid = try BeatGrid.load(anlz: datURL)
        var draft = GridDraft(trackUUID: uuid, grid: grid)
        draft.setBPM(bpm, at: 0)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: db, dryRun: false,
                                               backups: db.deletingLastPathComponent().appending(path: "backups"), shareRoot: root)
        for o in report.gridOutcomes ?? [] { print(o.status.rawValue, o.title, o.reason ?? "", "박", o.added) }
    }

    /// 라이브러리 전체 그리드에서 변속 곡을 찾는다(시간 측정용)
    static func tempoScan(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest())
        let started = Date()
        var found: [(String, [Double])] = [], read = 0
        for track in library.tracks where !track.isStreaming {
            guard let url = RekordboxShare.analysisURL(track.analysisDataPath), let grid = try? BeatGrid.load(anlz: url) else { continue }
            read += 1
            let changes = grid.tempoChanges
            if !changes.isEmpty { found.append((track.title, changes)) }
        }
        print(String(format: "그리드 %d곡 읽음 · 변속 곡 %d곡 · %.2f초", read, found.count, Date().timeIntervalSince(started)))
        for (title, bpms) in found.prefix(12) { print("  \(title.prefix(30)): " + bpms.map { String(format: "%.0f", $0) }.joined(separator: "→")) }
    }

    /// rekordbox가 변속으로 잡은 곡에서 DJCrate 추정도 구간을 나누는지(읽기 전용, MU 분석은 캐시 사용)
    static func tempoEstimateCheck(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest())
        var checked = 0, split = 0
        for track in library.tracks where !track.isStreaming && FileManager.default.fileExists(atPath: track.folderPath) {
            guard let anlz = RekordboxShare.analysisURL(track.analysisDataPath), let grid = try? BeatGrid.load(anlz: anlz) else { continue }
            let rb = grid.tempoChanges
            guard !rb.isEmpty else { continue }
            let url = URL(filePath: track.folderPath)
            guard let analysis = try? await PartAnalyzer.analyze(fileAt: url, cacheKey: track.uuid),
                  let onset = try? OnsetEnvelope.compute(url: url),
                  let estimate = GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset)
            else { continue }
            checked += 1
            let ours = estimate.segments.map { String(format: "%.0f", $0.bpm) }.joined(separator: "→")
            if estimate.segments.count > 1 { split += 1 }
            print("\(track.title.prefix(26)) · rekordbox \(rb.map { String(format: "%.0f", $0) }.joined(separator: "→")) · DJCrate \(ours)")
        }
        print("변속 곡 \(checked)곡 중 DJCrate도 구간을 나눈 곡 \(split)")
    }

    /// 한 곡의 BPM 후보별 어택 점수(위상 ±25ms 최적화 포함)와 히스토그램 봉우리를 본다.
    static func tempoDebug(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        guard args.count > 1, let track = library.tracks.first(where: { $0.title.contains(args[1]) }) else { print("곡 없음"); return }
        let url = URL(filePath: track.folderPath)
        let onset = try OnsetEnvelope.compute(url: url)
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: track.uuid)
        let offset = RekordboxTimeline.predictedOffset(url: url)
        print("rb BPM \(track.bpm ?? 0) · MU BPM \(analysis.bpm ?? 0) · 시간축 차이 \(offset * 1000)ms")
        if let dat = RekordboxShare.analysisURL(track.analysisDataPath), let grid = try? BeatGrid.load(anlz: dat), let first = grid.beats.first {
            let rbTimes = grid.beats.map { $0.time - offset }
            let rbScore = rbTimes.reduce(0.0) { $0 + Double(onset.value(at: $1)) } / Double(rbTimes.count)
            print(String(format: "rekordbox 그리드 박 평균 어택 %.4f (첫 박 %.3f)", rbScore, first.time))
        }
        let center = track.bpm ?? analysis.bpm ?? 120
        let start = analysis.beats.first ?? 0
        for step in -12...12 {
            let bpm = (center * 100).rounded() / 100 + Double(step) * 0.02
            let period = 60 / bpm
            var best = 0.0
            // 위상은 MU 첫 박 근처 한 주기 안을 1ms 간격으로
            for phaseStep in 0..<Int(period * 1000) {
                let phase = start + Double(phaseStep) / 1000
                var sum = 0.0, n = 0
                var t = phase.truncatingRemainder(dividingBy: period)
                while t < onset.duration - 1 { sum += Double(onset.value(at: t)); n += 1; t += period }
                best = max(best, sum / Double(max(n, 1)))
            }
            print(String(format: "  %.2f BPM · 최고 평균 어택 %.4f", bpm, best))
        }
    }

    /// 한 곡의 rekordbox 파형 길이·상관 곡선을 본다.
    static func timelineDebug(_ args: [String]) async throws {
        let snapshot = try LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        guard args.count > 1, let track = library.tracks.first(where: { $0.title.contains(args[1]) }),
              let dat = RekordboxShare.analysisURL(track.analysisDataPath) else { print("곡 없음"); return }
        let heights = try RekordboxTimeline.detailWaveform(ext: RekordboxTimeline.extURL(forAnalysis: dat))
        let file = try AVAudioFile(forReading: URL(filePath: track.folderPath))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        print("rb 칸 \(heights.count) · 길이×150 \(Int(duration * 150)) · 길이 \(duration)")
        print("rb 앞 60칸:", heights.prefix(60).map(String.init).joined(separator: " "))
        let peaks = try RekordboxTimeline.millisecondPeaks(url: URL(filePath: track.folderPath))
        let ours = RekordboxTimeline.binned(peaks, lagMs: 0, bins: 60).map { String(format: "%.0f", $0 * 31) }
        print("우리 앞 60칸:", ours.joined(separator: " "))
        for lag in stride(from: -400, through: 400, by: 20) {
            let c = RekordboxTimeline.correlation(heights.map(Double.init), RekordboxTimeline.binned(peaks, lagMs: Double(lag), bins: heights.count))
            print(String(format: "  lag %+4dms · %.3f", lag, c))
        }
    }

    static func bpmHistogram(_ args: [String]) async throws {
        let library = try RekordboxLibrary.load(snapshot: LibrarySnapshot.latest())
        let bpms = library.tracks.compactMap(\.bpm).filter { $0 > 0 }
        var bins: [Int: Int] = [:]
        for bpm in bpms { bins[Int(bpm / 5) * 5, default: 0] += 1 }
        for (start, count) in bins.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%3d~%3d %5d %@", start, start + 4, count, String(repeating: "█", count: max(1, count / 20))))
        }
    }

    static func timelineCheck(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 40
        try timelineCheck(limit: limit, snapshotPath: value(after: "--db", in: args))
    }

    // MARK: - 도움

    static func gridCheck(limit: Int, snapshotPath: String?) throws {
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        var errors: [Double] = [], segmentCounts: [Int: Int] = [:], checked = 0, mismatchedCount = 0
        for track in library.tracks.sorted(by: { $0.uuid < $1.uuid }).prefix(limit) {
            guard let url = RekordboxShare.analysisURL(track.analysisDataPath),
                  let grid = try? BeatGrid.load(anlz: url), !grid.beats.isEmpty else { continue }
            let draft = GridDraft(trackUUID: track.uuid, grid: grid)
            let duration = Double(track.lengthSeconds) + 1
            let rebuilt = draft.grid(duration: max(duration, grid.beats.last!.time + 0.01))
            segmentCounts[draft.segments.count, default: 0] += 1
            checked += 1
            // 원본 박마다 가장 가까운 재생성 박과의 차이
            var worst = 0.0
            for beat in grid.beats {
                let nearest = rebuilt.snap(beat.time)
                worst = max(worst, abs(nearest - beat.time))
            }
            if rebuilt.beats.count != grid.beats.count { mismatchedCount += 1 }
            errors.append(worst * 1000)
            if worst > 0.01 { print("  큰 오차 \(Int(worst * 1000))ms · 구간 \(draft.segments.count) · \(track.title.prefix(30))") }
        }
        errors.sort()
        func pct(_ p: Double) -> Double { errors.isEmpty ? 0 : errors[min(errors.count - 1, Int(Double(errors.count - 1) * p))] }
        print("검사 \(checked)곡 · 구간 수 분포 \(segmentCounts.sorted { $0.key < $1.key })")
        print(String(format: "곡별 최대 오차(ms): 중앙값 %.2f · 95%% %.2f · 99%% %.2f · 최대 %.2f", pct(0.5), pct(0.95), pct(0.99), errors.last ?? 0))
        print("오차 ≤1ms 곡: \(errors.filter { $0 <= 1.0005 }.count) · ≤2ms: \(errors.filter { $0 <= 2.0005 }.count) · 박 개수 불일치 곡: \(mismatchedCount)")
    }

    /// MU 박·마디로 추정한 그리드를 rekordbox 그리드와 비교한다.
    static func evaluateGridEstimates(limit: Int, snapshotPath: String?) async throws {
        if let ratio = ProcessInfo.processInfo.environment["DJC_HALF"].flatMap(Double.init) { GridEstimator.halfBeatRatio = ratio }
        if let ratio = ProcessInfo.processInfo.environment["DJC_SINGLE"].flatMap(Double.init) { GridEstimator.singleSegmentRatio = ratio }
        if let spread = ProcessInfo.processInfo.environment["DJC_SPREAD"].flatMap(Double.init) { GridEstimator.tempoSpread = spread }
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let playable = library.tracks.filter { !$0.isStreaming && FileManager.default.fileExists(atPath: $0.folderPath) }
        let withGrid = playable.filter { track in
            guard let url = RekordboxShare.analysisURL(track.analysisDataPath), let grid = try? BeatGrid.load(anlz: url) else { return false }
            return !grid.beats.isEmpty
        }
        print("재생 가능 \(playable.count)곡 · rekordbox 그리드 있음 \(withGrid.count) · 없음 \(playable.count - withGrid.count) · BPM 없음 \(playable.filter { ($0.bpm ?? 0) <= 0 }.count)")

        // 이미 분석 캐시가 있는 곡을 먼저 쓰고, 모자라면 uuid 순으로 채운다(표본이 매번 같게).
        let cached = Set((try? FileManager.default.contentsOfDirectory(atPath: PartAnalyzer.cacheDirectory.path)) ?? [])
            .compactMap { $0.split(separator: "-").first.map(String.init) }
        let sample = (withGrid.filter { cached.contains($0.uuid) } + withGrid.sorted { $0.uuid < $1.uuid })
            .reduce(into: [Track]()) { list, track in if !list.contains(where: { $0.id == track.id }) { list.append(track) } }
            .prefix(limit)

        var checked = 0, failed = 0, octave = 0, bpmClose = 0, gridOK = 0, downbeatOK = 0, confident = 0, confidentGridOK = 0
        var multiTruth = 0, multiEstimate = 0
        var diagMU = 0, diagAccent = 0, diagAccentLow = 0, diagCount = 0
        var oursBetter = 0, rbBetter = 0, tie = 0
        var bpmErrors: [Double] = []
        for track in sample {
            guard let anlz = RekordboxShare.analysisURL(track.analysisDataPath), let truthGrid = try? BeatGrid.load(anlz: anlz) else { continue }
            let analysis: PartAnalysis
            do { analysis = try await PartAnalyzer.analyze(fileAt: URL(filePath: track.folderPath), cacheKey: track.uuid) } catch { failed += 1; continue }
            let audioURL = URL(filePath: track.folderPath)
            let onset = ProcessInfo.processInfo.environment["DJC_NO_ONSET"] == nil ? try? OnsetEnvelope.compute(url: audioURL) : nil
            // 추정은 DJCrate 시간축, rekordbox 그리드는 rekordbox 시간축 → 형식 규칙으로 옮겨 비교한다.
            let timelineOffset = RekordboxTimeline.predictedOffset(url: audioURL)
            guard var estimate = GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset) else {
                failed += 1
                print("  추정 실패 · 박 \(analysis.beats.count) · \(track.title.prefix(30))")
                continue
            }
            checked += 1
            for i in estimate.segments.indices { estimate.segments[i].start += timelineOffset }
            let truth = GridDraft.segments(from: truthGrid)
            if truth.count > 1 { multiTruth += 1 }
            if estimate.segments.count > 1 { multiEstimate += 1 }
            let grid = GridDraft(trackUUID: track.uuid, base: [], segments: estimate.segments).grid(duration: analysis.duration + 1)
            let ratio = estimate.bpm / truth[0].bpm
            if abs(ratio - 2) < 0.02 || abs(ratio - 0.5) < 0.01 { octave += 1 }
            let error = abs(estimate.bpm - truth[0].bpm)
            bpmErrors.append(error)
            if error < 0.05 { bpmClose += 1 }

            // 곡 앞뒤 10%를 뺀 rekordbox 박마다 가장 가까운 추정 박과의 거리, 1박 일치
            let lo = analysis.duration * 0.1, hi = analysis.duration * 0.9
            var distances: [Double] = [], downbeats = 0, downbeatHits = 0
            for beat in truthGrid.beats where beat.time >= lo && beat.time <= hi {
                guard let nearest = nearestBeat(grid, to: beat.time) else { continue }
                distances.append(abs(nearest.time - beat.time) * 1000)
                if beat.number == 1 {
                    downbeats += 1
                    if nearest.number == 1 { downbeatHits += 1 }
                }
            }
            distances.sort()
            let p90 = distances.isEmpty ? .infinity : distances[Int(Double(distances.count - 1) * 0.9)]
            let aligned = p90 <= 20
            let downbeatRate = downbeats > 0 ? Double(downbeatHits) / Double(downbeats) : 0
            if aligned { gridOK += 1 }
            if aligned && downbeatRate >= 0.9 { downbeatOK += 1 }
            if estimate.isConfident {
                confident += 1
                if aligned { confidentGridOK += 1 }
            }
            if ProcessInfo.processInfo.environment["DJC_DIAG"] != nil, let onset, let first = grid.beats.first {
                // 1박 어긋남(칸) · 반 박 비율(저역·전체)
                var deltas = [0, 0, 0, 0]
                for beat in truthGrid.beats where beat.number == 1 && beat.time >= lo && beat.time <= hi {
                    if let nearest = nearestBeat(grid, to: beat.time) { deltas[(nearest.number - 1 + 4) % 4] += 1 }
                }
                let period = 60 / estimate.bpm
                let times = grid.beats.map { $0.time - timelineOffset }.filter { $0 > first.time - timelineOffset }
                let on = times.reduce(0.0) { $0 + Double(onset.value(at: $1)) }, off = times.reduce(0.0) { $0 + Double(onset.value(at: $1 + period / 2)) }
                // 박 번호별 어택 합: 가장 센 번호를 1박으로 보면 rekordbox와 맞는가
                var accent = [0.0, 0.0, 0.0, 0.0], accentLow = [0.0, 0.0, 0.0, 0.0]
                for beat in grid.beats {
                    accent[beat.number - 1] += Double(onset.value(at: beat.time - timelineOffset))
                    accentLow[beat.number - 1] += Double(onset.lowValue(at: beat.time - timelineOffset))
                }
                let rbNumber = (deltas.indices.max { deltas[$0] < deltas[$1] } ?? 0) + 1
                let accentNumber = (accent.indices.max { accent[$0] < accent[$1] } ?? 0) + 1
                let accentLowNumber = (accentLow.indices.max { accentLow[$0] < accentLow[$1] } ?? 0) + 1
                if aligned { diagMU += rbNumber == 1 ? 1 : 0; diagAccent += rbNumber == accentNumber ? 1 : 0; diagAccentLow += rbNumber == accentLowNumber ? 1 : 0; diagCount += 1 }
                print(String(format: "  [진단] %@ · rb 1박에 놓인 우리 박 번호 분포 %@ · 어택최대 %d 저역최대 %d · 반박/정박 %.2f · %@",
                             aligned ? "박맞음" : (p90 > period * 1000 * 0.35 ? "반박?" : "어긋남"), deltas.description, accentNumber, accentLowNumber, off / max(on, 1e-9), String(track.title.prefix(20))))
            }
            if ProcessInfo.processInfo.environment["DJC_VERBOSE"] != nil {
                // 부호 있는 차이(추정 - rekordbox), 박 간격으로 접어서 본다.
                let period = 60 / truth[0].bpm
                var signed: [Double] = []
                for beat in truthGrid.beats where beat.time >= lo && beat.time <= hi {
                    guard let nearest = nearestBeat(grid, to: beat.time) else { continue }
                    var d = (nearest.time - beat.time).truncatingRemainder(dividingBy: period)
                    if d > period / 2 { d -= period } else if d < -period / 2 { d += period }
                    signed.append(d * 1000)
                }
                signed.sort()
                let ext = (track.folderPath as NSString).pathExtension.lowercased()
                print(String(format: "  [상세] %@ · 차이 중앙값 %+.1fms · rb %.2f 추정 %.2f · %@", ext, signed.isEmpty ? 0 : signed[signed.count / 2],
                             truth[0].bpm, estimate.bpm, String(track.title.prefix(24))))
            }
            if !aligned, let onset {
                // 어긋난 곡: 실제 어택에 더 잘 맞는 쪽은? (박 위치의 평균 어택)
                let rbScore = truthGrid.beats.reduce(0.0) { $0 + Double(onset.value(at: $1.time - timelineOffset)) } / Double(truthGrid.beats.count)
                let ours = grid.beats.filter { $0.time >= truthGrid.beats[0].time }
                let ourScore = ours.reduce(0.0) { $0 + Double(onset.value(at: $1.time - timelineOffset)) } / Double(max(ours.count, 1))
                if ourScore > rbScore * 1.05 { oursBetter += 1 } else if rbScore > ourScore * 1.05 { rbBetter += 1 } else { tie += 1 }
            }
            if !aligned || downbeatRate < 0.9 {
                print(String(format: "  %@ · rb %.2f(%d구간) · 추정 %.2f(%d구간) · p90 %.0fms · 1박 %.0f%% · 잔차 %.1fms · 적합 %.0f%% · %@",
                             aligned ? "1박만 틀림" : "어긋남", truth[0].bpm, truth.count, estimate.bpm, estimate.segments.count,
                             p90, downbeatRate * 100, estimate.medianResidualMs, estimate.inlierRatio * 100, String(track.title.prefix(28))))
            }
        }
        bpmErrors.sort()
        func pct(_ p: Double) -> Double { bpmErrors.isEmpty ? 0 : bpmErrors[Int(Double(bpmErrors.count - 1) * p)] }
        print("비교 \(checked)곡(실패 \(failed)) · rekordbox 변속곡 \(multiTruth) · 추정 변속곡 \(multiEstimate)")
        print(String(format: "BPM 오차 중앙값 %.3f · 90%% %.3f · ±0.05 안 %d곡 · 두 배/절반 %d곡", pct(0.5), pct(0.9), bpmClose, octave))
        if diagCount > 0 { print("[진단] 박 맞은 \(diagCount)곡에서 1박 일치: MU 마디 \(diagMU) · 어택 최대 \(diagAccent) · 저역 어택 최대 \(diagAccentLow)") }
        print("어긋난 곡에서 실제 어택에 더 잘 맞는 쪽: DJCrate \(oursBetter) · rekordbox \(rbBetter) · 비슷 \(tie)")
        print("박 위치 일치(90%가 20ms 안) \(gridOK)곡 · 1박까지 일치 \(downbeatOK)곡 · 자신 있는 추정 \(confident)곡 중 박 일치 \(confidentGridOK)")
    }

    /// rekordbox 파형과 DJCrate 디코딩을 맞대어 파일별 시간축 차이를 재고, 프라이밍 정보와 비교한다.
    static func timelineCheck(limit: Int, snapshotPath: String?) throws {
        let snapshot = try snapshotPath.map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        // 형식이 고루 섞이게 확장자별로 번갈아 뽑는다.
        let candidates = library.tracks.filter { !$0.isStreaming && FileManager.default.fileExists(atPath: $0.folderPath) }
            .sorted { $0.uuid < $1.uuid }
        let byExt = Dictionary(grouping: candidates) { ($0.folderPath as NSString).pathExtension.lowercased() }
        var sample: [Track] = []
        var cursors = byExt.mapValues { _ in 0 }
        while sample.count < limit, cursors.contains(where: { byExt[$0.key]!.count > $0.value }) {
            for ext in byExt.keys.sorted() where sample.count < limit {
                let i = cursors[ext]!
                if i < byExt[ext]!.count { sample.append(byExt[ext]![i]); cursors[ext] = i + 1 }
            }
        }
        var rows: [(ext: String, offset: Double, corr: Double, priming: Int, remainder: Int, rate: Double, format: String)] = []
        var predictions: [(String, Double, Double, Double)] = []
        var waves: [(ext: String, offset: Double, corr: Double, predicted: Double, header: String)] = []
        for track in sample {
            guard let dat = RekordboxShare.analysisURL(track.analysisDataPath),
                  let grid = try? BeatGrid.load(anlz: dat), grid.beats.count > 32 else { continue }
            let url = URL(filePath: track.folderPath)
            guard let onset = try? OnsetEnvelope.compute(url: url) else { continue }
            // rekordbox 박을 lag만큼 당겼을 때 DJCrate 디코딩의 어택과 가장 잘 겹치는 lag(그리드 기준)
            let best = onset.bestLag(for: grid.beats.map(\.time), range: -0.12...0.12)
            // rekordbox 파형과 맞댄 순수한 시간축 차이(그리드 무관)
            let heights = (try? RekordboxTimeline.detailWaveform(ext: RekordboxTimeline.extURL(forAnalysis: dat))) ?? []
            let wave = heights.isEmpty ? nil : try? RekordboxTimeline.measureOffset(audio: url, rekordboxHeights: heights)
            waves.append((ext: (track.folderPath as NSString).pathExtension.lowercased(), offset: (wave?.offset ?? .nan) * 1000,
                          corr: wave?.correlation ?? 0, predicted: RekordboxTimeline.predictedOffset(url: url) * 1000,
                          header: (track.folderPath as NSString).pathExtension.lowercased() == "mp3" ? RekordboxTimeline.mp3Header(url: url) : ""))
            let info = RekordboxTimeline.packetInfo(url: url)
            let row = (ext: (track.folderPath as NSString).pathExtension.lowercased(), offset: best.lag * 1000,
                       corr: best.sharpness, priming: info?.primingFrames ?? -1, remainder: info?.remainderFrames ?? -1,
                       rate: info?.sampleRate ?? 0, format: info?.formatID ?? "?")
            rows.append(row)
            let predicted = RekordboxTimeline.predictedOffset(url: url) * 1000
            predictions.append((row.ext, row.offset, predicted, row.corr))
            if ProcessInfo.processInfo.environment["DJC_VERBOSE"] != nil || (row.corr >= 1.5 && abs(row.offset - predicted) > 5) {
                let header = row.ext == "mp3" ? RekordboxTimeline.mp3Header(url: url)
                    : ["m4a", "mp4", "aac"].contains(row.ext) ? RekordboxTimeline.mp4Header(url: url) : ""
                print(String(format: "  %@ %@ · 실측 %+6.1fms · 예측 %+5.1fms · 선명도 %.2f · 프라이밍 %d 패딩 %d · %.0fHz · %@ · %@",
                             row.ext, row.format, row.offset, predicted, row.corr, row.priming, row.remainder, row.rate, header, String(track.title.prefix(20))))
            }
        }
        print("\n[파형 실측] 형식별 예측 적중(상관 0.8 이상, ±3ms 안)")
        for (ext, group) in Dictionary(grouping: waves.filter { $0.corr >= 0.8 }, by: \.ext).sorted(by: { $0.key < $1.key }) {
            let hits = group.filter { abs($0.offset - $0.predicted) <= 3 }.count
            let sorted = group.map(\.offset).sorted()
            print(String(format: "  %@: %d/%d · 실측 중앙값 %+.1fms (범위 %+.1f~%+.1f)", ext, hits, group.count, sorted[sorted.count / 2], sorted.first!, sorted.last!))
            for miss in group where abs(miss.offset - miss.predicted) > 3 {
                print(String(format: "    빗나감 실측 %+.1f · 예측 %+.1f · 상관 %.2f %@", miss.offset, miss.predicted, miss.corr, miss.header))
            }
        }
        print("  상관 낮아 제외: \(waves.filter { $0.corr < 0.8 }.count)곡")
        print("\n[그리드 기준] 예측 적중(선명도 1.5 이상, ±5ms 안)")
        for (ext, group) in Dictionary(grouping: predictions.filter { $0.3 >= 1.5 }, by: \.0).sorted(by: { $0.key < $1.key }) {
            let hits = group.filter { abs($0.1 - $0.2) <= 5 }.count
            print("  \(ext): \(hits)/\(group.count)")
        }
        let reliable = predictions.filter { $0.3 >= 1.5 }
        print("  전체: \(reliable.filter { abs($0.1 - $0.2) <= 5 }.count)/\(reliable.count) · 선명도 낮아 제외 \(predictions.count - reliable.count)")
        print("\n형식별 요약 (선명도 1.5 이상)")
        for (ext, group) in Dictionary(grouping: rows.filter { $0.corr >= 1.5 }, by: \.ext).sorted(by: { $0.key < $1.key }) {
            let diffs = group.map { $0.offset - (Double($0.priming) / max($0.rate, 1) * 1000) }.sorted()
            let offsets = group.map(\.offset).sorted()
            print(String(format: "  %@ %d곡 · 차이 중앙값 %+.1fms (범위 %+.1f~%+.1f) · 차이-프라이밍 중앙값 %+.1fms (범위 %+.1f~%+.1f)",
                         ext, group.count, offsets[offsets.count / 2], offsets.first!, offsets.last!,
                         diffs[diffs.count / 2], diffs.first!, diffs.last!))
        }
    }
}
