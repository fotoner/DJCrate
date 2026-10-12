import DJCDomain
import Foundation

enum CLILocalization {
    static func language(override: String?, preferredLanguages: [String]) -> String {
        let override = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = override.flatMap { $0.isEmpty ? nil : [$0] } ?? preferredLanguages
        for candidate in candidates {
            let language = candidate.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let language, ["ko", "en", "ja"].contains(language) { return language }
        }
        return "en"
    }

    /// 문구 카탈로그와 언어를 정한다(핵심부 `UIStrings`는 번들·시스템 언어를 고르지 않는다).
    /// 실험 명령(`djc lab`)은 카탈로그 없이 원문으로, 수 형식만 시스템 언어로 둔다.
    static func configure(lab: Bool) {
        guard !lab else {
            UIStrings.locale = .current
            return
        }
        let language = language(override: ProcessInfo.processInfo.environment["DJC_LANG"], preferredLanguages: Locale.preferredLanguages)
        UIStrings.locale = Locale(identifier: language)
        // 번들이 빠져도 원문으로 실행한다.
        let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() ?? Bundle.main.bundleURL
        guard let bundle = resourceBundles(executableDirectory: directory).lazy.compactMap({ Bundle(url: $0) }).first,
              let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else { return }
        UIStrings.catalog = UIStrings.Catalog(string: { String(localized: $0, bundle: localized, locale: $1) },
                                              resource: { LocalizedStringResource($0, locale: $1, bundle: localized) })
    }

    /// 리소스 번들 자리: 실행 파일 옆(빌드 폴더, PATH에 함께 옮긴 경우), 그다음 앱 번들 안
    /// (`Contents/Helpers/djc` → `Contents/Resources`, #262). 링크로 불러도 실제 자리 기준이다
    static func resourceBundles(executableDirectory: URL) -> [URL] {
        [executableDirectory.appending(path: "DJCrate_djc.bundle"),
         executableDirectory.deletingLastPathComponent().appending(path: "Resources/DJCrate_djc.bundle")]
    }
}
