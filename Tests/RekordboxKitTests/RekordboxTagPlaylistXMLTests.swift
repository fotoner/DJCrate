import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 곡 정보를 쓰면 그 곡이 든 재생 목록의 `masterPlaylists6.xml` Timestamp도 고친다(#173, 2026-10-04 rekordbox 7.2.18).
/// S1 X1(아티스트)·S2 U11(제목, 256)·U12(제목, 상태 0)·X4(같은 값 저장)·S3 V07(장르)·S4 A1~A6(앨범·앨범 아티스트·작곡가·연도·트랙 번호·
/// 코멘트)·B2(앨범): 그 저장에서 곡이 든 살아 있는 목록마다 Timestamp를 저장 시각(UTC epoch ms)으로 바꿨다. 정보 패널 아홉 칸 모두다. 키도 같다(S5 K1, `RekordboxTagKeyTests`).
/// 부모 폴더·다른 목록·DB 재생 목록 표는 그대로였다. 그림 저장은 바꾸지 않는다(#66 범위). 그 곡이 든 살아 있는 목록이 없는 초안은 XML을
/// 읽지도 고치지도 않는다. XML은 쓰는 DB 옆 파일만 고친다(사본이면 사본 옆, 없으면 DB만).
extension RekordboxTagWriterTests {
    var nowMS: Int64 { 1_790_337_600_000 }

    /// 재생 목록을 넣고 DB 옆에 그 NODE가 든 XML(Timestamp 1000)을 둔다.
    @discardableResult
    func withPlaylists(_ fixture: RekordboxFixture, _ playlists: [PlaylistSpec]) throws -> URL {
        var xml = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        for playlist in playlists {
            try fixture.add(playlist)
            try xml.append(id: playlist.id, parentID: playlist.parentID, isFolder: playlist.isFolder, timestamp: 1_000)
        }
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try xml.text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func timestamps(_ url: URL) throws -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: try MasterPlaylistsXML(contentsOf: url).nodes.map { ($0.id, $0.timestamp) })
    }

    /// 칸마다 쓸 값(연도·트랙 번호는 숫자)
    static let xmlValues: [TagFields.Key: String] = [
        .title: "DJC 173 제목", .artist: "DJC 173 아티스트", .album: "DJC 173 앨범", .albumArtist: "DJC 173 앨범 아티스트",
        .genre: "DJC 173 장르", .composer: "DJC 173 작곡가", .year: "2020", .trackNumber: "99", .comment: "DJC 173 코멘트",
    ]
    /// 아홉 칸 × 곡 상태(0·256·257을 돌려 가며)
    static let xmlCases: [(Int, TagFields.Key)] = infoPanelKeys.enumerated().map { ([0, 256, 257][$0.offset % 3], $0.element) }

    @Test(arguments: xmlCases)
    func 곡_정보를_쓰면_곡이_든_재생_목록의_Timestamp만_쓴_시각으로_고친다(state: Int, key: TagFields.Key) throws {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID = '500'", [.int(state)])
        // 앨범 아티스트는 한 곡만 쓰는 앨범에서 쓴다(곡 501은 목록에만 둔다)
        try fixture.execute("UPDATE djmdContent SET AlbumID = '' WHERE ID = '501'")
        let url = try withPlaylists(fixture, [
            PlaylistSpec(id: "100", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "201", name: "곡이 든 목록", parentID: "100", seq: 1, contentIDs: ["501", "500"]),
            PlaylistSpec(id: "202", name: "두 번 든 목록", seq: 2, contentIDs: ["500", "500"]),
            PlaylistSpec(id: "203", name: "다른 곡 목록", seq: 3, contentIDs: ["501"]),
            PlaylistSpec(id: "204", name: "지운 목록", seq: 4, contentIDs: ["500"]),
            PlaylistSpec(id: "205", name: "지운 항목", seq: 5, contentIDs: ["500"]),
        ])
        try fixture.execute("UPDATE djmdPlaylist SET rb_local_deleted = 1 WHERE ID = '204'")
        try fixture.execute("UPDATE djmdSongPlaylist SET rb_local_deleted = 1 WHERE PlaylistID = '205'")
        let tables = try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID")
        let before = try Data(contentsOf: url)
        let tags = try draft(fixture, track) { $0[key] = Self.xmlValues[key] ?? "" }

        // 미리 보기와 막힌 초안은 XML을 건드리지 않는다
        #expect(try write(fixture, tags: [tags], dryRun: true).tagWritten.count == 1)
        #expect(try write(fixture, tags: [tags], keys: []).tagBlocked.count == 1)
        #expect(try Data(contentsOf: url) == before)

        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let hex = { (id: String) in MasterPlaylistsXML.hex(id) ?? "" }
        let after = try timestamps(url)
        #expect(after[hex("201")] == nowMS && after[hex("202")] == nowMS)
        for id in ["100", "203", "204", "205"] { #expect(after[hex(id)] == 1_000, "\(id)") }
        // 고친 줄 말고는 바이트 그대로, DB 재생 목록 표도 그대로
        let lines = { (data: Data) in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") }
        let written = try Data(contentsOf: url)
        let changed = zip(lines(before), lines(written)).filter { $0 != $1 }
        #expect(changed.count == 2 && lines(before).count == lines(written).count)
        #expect(try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID") == tables)
    }

    @Test func 곡_정보_아홉_칸_모두_XML_Timestamp를_고친다() throws {
        // #173 S4(2026-10-04): A1 앨범 새 이름·A2 앨범 아티스트 넣기·A3 작곡가 넣기·A4 연도·A5 트랙 번호·A6 코멘트·B2 앨범 새 이름(둘째 저장)도
        // 그 곡이 든 살아 있는 목록의 Timestamp를 고쳤다. S1~S3의 제목·아티스트·장르와 합쳐 아홉 칸 모두다. 칸마다 따로 써도 매번 고친다.
        let (fixture, track) = try library(shared: false)
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let before = try Data(contentsOf: url)
        for key in Self.infoPanelKeys {
            try before.write(to: url)
            #expect(try write(fixture, tags: [try draft(fixture, track) { $0[key] = Self.xmlValues[key] ?? "" }]).tagWritten.count == 1, "\(key)")
            #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS, "\(key)")
        }
    }

    @Test func XML이_깨져_있으면_목록에_든_곡의_코멘트_초안도_막는다() throws {
        // 코멘트도 XML을 고치므로(S4 A6) 그 곡이 든 살아 있는 목록이 있으면 XML이 망가져 있을 때 막는다(목록에 없는 곡은 아래처럼 쓴다).
        let (fixture, track) = try library()
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"]))
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 173 코멘트" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        #expect(report.tagBlocked.first?.reason?.contains("masterPlaylists6.xml") == true)
        #expect(report.tagBlocked.first?.title == "옛 제목", "다른 막힘처럼 DB의 곡 제목")
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
    }

    @Test func 고칠_XML이_원본과_같으면_쓰지_않는다() throws {
        // 곡이 든 목록의 NODE가 XML에 없으면 고칠 줄이 없다. 같은 내용을 다시 쓰지 않는다(파일을 바꿔 넣지 않아 inode가 그대로).
        let (fixture, track) = try library()
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"]))
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try MasterPlaylistsXMLTests.empty.write(to: url, atomically: true, encoding: .utf8)
        let inode = { (try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as? UInt64 }
        let before = try inode()
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }]).tagWritten.count == 1)
        #expect(try inode() == before)
    }

    @Test func 목록에_없는_곡의_장르_쓰기는_XML이_깨져_있어도_쓴다() throws {
        // 곡 정보를 써도 그 곡이 든 살아 있는 목록이 없으면 고칠 XML이 없어 읽지 않는다.
        let (fixture, track) = try library()
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.genre = "DJC 173 장르" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
    }

    @Test func XML이_깨져_있으면_목록에_든_곡의_곡정보_초안만_막고_큐는_쓴다() throws {
        // XML을 고쳐야 하는 곡정보 초안만 할 일과 함께 막고, 같은 쓰기의 큐·목록에 없는 곡의 곡정보는 그대로 쓴다(재생 목록 쓰기는 예전처럼 쓰기째 막는다).
        let (fixture, track) = try library()
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"]))
        var cued = TrackSpec(id: "600", uuid: "track-uuid-600")
        cued.cues = [.autoCue(at: 1024)]
        try fixture.add(cued)
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        var cues = CueDraft(trackUUID: cued.uuid, rekordboxCues: cued.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let tags = [try draft(fixture, track) { $0.title = "DJC 173 제목" }, try draft(fixture, neighbor) { $0.title = "DJC 173 이웃" }]
        let report = try write(fixture, tags: tags, drafts: [cues])
        #expect(report.written.count == 1)
        #expect(report.tagWritten.map(\.trackUUID) == [neighbor.uuid] && report.tagBlocked.map(\.trackUUID) == [track.uuid])
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains("masterPlaylists6.xml") && reason.contains("다시"))
        #expect(try content(fixture)["Title"] == "옛 제목" && content(fixture, "501")["Title"] == "DJC 173 이웃")
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
        // 막힌 곡정보만 있으면 백업도 만들지 않는다
        let alone = try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }])
        #expect(alone.tagBlocked.count == 1 && alone.backup == nil)
    }

    @Test func 곡_정보의_XML은_쓰는_DB_옆_파일만_고치고_없으면_DB만_쓴다() throws {
        // 안전: 사본 DB에 쓰면 사본 옆 XML만 고친다. 다른 폴더(같은 NODE가 든 미끼)·rekordbox 폴더(DJC_REKORDBOX_DIR)의 XML은 그대로다.
        let (fixture, track) = try library()
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let (decoy, _) = try library()
        let decoyURL = try withPlaylists(decoy, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        let decoyBefore = try Data(contentsOf: decoyURL)
        let rekordboxXML = LibrarySnapshot.rekordboxDirectory.appending(path: "masterPlaylists6.xml")
        let rekordboxBefore = try? Data(contentsOf: rekordboxXML)

        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }]).tagWritten.count == 1)
        #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
        #expect(try Data(contentsOf: decoyURL) == decoyBefore)
        #expect((try? Data(contentsOf: rekordboxXML)) == rekordboxBefore)

        // DB 옆에 XML이 없으면 DB만 쓰고 XML을 만들지 않는다
        try FileManager.default.removeItem(at: url)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목 2" }])
        #expect(try report.tagWritten.count == 1 && content(fixture)["Title"] == "DJC 173 제목 2")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: decoyURL) == decoyBefore)
        #expect((try? Data(contentsOf: rekordboxXML)) == rekordboxBefore)
    }

    /// 사본 DB 옆 XML을 라이브(합성 폴더)의 XML에 이어 둔다(링크는 심볼릭·하드). 라이브 폴더를 가리키는 관문과 라이브 XML 원문을 돌려준다.
    func linkedPlaylistXML(_ fixture: RekordboxFixture, hardLink: Bool, contentIDs: [String] = ["500"])
        throws -> (guardian: RekordboxWriteGuard, liveXML: URL, original: Data) {
        let live = fixture.root.appending(path: "live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: live.appending(path: "master.db"))
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: contentIDs)])
        let liveXML = live.appending(path: "masterPlaylists6.xml")
        try FileManager.default.moveItem(at: url, to: liveXML)
        if hardLink {
            try FileManager.default.linkItem(at: liveXML, to: url)
        } else {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: liveXML)
        }
        let guardian = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { nil }, liveDirectories: [live])
        return (guardian, liveXML, try Data(contentsOf: liveXML))
    }

    func writeGuarded(_ fixture: RekordboxFixture, _ guardian: RekordboxWriteGuard, tags: [TagDraft], drafts: [CueDraft] = [],
                      playlists: [PlaylistEdit] = []) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: [], gains: [:], tags: tags, analysisInputs: [:], playlists: playlists, to: fixture.database,
                                  dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot, guard: guardian,
                                  attachesAnalysis: false)
    }

    @Test(arguments: [false, true]) func 사본_옆_XML이_라이브_XML에_이어져_있으면_그_곡정보_초안만_막고_백업도_만들지_않는다(hardLink: Bool) throws {
        // 사본 DB 옆 XML이 라이브 폴더 XML의 링크면 그 XML을 고칠 곡정보 초안만 막는다(XML을 읽지 못할 때와 같다). 라이브 XML은 그대로다.
        let (fixture, track) = try library()
        let (guardian, liveXML, liveBefore) = try linkedPlaylistXML(fixture, hardLink: hardLink)
        let before = try content(fixture)
        let report = try writeGuarded(fixture, guardian, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        let blocked = try #require(report.tagBlocked.first)
        #expect(blocked.title == "옛 제목", "다른 막힘처럼 DB의 곡 제목")
        #expect(blocked.reason?.contains("masterPlaylists6.xml") == true && blocked.reason?.contains("라이브") == true)
        #expect(try Data(contentsOf: liveXML) == liveBefore)
        #expect(try content(fixture) == before && RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    @Test(arguments: [false, true]) func 사본_옆_XML이_이어져_있어도_같은_쓰기의_큐와_목록에_없는_곡의_곡정보는_쓴다(hardLink: Bool) throws {
        let (fixture, track) = try library()
        var cued = TrackSpec(id: "600", uuid: "track-uuid-600")
        cued.cues = [.autoCue(at: 1024)]
        try fixture.add(cued)
        let (guardian, liveXML, liveBefore) = try linkedPlaylistXML(fixture, hardLink: hardLink)
        var cues = CueDraft(trackUUID: cued.uuid, rekordboxCues: cued.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let tags = [try draft(fixture, track) { $0.title = "DJC 173 제목" }, try draft(fixture, neighbor) { $0.title = "DJC 173 이웃" }]
        let report = try writeGuarded(fixture, guardian, tags: tags, drafts: [cues])
        #expect(report.written.count == 1 && report.backup != nil)
        #expect(report.tagWritten.map(\.trackUUID) == [neighbor.uuid] && report.tagBlocked.map(\.trackUUID) == [track.uuid])
        #expect(try content(fixture)["Title"] == "옛 제목" && content(fixture, "501")["Title"] == "DJC 173 이웃")
        #expect(try Data(contentsOf: liveXML) == liveBefore, "이어진 라이브 XML은 쓰지 않는다")
    }

    @Test(arguments: [false, true]) func 사본_옆_XML이_이어져_있으면_재생_목록_편집은_쓰기째_백업_전에_막는다(hardLink: Bool) throws {
        let (fixture, track) = try library()
        let (guardian, liveXML, liveBefore) = try linkedPlaylistXML(fixture, hardLink: hardLink)
        let before = try content(fixture)
        #expect(throws: DJCError.self) {
            try writeGuarded(fixture, guardian, tags: [try draft(fixture, track) { $0.title = "DJC 173 제목" }],
                             playlists: [.create(key: "n", name: "새 목록", isFolder: false, parent: .root)])
        }
        #expect(try Data(contentsOf: liveXML) == liveBefore)
        #expect(try content(fixture) == before && RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }
}
