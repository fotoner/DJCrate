import DJCDomain
import Foundation
import Observation

/// 화면 상태 설정 하나를 뷰가 지켜본다. 값이 실제로 바뀔 때만 알린다.
/// `@AppStorage`는 이름에 점이 든 설정(`sidebar.visible`·`view.textScale`)을 KVO로 지켜보지 못해, 어느 설정이 바뀌든
/// (창 크기를 바꾸는 동안 창 프레임 자동 저장 등) 그 뷰를 다시 계산했다. 주 창 본문이 창 크기 한 단계마다
/// 툴바·사이드바 목록·메뉴까지 다시 계산했다(#138).
@MainActor
@Observable
final class ObservedSetting<Value: Sendable & Equatable> {
    @ObservationIgnored let key: SettingKey<Value>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    private var current: Value

    init(_ key: SettingKey<Value>, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        current = key.value(from: defaults.object(forKey: key.name))
        // 자가 측정·설정 창처럼 UserDefaults에 바로 쓰는 곳도 따라간다.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.reload() }
            } else {
                Task { @MainActor in self?.reload() }
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var value: Value {
        get { current }
        set {
            guard newValue != current else { return }
            current = newValue
            defaults.set(newValue, forKey: key.name)
        }
    }

    private func reload() {
        let stored = key.value(from: defaults.object(forKey: key.name))
        if stored != current { current = stored }
    }
}

/// 여러 창과 메뉴가 함께 지켜보는 화면 설정
@MainActor
enum SharedSettings {
    /// 앱 안 글자 배율(보기 › 글자 크게·작게)
    static let textScale = ObservedSetting(SettingKeys.textScale)
}
