import Foundation

/// 설치된 rekordbox가 DJCrate가 쓰기를 확인한 버전이 아닐 때의 안내(#299). 라이브러리는 읽히므로 실패 화면이 아니라 목록 위 알림으로 알린다.
/// 판정은 `djc compat`와 같다(`RekordboxCompatibility.checkApp`). 여기는 문구만 정한다.
public enum UnsupportedRekordboxNotice {
    /// 버전은 앞 두 자리(주.부)만 보인다. 7.3.1이면 7.3
    public static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    public static func title(version: String) -> String {
        String(ui: "이 rekordbox 버전(\(majorMinor(version)))은 아직 지원하지 않습니다")
    }

    public static var guidance: String { String(ui: "읽기만 하고 rekordbox에 쓰기는 막혀 있습니다") }
}
