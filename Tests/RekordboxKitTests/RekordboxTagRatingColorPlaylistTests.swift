import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 재생 목록에 든 곡의 평점·곡 색(#65 실험 R65, rekordbox 7.2.18.0311, 2026-10-09, 곡마다 한 칸, 5초 간격):
/// ① "DJC 실험곡 3"(일반 목록 4곳) 평점 0 → 3, ② "DJC 실험곡 5"(목록 2곳) 곡 색 없음 → Red('2'),
/// ③ "DJC 실험곡 1 T"(목록 5곳, 그중 한 목록에 두 번) 평점 0 → 5.
/// - `djmdContent`: `Rating`·`ColorID`, `TrackInfoUpdated` +1, `rb_local_usn`, `updated_at`만 바뀌었다. 곡·재생 목록 표는 그대로였다.
/// - `masterPlaylists6.xml`: 저장마다 그 곡이 든 일반 목록 NODE의 Timestamp만 바뀌었다(같은 목록에 두 번 들어도 한 번, 부모 폴더·다른 속성 그대로).
///   정보 패널 아홉 칸·키(#173·S5 K1)와 같은 규칙이다. 값은 곡 행 `updated_at` 몇 ms 뒤에서 목록마다 조금씩 커졌다. DJCrate는 한 값을 쓴다.
extension RekordboxTagWriterTests {
    static let r65Edits: [(String, @Sendable (inout TagFields) -> Void)] = [
        ("① 평점 0 → 3", { $0.rating = "3" }), ("② 곡 색 없음 → Red", { $0.color = "2" }), ("③ 평점 0 → 5", { $0.rating = "5" }),
    ]

    @Test(arguments: [0, 256, 257])
    func 재생_목록에_든_곡의_평점과_곡_색은_곡_행과_곡이_든_목록의_Timestamp만_고친다(state: Int) throws {
        for (name, edit) in Self.r65Edits {
            let (fixture, track) = try ratingLibrary(state: state)
            let url = try withPlaylists(fixture, [
                PlaylistSpec(id: "100", name: "폴더", seq: 1, isFolder: true),
                PlaylistSpec(id: "201", name: "곡이 든 목록", parentID: "100", seq: 1, contentIDs: ["501", "500"]),
                PlaylistSpec(id: "202", name: "두 번 든 목록", seq: 2, contentIDs: ["500", "500"]),
                PlaylistSpec(id: "203", name: "다른 곡 목록", seq: 3, contentIDs: ["501"]),
                PlaylistSpec(id: "204", name: "지운 목록", seq: 4, contentIDs: ["500"]),
            ])
            try fixture.execute("UPDATE djmdPlaylist SET rb_local_deleted = 1 WHERE ID = '204'")
            let tables = try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID")
            let others = try otherTables(fixture)
            let xml = try Data(contentsOf: url), before = try content(fixture)

            let report = try write(fixture, tags: [try draft(fixture, track, edit)])
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty, "\(name) \(report.tagBlocked.map(\.reason))")
            let after = try content(fixture)
            var saved: Set<String> = [name.contains("색") ? "ColorID" : "Rating", "TrackInfoUpdated", "rb_local_usn", "updated_at"]
            if state == 256 { saved.insert("rb_data_status") }
            #expect(changedColumns(before, after) == saved, "\(name)")
            #expect(Int(after["TrackInfoUpdated"] ?? "") == (Int(before["TrackInfoUpdated"] ?? "") ?? 0) + 1, "\(name)")
            #expect(try otherTables(fixture) == others, "\(name): 다른 표는 그대로")
            #expect(try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY ID") + fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID") == tables)

            // 곡이 든 살아 있는 목록만(두 번 든 목록도 한 줄), 부모 폴더·다른 곡 목록·지운 목록은 그대로
            let hex = { (id: String) in MasterPlaylistsXML.hex(id) ?? "" }
            let stamps = try timestamps(url)
            #expect(stamps[hex("201")] == nowMS && stamps[hex("202")] == nowMS, "\(name)")
            for id in ["100", "203", "204"] { #expect(stamps[hex(id)] == 1_000, "\(name) \(id)") }
            let lines = { (data: Data) in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") }
            let written = try Data(contentsOf: url)
            #expect(zip(lines(xml), lines(written)).filter { $0 != $1 }.count == 2 && lines(xml).count == lines(written).count, "\(name)")
        }
    }

    @Test func 목록에_든_곡의_평점은_XML이_깨져_있으면_그_초안만_막는다() throws {
        // 평점·곡 색도 XML을 고치는 칸이라(R65) 정보 패널 칸과 같이 XML을 읽지 못하면 그 곡정보 초안만 막는다
        let (fixture, track) = try ratingLibrary()
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"]))
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.rating = "3" }])
        #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("masterPlaylists6.xml") == true)
        #expect(try content(fixture) == before && Data(contentsOf: url) == Data("망가짐".utf8))
    }
}
