import DJCDomain
import Foundation
import Observation

/// 설정 › 업데이트와 앱 메뉴가 보는 업데이트 도구(#59). 앱은 Sparkle 연결(`AppUpdater`), 시험은 가짜를 쓴다.
/// 자동 확인·자동 설치·마지막 확인 시각은 Sparkle이 저장한다(앱 번들 ID 환경설정의 SU… 키). 그래서 `SettingKeys`에 두지 않는다.
@MainActor
protocol UpdaterControl: AnyObject {
    var automaticallyChecks: Bool { get set }
    var automaticallyDownloads: Bool { get set }
    var canCheck: Bool { get }
    var lastCheckDate: Date? { get }
    func checkForUpdates()
    /// 위 값이 바뀌면 부른다(확인이 끝남, 다른 창에서 바꿈)
    var onChange: (() -> Void)? { get set }
}

/// 앱 번들의 버전(Info.plist). 조립 지점이 읽어 넘긴다.
struct AppVersion: Equatable {
    var short: String
    var build: String

    static func of(_ bundle: Bundle) -> AppVersion {
        AppVersion(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                   build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
    }
}

/// 업데이트를 켤 수 있는 번들인지. 배포 앱만 Info.plist에 정보 파일 주소와 공개 키가 있다(scripts/build-app.sh).
/// 개발 빌드·시험 프로세스에서는 업데이트 도구를 만들지 않아 Sparkle이 환경설정에 쓰지 않는다.
enum UpdateFeedConfig {
    static func isConfigured(_ info: [String: Any]) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { (info[$0] as? String)?.isEmpty == false }
    }
}

/// 설정 › 업데이트(#59): 자동 확인·자동 설치 켜기, 지금 확인, 지금 버전·마지막 확인 시각.
/// 조립 지점이 하나 만들어 설정 창과 앱 메뉴가 함께 쓴다.
@MainActor @Observable
final class UpdateSettingsModel {
    let version: AppVersion
    private(set) var canCheck = false
    private(set) var lastCheckDate: Date?
    var automaticallyChecks = false {
        didSet { if !isReading { updater?.automaticallyChecks = automaticallyChecks } }
    }
    var automaticallyDownloads = false {
        didSet { if !isReading { updater?.automaticallyDownloads = automaticallyDownloads } }
    }
    @ObservationIgnored private let updater: (any UpdaterControl)?
    /// 도구의 값을 읽어 오는 중(도구에 다시 쓰지 않게)
    @ObservationIgnored private var isReading = false

    init(updater: (any UpdaterControl)?, version: AppVersion) {
        self.updater = updater
        self.version = version
        updater?.onChange = { [weak self] in self?.reload() }
        reload()
    }

    var isAvailable: Bool { updater != nil }
    var versionText: String { "\(version.short) (\(version.build))" }
    /// 자동 설치는 자동 확인이 켜져 있을 때만 의미가 있다
    var canChangeAutomaticDownloads: Bool { isAvailable && automaticallyChecks }
    var lastCheckText: String {
        lastCheckDate.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UIStrings.locale)) }
            ?? String(ui: "아직 확인하지 않음")
    }
    var unavailableReason: String? {
        isAvailable ? nil : String(ui: "개발 빌드에서는 업데이트를 확인하지 않습니다. 배포한 앱에서 확인하세요")
    }

    func checkNow() {
        guard let updater, updater.canCheck else { return }
        updater.checkForUpdates()
    }

    private func reload() {
        guard let updater else { return }
        isReading = true
        defer { isReading = false }
        canCheck = updater.canCheck
        lastCheckDate = updater.lastCheckDate
        automaticallyChecks = updater.automaticallyChecks
        automaticallyDownloads = updater.automaticallyDownloads
    }
}
