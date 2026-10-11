import DJCDomain
import Foundation
import Synchronization

/// 앱의 문구 카탈로그(이 타깃 번들). 핵심부 `UIStrings`는 번들을 모르고, 앱이 정한 찾기 함수와 언어만 쓴다.
extension UIStrings {
    private static let appBundle = Mutex<Bundle>(.main)

    /// 같은 한국어를 뜻에 따라 달리 번역하려고 키를 따로 준 문구(`String(localized:defaultValue:bundle:)`)가 찾을 번들(docs/i18n.md).
    /// 앱이 카탈로그를 정하기 전(테스트)에는 실행 파일 번들이라 원문이 나온다
    static var bundle: Bundle { appBundle.withLock { $0 } }

    /// 이 타깃의 리소스 번들(문구 카탈로그)
    static var appResources: Bundle { .module }

    /// 앱이 시작할 때 가장 먼저 부른다: 이 타깃의 카탈로그와 시스템 언어로 정한다
    static func useAppCatalog() {
        let bundle = appResources
        appBundle.withLock { $0 = bundle }
        locale = .current
        catalog = .bundle(bundle)
    }
}

extension UIStrings.Catalog {
    /// 그 번들의 String Catalog에서 찾는다
    static func bundle(_ bundle: Bundle) -> Self {
        Self(string: { String(localized: $0, bundle: bundle, locale: $1) },
             resource: { LocalizedStringResource($0, locale: $1, bundle: bundle) })
    }
}
