import DJCDomain
import Foundation

/// 앱과 `djc`가 함께 읽는 설정(데이터 폴더의 `shared-settings.json`). 앱 설정은 앱의 UserDefaults에 있어
/// 다른 프로세스인 CLI가 읽지 못한다. 그래서 둘 다 따라야 하는 값(시점 스냅샷 보관 일수)만 앱이 이 파일에도 적는다.
/// 데이터 폴더 아래라 `DJC_HOME`·시험 임시 폴더를 함께 따른다.
public enum SharedSettingsFile {
    /// 이 파일에도 적는 설정 이름
    public static let names: Set<String> = [SettingKeys.pointSnapshotAutoDays.name]

    public static var file: URL { DJCPaths.userData.appending(path: "shared-settings.json") }

    /// 파일의 값. 없거나 읽지 못하면 기본값(범위 밖이면 범위로 자른다)
    public static func value<Value>(_ key: SettingKey<Value>, in file: URL = file) -> Value {
        key.value(from: load(file)[key.name])
    }

    /// 한 값을 적는다(나머지 값은 그대로).
    public static func set(_ value: Any, for name: String, in file: URL = file) throws {
        try set([name: value], in: file)
    }

    /// 여러 값을 한 번에 적는다. 이 파일에 적지 않는 이름은 버린다.
    public static func set(_ values: [String: Any], in file: URL = file) throws {
        var stored = load(file)
        for (name, value) in values where names.contains(name) { stored[name] = value }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    static func load(_ file: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
