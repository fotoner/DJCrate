import DJCDomain
import Foundation

/// 앱과 `djc`가 함께 읽는 설정 파일(피동 포트, 데이터 폴더의 `shared-settings.json`). 앱 설정(UserDefaults)은 다른 프로세스인 CLI가
/// 읽지 못하므로 둘 다 따라야 하는 값(시점 스냅샷 보관 일수)만 앱이 이 파일에도 적는다. 실제 구현은 DJCAdapters(`SharedSettingsWriter.live(file:)`).
public struct SharedSettingsWriter: Sendable {
    /// 이 파일에도 적는 설정 이름
    public var names: Set<String>
    /// 값을 적는다(나머지 값은 그대로, 이 파일에 적지 않는 이름은 버린다)
    public var set: @Sendable (_ values: [String: Any]) throws -> Void

    public init(names: Set<String>, set: @escaping @Sendable (_ values: [String: Any]) throws -> Void) {
        self.names = names
        self.set = set
    }
}
