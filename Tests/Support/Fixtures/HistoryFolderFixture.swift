import Foundation
import RekordboxKit

/// rekordbox처럼 연 › 월 폴더 아래에 둔 합성 기록. root 바로 아래·부모가 빈 값·삭제된 폴더·순환 폴더·지나치게 깊은 폴더 아래 기록도 섞는다.
/// 폴더 모양은 실제 rekordbox 7 라이브러리에서 읽기만 해 확인했다: 연 폴더(ID "2026", 이름 "2026", 부모 root)와
/// 월 폴더(ID "202608", 이름 "8", 부모 연 폴더)는 Attribute 1, 기록은 Attribute 0에 Seq가 월 폴더 안 순서다.
public func historyFolderFixture() throws -> RekordboxFixture {
    let fixture = try RekordboxFixture()
    try fixture.session { db in
        for (id, name, parent, seq, attribute, date, deleted) in [
            ("2026", "2026", "root", 1, 1, "", 0),
            ("202608", "8", "2026", 2, 1, "", 0),
            ("202607", "7", "2026", 1, 1, "", 1),
            ("loop-a", "순환 A", "loop-b", 1, 1, "", 0),
            ("loop-b", "순환 B", "loop-a", 1, 1, "", 0),
            ("1001", "HISTORY 2026-08-01", "202608", 1, 0, "2026-08-01 23:12:27", 0),
            ("1002", "HISTORY 2026-08-01 (1)", "202608", 2, 0, "2026-08-01 23:40:05", 0),
            ("1003", "합성 root 기록", "root", 3, 0, "2026-06-05 20:00:00", 0),
            ("1004", "HISTORY 2026-07-10", "202607", 1, 0, "2026-07-10 21:00:00", 0),
            ("1005", "합성 순환 기록", "loop-a", 1, 0, "2026-05-01 19:00:00", 0),
            ("1007", "합성 깊은 기록", "deep-1", 1, 0, "2026-03-01 18:00:00", 0),
        ] {
            try db.insert("djmdHistory", ["ID": .text(id), "Name": .text(name), "DateCreated": .text(date),
                "Seq": .int(seq), "Attribute": .int(attribute), "ParentID": .text(parent), "rb_local_deleted": .int(deleted)])
        }
        // 부모가 빈 값이고 Seq가 없는(NULL) 기록
        try db.insert("djmdHistory", ["ID": .text("1006"), "Name": .text("합성 부모 없는 기록"), "DateCreated": .text("2026-04-01 18:00:00"),
            "Attribute": .int(0), "ParentID": .text(""), "rb_local_deleted": .int(0)])
        // deep-1 › … › deep-40 › root: 깊이 제한(32)에서 멈추는지 본다
        for depth in 1...40 {
            try db.insert("djmdHistory", ["ID": .text("deep-\(depth)"), "Name": .text("깊이 \(depth)"), "DateCreated": .text(""),
                "Seq": .int(1), "Attribute": .int(1), "ParentID": .text(depth == 40 ? "root" : "deep-\(depth + 1)"),
                "rb_local_deleted": .int(0)])
        }
    }
    return fixture
}
