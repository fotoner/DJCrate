import Foundation
import RekordboxKit

/// 날짜·순번·반복 재생·삭제 행이 섞인 합성 기록. 화면 확인에도 같은 자료를 쓴다.
public func historyFixture() throws -> RekordboxFixture {
    let fixture = try RekordboxFixture()
    return try fixture.withConnection {
        for (id, title) in [("101", "합성 Alpha"), ("102", "합성 Beta"), ("103", "삭제된 합성 곡")] {
            var track = TrackSpec(id: id, uuid: "history-track-\(id)")
            track.title = title
            track.folderPath = "/synthetic/history-\(id).mp3"
            try fixture.add(track)
        }
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '103'")
        for (id, name, date, seq, attribute, deleted) in [
            ("old", "합성 이전 기록", "2025-01-02", 1, 0, 0),
            ("new-b", "합성 저녁 기록", "2025-02-03", 2, 0, 0),
            ("new-a", "합성 오전 기록", "2025-02-03", 1, 0, 0),
            ("folder", "합성 폴더", "2025-03-01", 1, 1, 0),
            ("deleted", "삭제된 기록", "2025-04-01", 1, 0, 1),
            ("undated", "날짜 없는 합성 기록", "", 1, 0, 0),
        ] {
            try fixture.insert("djmdHistory", ["ID": .text(id), "Name": .text(name), "DateCreated": .text(date),
                "Seq": .int(seq), "Attribute": .int(attribute), "ParentID": .text("root"), "rb_local_deleted": .int(deleted)])
        }
        for (id, content, number, deleted) in [
            ("entry-3", "101", 3, 0), ("entry-1", "102", 1, 0), ("entry-2", "101", 2, 0),
            ("removed-entry", "102", 4, 1), ("missing", "missing", 5, 0), ("removed-track", "103", 6, 0),
        ] {
            try fixture.insert("djmdSongHistory", ["ID": .text(id), "HistoryID": .text("new-a"),
                "ContentID": .text(content), "TrackNo": .int(number), "rb_local_deleted": .int(deleted)])
        }
        return fixture
    }
}
