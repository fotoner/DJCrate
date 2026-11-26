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
    // cfprefsd가 이전 값을 돌려줘도 이 인스턴스에서 방금 쓴 값은 즉시 읽는다.
    // 읽기만 한 값은 담지 않아 뷰가 UserDefaults에 직접 바꾼 설정도 계속 읽는다.
    private let lock = NSRecursiveLock()
    private var writtenValues: [String: Any] = [:]
    /// CLI와 함께 읽는 설정 파일(nil이면 적지 않는다). 실제 파일은 조립 지점이 붙인다
    let sharedFile: SharedSettingsWriter?

    init(defaults: UserDefaults = .standard,
         persist: Bool = SettingsStore.persists(arguments: ProcessInfo.processInfo.arguments),
         sharedFile: SharedSettingsWriter? = nil) {
        self.defaults = defaults
        self.persist = persist
        self.sharedFile = sharedFile
    }

    /// 이 실행 인자로 띄운 앱이 설정을 읽고 저장하는지. 자가 테스트·측정·일부 캡처는 기본값으로 돈다(두 빌드 모두).
    /// 값이 붙는 사본 자가 테스트도 설정을 읽거나 저장하지 않는다.
    static func persists(arguments: [String]) -> Bool {
        !DiagnosticRun.isolatesPreferences(arguments: arguments) && !arguments.contains {
            $0.hasSuffix("-selftest") || $0.hasPrefix("--sidebar-multi-") || $0.hasPrefix("--usb-snapshot-capture=") || $0 == "--autoplay"
                || $0 == "--scroll-perf" || $0.hasPrefix("--ui-perf=")
        }
    }

    func value<Value>(_ key: SettingKey<Value>) -> Value {
        guard persist else { return key.defaultValue }
        return key.value(from: storedValue(key.name))
    }

    func set<Value>(_ key: SettingKey<Value>, _ value: Value) {
        guard persist else { return }
        lock.withLock {
            writtenValues[key.name] = value
            defaults.set(value, forKey: key.name)
        }
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
        let key = storedValue(SettingKeys.playQuantize.name) != nil
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
            return DeckShortcuts(overrides: storedValue(SettingKeys.deckShortcuts) as? [String: Any])
        }
        set {
            guard persist else { return }
            let overrides = newValue.overrides
            lock.withLock {
                writtenValues[SettingKeys.deckShortcuts] = overrides
                if overrides.isEmpty {
                    defaults.removeObject(forKey: SettingKeys.deckShortcuts)
                } else {
                    defaults.set(overrides, forKey: SettingKeys.deckShortcuts)
                }
            }
        }
    }

    /// 곡 UUID 모음(무시한 제안 등). 설정을 저장하지 않는 실행에서는 이 인스턴스에 쓴 값만 읽는다.
    func strings(_ name: String) -> Set<String> { Set(storedValue(name) as? [String] ?? []) }

    func setStrings(_ name: String, _ value: Set<String>) {
        lock.withLock {
            let strings = Array(value)
            writtenValues[name] = strings
            if persist { defaults.set(strings, forKey: name) }
        }
    }

    private func storedValue(_ name: String) -> Any? {
        lock.withLock { writtenValues[name] ?? (persist ? defaults.object(forKey: name) : nil) }
    }
}
