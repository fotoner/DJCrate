import Foundation
import Synchronization

/// 사용자에게 보이는 문구를 찾는 카탈로그와 언어. 번들·시스템 언어를 고르는 일은 핵심부 밖에서 한다:
/// 앱(`UIStrings.useAppCatalog`)·CLI(`CLILocalization`)가 시작할 때 자기 String Catalog(`Sources/DJCrate/Resources/Localizable.xcstrings`)와
/// 언어로 정하고, 하위 모듈의 문구(막힘 이유 등)도 이 카탈로그로 찾는다. 테스트는 정하지 않아 원문(한국어)이 그대로 나오고
/// 수 형식도 원문 언어를 따른다(시스템 언어와 관계없이 같다). 하위 모듈이 자기 번들을 두지 않는 까닭은
/// 번들이 없는 곳(PATH에 복사한 djc 등)에서 `Bundle.module`이 멈추기 때문이다.
public enum UIStrings {
    /// 카탈로그에서 문구를 찾는 함수(앱·CLI가 자기 번들로 만든다)
    public struct Catalog: Sendable {
        public var string: @Sendable (String.LocalizationValue, Locale) -> String
        /// SwiftUI 제목 인자에 넣는 문구
        public var resource: @Sendable (String.LocalizationValue, Locale) -> LocalizedStringResource

        public init(string: @escaping @Sendable (String.LocalizationValue, Locale) -> String,
                    resource: @escaping @Sendable (String.LocalizationValue, Locale) -> LocalizedStringResource) {
            self.string = string
            self.resource = resource
        }
    }

    /// 원문 언어. 언어를 정하지 않은 실행(테스트)의 수 형식·복수형
    public static let sourceLocale = Locale(identifier: "ko")
    private static let catalogStorage = Mutex<Catalog?>(nil)
    private static let localeStorage = Mutex<Locale>(sourceLocale)

    /// nil이면 카탈로그 없이 원문
    public static var catalog: Catalog? {
        get { catalogStorage.withLock { $0 } }
        set { catalogStorage.withLock { $0 = newValue } }
    }

    /// 문구의 복수형·수 형식 언어. 앱은 시스템 언어, CLI는 고른 언어로 정한다.
    public static var locale: Locale {
        get { localeStorage.withLock { $0 } }
        set { localeStorage.withLock { $0 = newValue } }
    }
}

extension String {
    /// 카탈로그에서 찾은 문구. 원문(키)은 한국어이고, 번역이 없으면 원문이 그대로 나온다.
    /// 키는 컴파일러가 뽑아 `scripts/i18n.swift`가 카탈로그와 맞춘다(docs/i18n.md).
    public init(ui value: String.LocalizationValue) {
        let locale = UIStrings.locale
        if let catalog = UIStrings.catalog {
            self = catalog.string(value, locale)
        } else {
            // 카탈로그를 정하지 않았다: Foundation 기본(실행 파일 번들)에서 찾는다. 테스트 실행기·번들 없는 djc에는 카탈로그가 없어 원문이다
            self.init(localized: value, locale: locale)
        }
    }
}

extension LocalizedStringResource {
    /// SwiftUI 제목 인자(Text·Button·Label·Toggle·help·accessibilityLabel…)에 넣는 문구.
    public static func ui(_ value: String.LocalizationValue) -> LocalizedStringResource {
        let locale = UIStrings.locale
        return UIStrings.catalog?.resource(value, locale) ?? LocalizedStringResource(value, locale: locale)
    }
}
