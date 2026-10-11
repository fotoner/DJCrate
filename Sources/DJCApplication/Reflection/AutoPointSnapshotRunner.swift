import DJCDomain
import Foundation

/// 하루 한 번 자동 시점 스냅샷(#228)을 앱이 돌아가는 동안 뒤에서 남긴다. 확인 창·알림 없이 조용히 하고,
/// 미룬 이유(rekordbox 켜짐·오늘 이미 있음·바뀐 것 없음 등)는 남기지 않는다. 실패는 로그로 남기고, 다시 해 볼 일이 아닌 실패만
/// 앱을 켠 동안 한 번 작은 알림으로 알린다. 뜨기는 메인 액터 밖에서 한다. 앱은 저장소의 대상·설정으로 환경을 붙인다(`init(store:files:)`).
@MainActor
public final class AutoPointSnapshotRunner {
    public struct Environment {
        public var database: () -> URL
        public var shareRoot: () -> URL?
        public var snapshots: URL
        public var enabled: () -> Bool
        public var autoDays: () -> Int
        /// rekordbox에 쓰는 중이면 미룬다(쓰기를 막지 않는다)
        public var busy: () -> Bool
        /// rekordbox 쓰기를 시작한 횟수. 뜨는 동안 늘면 분석 파일과 DB가 다른 시점일 수 있어 그 스냅샷을 버린다
        public var writeCount: () -> Int
        /// 시점 스냅샷 파일(뜨기·버리기·클론 가능·rekordbox 실행). 시험은 사본만 보는 가드의 실제 구현을 준다
        public var files: PointSnapshotFiles
        public var now: () -> Date
        public var calendar: Calendar

        public init(database: @escaping () -> URL, shareRoot: @escaping () -> URL?, snapshots: URL, enabled: @escaping () -> Bool,
                    autoDays: @escaping () -> Int, busy: @escaping () -> Bool, writeCount: @escaping () -> Int = { 0 }, files: PointSnapshotFiles,
                    now: @escaping () -> Date, calendar: Calendar) {
            self.database = database
            self.shareRoot = shareRoot
            self.snapshots = snapshots
            self.enabled = enabled
            self.autoDays = autoDays
            self.busy = busy
            self.writeCount = writeCount
            self.files = files
            self.now = now
            self.calendar = calendar
        }
    }

    /// 처음 볼 때까지(앱이 막 켜져 라이브러리를 읽는 동안은 비켜 준다)
    public static let firstDelay: Duration = .seconds(90)
    /// 다시 볼 간격(rekordbox를 끈 뒤 오래 기다리지 않게 짧게, 보는 일은 폴더 목록·파일 정보뿐이다)
    public static let interval: Duration = .seconds(600)

    public let environment: Environment
    /// 실패 알림(앱은 토스트): 제목과 이유
    public var onFailure: (_ title: String, _ text: String) -> Void
    /// 실패의 사용자 문구(앱은 `AppErrorMessage`)
    public var errorText: (any Error) -> String
    /// 알리지 않는 기록 한 줄(앱은 표준 오류)
    public var log: (String) -> Void
    public private(set) var isRunning = false
    private var warned = false

    public init(environment: Environment, errorText: @escaping (any Error) -> String = { "\($0)" }, log: @escaping (String) -> Void = { _ in },
                onFailure: @escaping (String, String) -> Void = { _, _ in }) {
        self.environment = environment
        self.errorText = errorText
        self.log = log
        self.onFailure = onFailure
    }

    /// 이 실행에서 자동 스냅샷을 볼지. 명시한 사본(`--db`·`DJC_DB`)으로 연 창은 사용자의 라이브러리를 고른 실행이 아니라서
    /// 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)가 있어도 보지 않고, 자가 테스트·측정·캡처 실행(`DiagnosticRun`)은
    /// 90초 뒤 디스크 일이 끼지 않게 보지 않는다.
    public static func isAllowed(location: LibraryLocation, diagnosticRun: Bool) -> Bool {
        !location.opensExplicitCopy && !diagnosticRun
    }

    /// 앱이 켜져 있는 동안 되풀이한다(취소되면 끝).
    public func loop() async {
        do { try await Task.sleep(for: Self.firstDelay) } catch { return }
        while !Task.isCancelled {
            await runIfDue()
            do { try await Task.sleep(for: Self.interval) } catch { return }
        }
    }

    /// 때가 됐으면 한 번 뜬다. 끄거나 쓰는 중이면 nil.
    @discardableResult
    public func runIfDue() async -> RekordboxPointSnapshotAutoOutcome? {
        guard !isRunning, environment.enabled(), !environment.busy() else { return nil }
        isRunning = true
        defer { isRunning = false }
        let env = environment, database = env.database(), share = env.shareRoot(), days = env.autoDays(), now = env.now()
        let snapshots = env.snapshots, calendar = env.calendar, files = env.files
        let writesBefore = env.writeCount()
        let result = await BlockingWork.run(qos: .utility) {
            Result { try files.takeAutoIfDue(database, share, snapshots, days, now, calendar, files.canClone) }
        }
        switch result {
        case let .success(outcome):
            // 뜨는 동안 DJCrate가 rekordbox에 쓰기 시작했으면 DB와 분석 파일이 어긋났을 수 있다(다음에 다시 뜬다)
            if case let .took(entry) = outcome, env.busy() || env.writeCount() != writesBefore {
                try? files.discard(entry.url)
                log("[자동 시점 스냅샷] 뜨는 동안 rekordbox 쓰기가 끼어들어 버렸습니다")
                return nil
            }
            return outcome
        case let .failure(error):
            log("[자동 시점 스냅샷] \(error)")
            // 뜨는 도중 rekordbox가 켜지거나 쓰기가 끼어든 것은 다음에 다시 본다(알리지 않는다)
            if files.isRekordboxRunning() || env.busy() || warned { return nil }
            warned = true
            onFailure(String(ui: "자동 시점 스냅샷을 남기지 못했습니다"), errorText(error))
            return nil
        }
    }
}
