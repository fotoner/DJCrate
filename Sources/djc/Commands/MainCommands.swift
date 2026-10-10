import DJCApplication
import DJCDomain
import Foundation

/// 늘 쓰는 명령: 스냅샷·현황·파싱·분석, rekordbox 쓰기·되돌리기, 테스트 픽스처.
enum MainCommands {
    static let all: [Command] = [
        Command("snapshot", "[--force]", String(ui: "rekordbox master.db 스냅샷을 뜬다"), snapshot),
        PointSnapshotCommand.command,
        CacheCommand.command,
        Command("report", "[--db PATH] [--files] [--comment-preset none|anisong] [--json]", String(ui: "라이브러리 현황(기본: 최신 스냅샷)"), report),
        Command("analyze", String(ui: "<파일|ContentID> [--db PATH]"), String(ui: "곡 파트 분석(ContentID면 기존 큐와 비교)"), analyze),
        Command("reflection-dry-run", "[--out <파일.xml>] [--overwrite]", String(ui: "초안으로 반영 계획을 만들어 XML을 지정한 곳에만 쓴다(rekordbox는 그대로)"), reflectionDryRun),
        Command("cue-write", String(ui: "--db <사본.db> [--dry-run] [--uuid U] | --live"), String(ui: "큐 초안을 rekordbox DB에 직접 쓴다"), cueWrite),
        Command("track-add", String(ui: "--db <사본.db> [--share <분석 뿌리>] [--analyze] [--dry-run] <음원…> | --live …"),
                String(ui: "음원을 rekordbox 컬렉션에 넣는다(--analyze면 그리드·파형·오토게인까지, 기본은 사본)"), trackAdd),
        Command("track-delete", String(ui: "--db <사본.db> [--share <분석 뿌리>] [--dry-run] <ContentID…> | --live …"), String(ui: "곡을 rekordbox 컬렉션에서 뺀다(음원 파일은 그대로)"), trackDelete),
        Command("playlist-write", String(ui: "--db <사본.db> [--dry-run] <편집.json>"),
                String(ui: "재생 목록 편집(JSON 배열)을 사본 DB와 그 옆 masterPlaylists6.xml에 쓴다(라이브 라이브러리는 거부)"), playlistWrite),
        Command("rekordbox-restore", String(ui: "[--backup <폴더> (--db <사본> | --live) [--share <폴더>]]"), String(ui: "백업으로 되돌린다"), rekordboxRestore),
        XMLExportCommand.command,
        XMLDiffCommand.command,
        Command("schema-dump", String(ui: "<사본.db> <출력.sql> [--overwrite]"), String(ui: "사본 DB의 구조(CREATE 문)만 뽑는다"), schemaDump),
        Command("path", String(ui: "<제목> [--db PATH] [--json]"), String(ui: "제목으로 파일 경로 찾기"), path),
        Command("parse", String(ui: "\"<코멘트>\" [--json]"), String(ui: "애니송 프리셋으로 코멘트 파싱"), parse),
    ] + ReadCommands.all + UsbCommands.all

    static func snapshot(_ args: [String]) async throws {
        let url = try CLIComposition.live.library().load.takeSnapshot(force: args.contains("--force"))
        print(url.path)
    }

    static func report(_ args: [String]) async throws {
        let preset: CommentPreset
        if args.contains("--comment-preset") {
            guard let raw = value(after: "--comment-preset", in: args), let selected = CommentPreset(rawValue: raw) else {
                throw ReadFailure("invalid_arguments", String(ui: "코멘트 프리셋은 --comment-preset none 또는 anisong으로 쓰세요"))
            }
            preset = selected
        } else { preset = .none }
        // 사본 정하기·읽기는 JSON(`ReadCommands`)과 같은 유스케이스(`QueryLibrary`)
        let (snapshot, read) = try CLIComposition.live.library().queries
            .openCopy(database: value(after: "--db", in: args).map { URL(filePath: $0) }, commentPreset: preset)
        print(String(ui: "스냅샷: \(snapshot.path)\n"))
        print(read.report(args.contains("--files")).render())
    }

    static func analyze(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        try await analyzeTrack(args[1], snapshotPath: value(after: "--db", in: args))
    }

    /// 실제 초안으로 반영 계획을 만들어 보고 XML을 지정한 곳에만 쓴다(rekordbox는 건드리지 않는다).
    static func reflectionDryRun(_ args: [String]) async throws {
        // 출력 자리는 계획을 만들기 전에 확인한다(있으면 --overwrite 없이는 거부)
        if let out = value(after: "--out", in: args) {
            try CLIGuards.refuseExistingOutput(URL(filePath: out), overwrite: args.contains("--overwrite"))
        }
        // 초안 저장소·XML 형식은 앱의 반영 XML과 같은 유스케이스(`ExportXML`)
        let composition = CLIComposition.live
        let export = composition.library().exportXML
        let plans = try export.dryRunPlans(snapshotDirectory: composition.location.snapshotDirectory)
        for (plan, cueChanges) in plans.map({ ($0.plan, $0.cueChanges) }) {
            print(String(ui: "• \(plan.title.prefix(30)) · 큐 변경 \(cueChanges) · 그리드 변경 \(String(plan.gridChanged)) · 표시 \(plan.beforeMarks.count)→\(plan.marks.count) · ") +
                  (plan.isEligible ? String(ui: "반영 가능") : plan.blockers.isEmpty ? String(ui: "변경 없음") : String(ui: "막힘: \(plan.blockers.joined(separator: " / "))")))
        }
        if let out = value(after: "--out", in: args) {
            try export.writeDryRun(plans.map(\.plan), to: URL(filePath: out))
            print("XML: \(out)")
        }
    }

    /// 큐 초안을 rekordbox DB에 직접 쓴다. 기본은 --db 사본. 라이브 DB는 --live를 줘야 하고 rekordbox가 꺼져 있어야 한다.
    @MainActor
    static func cueWrite(_ args: [String]) async throws {
        // cue-write는 --share를 받지 않는다(분석 파일 뿌리는 쓰기 관문이 정한다).
        guard var target = RekordboxWriteTarget.cli(args) else { throw UsageError() }
        target.shareRoot = nil
        let composition = CLIComposition.live
        let uuids = value(after: "--uuid", in: args).map { $0.components(separatedBy: ",") } ?? composition.drafts.cueDraftUUIDs().sorted()
        let drafts = uuids.compactMap(composition.drafts.cueDraft)
        // 앱과 같은 반영 세션. 쓴 초안은 지우지 않는다(앱과 다름, 사용자 결정 2026-10-10: 세션 옵션 `liveCLI`가 끈다).
        let report = try await composition.reflection().writeDrafts(DraftWriteBatch(drafts: drafts), to: target, dryRun: args.contains("--dry-run"))
        for outcome in report.outcomes {
            let mark = switch outcome.status { case .written: "✓"; case .blocked: "✗"; case .unchanged: "·" }
            print(String(ui: "\(mark) \(outcome.title.prefix(34)) — 지움 \(outcome.removed) · 넣음 \(outcome.added)\(outcome.reason.map { " · \($0)" } ?? "")"))
        }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "씀")) · 쓴 곡 \(report.written.count) · 막힌 곡 \(report.blocked.count) · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 인자 가운데 옵션(과 그 값)을 뺀 나머지
    static func operands(_ args: [String], valued: Set<String>) -> [String] {
        var result: [String] = [], skip = false
        for arg in args.dropFirst() {
            if skip { skip = false; continue }
            if valued.contains(arg) { skip = true; continue }
            if arg.hasPrefix("--") { continue }
            result.append(arg)
        }
        return result
    }

    /// 음원을 컬렉션에 넣는다(분석 전). 기본은 --db 사본, 라이브 DB는 --live(rekordbox가 꺼져 있어야 한다).
    @MainActor
    static func trackAdd(_ args: [String]) async throws {
        guard let target = RekordboxWriteTarget.cli(args) else { throw UsageError() }
        let files = operands(args, valued: ["--db", "--share"])
        guard !files.isEmpty else { throw UsageError() }
        // 파일마다 태그 → 넣기 계획, --analyze면 그리드(rekordbox 시간축으로 옮김)·음량(오토게인 −10 LUFS 목표)
        let prepared = await CLIComposition.trackAddPreparation().prepare(files.map { URL(filePath: $0) }, analyze: args.contains("--analyze")) { line in
            // 파일마다 바로 찍는다(여러 곡을 분석하는 동안 진행이 보이게)
            switch line {
            case let .withoutAnalysis(fileName): print(String(ui: "· \(fileName): 그리드를 추정하지 못해 분석 없이 넣습니다"))
            case let .analyzed(fileName, bpm, integrated): print(String(format: "· %@: %.2f BPM · %.1f LUFS", fileName, bpm, integrated ?? .nan))
            case let .failed(file, error): print("✗ \(file) — \(error)")
            }
        }
        // 앱의 곡 넣기와 같은 반영 세션(추가 목록 없이 받은 계획으로 바로 넣는 단계)
        let report = try CLIComposition.live.reflection().addTracks(TrackAddBatch(plans: prepared.plans, analyses: prepared.analyses), to: target,
                                                                    dryRun: args.contains("--dry-run"))
        for o in report.added { print("\(o.written ? "✓" : "✗") \(o.title.prefix(40))\(o.contentID.map { " · ID \($0)" } ?? "")\(o.reason.map { " · \($0)" } ?? "")") }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "넣음")) · \(report.added.filter(\.written).count)곡 · 만든 파일(분석·앨범아트) \(report.createdFiles.count)개 · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 곡을 컬렉션에서 뺀다. 분석 파일은 백업으로 옮긴다. 기본은 --db 사본(분석 파일은 --share를 줄 때만), 라이브는 --live.
    @MainActor
    static func trackDelete(_ args: [String]) async throws {
        guard let target = RekordboxWriteTarget.cli(args) else { throw UsageError() }
        let ids = operands(args, valued: ["--db", "--share"])
        guard !ids.isEmpty else { throw UsageError() }
        let report = try CLIComposition.live.reflection().deleteTracks(ids, from: target, dryRun: args.contains("--dry-run"))
        for o in report.deleted { print("\(o.written ? "✓" : "✗") \(o.title.prefix(40)) · ID \(o.contentID ?? "")\(o.reason.map { " · \($0)" } ?? "")") }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "뺌")) · \(report.deleted.filter(\.written).count)곡 · 지운 파일(분석·앨범아트) \(report.removedFiles.count)개 · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 재생 목록 편집을 사본에 쓴다. 편집 JSON 예: `[{"create":{"key":"f","name":"새 폴더","isFolder":true,"parent":"root"}},
    /// {"addTracks":{"playlist":"new:f","contentIDs":["123"]}}]`. 라이브 라이브러리는 앱의 반영으로만 쓴다.
    @MainActor
    static func playlistWrite(_ args: [String]) async throws {
        guard let path = value(after: "--db", in: args), let file = operands(args, valued: ["--db"]).first else { throw UsageError() }
        let database = URL(filePath: path)
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer/rekordbox/master.db")
        guard database.resolvingSymlinksInPath().standardizedFileURL.path != real.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw DJCError.writeRefused(String(ui: "playlist-write는 사본에만 씁니다. rekordbox 라이브러리는 앱의 반영으로 쓰세요"))
        }
        let edits = try JSONDecoder().decode([PlaylistEdit].self, from: Data(contentsOf: URL(filePath: file)))
        // 반영 세션의 재생 목록 편집 쓰기(관문 묶음). 백업은 사본 옆 `backups/`
        let report = try CLIComposition.live.reflection().writePlaylistEdits(edits, to: .copy(database: database, shareRoot: nil),
                                                                             dryRun: args.contains("--dry-run"))
        for o in report.playlistOutcomes ?? [] {
            let mark = switch o.status { case .written: "✓"; case .blocked: "✗"; case .unchanged: "·" }
            print("\(mark) \(o.name.prefix(34))\(o.playlistID.map { " · ID \($0)" } ?? "")\(o.reason.map { " · \($0)" } ?? "")")
        }
        print(String(ui: "\(report.dryRun ? String(ui: "미리 보기(되돌림)") : String(ui: "씀")) · 쓴 편집 \(report.playlistWritten.count) · 막힌 편집 \(report.playlistBlocked.count) · 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? String(ui: "없음"))"))
    }

    /// 백업으로 되돌린다. 기본은 --db 사본. 라이브 DB는 --live(rekordbox가 꺼져 있어야 한다). 백업 목록은 인자 없이.
    @MainActor
    static func rekordboxRestore(_ args: [String]) async throws {
        guard let folder = value(after: "--backup", in: args), let target = RekordboxWriteTarget.cli(args) else {
            let composition = CLIComposition.live
            for backup in composition.library().writeBackups(in: composition.location.backupDirectory) {
                print(backup.url.lastPathComponent, "·", backup.titles.prefix(5).joined(separator: ", "), String(ui: "· 카운터"), backup.report?.finalUpdateCount ?? -1)
            }
            throw UsageError()
        }
        // 앱과 같은 반영 세션. 초안은 되살리지 않는다(앱과 다름, 사용자 결정 2026-10-10: 세션 옵션 `liveCLI`가 끈다). 백업은 폴더만 안다.
        let backup = RekordboxWriteBackup(url: URL(filePath: folder), createdAt: .distantPast, isWrite: true)
        let saved = try await CLIComposition.live.reflection().restoreBackup(backup, to: target)
        print(String(ui: "되돌림 완료 · 되돌리기 전 상태 백업: \(saved.path)"))
    }

    /// 사본 DB의 구조(CREATE 문)만 뽑는다. 데이터는 한 줄도 담지 않는다(테스트 픽스처용).
    static func schemaDump(_ args: [String]) async throws {
        let overwrite = args.contains("--overwrite")
        let args = args.filter { $0 != "--overwrite" }
        guard args.count > 2 else { throw UsageError() }
        try CLIGuards.refuseExistingOutput(URL(filePath: args[2]), overwrite: overwrite)
        let (statements, version) = try CLIComposition.schema(of: args[1])
        let text = "-- rekordbox master.db 구조(데이터 없음). DBVersion \(version)\n-- DJCrate schema-dump로 뽑음\n\n"
            + statements.map { $0 + ";" }.joined(separator: "\n\n") + "\n"
        try text.write(toFile: args[2], atomically: true, encoding: .utf8)
        print(String(ui: "구조 \(statements.count)개 → \(args[2]) · DBVersion \(version)"))
    }

    /// 제목으로 파일 경로 찾기(개발용)
    static func path(_ args: [String]) async throws {
        let read = try CLIComposition.live.library().queries.open(database: value(after: "--db", in: args).map { URL(filePath: $0) })
        guard args.count > 1 else { return }
        for path in read.titlePaths(args[1]) { print(path) }
    }

    static func parse(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        let comment = args[1]
        let rule = AnisongCommentRule()
        print(String(ui: "분류: \(rule.evaluate(comment).classification)"))
        if let parsed = rule.parse(comment) {
            dump(parsed)
        }
    }

    private static func partName(_ label: PartLabel) -> String {
        switch label {
        case .firstChorus: String(ui: "1사비")
        case .secondChorus: String(ui: "2사비")
        case .lastChorus: String(ui: "라사비")
        case .interlude: String(ui: "간주")
        }
    }

    // MARK: - 도움

    static func analyzeTrack(_ target: String, snapshotPath: String?) async throws {
        // 파일이 없으면 사본(--db, 없으면 최신 스냅샷)의 ContentID로 곡을 찾는다
        let parts = CLIComposition.live.analyzeParts()
        guard let found = try parts.target(target, database: snapshotPath.map { URL(filePath: $0) }) else {
            print(String(ui: "트랙을 찾지 못했습니다: \(target)")); return
        }
        let track = found.track, cues = found.cues

        let started = Date()
        let result = try await parts.analyze(found)
        let analysis = result.analysis

        if let track { print(String(ui: "\(track.title) — \(track.artist ?? "")\n코멘트: \(track.comment)")) }
        print(String(ui: "길이 \(clock(analysis.duration)) · BPM \(analysis.bpm.map { String(format: "%.1f", $0) } ?? "-") · 분석 \(Date().timeIntervalSince(started), specifier: "%.1f")초 · 통합 음량 \(analysis.integratedLoudness.map { String(format: "%.1f", $0) } ?? "-") LUFS"))
        print(String(ui: "키: \(analysis.keys.map { "\(clock($0.span.start)) \($0.name)" }.joined(separator: " → "))"))
        print(String(ui: "마디 \(analysis.bars.count) · 섹션 \(analysis.sections.count) · 세그먼트 \(analysis.segments.count) · 프레이즈 \(analysis.phrases.count)\n"))

        print(String(ui: "섹션별 에너지 (음량 LUFS / 보컬 / 드럼 / 점수)"))
        for e in result.energies {
            print(String(format: "  %@–%@  %6.1f  %.2f  %.2f  %.2f",
                         clock(e.span.start), clock(e.span.end), e.loudness, e.vocal, e.drum, e.score))
        }

        print(String(ui: "\n파트 추정 v0"))
        for m in result.parts {
            print(String(ui: "  \(partName(m.label))\t\(clock(m.time))\t\(m.bar.map { String(ui: "\($0)마디") } ?? "")\t신뢰도 \(String(m.confidence))"))
        }

        if !cues.isEmpty {
            print(String(ui: "\nrekordbox 기존 큐 (직접 찍은 것)"))
            for cue in cues.filter({ !$0.isAutoGenerated }).sorted(by: { $0.inMsec < $1.inMsec }) {
                let time = Double(cue.inMsec) / 1000
                let slot = cue.hotCueSlot.map { String(ui: "핫큐 \(String($0))") } ?? String(ui: "메모리")
                print("  \(slot)\t\(clock(time))\t\(analysis.barNumber(at: time).map { String(ui: "\($0)마디") } ?? "")")
            }
        }
    }
}
