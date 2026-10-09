import CoreGraphics
import CryptoKit
import DJCAnalysis
import DJCApplication
import DJCDomain
import Foundation
import ImageIO
import RekordboxKit

/// 곡 추가·삭제 규칙을 맞출 때 쓰는 실험(읽기 전용).
enum TrackLab {
    static let all: [Command] = [
        Command("track-add-plan", "<음원 파일…>", "파일로 만든 곡 추가 계획을 JSON으로(규칙 맞추기용)", TrackLab.trackAddPlan),
        Command("analysis-repro", "<ContentID…> [--db 스냅샷]", "rekordbox 분석 파일을 같은 그리드로 다시 만들어 태그마다 비교(파형은 수치로)", TrackLab.analysisRepro),
        Command("facts-check", "[--limit N] [--db 스냅샷]", "음원 정보(비트레이트·샘플레이트·비트)를 rekordbox 곡 행과 형식별로 비교", TrackLab.factsCheck),
        Command("pvbr-check", "[--db 스냅샷]", "라이브러리 MP3마다 만든 PVBR·비트레이트를 rekordbox .DAT와 바이트로 비교", TrackLab.pvbrCheck),
        Command("nonlame-vbr-check", "[--db 스냅샷]", "비LAME VBR의 비트레이트 후보·PVBR·파형 길이를 익명 수치로 비교(읽기 전용)", TrackLab.nonLameVBRCheck),
        Command("pvb2-check", "[--db 스냅샷]", "라이브러리 FLAC마다 만든 PVB2(.EXT 탐색표)·음원 칸을 rekordbox와 바이트로 비교", TrackLab.pvb2Check),
        Command("track-add-repro", "--db <스냅샷> <음원 파일…>", "파일로 곡 추가 계획을 만들어 rekordbox가 넣은 행과 칸마다 비교", TrackLab.trackAddRepro),
        Command("analysis-attach-test", "--db <사본.db> --share <사본 share> [--grid-from <.DAT>] <ContentID…>",
                "분석 전 곡에 분석 파일(음원 그림이 있으면 아트워크도)을 붙여 본다(사본만, 막아 둔 쓰기 경로를 열어서). 그리드는 .DAT에서 읽거나 추정", TrackLab.analysisAttachTest),
        Command("tag-write-test", "--db <사본.db> [--dry-run] <ContentID>:<칸>=<값>…",
                "곡 정보(태그)를 사본에 써 본다(사본만, 확인하지 않은 칸·곡 상태도 열어서). 칸: title·artist·album·albumArtist·genre·composer·year·trackNumber·comment·musicalKey·rating·color. 한 번 실행 = rekordbox에서 한 번 저장",
                TrackLab.tagWriteTest),
        Command("artwork-write-test", "--db <사본.db> [--share <사본 share>] [--dry-run] <ContentID> (--image <그림 파일> | --delete)",
                "곡 정보 그림을 사본에 넣기·바꾸기·지우기(사본만, share는 기본 DB 옆 share). 한 번 실행 = rekordbox에서 한 번 저장",
                TrackLab.artworkWriteTest),
        Command("artwork-check", "[--db 스냅샷] [--limit N] [<ContentID…>]",
                "음원 내장 아트워크로 아트워크 파일 셋을 만들어 rekordbox 파일과 크기·JPEG 머리·화소 차이를 비교(ID가 없으면 아트워크 있는 곡을 무작위로)",
                TrackLab.artworkCheck),
    ]

    static func trackAddPlan(_ args: [String]) async throws {
        guard args.count > 1 else { throw UsageError() }
        var plans: [TrackAddPlan] = []
        for file in args.dropFirst() {
            let url = URL(filePath: file)
            plans.append(try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(plans), as: UTF8.self))
    }

    static func analysisRepro(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let ids = MainCommands.operands(args, valued: ["--db"])
        guard !ids.isEmpty else { throw UsageError() }
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        for id in ids {
            var row: (path: String, dat: String, bitRate: Int, sampleRate: Int, bitDepth: Int, length: Int)?
            try db.query("SELECT FolderPath, AnalysisDataPath, BitRate, SampleRate, BitDepth, Length FROM djmdContent WHERE ID = ?", [.text(id)]) { r in
                row = (r.string(0) ?? "", r.string(1) ?? "", r.int(2) ?? 0, r.int(3) ?? 0, r.int(4) ?? 0, r.int(5) ?? 0)
            }
            guard let row, let datURL = RekordboxShare.analysisURL(row.dat) else { print("✘ \(id): 곡 없음"); continue }
            let url = URL(filePath: row.path)
            let facts = AudioFacts.read(url: url)
            let rbDat = try AnlzFile(url: datURL)
            let rbExt = try AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT"))
            let beats = BeatGridTags.decode(pqtz: rbDat.tag("PQTZ")!.bytes, pqt2: nil).beats
            let waves = try RekordboxWaveforms.analyze(url: url)
            let tags = try await AudioTags.read(url: url)
            let files = try TrackAnalysisFiles.make(fileName: url.lastPathComponent.precomposedStringWithCanonicalMapping, beats: beats,
                                                    waveforms: waves, facts: facts)
            let ours = try AnlzFile(data: files.dat), oursExt = try AnlzFile(data: files.ext)
            print("== \(url.lastPathComponent.prefix(40)) · \(facts.unsupported ?? "분석 붙이기 가능")")
            print("   칸: 비트레이트 rb \(row.bitRate)/djc \(facts.bitRate) · 샘플레이트 \(row.sampleRate)/\(facts.sampleRate) · 비트 \(row.bitDepth)/\(facts.bitDepth) · 길이 \(row.length)/\(Int(tags.duration))")
            print("   .DAT 태그 순서 rb \(rbDat.tags.map(\.fourcc).joined(separator: " ")) / djc \(ours.tags.map(\.fourcc).joined(separator: " "))")
            print("   .DAT 머리 같음 \(rbDat.header == ours.header) · " + ["PPTH", "PVBR", "PQTZ", "PCOB"].map { name in
                "\(name) \(rbDat.tags.filter { $0.fourcc == name }.map(\.bytes) == ours.tags.filter { $0.fourcc == name }.map(\.bytes) ? "같음" : "다름")"
            }.joined(separator: " · "))
            print("   .EXT 태그 순서 rb \(rbExt.tags.map(\.fourcc).joined(separator: " ")) / djc \(oursExt.tags.map(\.fourcc).joined(separator: " "))")
            for name in ["PWV3", "PWV5"] {
                if let reference = rbExt.tag(name), reference.bytes.count >= 20,
                   let generated = oursExt.tag(name), generated.bytes.count >= 20 {
                    let count = reference.bytes[16..<20].reduce(0) { ($0 << 8) | Int($1) }
                    let ours = generated.bytes[16..<20].reduce(0) { ($0 << 8) | Int($1) }
                    print("   \(name) 길이 rb \(count)/djc \(ours)")
                }
            }
            print("   PVB2 rb \(rbExt.tag("PVB2") != nil)/djc \(oursExt.tag("PVB2") != nil) · 예측 지연 \(RekordboxTimeline.predictedOffset(url: url))초")
            if let a = rbDat.tag("PVBR"), let b = ours.tag("PVBR"), a.bytes != b.bytes {
                print("   PVBR 끝값 rb \(a.bytes.suffix(4).map { String(format: "%02x", $0) }.joined()) / djc \(b.bytes.suffix(4).map { String(format: "%02x", $0) }.joined())")
            }
            if let a = rbDat.tag("PPTH"), let b = ours.tag("PPTH"), a.bytes != b.bytes { print("   PPTH rb \(a.bytes.count)바이트 / djc \(b.bytes.count)바이트") }
        }
    }

    static func factsCheck(_ args: [String]) async throws {
        let limit = Int(value(after: "--limit", in: args) ?? "") ?? 60
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(type: Int, path: String, bitRate: Int, sampleRate: Int, bitDepth: Int)] = []
        try db.query("""
            SELECT FileType, FolderPath, BitRate, SampleRate, BitDepth FROM djmdContent
            WHERE rb_local_deleted = 0 AND Analysed = 105 AND FolderPath LIKE '/%' ORDER BY random() LIMIT ?
            """, [.int(limit)]) { rows.append(($0.int(0) ?? 0, $0.string(1) ?? "", $0.int(2) ?? 0, $0.int(3) ?? 0, $0.int(4) ?? 0)) }
        var tally: [String: (all: Int, same: Int)] = [:]
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            let key = "형식 \(row.type)\(facts.unsupported == nil ? "" : " (분석 안 붙임)")"
            let same = facts.bitRate == row.bitRate && facts.sampleRate == row.sampleRate && facts.bitDepth == row.bitDepth
            tally[key, default: (0, 0)].all += 1
            if same { tally[key]!.same += 1 } else if facts.unsupported == nil {
                print("✘ \((row.path as NSString).lastPathComponent.prefix(36)) · 비트레이트 \(row.bitRate)/\(facts.bitRate) · 샘플레이트 \(row.sampleRate)/\(facts.sampleRate) · 비트 \(row.bitDepth)/\(facts.bitDepth)")
            }
        }
        for (key, t) in tally.sorted(by: { $0.key < $1.key }) { print("\(key): \(t.same)/\(t.all) 같음") }
    }

    static func pvbrCheck(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(path: String, dat: String, bitRate: Int)] = []
        try db.query("SELECT FolderPath, AnalysisDataPath, BitRate FROM djmdContent WHERE rb_local_deleted = 0 AND FileType = 1 AND Analysed = 105 AND FolderPath LIKE '/%'") {
            rows.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2) ?? 0))
        }
        var tally: [String: (all: Int, pvbr: Int, bitRate: Int)] = [:]
        var shown = 0
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            guard let datURL = RekordboxShare.analysisURL(row.dat), let dat = try? AnlzFile(url: datURL), let rb = dat.tag("PVBR") else { continue }
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            let kind = facts.unsupported != nil ? "막음" : (facts.pvbrEntries.isEmpty ? "CBR" : "VBR")
            let same = TrackAnalysisFiles.pvbr(facts) == rb.bytes
            tally[kind, default: (0, 0, 0)].all += 1
            if same { tally[kind]!.pvbr += 1 }
            if facts.bitRate == row.bitRate { tally[kind]!.bitRate += 1 }
            if kind != "막음", !same || facts.bitRate != row.bitRate {
                shown += 1
                print("✘ 익명 곡 \(shown) · \(kind) · PVBR \(same ? "같음" : "다름") · 비트레이트 \(row.bitRate)/\(facts.bitRate)")
                let url = URL(filePath: row.path)
                if !same, let frames = SeekInfo.mp3Frames(url: url) {
                    print("  이유: \(SeekDiagnostics.pvbr(stored: rb.bytes, current: TrackAnalysisFiles.pvbr(facts), frames: frames))")
                }
                if facts.bitRate != row.bitRate { print("  이유: 저장 비트레이트와 현재 프레임 비트레이트가 다릅니다. 재분석 전후를 비교하세요") }
                try diagnosticMetadata(db, path: row.path, analysis: datURL)
            }
        }
        for (kind, t) in tally.sorted(by: { $0.key < $1.key }) where kind != "막음" {
            print("\(kind): PVBR 어긋남 \(t.all - t.pvbr) · 비트레이트 어긋남 \(t.all - t.bitRate)")
        }
        if tally["막음"] != nil { print("미확인 형식은 비교에서 제외했습니다(기존 쓰기 차단 유지)") }
    }

    static func pvb2Check(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var rows: [(path: String, dat: String, sampleRate: Int, bitDepth: Int, bitRate: Int)] = []
        try db.query("SELECT FolderPath, AnalysisDataPath, SampleRate, BitDepth, BitRate FROM djmdContent WHERE rb_local_deleted = 0 AND FileType = 5 AND Analysed = 105 AND FolderPath LIKE '/%'") {
            rows.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2) ?? 0, $0.int(3) ?? 0, $0.int(4) ?? 0))
        }
        var all = 0, same = 0, cells = 0, blocked = 0, shown = 0
        for row in rows where FileManager.default.fileExists(atPath: row.path) {
            guard let datURL = RekordboxShare.analysisURL(row.dat),
                  let ext = try? AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT")), let rb = ext.tag("PVB2") else { continue }
            all += 1
            let facts = AudioFacts.read(url: URL(filePath: row.path))
            guard facts.unsupported == nil, let ours = TrackAnalysisFiles.pvb2(facts) else {
                blocked += 1
                shown += 1
                print("· 익명 곡 \(shown) · 분석 막음(비교 제외): \(facts.unsupported ?? "PVB2 없음")")
                // CRC-16이 맞지 않는 프레임이 있으면 두 후보 규칙을 저장값과 견준다(#14 곡 D: 빼고 이어 매김)
                let url = URL(filePath: row.path)
                if let table = SeekInfo.flacFrames(url: url)?.frames, let last = table.last,
                   let failures = SeekInfo.flacCRCFailures(url: url, frames: table), !failures.isEmpty {
                    let total = last.startSample + last.blockSize
                    func pvb2(_ frames: [SeekInfo.FlacFrame]) -> Data? {
                        var candidate = facts
                        candidate.flacTotalSamples = UInt64(total)
                        candidate.flacEntries = AudioFacts.pvb2Entries(frames: frames, total: total)
                        return TrackAnalysisFiles.pvb2(candidate)
                    }
                    let dropped = Set(failures)
                    var start = 0
                    let renumbered = table.enumerated().filter { !dropped.contains($0.offset) }.map { _, frame -> SeekInfo.FlacFrame in
                        defer { start += frame.blockSize }
                        return SeekInfo.FlacFrame(startSample: start, offset: frame.offset, blockSize: frame.blockSize)
                    }
                    print("  CRC-16 안 맞는 프레임 \(failures.count)개 · 머리 번호 규칙 \(pvb2(table) == rb.bytes ? "같음" : "다름")"
                        + " · 그 프레임 빼고 이어 매김 \(pvb2(renumbered) == rb.bytes ? "같음" : "다름")")
                }
                continue
            }
            let sameCells = (facts.sampleRate, facts.bitDepth, facts.bitRate) == (row.sampleRate, row.bitDepth, row.bitRate)
            if sameCells { cells += 1 }
            if ours == rb.bytes { same += 1 }
            if ours == rb.bytes && sameCells { continue }
            shown += 1
            print("✘ 익명 곡 \(shown) · PVB2 \(ours == rb.bytes ? "같음" : "다름")")
            if ours != rb.bytes {
                print("  이유: \(SeekDiagnostics.pvb2(stored: rb.bytes, current: ours))")
            }
            if !sameCells { print("  이유: 저장 음원 정보와 현재 샘플레이트·비트·비트레이트가 다릅니다. 재분석 전후를 비교하세요") }
            try diagnosticMetadata(db, path: row.path, analysis: datURL.deletingPathExtension().appendingPathExtension("EXT"))
        }
        print("FLAC: PVB2 어긋남 \(all - blocked - same) · 음원 정보 어긋남 \(all - blocked - cells)")
        if blocked > 0 { print("못 읽는 형식은 비교에서 제외했습니다(기존 쓰기 차단 유지)") }
    }

    static func diagnosticMetadata(_ db: CipherDatabase, path: String, analysis: URL?) throws {
        let audio = try? FileManager.default.attributesOfItem(atPath: path)
        let anlz = analysis.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        // AnalysisUpdated는 시각이 아닌 갱신 번호다. ANLZ 수정 시각도 재분석 시각과 같다고 단정하지 않는다.
        if let modified = audio?[.modificationDate] as? Date, let analyzed = anlz?[.modificationDate] as? Date {
            if modified > analyzed {
                print("  근거: 음원 수정 시각 > 분석 파일 수정 시각; 분석 후 파일 변경 가능성(재인코딩 여부는 미확인)")
            } else {
                print("  근거: 음원 수정 시각 ≤ 분석 파일 수정 시각; 시각만으로 분석 후 변경을 입증할 수 없습니다")
            }
        } else {
            print("  근거: 파일 수정 시각을 읽지 못해 분석 후 변경 여부를 확인할 수 없습니다")
        }
        try db.query("SELECT FileSize FROM djmdContent WHERE FolderPath = ?", [.text(path)]) {
            guard let stored = $0.int(0), let current = audio?[.size] as? Int else { return }
            print("  근거: DB 파일 크기와 현재 음원 크기 \(stored == current ? "같음" : "다름(태그 변경만으로도 달라질 수 있음)")")
        }
    }

    /// 파일마다 DJCrate 계획과 rekordbox가 넣은 행(같은 경로)을 칸마다 비교한다.
    /// 분석 붙이기를 사본에 써 본다. rekordbox 실험(기존 분석 전 곡을 rekordbox가 분석) 전 사본에 같은 곡을 써서
    /// `djc lab db-diff`로 rekordbox 결과와 칸마다 비교할 때 쓴다. 라이브 DB·실제 분석 폴더는 거부한다.
    static func analysisAttachTest(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args), let sharePath = value(after: "--share", in: args) else { throw UsageError() }
        let database = URL(filePath: dbPath), share = URL(filePath: sharePath)
        try CLIGuards.refuseLiveDatabase(database)
        try CLIGuards.refuseLiveShare(share)
        let ids = MainCommands.operands(args, valued: ["--db", "--share", "--grid-from"])
        guard !ids.isEmpty else { throw UsageError() }
        let db = try CipherDatabase.diagnostic(path: database.path, key: RekordboxKey.derive())
        var tracks: [(id: String, uuid: String, path: String)] = []
        for id in ids {
            try db.query("SELECT ID, UUID, FolderPath FROM djmdContent WHERE ID = ? AND rb_local_deleted = 0", [.text(id)]) {
                tracks.append(($0.string(0) ?? "", $0.string(1) ?? "", $0.string(2) ?? ""))
            }
        }
        db.close()
        var grids: [GridDraft] = [], inputs: [String: RekordboxWriter.AnalysisInput] = [:]
        for track in tracks {
            let url = URL(filePath: track.path)
            var segments: [GridSegment]
            if let dat = value(after: "--grid-from", in: args) {
                // rekordbox 분석의 정밀 시각: .DAT의 ms에 옆 .EXT의 소수(PQT2)를 더한다(그리드 쓰기와 같다)
                let datURL = URL(filePath: dat)
                let pqtz = try AnlzFile(url: datURL).tag("PQTZ")?.bytes ?? Data()
                let pqt2 = (try? AnlzFile(url: datURL.deletingPathExtension().appendingPathExtension("EXT")))?.tag("PQT2")?.bytes
                let beats = BeatGridTags.decode(pqtz: pqtz, pqt2: pqt2).beats
                segments = GridDraft.segments(from: BeatGrid(beats: beats.map { .init(number: $0.number, bpm: Double($0.bpm100) / 100, time: $0.time / 1000) }))
            } else {
                // 음원 시간축 추정을 rekordbox 시간축으로 옮긴다(곡 넣기 --analyze와 같다)
                guard let estimate = try await GridSuggestion.estimate(fileAt: url, cacheKey: "attach-\(track.uuid)") else {
                    print("✗ \(track.id): 그리드를 추정하지 못했습니다"); continue
                }
                let offset = RekordboxTimeline.predictedOffset(url: url)
                segments = estimate.segments.map { var s = $0; s.start += offset; return s }
            }
            let loudness = try Loudness.measure(fileAt: url)
            // 음원 내장 그림이 있으면 앱처럼 아트워크도 넣는다(#87)
            let tags = try await AudioTags.read(url: url)
            inputs[track.uuid] = .init(duration: tags.duration, loudness: loudness, artwork: tags.artwork)
            grids.append(GridDraft(trackUUID: track.uuid, base: [], segments: segments))
            print(String(format: "· %@: %.2f BPM · 첫 박 %.4f초 · %.1f LUFS", track.id, segments.first?.bpm ?? 0, segments.first?.start ?? 0,
                         loudness.integrated ?? .nan))
        }
        let report = try RekordboxWriter.write(drafts: [], grids: grids, gains: [:], analysisInputs: inputs, to: database,
                                               dryRun: args.contains("--dry-run"), now: .now,
                                               backups: database.deletingLastPathComponent().appending(path: "backups"), shareRoot: share,
                                               attachesAnalysis: true)
        for o in (report.analysisOutcomes ?? []) + (report.gridOutcomes ?? []) {
            print("\(o.status == .written ? "✓" : "✗") \(o.title.prefix(40)) · 박 \(o.added)\(o.reason.map { " · \($0)" } ?? "")")
        }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "씀") · 만든 파일 \(report.createdFiles?.count ?? 0)개 · 아트워크 \(report.artworkAdded?.count ?? 0)곡 · 변경 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? "없음")")
    }

    /// rekordbox 곡 정보 편집 실험을 사본에 재현한다(#1). 실험 전 사본에 같은 편집을 쓰고 `djc lab db-diff`로 rekordbox 결과와 비교한다.
    static func tagWriteTest(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args) else { throw UsageError() }
        let database = URL(filePath: dbPath)
        try CLIGuards.refuseLiveDatabase(database)
        // "<ContentID>:<칸>=<값>"을 곡마다 모은다(같은 곡은 한 초안으로).
        var edits: [(id: String, changes: [(TagFields.Key, String)])] = []
        for operand in MainCommands.operands(args.filter { $0 != "--dry-run" }, valued: ["--db"]) {
            guard let colon = operand.firstIndex(of: ":"), let equals = operand[colon...].firstIndex(of: "="),
                  let key = TagFields.Key(rawValue: String(operand[operand.index(after: colon)..<equals])) else {
                print("✗ 알 수 없는 편집: \(operand)(예: 123:title=새 제목)"); throw UsageError()
            }
            let id = String(operand[..<colon]), value = String(operand[operand.index(after: equals)...])
            if let i = edits.firstIndex(where: { $0.id == id }) { edits[i].changes.append((key, value)) } else { edits.append((id, [(key, value)])) }
        }
        guard !edits.isEmpty else { throw UsageError() }
        var drafts: [TagDraft] = []
        let db = try CipherDatabase.diagnostic(path: database.path, key: RekordboxKey.derive())
        for edit in edits {
            var uuid: String?
            try db.query("SELECT UUID FROM djmdContent WHERE ID = ?", [.text(edit.id)]) { uuid = $0.string(0) }
            guard let uuid, let base = try RekordboxWriter.currentTags(db: db, contentID: edit.id) else { print("✗ \(edit.id): 곡이 없습니다"); continue }
            var draft = TagDraft(trackUUID: uuid, base: base)
            for (key, value) in edit.changes { draft.fields[key] = value }
            drafts.append(draft)
        }
        db.close()
        let report = try RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: drafts, analysisInputs: [:], to: database,
                                               dryRun: args.contains("--dry-run"), now: .now,
                                               backups: database.deletingLastPathComponent().appending(path: "backups"), shareRoot: nil,
                                               attachesAnalysis: false, tagKeys: Set(TagFields.Key.allCases), tagScopes: [:])
        for o in report.tagOutcomes ?? [] {
            print("\(o.status == .written ? "✓" : "✗") \(o.title.prefix(40)) · \((o.fields ?? []).joined(separator: ","))\(o.reason.map { " · \($0)" } ?? "")")
        }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "씀") · 변경 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? "없음")")
    }

    /// rekordbox 곡 정보 그림 편집 실험을 사본에 재현한다(#66). 실험 전 사본에 같은 편집을 쓰고 rekordbox 결과와 칸마다 비교한다.
    static func artworkWriteTest(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args) else { throw UsageError() }
        let database = URL(filePath: dbPath)
        try CLIGuards.refuseLiveDatabase(database)
        let share = value(after: "--share", in: args).map { URL(filePath: $0) } ?? database.deletingLastPathComponent().appending(path: "share")
        let imagePath = value(after: "--image", in: args)
        let operands = MainCommands.operands(args.filter { $0 != "--dry-run" && $0 != "--delete" }, valued: ["--db", "--share", "--image"])
        guard operands.count == 1, let contentID = operands.first, (imagePath == nil) == args.contains("--delete") else { throw UsageError() }
        let image = try imagePath.map { try Data(contentsOf: URL(filePath: $0)) }
        let db = try CipherDatabase.diagnostic(path: database.path, key: RekordboxKey.derive())
        var uuid: String?
        try db.query("SELECT UUID FROM djmdContent WHERE ID = ?", [.text(contentID)]) { uuid = $0.string(0) }
        let base = try RekordboxWriter.artworkBase(db: db, contentID: contentID)
        db.close()
        guard let uuid, let base else { print("✗ \(contentID): 곡이 없습니다"); return }
        let sha = image.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let draft = ArtworkDraft(trackUUID: uuid, change: image == nil ? .delete : .set, base: base,
                                 imageName: imagePath.map { URL(filePath: $0).lastPathComponent }, imageSHA256: sha)
        let report = try RekordboxWriter.write(drafts: [], grids: [], gains: [:], artworks: [ArtworkEdit(draft: draft, image: image)],
                                               analysisInputs: [:], to: database, dryRun: args.contains("--dry-run"), now: .now,
                                               backups: database.deletingLastPathComponent().appending(path: "backups"), shareRoot: share,
                                               attachesAnalysis: false)
        for o in report.artworkOutcomes ?? [] {
            print("\(o.status == .written ? "✓" : "✗") \(o.title.prefix(40)) · \(o.artwork?.rawValue ?? "-")\(o.reason.map { " · \($0)" } ?? "")")
        }
        print("\(report.dryRun ? "미리 보기(되돌림)" : "씀") · 만든 파일 \(report.createdFiles?.count ?? 0)개 · 변경 카운터 \(report.finalUpdateCount.map(String.init) ?? "-") · 백업 \(report.backup ?? "없음")")
    }

    static func trackAddRepro(_ args: [String]) async throws {
        guard let dbPath = value(after: "--db", in: args) else { throw UsageError() }
        let files = args.dropFirst().filter { $0 != "--db" && $0 != dbPath }
        guard !files.isEmpty else { throw UsageError() }
        let db = try CipherDatabase.diagnostic(path: dbPath, key: RekordboxKey.derive())
        defer { db.close() }
        func name(_ table: String, _ id: String?) throws -> String? {
            guard let id, !id.isEmpty else { return nil }
            var result: String?
            try db.query("SELECT Name FROM \(table) WHERE ID = ?", [.text(id)]) { result = $0.string(0) }
            return result
        }
        var total = 0, matched = 0
        for file in files {
            let url = URL(filePath: file)
            let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url))
            var row: [String: String?] = [:]
            let columns = ["Title", "FileNameL", "ArtistID", "AlbumID", "GenreID", "ComposerID", "Commnt", "ReleaseYear", "TrackNo", "DiscNo",
                           "ISRC", "Lyricist", "FileType", "FileSize", "rb_file_id", "DateCreated", "StockDate", "Length", "Analysed"]
            try db.query("SELECT \(columns.joined(separator: ", ")) FROM djmdContent WHERE FolderPath = ? AND rb_local_deleted = 0",
                         [.text(plan.path)]) { r in
                for (i, c) in columns.enumerated() { row[c] = r.string(Int32(i)) }
            }
            guard !row.isEmpty else { print("✘ \(plan.fileName): rekordbox 행 없음"); continue }
            var albumArtist: String?
            if let albumID = row["AlbumID"] ?? nil {
                try db.query("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = ?", [.text(albumID)]) { albumArtist = $0.string(0) }
            }
            let rekordbox: [(String, String?)] = [
                ("제목", row["Title"] ?? nil), ("파일 이름", row["FileNameL"] ?? nil), ("아티스트", try name("djmdArtist", row["ArtistID"] ?? nil)),
                ("앨범", try name("djmdAlbum", row["AlbumID"] ?? nil)), ("앨범 아티스트", try name("djmdArtist", albumArtist)),
                ("장르", try name("djmdGenre", row["GenreID"] ?? nil)), ("작곡가", try name("djmdArtist", row["ComposerID"] ?? nil)),
                ("코멘트", row["Commnt"] ?? nil), ("연도", row["ReleaseYear"] ?? nil), ("트랙", row["TrackNo"] ?? nil), ("디스크", row["DiscNo"] ?? nil),
                ("ISRC", row["ISRC"] ?? nil), ("작사", row["Lyricist"] ?? nil), ("형식", row["FileType"] ?? nil), ("크기", row["FileSize"] ?? nil),
                ("파일 ID", row["rb_file_id"] ?? nil), ("만든 날", row["DateCreated"] ?? nil), ("넣은 날", row["StockDate"] ?? nil),
                ("길이", row["Length"] ?? nil),
            ]
            let ours: [String?] = [plan.title, plan.fileName, plan.artist, plan.album, plan.albumArtist, plan.genre, plan.composer, plan.comment,
                                   String(plan.year), String(plan.trackNumber), String(plan.discNumber), plan.isrc, plan.lyricist,
                                   String(plan.fileType), String(plan.fileSize), plan.fileID, plan.dateCreated, plan.stockDate, String(plan.length)]
            var diffs: [String] = []
            for ((label, theirs), mine) in zip(rekordbox, ours) {
                total += 1
                if (theirs ?? "") == (mine ?? "") { matched += 1 } else { diffs.append("\(label): rekordbox「\(theirs ?? "nil")」 · DJC「\(mine ?? "nil")」") }
            }
            let analysed = (row["Analysed"] ?? nil) ?? "0"
            print("\(diffs.isEmpty ? "✔" : "✘") \(plan.fileName.prefix(40)) (분석 \(analysed))" + (diffs.isEmpty ? "" : "\n    " + diffs.joined(separator: "\n    ")))
        }
        print("칸 \(total)개 중 \(matched)개 같음")
    }

    static func artworkCheck(_ args: [String]) async throws {
        let snapshot = try value(after: "--db", in: args).map { URL(filePath: $0) } ?? LibrarySnapshot.latest()
        let limit = value(after: "--limit", in: args).flatMap(Int.init) ?? 20
        var ids = MainCommands.operands(args, valued: ["--db", "--limit"])
        let db = try CipherDatabase.diagnostic(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        if ids.isEmpty {
            try db.query("SELECT ID FROM djmdContent WHERE rb_local_deleted = 0 AND ImagePath != '' ORDER BY random() LIMIT ?", [.int(limit)]) {
                ids.append($0.string(0) ?? "")
            }
        }
        /// 머리(DHT 빼고)가 같은지, 크기, 화소 평균 차이(0~255)
        func compare(_ ours: Data, _ theirs: Data) -> String {
            func segments(_ data: Data) -> [String] {
                let bytes = [UInt8](data)
                var out: [String] = [], i = 2
                while i + 4 <= bytes.count, bytes[i] == 0xFF {
                    let marker = bytes[i + 1], length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                    out.append(marker == 0xC4 ? "DHT" : bytes[i..<min(i + 2 + length, bytes.count)].map { String(format: "%02x", $0) }.joined())
                    if marker == 0xDA { break }
                    i += 2 + length
                }
                return out
            }
            func pixels(_ data: Data) -> (Int, Int, [UInt8])? {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let base = context.data else { return nil }
                return (image.width, image.height, [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)))
            }
            guard let a = pixels(ours), let b = pixels(theirs) else { return "풀지 못함" }
            guard a.0 == b.0, a.1 == b.1 else { return "크기 다름 djc \(a.0)x\(a.1) · rb \(b.0)x\(b.1)" }
            var sum = 0
            for i in 0..<a.2.count where i % 4 != 3 { sum += abs(Int(a.2[i]) - Int(b.2[i])) }
            let same = segments(ours) == segments(theirs)
            return "\(a.0)x\(a.1) · 머리 \(same ? "같음" : "다름") · 화소 차이 \(String(format: "%.1f", Double(sum) / Double(a.0 * a.1 * 3)))"
                + " · 크기 djc \(ours.count)/rb \(theirs.count)B"
        }
        for id in ids {
            var row: (path: String, image: String)?
            try db.query("SELECT FolderPath, ImagePath FROM djmdContent WHERE ID = ?", [.text(id)]) { row = ($0.string(0) ?? "", $0.string(1) ?? "") }
            guard let row else { print("✘ \(id): 곡 없음"); continue }
            guard let tags = try? await AudioTags.read(url: URL(filePath: row.path)) else { print("✘ \(id): 음원을 읽지 못함"); continue }
            guard let image = tags.artwork else {
                print("· \(id): 음원에 아트워크 없음(rekordbox ImagePath \(row.image.isEmpty ? "빈 값" : "있음"))"); continue
            }
            let started = Date()
            guard let files = TrackArtwork.make(image) else { print("✘ \(id): 그림을 풀지 못함"); continue }
            let elapsed = Date().timeIntervalSince(started)
            guard !row.image.isEmpty else { print("· \(id): rekordbox ImagePath 빈 값 · 만든 \(files.full.count)B"); continue }
            let results = zip([files.full, files.medium, files.small], [RekordboxShare.ArtworkSize.full, .medium, .small]).map { ours, size in
                RekordboxShare.artworkURL(row.image, size: size).flatMap { try? Data(contentsOf: $0) }.map { compare(ours, $0) } ?? "rekordbox 파일 없음"
            }
            print("\(id) (\(String(format: "%.2f", elapsed))초)\n    " + results.joined(separator: "\n    "))
        }
    }
}
