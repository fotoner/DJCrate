import DJCDomain
import Foundation

/// 곡의 키 쓰기(#5): `djmdContent.KeyID`에 `djmdKey` 줄의 ID(글자)를 넣는다. `djmdKey`는 더하거나 고치지 않는다.
///
/// rekordbox 7.2.18은 키를 고를 때 화면 표기(이 사용자는 Camelot, "8A")와 같은 `ScaleName`의, 삭제 표시가 없는(`rb_local_deleted` 0) 줄에 곡을
/// 이었다(2026-10-04 묶음 2 S1·S3, #173 T13). 이 라이브러리에서는 그 둘이 같은 줄이라 무엇이 기준인지는 가르지 못했다. 그래서 두 조건을 모두 만족하는
/// 줄만 고른다: 받는 이름은 Camelot 24개뿐이고(`KeyNotation.camelotNames`, 살아 있는 옛 표기 줄 Em 같은 것도 고르지 않는다),
/// 그 이름의 살아 있는 줄이 정확히 하나일 때만 쓴다. 줄이 없거나 둘 이상이거나 삭제 표시 줄뿐인 조성은 rekordbox 동작을 보지 못해 막는다.
extension RekordboxWriter {
    /// 고른 키 이름에 이을 `djmdKey` 줄의 ID. 비우면(빈 이름) '0'(글자, 키 없음)이다(S4 지우기, #173 U10).
    /// - Parameter block: 막힐 때 던질 오류를 만든다(곡 이름은 부른 쪽이 안다)
    static func resolveKeyID(_ name: String, db: CipherDatabase, block: (String) -> Blocked) throws -> String {
        guard !name.isEmpty else { return "0" }
        guard KeyNotation.camelotNames.contains(name) else {
            throw block(String(ui: "키는 1A~12B 중에서 고르거나 비운 뒤 rekordbox에 쓰세요"))
        }
        var live: [String] = [], deleted = 0
        try db.query("SELECT ID, rb_local_deleted FROM djmdKey WHERE ScaleName = ?", [.text(name)]) { row in
            if row.int(1) == 0 { live.append(row.string(0) ?? "") } else { deleted += 1 }
        }
        guard live.count <= 1 else {
            throw block(String(ui: "rekordbox 키 목록에 살아 있는 '\(name)' 줄이 둘 이상이라 어느 것인지 알 수 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요"))
        }
        guard let id = live.first else {
            throw block(deleted > 0
                ? String(ui: "rekordbox 키 목록의 '\(name)' 줄이 모두 삭제 표시라 쓸 수 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요")
                : String(ui: "rekordbox 키 목록에 '\(name)' 줄이 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요"))
        }
        // '0'·빈 ID는 키 없음과 겹친다
        guard !id.isEmpty, id != "0" else {
            throw block(String(ui: "rekordbox 키 목록의 '\(name)' 줄 번호가 올바르지 않습니다. rekordbox에서 이 곡의 키를 직접 고르세요"))
        }
        return id
    }
}
