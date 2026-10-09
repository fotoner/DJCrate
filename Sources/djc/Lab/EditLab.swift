import AVFoundation
import DJCAdapters
import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 곡 편집 PoC(#80): 마디 구간을 이어 새 파일로 렌더하고, 변환한 그리드·옮긴 큐와 함께 곡 넣기 흐름으로 보낸다.
/// 원본 음원·라이브 rekordbox에는 쓰지 않는다(넣기는 추가한 곡 목록이나 --into 사본 DB로만).
enum EditLab {
    static let all: [Command] = [
        Command("edit-render", "<ContentID|음원> --bars 1-16,1-16,17-64 --out <파일.wav> [--db 스냅샷] [--plan] [--vocal] [--bits 24] [--title 제목] [--check-grid] [--stage] [--into <사본.db> --share <사본 share> [--dry-run]]",
                "마디 구간을 이어 WAV·AIFF로 렌더(원본 그대로). --stage면 추가한 곡으로, --into면 사본 DB에 그리드·큐와 함께 넣는다", EditLab.editRender),
    ]

    /// 편집할 원본: 곡(있으면)·음원·그리드(rekordbox 시간축)·큐·시간축 차이
    struct Source {
        var track: Track?
        var url: URL
        var grid: [GridSegment]
        var gridOrigin: String
        var cues: [EditableCue]
        var offset: Double
        var duration: Double
    }

    static func editRender(_ args: [String]) async throws {
        let valued: Set<String> = ["--bars", "--out", "--db", "--bits", "--title", "--into", "--share"]
        guard let target = MainCommands.operands(args, valued: valued).first, let barsText = value(after: "--bars", in: args),
              let outPath = value(after: "--out", in: args) else { throw UsageError() }
        let bars = try BarRange.list(barsText)
        // 넣을 곳은 렌더 전에 확인한다(라이브면 파일도 만들지 않는다).
        let into = value(after: "--into", in: args).map { URL(filePath: $0) }
        let share = value(after: "--share", in: args).map { URL(filePath: $0) }
        if let into {
            guard let share else { throw UsageError() }
            try checkCopy(database: into, share: share)
        }
        let source = try await loadSource(target, snapshot: value(after: "--db", in: args))
        print("원본: \(source.track.map { "\($0.title) · ID \($0.id)" } ?? source.url.lastPathComponent)")
        print(String(format: "  %@ · 길이 %@ · 시간축 차이 %+.1fms · 그리드 %@ · 큐 %d개", source.url.pathExtension.uppercased(),
                     clock(source.duration), source.offset * 1000, source.gridOrigin, source.cues.count))

        let edit = try TrackEdit(grid: source.grid, sourceDuration: source.duration, bars: bars)
        let layout = edit.layout
        print(String(format: "  %.3f BPM · 1마디 %.3f초 · 첫 다운비트 %.3f초 · 마디 %d개%@%@", layout.segment.bpm, layout.barLength,
                     layout.firstDownbeat, layout.count, layout.hasLeadIn ? " · 0마디(곡 머리) 있음" : "",
                     layout.lastBarIsPartial ? " · 마지막 마디는 잘림" : ""))
        if args.contains("--vocal") { try await printVocalRuns(source, layout: layout) }

        print("\n시간표(\(edit.pieces.count)조각, 이음새 \(max(0, edit.pieces.count - 1))곳):")
        for piece in edit.pieces {
            print("  마디 \(piece.bars)\t원본 \(clock(piece.sourceStart))–\(clock(piece.sourceEnd))\t→ 출력 \(clock(piece.outputStart))–\(clock(piece.outputEnd))")
        }
        let grid = edit.outputGrid
        print(String(format: "출력: 길이 %@ · 그리드 %.3f BPM, %.3f초 %d박에서", clock(edit.duration), grid.bpm, grid.start, grid.firstBeatNumber))

        let carried = edit.carry(source.cues, newID: { UUID() })
        let outputBars = try BarLayout(grid: [grid], duration: edit.duration)
        for cue in carried.placed {
            print("  큐 \(label(cue))\t→ 출력 \(clock(cue.time)) (\(outputBars.bar(at: cue.time))마디)\(cue.loop.map { String(format: " · 루프 %.2f초", $0.end - cue.time) } ?? "")")
        }
        for drop in carried.dropped {
            print("  ✗ 큐 \(label(drop.cue)) 원본 \(clock(drop.cue.time)) — \(drop.reason.label)")
        }
        guard !args.contains("--plan") else { print("\n계획만 봤습니다(--plan). 렌더하지 않았습니다."); return }

        let output = URL(filePath: outPath)
        let started = Date()
        let rate = try AVAudioFile(forReading: source.url).processingFormat.sampleRate
        let spans = edit.frames(sampleRate: rate, sourceOffset: source.offset)
        let result = try EditRenderer.render(spans, source: source.url, to: output, bitDepth: Int(value(after: "--bits", in: args) ?? "") ?? 16)
        print(String(format: "\n✓ 렌더: %@ · %lld프레임(%.3f초, %.0fHz %d채널) · 이음새 %d곳 · %.1f초 걸림", output.lastPathComponent,
                     result.frames, result.duration, result.sampleRate, result.channels, result.seams, Date().timeIntervalSince(started)))
        let check = try sampleCheck(spans, source: source.url, output: output)
        print(String(format: "  샘플 대조(원본을 처음부터 이어 읽어 비교, 이음새 앞 섞는 구간 제외): %d프레임 · 최대 차이 %.6f(16비트 한 칸 %.6f)%@",
                     check.compared, check.maxDifference, 1.0 / 32768, check.clipped > 0 ? " · 원본 1.0 넘는 \(check.clipped)프레임 제외" : ""))
        if args.contains("--check-grid") { try await checkGrid(source, output: output, grid: grid, duration: edit.duration) }

        if args.contains("--stage") {
            let title = value(after: "--title", in: args) ?? source.track.map { "\($0.title) (Edit)" }
                ?? output.deletingPathExtension().lastPathComponent
            let staged = try await StageEdit.files(home: DJCPaths.userData).stage(
                EditStagingRequest(file: output, grid: [edit.outputGrid], cues: carried.placed, source: source.track, title: title))
            print("✓ 추가한 곡에 넣음: \(staged.uuid) · 그리드 초안 · 큐 초안 \(carried.placed.count)개 · 데이터 폴더 \(DJCPaths.userData.path)")
        }
        if let into, let share {
            try await addToCopy(output, database: into, share: share, grid: grid, cues: carried.placed, source: source.track,
                                title: value(after: "--title", in: args), dryRun: args.contains("--dry-run"))
        }
    }

    static func label(_ cue: EditableCue) -> String {
        let kind = cue.kind.slotLetter.map { "핫큐 \($0)" } ?? "메모리"
        return cue.name.isEmpty ? kind : "\(kind) \(cue.name)"
    }

    // MARK: - 원본

    static func loadSource(_ target: String, snapshot: String?) async throws -> Source {
        let isID = !target.isEmpty && target.allSatisfy(\.isNumber)
        let library: RekordboxLibrary? = try {
            if let snapshot { return try RekordboxLibrary.load(snapshot: URL(filePath: snapshot)) }
            guard let latest = try? LibrarySnapshot.latest() else {
                if isID { throw DJCError.snapshotNotFound }
                return nil
            }
            return try RekordboxLibrary.load(snapshot: latest)
        }()
        let path = target.precomposedStringWithCanonicalMapping
        let track = library?.tracks.first { isID ? $0.id == target : $0.folderPath.precomposedStringWithCanonicalMapping == path }
        if isID, track == nil { throw DJCError.editRefused("ContentID \(target) 곡을 스냅샷에서 찾지 못했습니다. djc search로 확인하세요") }
        let url = URL(filePath: track?.folderPath ?? target)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DJCError.editRefused("음원 파일이 없습니다: \(url.path). 파일 위치를 확인하세요")
        }
        let offset = RekordboxTimeline.predictedOffset(url: url)
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate + offset

        // 그리드·큐는 덱과 같은 순서로: DJCrate 초안이 있으면 초안, 없으면 rekordbox 값(모두 rekordbox 시간축)
        var grid: [GridSegment] = [], origin = "없음"
        var cues: [EditableCue] = []
        if let track {
            if let draft = GridDraftStore.load(trackUUID: track.uuid) {
                grid = draft.segments; origin = "DJCrate 초안"
            } else if let anlz = RekordboxShare.analysisURL(track.analysisDataPath), let beats = try? BeatGrid.load(anlz: anlz), !beats.beats.isEmpty {
                grid = GridDraft.segments(from: beats); origin = "rekordbox"
            }
            cues = CueDraftStore.load(trackUUID: track.uuid)?.cues
                ?? CueDraft(trackUUID: track.uuid, rekordboxCues: library?.cues(for: track) ?? []).cues
        }
        if grid.isEmpty, track == nil, let estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: cacheKey(url)) {
            grid = estimate.segments.map { GridSegment(start: $0.start + offset, bpm: $0.bpm, firstBeatNumber: $0.firstBeatNumber) }
            origin = estimate.isConfident ? "추정" : "추정(확인 필요)"
        }
        return Source(track: track, url: url, grid: grid, gridOrigin: origin, cues: cues, offset: offset, duration: duration)
    }

    /// 컬렉션 밖 음원의 분석 캐시 키(곡 넣기 `add-파일번호`와 같은 방식)
    static func cacheKey(_ url: URL) -> String {
        "edit-\((try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? 0)"
    }

    /// 보컬 없는 마디 구간 후보(MusicUnderstanding 보컬 활동, 마디 평균 0.25 미만이 4마디 이상)
    static func printVocalRuns(_ source: Source, layout: BarLayout) async throws {
        let analysis = try await PartAnalyzer.analyze(fileAt: source.url, cacheKey: source.track?.uuid)
        guard !analysis.vocal.isEmpty else { print("  보컬 활동: 분석 값 없음"); return }
        // 분석은 음원 시간축이라 rekordbox 시간축 마디 경계에서 시간축 차이를 뺀다.
        let values = (1...max(1, layout.count)).map { bar -> Double in
            let from = layout.start(ofBar: bar) - source.offset, to = layout.end(ofBar: bar) - source.offset
            let inside = analysis.vocal.filter { $0.time >= from && $0.time < to }.map { max($0.value, 0) }
            return inside.isEmpty ? 0 : inside.reduce(0, +) / Double(inside.count)
        }
        let runs = BarLayout.runs(values, below: 0.25, minimum: 4)
        print("  보컬 없는 구간 후보: \(runs.isEmpty ? "없음" : runs.map(\.description).joined(separator: ", "))")
    }

    // MARK: - 확인

    struct SampleCheck {
        var compared: Int
        var maxDifference: Float
        var clipped: Int
    }

    /// 출력의 조각마다 원본을 처음부터 이어 읽은 값과 비교한다(렌더러의 찾기·이어 읽기가 샘플 단위로 맞는지). 왼쪽 채널만.
    static func sampleCheck(_ spans: [EditFrameSpan], source: URL, output: URL) throws -> SampleCheck {
        func channel(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { return [] }
            var values: [Float] = []
            values.reserveCapacity(Int(file.length))
            // MP3는 끝에서 0프레임 대신 eofErr를 던진다.
            while file.framePosition < file.length, (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                values += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            return values
        }
        let original = try channel(source), rendered = try channel(output)
        var check = SampleCheck(compared: 0, maxDifference: 0, clipped: 0)
        for (index, span) in spans.enumerated() {
            let hold = index + 1 < spans.count ? spans[index + 1].crossfadeFrames : 0
            for k in 0..<Int(span.frameCount - hold) {
                let o = Int(span.outputFrame) + k, s = Int(span.sourceFrame) + k
                guard o < rendered.count else { break }
                let expected: Float = s >= 0 && s < original.count ? original[s] : 0
                if abs(expected) > 1 { check.clipped += 1; continue }
                check.maxDifference = max(check.maxDifference, abs(rendered[o] - expected))
                check.compared += 1
            }
        }
        return check
    }

    /// 렌더한 소리에서 박을 추정해 변환한 그리드와 견준다. 원본도 같은 방법으로 rekordbox 그리드와 견줘 기준으로 삼는다.
    static func checkGrid(_ source: Source, output: URL, grid: GridSegment, duration: Double) async throws {
        func deviation(_ estimated: [GridSegment], shift: Double, against ours: [GridSegment], duration: Double) -> (median: Double, p90: Double)? {
            let theirs = GridDraft(trackUUID: "", base: [], segments: estimated.map {
                GridSegment(start: $0.start + shift, bpm: $0.bpm, firstBeatNumber: $0.firstBeatNumber)
            }).grid(duration: duration)
            let reference = GridDraft(trackUUID: "", base: [], segments: ours).grid(duration: duration + 1)
            let gaps = theirs.beats.filter { $0.time > duration * 0.05 && $0.time < duration * 0.95 }
                .compactMap { beat in nearestBeat(reference, to: beat.time).map { abs($0.time - beat.time) * 1000 } }.sorted()
            guard !gaps.isEmpty else { return nil }
            return (gaps[gaps.count / 2], gaps[min(gaps.count - 1, gaps.count * 9 / 10)])
        }
        let analysis = try await PartAnalyzer.analyze(fileAt: output, cacheKey: nil)
        let onset = try OnsetEnvelope.compute(url: output)
        guard let estimate = GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset),
              let out = deviation(estimate.segments, shift: 0, against: [grid], duration: duration) else {
            print("  그리드 확인: 출력에서 박을 추정하지 못했습니다"); return
        }
        print(String(format: "  그리드 확인(출력): 추정 %.3f BPM · 변환 그리드와 박 차이 중앙값 %.1fms · 90%% %.1fms", estimate.bpm, out.median, out.p90))
        if let original = try await GridSuggestion.estimate(fileAt: source.url, cacheKey: source.track?.uuid ?? cacheKey(source.url)),
           let base = deviation(original.segments, shift: source.offset, against: source.grid, duration: source.duration) {
            print(String(format: "  그리드 확인(원본 기준): 추정 %.3f BPM · 원본 그리드와 박 차이 중앙값 %.1fms · 90%% %.1fms", original.bpm, base.median, base.p90))
        }
    }

    // MARK: - 사본 DB에 넣기

    /// 실험 명령은 사본에만 넣는다: 라이브 DB·share(DJC_REKORDBOX_DIR 포함)와 실제 rekordbox 폴더 안은 막는다.
    static func checkCopy(database: URL, share: URL) throws {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let realRoot = canonical(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer"))
        guard !RekordboxWriteGuard.system.isLive(database),
              ![database, share].contains(where: { canonical($0).hasPrefix(realRoot) || canonical($0) == canonical(RekordboxShare.directory) }) else {
            throw DJCError.editRefused("실험 명령은 rekordbox 라이브러리에 넣지 않습니다. djc snapshot 사본(DB·share)을 --into·--share로 주세요")
        }
    }

    /// 렌더한 파일을 사본 DB에 곡으로 넣는다(변환한 그리드로 분석 파일, 옮긴 큐, 원곡 정보).
    static func addToCopy(_ output: URL, database: URL, share: URL, grid: GridSegment, cues: [EditableCue], source: Track?,
                          title: String?, dryRun: Bool) async throws {
        try checkCopy(database: database, share: share)
        var plan = try TrackAddPlan.make(url: output, tags: try await AudioTags.read(url: output))
        if let source {
            plan.artist = source.artist; plan.album = source.album; plan.albumArtist = source.albumArtist
            plan.genre = source.genre; plan.composer = source.composer; plan.comment = source.comment
            plan.year = source.releaseYear ?? 0
        }
        plan.title = title ?? source.map { "\($0.title) (Edit)" } ?? plan.title
        let loudness = try Loudness.measure(fileAt: output)
        let analysis = RekordboxTrackWriter.Analysis(segments: [grid], loudness: loudness)
        let report = try RekordboxTrackWriter.add([plan], analyses: [plan.path: analysis], cues: [plan.path: cues], to: database,
                                                  shareRoot: share, dryRun: dryRun, backups: database.deletingLastPathComponent().appending(path: "backups"))
        for o in report.added {
            print("\(o.written ? "✓" : "✗") 사본 DB\(dryRun ? "(미리 보기)" : ""): \(o.title)\(o.contentID.map { " · ID \($0)" } ?? "")\(o.reason.map { " · \($0)" } ?? "")"
                  + " · 큐 \(o.cuesWritten ?? 0)개\(o.cueReason.map { "(\($0))" } ?? "") · 분석 파일 \(report.createdFiles.count)개")
        }
        // 넣은 분석 파일의 그리드를 다시 읽어 보낸 그리드와 비교한다.
        guard !dryRun, let id = report.added.first(where: \.written)?.contentID else { return }
        let db = try CipherDatabase.diagnostic(path: database.path, key: RekordboxKey.derive())
        defer { db.close() }
        var dat: String?
        try db.query("SELECT AnalysisDataPath FROM djmdContent WHERE ID = ?", [.text(id)]) { dat = $0.string(0) }
        let written = RekordboxShare.analysisURL(dat, root: share).flatMap { try? BeatGrid.load(anlz: $0) }
        let check = StagedTrack.ImportCheck.compare(sent: [grid], imported: written, duration: plan.duration, checkedOn: "")
        print(String(format: "  분석 파일 그리드: %@ · 최대 차이 %.1fms", check.result.rawValue, check.maxDeviationMs ?? .nan))
    }
}
