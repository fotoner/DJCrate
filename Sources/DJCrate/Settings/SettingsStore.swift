import DJCApplication
import DJCDomain
import Foundation

/// 앱 설정 저장소(UserDefaults). 이름·기본값·범위는 `SettingKeys`(DJCDomain)를 따른다.
/// 개발용 자가 테스트(음량을 −70dB로 바꾼다)는 설정을 읽지도 저장하지도 않고 기본값으로 돈다.
/// 화면 상태(파형 높이·사이드바 접기)는 뷰의 `@AppStorage`가 같은 이름으로 직접 읽는다.
/// CLI도 따라야 하는 값(`SharedSettingsWriter.names`)은 데이터 폴더의 공유 파일에도 적는다(CLI는 앱의 UserDefaults를 읽지 못한다).
final class SettingsStore: @unchecked Sendable {
    let defaults: UserDefaults
    let persist: Bool
    /// CLI와 함께 읽는 설정 파일(nil이면 적지 않는다). 실제 파일은 조립 지점이 붙인다
    let sharedFile: SharedSettingsWriter?

    init(defaults: UserDefaults = .standard,
         persist: Bool = !ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-selftest") || $0 == "--autoplay" || $0 == "--scroll-perf" || $0.hasPrefix("--ui-perf=") },
         sharedFile: SharedSettingsWriter? = nil) {
        self.defaults = defaults
        self.persist = persist
        self.sharedFile = sharedFile
    }

    func value<Value>(_ key: SettingKey<Value>) -> Value {
        guard persist else { return key.defaultValue }
        return key.value(from: defaults.object(forKey: key.name))
    }

    func set<Value>(_ key: SettingKey<Value>, _ value: Value) {
        guard persist else { return }
        defaults.set(value, forKey: key.name)
        if let sharedFile, sharedFile.names.contains(key.name) {
            do { try sharedFile.set([key.name: value]) } catch { AppErrorMessage.log(error) }
        }
    }

    /// 앱을 켤 때 지금 값을 공유 파일에 맞춘다(공유 파일이 생기기 전에 바꾼 값·파일을 지운 경우).
    func syncShared() {
        guard persist, let sharedFile else { return }
        let days = SettingKeys.pointSnapshotAutoDays
        do { try sharedFile.set([days.name: value(days)]) } catch { AppErrorMessage.log(error) }
    }

    /// 저장된 Q가 우선이다. Q를 저장한 적 없는 구버전은 등록 퀀타이즈 설정을 이어받는다.
    var quantize: Bool {
        guard persist else { return SettingKeys.playQuantize.defaultValue }
        let key = defaults.object(forKey: SettingKeys.playQuantize.name) != nil
            ? SettingKeys.playQuantize : SettingKeys.quantize
        return value(key)
    }

    var commentPreset: CommentPreset {
        get { CommentPreset(rawValue: value(SettingKeys.commentPreset)) ?? .none }
        set { set(SettingKeys.commentPreset, newValue.rawValue) }
    }

    /// 덱 단축키. 기본과 다른 동작만 저장하고, 모두 기본이면 지운다.
    var shortcuts: DeckShortcuts {
        get {
            guard persist else { return .standard }
            return DeckShortcuts(overrides: defaults.dictionary(forKey: SettingKeys.deckShortcuts))
        }
        set {
            guard persist else { return }
            let overrides = newValue.overrides
            if overrides.isEmpty {
                defaults.removeObject(forKey: SettingKeys.deckShortcuts)
            } else {
                defaults.set(overrides, forKey: SettingKeys.deckShortcuts)
            }
        }
    }

    /// 곡 UUID 모음(무시한 제안 등). 자가 테스트 중에도 읽기·쓰기는 한다(화면 상태라서).
    func strings(_ name: String) -> Set<String> { Set(defaults.stringArray(forKey: name) ?? []) }

    func setStrings(_ name: String, _ value: Set<String>) { defaults.set(Array(value), forKey: name) }
}
