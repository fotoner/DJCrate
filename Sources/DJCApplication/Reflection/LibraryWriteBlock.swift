import DJCDomain
import Foundation

/// 라이브러리를 읽은 뒤 미리 아는 rekordbox 쓰기 막힘(#327). 편집해도 쓸 수 없는 상태를 편집하기 전에 상태 줄이 알린다.
/// 판정은 `djc compat`와 같은 `CompatibilityCheck`(설치된 앱 버전 → 사본 DB 구조 → 변경 카운터)와 쓰기 확인 창과 같은
/// 백업 폴더 확인(`RekordboxBackups.canWrite`)이 한다. 여기는 이유 하나를 고르는 차례와 문구만 정한다.
/// 표시만 바꾼다: 쓸지 말지는 이 값을 보지 않고 쓰기 관문(`RekordboxWriteGuard`·`RekordboxCompatibility`)과 반영 세션이 정한다.
public enum LibraryWriteBlock: Equatable, Sendable {
    /// 설치된 rekordbox가 쓰기를 확인한 버전이 아니다(설치된 버전)
    case unsupportedVersion(String)
    /// DB 구조·DB 버전이 확인한 모양이 아니다
    case schema
    /// 로컬 변경 카운터가 클라우드 동기화 카운터보다 작다
    case counters
    /// 쓰기 전 백업 폴더에 쓸 수 없다
    case backupFolder

    /// 이유를 하나 고른다. 여럿이면 실제 쓰기가 막히는 차례(버전 → DB 구조·카운터 → 백업 폴더)에서 앞의 것이다.
    /// 사본을 열지 못했으면 구조를 모르므로 이유로 삼지 않는다(쓸 때 관문이 막는다).
    public static func first(_ verdict: CompatibilityCheck.Verdict, canBackUp: Bool) -> Self? {
        switch verdict {
        case let .blocked(.app, installed): return .unsupportedVersion(installed ?? "?")
        case .blocked(.schema, _): return .schema
        case .blocked(.counters, _): return .counters
        case .blocked(.snapshot, _), .passed: return canBackUp ? nil : .backupFolder
        }
    }

    /// 원인과 할 일 한 문장(STR-16). 상태 줄 칩의 툴팁과 상태 팝오버 맨 위에 보인다
    public var reason: String {
        switch self {
        case let .unsupportedVersion(version):
            String(ui: "이 rekordbox 버전(\(UnsupportedRekordboxNotice.majorMinor(version)))은 아직 지원하지 않으니 DJCrate 업데이트를 확인하세요")
        case .schema:
            String(ui: "rekordbox DB 구조가 DJCrate가 확인한 모양과 다르니 DJCrate 업데이트를 확인하세요")
        case .counters:
            String(ui: "rekordbox 변경 카운터가 클라우드 동기화 카운터보다 작으니 rekordbox를 켜서 동기화를 끝낸 뒤 종료하세요")
        case .backupFolder:
            // 쓰기 확인 창 문장(「쓰기가 막힐 수 있으니」)은 칩의 「쓸 수 없음」과 어긋나 칩은 단정한다
            String(ui: "쓰기 전 백업을 만들 폴더에 쓸 수 없으니 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요")
        }
    }
}
