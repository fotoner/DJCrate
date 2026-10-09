import Foundation
import RekordboxKit

/// USB 라이브러리 작성 시험용: 로컬 색·메뉴·카테고리·정렬·My Tag·DBID 행을 합성한다.
/// 이름은 rekordbox 기본 이름만 쓰고, 순서·숨김·ID·DBID는 지어낸 값이다(사용자 로컬 설정을 옮기지 않는다).
public extension RekordboxFixture {
    /// rekordbox 기본 색 이름 8개(ID 1…8)
    static let defaultColorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]

    /// rekordbox 기본 메뉴 이름 몇 개(ID 1…, Class는 지어낸 값)
    static let defaultMenuNames = ["Genre", "Artist", "Album", "Track", "BPM", "Rating", "Year", "Key", "Label", "Color",
                                   "Time", "Bitrate", "Comments", "Date Added"]

    /// 여러 행은 연결 하나로 넣는다(연결을 열 때마다 큰 스키마를 다시 읽는다)
    func addColorDefaults() throws {
        try session { db in
            for (index, name) in Self.defaultColorNames.enumerated() {
                try db.insert("djmdColor", ["ID": .text(String(index + 1)), "ColorCode": .int(index), "SortKey": .int(index + 1),
                                            "Commnt": .text(name), "UUID": .text(UUID().uuidString.lowercased()), "rb_local_deleted": .int(0)])
            }
        }
    }

    /// 메뉴 항목 `defaultMenuNames`(ID = 순번 + 1, Class = 순번 + 1)
    func addMenuDefaults() throws {
        try session { db in
            for (index, name) in Self.defaultMenuNames.enumerated() {
                try db.insert("djmdMenuItems", Self.menuItem(id: String(index + 1), classValue: index + 1, name: name))
            }
        }
    }

    func addMenuItem(id: String, classValue: Int, name: String, deleted: Bool = false) throws {
        try insert("djmdMenuItems", Self.menuItem(id: id, classValue: classValue, name: name, deleted: deleted))
    }

    private static func menuItem(id: String, classValue: Int, name: String, deleted: Bool = false) -> [String: CipherDatabase.Value] {
        ["ID": .text(id), "Class": .int(classValue), "Name": .text(name), "UUID": .text(UUID().uuidString.lowercased()),
         "rb_local_deleted": .int(deleted ? 1 : 0)]
    }

    func addCategory(id: String, menuItemID: String, seq: Int, disable: Int?, infoOrder: Int? = nil, deleted: Bool = false) throws {
        try insert("djmdCategory", ["ID": .text(id), "MenuItemID": .text(menuItemID), "Seq": .int(seq),
                                    "Disable": disable.map { .int($0) } ?? .null, "InfoOrder": infoOrder.map { .int($0) } ?? .null,
                                    "UUID": .text(UUID().uuidString.lowercased()), "rb_local_deleted": .int(deleted ? 1 : 0)])
    }

    func addSort(id: String, menuItemID: String, seq: Int, disable: Int?, deleted: Bool = false) throws {
        try insert("djmdSort", ["ID": .text(id), "MenuItemID": .text(menuItemID), "Seq": .int(seq),
                                "Disable": disable.map { .int($0) } ?? .null,
                                "UUID": .text(UUID().uuidString.lowercased()), "rb_local_deleted": .int(deleted ? 1 : 0)])
    }

    /// attribute 1 = 분류, 0 = 태그. 맨 위 분류의 부모는 "root"
    func addMyTag(id: String, name: String, seq: Int, attribute: Int, parentID: String = "root", deleted: Bool = false) throws {
        try insert("djmdMyTag", ["ID": .text(id), "Seq": .int(seq), "Name": .text(name), "Attribute": .int(attribute),
                                 "ParentID": .text(parentID), "UUID": .text(UUID().uuidString.lowercased()),
                                 "rb_local_deleted": .int(deleted ? 1 : 0)])
    }

    /// djmdProperty.DBID(지어낸 값)
    func setDBID(_ dbid: String) throws {
        try execute("UPDATE djmdProperty SET DBID = ?", [.text(dbid)])
    }

    func addGenre(id: String, name: String) throws {
        try insert("djmdGenre", ["ID": .text(id), "Name": .text(name), "rb_local_deleted": .int(0)])
    }

    func addLabel(id: String, name: String) throws {
        try insert("djmdLabel", ["ID": .text(id), "Name": .text(name), "rb_local_deleted": .int(0)])
    }

    func addKey(id: String, scaleName: String) throws {
        try insert("djmdKey", ["ID": .text(id), "ScaleName": .text(scaleName), "Seq": .int(1), "rb_local_deleted": .int(0)])
    }

    /// djmdContent 칸 몇 개를 한 번에 바꾼다(칸 이름 → 값)
    func setContent(track: TrackSpec, _ values: [String: CipherDatabase.Value]) throws {
        let keys = values.keys.sorted()
        try execute("UPDATE djmdContent SET \(keys.map { "\($0) = ?" }.joined(separator: ", ")) WHERE ID = ?",
                    keys.map { values[$0]! } + [.text(track.id)])
    }
}
