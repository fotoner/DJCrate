import AppKit
import DJCApplication
import DJCDomain
import Observation
import Sparkle

/// 앱 자동 업데이트(#59): Sparkle 표준 창으로 GitHub Releases의 정보 파일(appcast)을 보고, EdDSA 서명을 확인한 업데이트만 설치한다.
/// Sparkle을 import하는 유일한 파일이다(scripts/check-imports.py `EXTERNAL_FILES`). 미룰지 판정은 `UpdateDeferral`이 한다.
/// 정보 파일 주소·공개 키·기본값(하루 한 번 확인, 자동 설치 끔)은 앱 번들 Info.plist에 있다(scripts/build-app.sh).
@MainActor
final class AppUpdater: NSObject, UpdaterControl {
    private let deferral: UpdateDeferral
    private let activity: @MainActor () -> AppWriteActivity
    private let announce: @MainActor (String) -> Void
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var watchingActivity = false
    /// 업데이트를 설치하고 다시 켜려고 앱을 끄는 중이다(#326). 켜진 채 종료 시트가 이 종료를 사용자가 고른 종료로 보고 막지 않게 한다
    private var relaunchMark = false
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - activity: 지금 앱이 쓰는 중인 것. 관찰할 수 있는 값에서 읽어야 쓰기가 끝난 것을 안다
    ///   - announce: 설치를 미룰 때 사용자에게 알린다
    private init(activity: @escaping @MainActor () -> AppWriteActivity, announce: @escaping @MainActor (String) -> Void) {
        self.activity = activity
        self.announce = announce
        deferral = UpdateDeferral(activity: activity)
    }

    /// 배포 앱 번들(정보 파일 주소·공개 키가 있음)에서만 만든다. 개발 빌드·시험은 nil이다.
    static func make(bundle: Bundle = .main, activity: @escaping @MainActor () -> AppWriteActivity,
                     announce: @escaping @MainActor (String) -> Void) -> AppUpdater? {
        guard UpdateFeedConfig.isConfigured(bundle.infoDictionary ?? [:]) else { return nil }
        return AppUpdater(activity: activity, announce: announce)
    }

    /// 업데이트 도구를 켠다. 첫 실행에도 묻는 창 없이 하루 한 번 확인한다(Info.plist `SUEnableAutomaticChecks`).
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        let changed: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.onChange?() } }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in changed() },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in changed() },
        ]
        controller.startUpdater()
        onChange?()
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// 업데이트 다시 켜기로 앱을 끄는 중인지 읽고 표시를 지운다. 종료 요청마다 한 번 읽는다(다시 켜기가 취소돼도 표시가 남지 않게)
    func consumeRelaunchMark() -> Bool {
        defer { relaunchMark = false }
        return relaunchMark
    }

    /// 미룬 동안만 쓰기 상태를 지켜본다. 쓰기가 모두 끝나면 맡아 둔 설치를 이어 간다.
    private func watchActivity() {
        guard !watchingActivity else { return }
        watchingActivity = true
        withObservationTracking { _ = activity() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingActivity = false
                self.deferral.activityChanged()
                if self.deferral.isHolding { self.watchActivity() }
            }
        }
    }
}

extension AppUpdater: @preconcurrency SPUUpdaterDelegate {
    /// 받은 업데이트를 설치하고 다시 켜기 직전. rekordbox·USB에 쓰는 중이면 미뤘다가 쓰기가 끝나면 이어 간다.
    /// 자동으로 받은 업데이트는 앱을 끌 때 설치한다. 받아 둔 업데이트는 이 위임 없이 바로 다시 켜기도 한다(SPUUpdaterDelegate.h).
    /// 두 경로 모두 앱 끄기를 지나고, 쓰는 중에는 `AppDelegate`가 끄기를 막는다.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let decision = deferral.postpone { [weak self] in
            self?.relaunchMark = true
            installHandler()
        }
        guard let message = decision.waitMessage else {
            relaunchMark = true
            return false
        }
        announce(message)
        watchActivity()
        return true
    }

    /// 다시 켜기 직전(SPUUpdaterDelegate.h: "Called immediately before relaunching"). 위 미루기 위임을 지나지 않는 다시 켜기도 표시한다.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        relaunchMark = true
    }
}
