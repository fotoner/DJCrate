@testable import DJCrate
import DJCStorage
import DJCDomain
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

@Suite("CLI 읽기 JSON")
struct LibraryReadTests {
    @Test func 프리셋을_안_고르면_JSON에_규칙_집계가_없다() throws {
        let fixture = try fixture(), read = try reader(fixture)
        let report = try json("report", read.report(checkFiles: false))
        #expect(report["commentClasses"] == nil)
        #expect(report["prefixes"] == nil)
        #expect(report["usages"] == nil)
        #expect(throws: ReadFailure.self) { try read.search(query: "", filter: .offConvention) }
    }

    @Test(arguments: ["none", "anisong"])
    func CLI_프리셋은_앱_설정_없이_명시한_값만_쓴다(preset: String) throws {
        let fixture = try fixture()
        let result = try runCLI(["report", "--json", "--comment-preset", preset, "--db", fixture.database.path], fixture: fixture)
        #expect(result.status == 0 && result.stderr.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        let report = try #require(envelope["data"] as? [String: Any])
        if preset == "anisong" {
            #expect(report["commentClasses"] as? [String: Int] == ["convention": 1, "empty": 1])
            #expect(report["prefixes"] as? [String: Int] == ["TVA": 1])
            #expect(report["usages"] as? [String: Int] == ["OP": 1])
        } else {
            #expect(report["commentClasses"] == nil && report["prefixes"] == nil && report["usages"] == nil)
        }
    }

    @Test(arguments: [["--comment-preset", "unknown"], ["--comment-preset"], ["--filter", "off-convention"]])
    func CLI는_잘못된_프리셋과_꺼진_필터를_DB보다_먼저_검사한다(options: [String]) throws {
        let fixture = try RekordboxFixture()
        let result = try runCLI(["search", "", "--json", "--db", fixture.root.appending(path: "missing.db").path] + options, fixture: fixture)
        #expect(result.status == 1 && result.stdout.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: result.stderr) as? [String: Any])
        #expect((envelope["error"] as? [String: String])?["code"] == "invalid_arguments")
    }

    private func runCLI(_ arguments: [String], fixture: RekordboxFixture) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path,
            "DJC_REKORDBOX_DIR": fixture.root.path,
        ]) { _, new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        return try fixture.withConnection {
            var first = TrackSpec(id: "101", uuid: "track-101")
            first.title = "시험 Alpha"
            first.folderPath = "/synthetic/alpha.mp3"
            first.analysisDataPath = "/PIONEER/USBANLZ/test/ANLZ0000.DAT"
            var loop = CueSpec(id: "loop", kind: 1, inMsec: 1000)
            loop.outMsec = 3000; loop.activeLoop = 1; loop.beatLoopSize = 4 << 16 | 1
            first.cues = [CueSpec(id: "memory", inMsec: 500), loop]
            first.gain = RekordboxAutoGain.halves(0.5)
            try fixture.add(first)
            try fixture.putAnalysis(for: first, dat: AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 128, first: 0, count: 16)), ext: nil)
            var second = TrackSpec(id: "102", uuid: "track-102")
            second.title = "시험 Beta"; second.bpm100 = 0; second.folderPath = "/synthetic/beta.mp3"
            try fixture.add(second)
            try fixture.add(TrackSpec(id: "103", uuid: "deleted"))
            try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '103'")
            try fixture.insert("djmdKey", ["ID": .text("k1"), "ScaleName": .text("8A")])
            try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
            try fixture.execute("UPDATE djmdContent SET KeyID = 'k1', ArtistID = 'a1', Commnt = 'TVA 시험 OP 1' WHERE ID = '101'")
            for (id, parent, name, attribute, seq) in [("f1", "root", "시험 폴더", 1, 1), ("p1", "f1", "시험 목록", 0, 1), ("p2", "root", "빈 목록", 0, 2)] {
                try fixture.insert("djmdPlaylist", ["ID": .text(id), "ParentID": .text(parent), "Name": .text(name), "Attribute": .int(attribute), "Seq": .int(seq)])
            }
            for (index, id) in ["102", "101", "101", "103"].enumerated() {
                try fixture.insert("djmdSongPlaylist", ["ID": .text("s\(index)"), "PlaylistID": .text("p1"), "ContentID": .text(id), "TrackNo": .int(index + 1)])
            }
            return fixture
        }
    }

    func reader(_ fixture: RekordboxFixture, preset: CommentPreset = .none) throws -> LibraryRead {
        try LibraryRead(snapshot: fixture.database, home: fixture.root.appending(path: "home"), shareRoot: fixture.shareRoot, commentPreset: preset)
    }

    func json<T: Encodable>(_ command: String, _ result: T) throws -> [String: Any] {
        let encoded = try ReadJSON.encode(command: command, data: result)
        let envelope = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(envelope.keys) == ["schemaVersion", "command", "data"])
        #expect(envelope["schemaVersion"] as? Int == 1)
        #expect(envelope["command"] as? String == command)
        return try #require(envelope["data"] as? [String: Any])
    }

    @Test func 검색_JSON과_교집합_필터() throws {
        let fixture = try fixture(), read = try reader(fixture, preset: .anisong)
        let data = try json("search", read.search(query: "ALPHA", bpm: 120...130, key: "8a", playlistID: "p1"))
        #expect(Set(data.keys) == ["tracks"])
        let tracks = try #require(data["tracks"] as? [[String: Any]])
        #expect(tracks.count == 1)
        #expect(tracks.first?["id"] as? String == "101")
        #expect(tracks.first?["bpm"] as? Double == 128)
        #expect(Set(try #require(tracks.first).keys) == ["id", "uuid", "title", "artist", "key", "bpm", "lengthSeconds", "path", "comment", "importedOn", "isStreaming"])
        #expect(try read.search(query: "").tracks.map(\.id) == ["101", "102"])
        #expect(try read.search(query: "없는 곡").tracks.isEmpty)
        #expect(try read.search(query: "", filter: .noBPM).tracks.map(\.id) == ["102"])
        #expect(try read.search(query: "", filter: .noCues).tracks.map(\.id) == ["102"])
        #expect(try read.search(query: "", filter: .emptyComment).tracks.map(\.id) == ["102"])
    }

    @Test func 곡_상세_JSON은_큐_그리드_게인_소속_초안을_담는다() throws {
        let fixture = try fixture(), read = try reader(fixture)
        let data = try json("track", read.track(id: "101"))
        #expect(Set(data.keys) == ["track", "cues", "grid", "gain", "playlists", "drafts"])
        let cues = try #require(data["cues"] as? [[String: Any]])
        #expect(cues.map { $0["id"] as? String } == ["memory", "loop"])
        #expect(cues.last?["hotCueSlot"] as? String == "A")
        #expect(cues.last?["isLoop"] as? Bool == true)
        #expect(cues.last?["outMsec"] as? Int == 3000)
        #expect(Set(try #require(cues.last).keys) == ["id", "kind", "hotCueSlot", "inMsec", "outMsec", "name", "isLoop", "activeLoop", "loopBeats", "isAutoGenerated", "color"])
        let grid = try #require(data["grid"] as? [String: Any])
        #expect(Set(grid.keys) == ["status", "beatCount", "segments", "tempoChanges"])
        #expect(grid["status"] as? String == "available")
        #expect(grid["beatCount"] as? Int == 16)
        #expect((grid["segments"] as? [Any])?.count == 1)
        let segment = try #require((grid["segments"] as? [[String: Any]])?.first)
        #expect(Set(segment.keys) == ["start", "bpm", "firstBeatNumber"])
        #expect((data["gain"] as? [String: Any])?["linear"] as? Double == 0.5)
        #expect(Set(try #require(data["gain"] as? [String: Any]).keys) == ["linear", "decibels", "peak"])
        #expect((data["playlists"] as? [[String: Any]])?.map { $0["id"] as? String } == ["p1"])
        #expect((data["drafts"] as? [String: Bool]) == ["cue": false, "grid": false, "gain": false, "tag": false])
        let missing = try json("track", read.track(id: "102"))
        #expect(missing["gain"] == nil)
        #expect((missing["grid"] as? [String: Any])?["status"] as? String == "unavailable")
    }

    @Test func 재생목록_JSON은_트리와_곡순서_중복을_보존한다() throws {
        let fixture = try fixture(), read = try reader(fixture)
        let flat = try json("playlists", read.playlists(tree: false))
        #expect(Set(flat.keys) == ["playlists"])
        #expect((flat["playlists"] as? [Any])?.count == 3)
        let flatFirst = try #require((flat["playlists"] as? [[String: Any]])?.first)
        #expect(Set(flatFirst.keys) == ["id", "name", "parentID", "sequence", "isFolder", "trackCount"])
        let tree = try json("playlists", read.playlists(tree: true))
        let roots = try #require(tree["playlists"] as? [[String: Any]])
        #expect(roots.map { $0["id"] as? String } == ["f1", "p2"])
        #expect((roots.first?["children"] as? [[String: Any]])?.first?["id"] as? String == "p1")
        let list = try json("playlist", read.playlist(id: "p1"))
        #expect(Set(list.keys) == ["playlist", "tracks"])
        #expect((list["tracks"] as? [[String: Any]])?.map { $0["id"] as? String } == ["102", "101", "101"])
        #expect(try read.playlist(id: "f1").tracks.map(\.id) == ["102", "101"])
    }

    @Test func 초안_JSON은_게인과_고아초안도_담는다() throws {
        let fixture = try fixture()
        let home = fixture.root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"track-101":-3,"orphan":2}"#.utf8).write(to: home.appending(path: "gain-drafts.json"))
        let read = try reader(fixture)
        let data = try json("drafts", read.drafts())
        #expect(Set(data.keys) == ["drafts"])
        let drafts = try #require(data["drafts"] as? [[String: Any]])
        #expect(drafts.map { $0["trackUUID"] as? String } == ["orphan", "track-101"])
        #expect(drafts.first?["contentID"] == nil)
        #expect(drafts.last?["contentID"] as? String == "101")
        #expect(drafts.last?["kinds"] as? [String] == ["gain"])
        #expect(Set(try #require(drafts.last).keys) == ["trackUUID", "contentID", "title", "kinds"])
        #expect(try read.track(id: "101").drafts.gain)
    }

    @Test func 최신_스냅샷만_선택한다() throws {
        let fixture = try fixture()
        let directory = fixture.root.appending(path: "snapshots")
        let live = fixture.root.appending(path: "live/master.db")
        #expect(throws: (any Error).self) { try LibraryRead.resolve(database: nil, snapshots: directory, liveDatabase: live) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["master-2026-01-01T000000.db", "master-2026-01-02T000000.db"] {
            try FileManager.default.copyItem(at: fixture.database, to: directory.appending(path: name))
        }
        #expect(try LibraryRead.resolve(database: nil, snapshots: directory, liveDatabase: live).lastPathComponent == "master-2026-01-02T000000.db")
    }

    @Test func 라이브_DB와_심볼릭_링크와_하드_링크를_차단한다() throws {
        let fixture = try RekordboxFixture()
        let fm = FileManager.default
        let live = fixture.root.appending(path: "live/master.db")
        try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: live)
        let absolute = fixture.root.appending(path: "absolute.db")
        let relative = fixture.root.appending(path: "relative.db")
        let hard = fixture.root.appending(path: "hard.db")
        try fm.createSymbolicLink(at: absolute, withDestinationURL: live)
        try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "live/master.db")
        try fm.linkItem(at: live, to: hard)
        for candidate in [live, absolute, relative, hard] {
            #expect(throws: ReadFailure.self) { try LibraryRead.resolve(database: candidate, liveDatabase: live) }
        }
        let copy = fixture.root.appending(path: "copy.db")
        try fm.copyItem(at: live, to: copy)
        let copyAlias = fixture.root.appending(path: "copy-alias.db")
        try fm.createSymbolicLink(at: copyAlias, withDestinationURL: copy)
        #expect(try LibraryRead.resolve(database: copy, liveDatabase: live) == copy)
        #expect(try LibraryRead.resolve(database: copyAlias, liveDatabase: live) == copyAlias)
    }

    @Test func 라이브_DB가_없어도_경로와_끊어진_링크를_차단한다() throws {
        let fixture = try RekordboxFixture()
        let fm = FileManager.default
        let live = fixture.root.appending(path: "missing/master.db")
        #expect(!fm.fileExists(atPath: live.path))
        let absolute = fixture.root.appending(path: "absolute.db")
        let relative = fixture.root.appending(path: "relative.db")
        try fm.createSymbolicLink(at: absolute, withDestinationURL: live)
        try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "missing/master.db")
        for candidate in [live, absolute, relative] {
            #expect(throws: ReadFailure.self) { try LibraryRead.resolve(database: candidate, liveDatabase: live) }
        }
        #expect(try LibraryRead.resolve(database: fixture.database, liveDatabase: live) == fixture.database)
    }

    @Test func 없는_ID는_JSON_오류다() throws {
        let fixture = try fixture(), read = try reader(fixture)
        #expect(throws: ReadFailure.self) { try read.track(id: "unknown") }
        #expect(throws: ReadFailure.self) { try read.playlist(id: "unknown") }
        #expect(throws: ReadFailure.self) { try read.search(query: "", playlistID: "unknown") }
        let encoded = try ReadJSON.error(command: "track", error: ReadFailure("not_found", "곡을 찾지 못했습니다. ID를 확인하세요"))
        let error = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(error.keys) == ["schemaVersion", "command", "error"])
        #expect((error["error"] as? [String: String])?["code"] == "not_found")
    }

    @Test func 기존_읽기명령_JSON() throws {
        let fixture = try fixture(), read = try reader(fixture, preset: .anisong)
        let report = try json("report", read.report(checkFiles: false))
        #expect(Set(report.keys) == ["totalRows", "deletedRows", "liveTracks", "streamingTracks", "extensions", "commentClasses", "prefixes", "usages", "emptyByImportYear", "tracksWithCues", "tracksWithManualCues", "tracksWithOnlyAutoCues", "tracksWithoutCues", "hotCueSlots", "playedTracks", "emptyCommentPlayed"])
        #expect(report["liveTracks"] as? Int == 2 && report["deletedRows"] as? Int == 1)
        #expect(read.report(checkFiles: true).missingFiles == 2)
        let paths = try json("path", read.paths(query: "Alpha"))
        #expect(Set(paths.keys) == ["paths"])
        #expect(paths["paths"] as? [String] == ["/synthetic/alpha.mp3"])
        let parsed = try json("parse", LibraryRead.parse(comment: "TVA 시험 OP 1"))
        #expect(parsed["classification"] as? String == "convention")
        #expect(Set(parsed.keys) == ["classification", "parsed"])
        #expect((parsed["parsed"] as? [String: Any])?["workName"] as? String == "시험")
        #expect(Set(try #require(parsed["parsed"] as? [String: Any]).keys) == ["prefix", "workRef", "workName", "abbreviations", "usages", "episodes", "isCharacterSong", "isTVSize", "variants", "isFormerAffiliation", "boomboxVolumes"])
        #expect(LibraryRead.parse(comment: "").parsed == nil)
        let compat = try json("compat", LibraryRead.compatibility(snapshot: fixture.database, version: "7.2.18"))
        #expect(Set(compat.keys) == ["appVersion", "verifiedAppVersions", "databaseVersion", "localUpdateCount"])
        #expect(compat["databaseVersion"] as? String == "6000")
        #expect(compat["localUpdateCount"] as? Int == 1000)
    }

    @Test func 네_종류_초안은_DB_값과_파일을_바꾸지_않는다() throws {
        let fixture = try fixture()
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        let track = try #require(library.tracks.first(where: { $0.id == "101" }))
        let home = fixture.root.appending(path: "home")
        func put<T: Encodable>(_ value: T, at path: String) throws {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url)
        }
        var cue = CueDraft(trackUUID: track.uuid, rekordboxCues: library.cues(for: track))
        cue.cues.removeAll()
        try put(cue, at: "cue-drafts/track-101.json")
        try put(CueDraft(trackUUID: "track-102", rekordboxCues: []), at: "cue-drafts/track-102.json")
        try put(GridDraft(trackUUID: track.uuid, base: [], segments: [.init(start: 1, bpm: 130, firstBeatNumber: 1)]), at: "grid-drafts/track-101.json")
        var tag = TagDraft(track: track)
        tag.fields.title = "초안 제목"
        try put(tag, at: "tag-drafts/track-101.json")
        try put([track.uuid: -3.0], at: "gain-drafts.json")
        let databaseBefore = try Data(contentsOf: fixture.database)
        let tagBefore = try Data(contentsOf: home.appending(path: "tag-drafts/track-101.json"))
        let read = try reader(fixture)
        let info = try read.track(id: track.id)
        #expect(info.drafts.kinds == ["cue", "grid", "gain", "tag"])
        #expect(info.track.title == "시험 Alpha" && info.cues.count == 2)
        #expect(read.drafts().drafts.count == 1)
        #expect(read.drafts().drafts.first?.kinds == ["cue", "grid", "gain", "tag"])
        #expect(try Data(contentsOf: fixture.database) == databaseBefore)
        #expect(try Data(contentsOf: home.appending(path: "tag-drafts/track-101.json")) == tagBefore)
    }

    @Test func 공유_필터는_스트리밍_변속_재생기록을_구분한다() throws {
        let fixture = try fixture()
        var streaming = TrackSpec(id: "104")
        streaming.title = "$A7:암호화된 제목"; streaming.folderPath = "spotify:synthetic"; streaming.bpm100 = 0
        try fixture.add(streaming)
        try fixture.execute("UPDATE djmdContent SET Commnt = '자유 코멘트' WHERE ID = '104'")
        try fixture.insert("djmdSongHistory", ["ID": .text("history-101"), "ContentID": .text("101")])
        var first = TrackSpec(id: "101")
        first.analysisDataPath = "/PIONEER/USBANLZ/test/ANLZ0000.DAT"
        let beats = AnlzBuilder.beats(bpm: 120, first: 0, count: 16) + AnlzBuilder.beats(bpm: 160, first: 8000, count: 16)
        try fixture.putAnalysis(for: first, dat: AnlzBuilder.dat(beats: beats), ext: nil)
        let read = try reader(fixture, preset: .anisong)
        let expected: [LibraryFilter: [String]] = [.emptyComment: ["102"], .offConvention: ["104"],
            .noCues: ["102", "104"], .played: ["101"], .streaming: ["104"], .noBPM: ["102"], .tempoChange: ["101"], .all: ["101", "102", "104"]]
        for filter in LibraryFilter.allCases {
            #expect(try read.search(query: "", filter: filter).tracks.map(\.id) == expected[filter])
        }
        #expect(try read.search(query: "암호화된 제목").tracks.isEmpty)
        #expect(try read.search(query: "합성 아티스트").tracks.map(\.id) == ["101"])
        #expect(try read.search(query: "Alpha", bpm: 129...130).tracks.isEmpty)
        #expect(try read.search(query: "Alpha", key: "8B").tracks.isEmpty)
        #expect(try read.search(query: "", playlistID: "f1").tracks.map(\.id) == ["101", "102"])
        #expect(Set(LibraryFilter.allCases.map(\.cliName)) == ["all", "empty-comment", "off-convention", "no-cues", "played", "streaming", "no-bpm", "tempo-change"])
    }

    @Test @MainActor func 사이드바_기본_선택은_전체다() {
        let store = LibraryStore(saveTagDrafts: { _ in })
        #expect(store.sidebar == .filter(.all))
        #expect(store.sidebarTitle == "전체")
    }

    @Test func 빈_코멘트는_연도와_스트리밍을_제한하지_않는다() throws {
        let fixture = try fixture()
        var streaming = TrackSpec(id: "104")
        streaming.folderPath = "spotify:synthetic"
        try fixture.add(streaming)
        try fixture.execute("UPDATE djmdContent SET StockDate = '2024-01-01' WHERE ID = '102'")
        try fixture.execute("UPDATE djmdContent SET StockDate = '2027-01-01' WHERE ID = '104'")
        #expect(try reader(fixture, preset: .anisong).search(query: "", filter: .emptyComment).tracks.map(\.id) == ["102", "104"])
    }

    @Test(arguments: [false, true])
    func CLI는_삭제한_필터를_DB를_열기_전에_거절한다(json: Bool) throws {
        let fixture = try RekordboxFixture()
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/djc", ".build/out/Products/Debug/djc"]
        let executable = try #require(candidates.map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = ["search", "", "--filter", "backlog", "--db", fixture.root.appending(path: "missing.db").path]
            + (json ? ["--json"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path,
            "DJC_REKORDBOX_DIR": fixture.root.path,
        ]) { _, new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1 && stdout.isEmpty)
        let message: String
        if json {
            let document = try #require(JSONSerialization.jsonObject(with: stderr) as? [String: Any])
            #expect(document["schemaVersion"] as? Int == 1 && document["command"] as? String == "search")
            let error = try #require(document["error"] as? [String: String])
            #expect(error["code"] == "invalid_arguments")
            message = try #require(error["message"])
        } else {
            message = String(decoding: stderr, as: UTF8.self)
        }
        #expect(message.contains("backlog"))
        #expect(message.contains("--filter empty-comment"))
    }
}
