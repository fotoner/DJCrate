import DJCDomain
import Foundation

/// 라이브 쓰기 전 확인(읽기 전용, `djc compat`): 설치된 rekordbox 버전이 쓰기를 확인한 버전인지, 라이브러리 사본의 DB 구조가 확인한 모양인지,
/// 변경 카운터가 쓸 수 있는 상태인지 차례로 본다. 확인한 것은 하나씩 알리고(`report`), 막히면 그 자리에서 던진다(알린 줄은 남는다).
/// 판정은 쓰기 관문과 같은 함수(RekordboxKit `RekordboxCompatibility`)가 하고, 실제 구현은 DJCAdapters `CompatibilityPorts.live`가 붙인다.
public struct CompatibilityCheck: Sendable {
    /// 확인한 것(명령이 문구로 바꿔 보인다)
    public enum Finding: Equatable, Sendable {
        /// 설치된 rekordbox(찾지 못하면 nil)와 쓰기를 확인한 버전(앞 두 자리, 차례대로)
        case app(installed: String?, verified: [String])
        /// DB 구조가 확인한 모양과 같다(확인한 DBVersion, 읽은 사본 파일 이름)
        case schema(databaseVersion: String, file: String)
        /// 변경 카운터(로컬·클라우드 동기화, 없으면 nil)
        case counters(local: Int?, cloud: Int?)
    }

    /// 확인하는 단계(차례대로). 앱이 막힌 단계로 이유를 고른다
    public enum Stage: Equatable, Sendable {
        /// 설치된 rekordbox 버전
        case app
        /// 사본 열기
        case snapshot
        /// DB 구조·DB 버전
        case schema
        /// 변경 카운터 읽기·판정
        case counters
    }

    /// 확인 결과 한 값(앱의 라이브러리 읽기, #327). `run`과 같은 차례·같은 판정 함수로 보고, 막힌 단계만 남긴다
    public enum Verdict: Equatable, Sendable {
        /// 모두 통과했다
        case passed
        /// 이 단계에서 막혔다(`djc compat`가 그 자리에서 던지는 것과 같다). 설치된 rekordbox 버전을 함께 든다(찾지 못하면 nil)
        case blocked(Stage, installed: String?)
    }

    public var ports: CompatibilityPorts

    public init(ports: CompatibilityPorts) {
        self.ports = ports
    }

    /// - Parameter database: 명시한 사본(`--db`). nil이면 마지막 스냅샷(라이브 DB는 열지 않는다)
    public func run(database: URL?, report: (Finding) -> Void) throws {
        try check(database: database, report: report, entering: { _ in })
    }

    /// `run`과 같은 확인을 던지지 않고 한 값으로 돌려준다(앱이 읽은 사본으로 쓸 수 있는지 미리 본다, 메인 밖에서 부른다)
    /// - Parameter database: 읽은 사본. nil이면 마지막 스냅샷(라이브 DB는 열지 않는다)
    public func verdict(database: URL?) -> Verdict {
        var stage = Stage.app, installed: String?
        do {
            try check(database: database, report: { finding in
                if case let .app(version, _) = finding { installed = version }
            }, entering: { stage = $0 })
            return .passed
        } catch {
            return .blocked(stage, installed: installed)
        }
    }

    /// 확인 차례 하나(`run`·`verdict`가 함께 쓴다). 단계에 들어갈 때마다 `entering`을 부른다
    private func check(database: URL?, report: (Finding) -> Void, entering: (Stage) -> Void) throws {
        entering(.app)
        let installed = ports.installedAppVersion()
        report(.app(installed: installed, verified: ports.verifiedAppVersions))
        try ports.checkApp(installed)
        entering(.snapshot)
        let snapshot = try ports.openSnapshot(database)
        defer { snapshot.close() }
        entering(.schema)
        try snapshot.checkSchema()
        report(.schema(databaseVersion: ports.databaseVersion, file: snapshot.fileName))
        entering(.counters)
        let counters = try snapshot.updateCounters()
        report(.counters(local: counters.local, cloud: counters.cloud))
        if let local = counters.local { try ports.checkCounters(local, counters.cloud) }
    }
}

/// 쓰기 전 확인의 피동 포트(설치된 앱·라이브러리 사본을 읽기만 한다)
public struct CompatibilityPorts: Sendable {
    public var installedAppVersion: @Sendable () -> String?
    /// 쓰기를 확인한 버전(앞 두 자리, 차례대로)
    public var verifiedAppVersions: [String]
    /// 설치된 버전이 확인한 버전이 아니면 던진다
    public var checkApp: @Sendable (_ installed: String?) throws -> Void
    /// 확인한 DB 구조의 DBVersion
    public var databaseVersion: String
    /// 사본을 연다(명시한 사본 또는 마지막 스냅샷, 라이브 DB는 거부)
    public var openSnapshot: @Sendable (_ database: URL?) throws -> CompatibilitySnapshot
    /// 변경 카운터가 쓸 수 있는 상태가 아니면 던진다
    public var checkCounters: @Sendable (_ local: Int, _ cloud: Int?) throws -> Void

    public init(installedAppVersion: @escaping @Sendable () -> String?, verifiedAppVersions: [String],
                checkApp: @escaping @Sendable (String?) throws -> Void, databaseVersion: String,
                openSnapshot: @escaping @Sendable (URL?) throws -> CompatibilitySnapshot,
                checkCounters: @escaping @Sendable (Int, Int?) throws -> Void) {
        self.installedAppVersion = installedAppVersion
        self.verifiedAppVersions = verifiedAppVersions
        self.checkApp = checkApp
        self.databaseVersion = databaseVersion
        self.openSnapshot = openSnapshot
        self.checkCounters = checkCounters
    }
}

/// 연 라이브러리 사본(읽기 전용). 다 보면 닫는다
public struct CompatibilitySnapshot {
    public var fileName: String
    /// 구조가 확인한 모양이 아니면 던진다
    public var checkSchema: () throws -> Void
    public var updateCounters: () throws -> (local: Int?, cloud: Int?)
    public var close: () -> Void

    public init(fileName: String, checkSchema: @escaping () throws -> Void, updateCounters: @escaping () throws -> (local: Int?, cloud: Int?),
                close: @escaping () -> Void) {
        self.fileName = fileName
        self.checkSchema = checkSchema
        self.updateCounters = updateCounters
        self.close = close
    }
}
