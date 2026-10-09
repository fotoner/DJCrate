import DJCApplication
import DJCDomain
import Foundation
import Testing

/// CLI `djc draft`의 유스케이스(곡별 큐·태그 초안 파일 바로 고치기)와 라이브러리 질의 사본 정하기. 파일·DB 없이 메모리 포트로 본다.
@Suite("초안 파일 바로 고치기·라이브러리 질의")
struct EditDraftFilesTests {
    static let track = Track(id: "7", uuid: "u7", title: "곡", artist: "가수", album: nil, albumArtist: nil, genre: nil, composer: nil,
                             releaseYear: nil, trackNumber: nil, key: nil, bpm: 128, lengthSeconds: 120, folderPath: "/m/a.mp3", comment: "",
                             importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: 0, dataStatus: 256)

    static func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let failure as ReadFailure { return failure.code } catch { return "other" }
    }

    @Test func 큐를_넣고_미리_보기는_저장하지_않는다() throws {
        let files = MemoryDraftFiles()
        let edits = EditDraftFiles(files: files.files)
        let request = EditDraftFiles.CueRequest(time: 10, loopEnd: nil, beats: nil, slot: 1, name: "B", active: false)
        let preview = try edits.addCue({ request }, track: Self.track, rekordboxCues: [], dryRun: true)
        #expect(preview.cues.count == 1 && files.cue("u7") == nil)
        _ = try edits.addCue({ request }, track: Self.track, rekordboxCues: [], dryRun: false)
        #expect(files.cue("u7")?.cues.first?.name == "B")
    }

    @Test func 곡_길이_밖이나_읽지_못하는_기존_초안은_막는다() {
        let files = MemoryDraftFiles()
        let edits = EditDraftFiles(files: files.files)
        let late = EditDraftFiles.CueRequest(time: 500, loopEnd: nil, beats: nil, slot: nil, name: nil, active: false)
        #expect(Self.code { _ = try edits.addCue({ late }, track: Self.track, rekordboxCues: [], dryRun: false) } == "invalid_arguments")
        var broken = files.files
        broken.cue = { _ in throw CocoaError(.fileReadCorruptFile) }
        let ok = EditDraftFiles.CueRequest(time: 1, loopEnd: nil, beats: nil, slot: nil, name: nil, active: false)
        // 기존 초안을 먼저 읽는다: 인자보다 손상이 먼저 알려진다
        #expect(Self.code { _ = try EditDraftFiles(files: broken).addCue({ throw ReadFailure("invalid_arguments", "x") }, track: Self.track, rekordboxCues: [], dryRun: false) } == "invalid_draft")
        #expect(Self.code { _ = try EditDraftFiles(files: broken).addCue({ ok }, track: Self.track, rekordboxCues: [], dryRun: false) } == "invalid_draft")
        var failing = files.files
        failing.saveCue = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(Self.code { _ = try EditDraftFiles(files: failing).addCue({ ok }, track: Self.track, rekordboxCues: [], dryRun: false) } == "draft_io_failed")
    }

    @Test func 태그는_고르기_값으로_맞추고_파일_이름과_링크를_본다() throws {
        let files = MemoryDraftFiles()
        let edits = EditDraftFiles(files: files.files)
        let draft = try edits.setTags([.rating: "3", .title: "새 제목"], track: Self.track, colors: TrackColor.rekordboxDefaults,
                                      inPlaylist: false, dryRun: false)
        #expect(draft.fields.title == "새 제목" && files.tag("u7")?.fields.title == "새 제목")
        #expect(Self.code { try edits.checkTarget(.cue, uuid: "../x") } == "invalid_arguments")
        var linked = files.files
        linked.isPlainPath = { _, _ in false }
        #expect(Self.code { try EditDraftFiles(files: linked).checkTarget(.tag, uuid: "u7") } == "invalid_arguments")
        try edits.remove(.tag, uuid: "u7", dryRun: true)
        #expect(files.tag("u7") != nil)
        try edits.remove(.tag, uuid: "u7", dryRun: false)
        #expect(files.tag("u7") == nil)
    }

    @Test func 질의는_명시한_사본을_열고_없으면_최신_스냅샷과_라이브_share를_쓴다() throws {
        let latest = URL(filePath: "/snapshots/master-2.db"), explicit = URL(filePath: "/copies/master.db")
        let opened = OpenLog()
        let source = LibraryQuerySource(open: { snapshot, share, _ in
            opened.add(snapshot, share)
            throw ReadFailure("stop", "")
        }, parse: { _ in LibraryRecords.ParsedComment(classification: "none", parsed: nil) },
           compatibility: { _ in throw ReadFailure("stop", "") })
        let queries = QueryLibrary(source: .memory([:], latest: latest), query: source, liveShare: URL(filePath: "/live/share"))
        _ = try? queries.open(database: explicit)
        _ = try? queries.open(database: nil)
        #expect(opened.calls == [(explicit, nil), (latest, URL(filePath: "/live/share"))].map { "\($0.0.path)|\($0.1?.path ?? "-")" })
    }

    @Test func 텍스트_현황은_JSON과_같은_질의를_열고_정한_사본을_함께_준다() throws {
        let latest = URL(filePath: "/snapshots/master-2.db")
        let library = RekordboxLibrary(allTracks: [Self.track], cues: [], playCounts: [:])
        let source = LibraryQuerySource(open: { _, _, preset in
            LibraryQuery(search: { _, _, _, _, _ in throw ReadFailure("stub", "") }, track: { _ in throw ReadFailure("stub", "") },
                         playlists: { _ in .init(playlists: []) }, playlist: { _ in throw ReadFailure("stub", "") },
                         histories: { .init(histories: []) }, history: { _ in throw ReadFailure("stub", "") },
                         drafts: { .init(drafts: []) }, duplicates: { LibraryRecords.duplicates(in: library) },
                         report: { _ in LibraryReport(library: library, commentRule: preset.rule) },
                         paths: { _ in .init(paths: []) }, titlePaths: { _ in [] },
                         draftSource: { _ in throw ReadFailure("stub", "") }, isInPlaylist: { _ in false }, colors: [])
        }, parse: { _ in LibraryRecords.ParsedComment(classification: "none", parsed: nil) },
           compatibility: { _ in throw ReadFailure("stub", "") })
        let queries = QueryLibrary(source: .memory([:], latest: latest), query: source, liveShare: URL(filePath: "/live/share"))
        let copy = try queries.openCopy(database: nil)
        #expect(copy.snapshot == latest)
        // JSON 값은 텍스트와 같은 현황에서 만든다. 코멘트 규칙이 없으면 코멘트 칸은 비운다
        let json = LibraryRecords.Report(copy.query.report(false))
        #expect(json.liveTracks == 1 && json.tracksWithoutCues == 1 && json.commentClasses == nil && json.missingFiles == nil)
        let anisong = LibraryRecords.Report(try queries.open(database: nil, commentPreset: .anisong).report(false))
        #expect(anisong.commentClasses != nil)
    }

    final class OpenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func add(_ snapshot: URL, _ share: URL?) { lock.withLock { log.append("\(snapshot.path)|\(share?.path ?? "-")") } }
        var calls: [String] { lock.withLock { log } }
    }
}
