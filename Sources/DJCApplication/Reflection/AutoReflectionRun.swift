import DJCDomain
import Foundation

/// 자동 저장 사본 자가 테스트의 경우(`--auto-reflect-selftest=<경우>`, R18). 디버그 빌드에서 사본에만 자동 저장하는 유일한 예외다.
/// 인자가 있으면(빈 값·모르는 값 포함) 두 빌드 모두 진단 실행이다: 환경설정을 저장하지 않고, 옛 데이터 옮기기·LINK·자동 시점 스냅샷·
/// 창 위치 저장·포커스 가져오기를 하지 않는다.
public enum AutoReflectSelfTest: String, CaseIterable, Sendable {
    /// 저장 완료 상태를 기다린 뒤 사본 DB 값을 단정한다(R1·R21 소리)
    case save
    /// 두 프로세스 동시 쓰기(R9)
    case twoProcess = "two-process"
    /// 실제 강제 종료 뒤 탐지·복원(R11)
    case killDetect = "kill-detect"

    /// 인자 이름(값을 `=` 뒤에 붙인다, UI-14)
    public static let argumentName = "--auto-reflect-selftest"
    public static let argumentPrefix = argumentName + "="

    /// 실행 인자에 이 자가 테스트 인자가 있는지(값이 비었거나 모르는 값이어도). 첫 인자(실행 파일 경로)는 보지 않는다
    public static func isRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == argumentName || $0.hasPrefix(argumentPrefix) }
    }

    /// 요청한 경우. 인자가 없거나, 값이 비었거나 모르는 값이거나, 인자가 둘 이상이면 nil
    public static func requested(arguments: [String]) -> Self? {
        let values = arguments.dropFirst().filter { $0 == argumentName || $0.hasPrefix(argumentPrefix) }
        guard values.count == 1, let value = values.first, value.hasPrefix(argumentPrefix) else { return nil }
        return Self(rawValue: String(value.dropFirst(argumentPrefix.count)))
    }
}

/// 이 실행이 자동 저장하는지(R18). 릴리스 빌드에서만 라이브 라이브러리에 자동 저장하고, 사본 실행(`--db`·`DJC_DB`)과
/// 진단 실행(자가 테스트·측정·캡처)은 자동 저장하지 않는다(⌘S·저장 단추로만 쓴다, R3 6번 줄).
public enum AutoReflectionRun: Equatable, Sendable {
    /// 릴리스 빌드의 라이브 라이브러리
    case live
    /// 디버그 빌드의 사본 자가 테스트(`AutoReflectSelfTest`). 조건을 모두 확인한 뒤에만 이 값이다
    case selfTest(AutoReflectSelfTest)
    /// 자동 저장하지 않는다
    case off(Off)

    /// 자동 저장하지 않는 이유
    public enum Off: Hashable, Sendable {
        /// 디버그 빌드의 일반 실행
        case debugBuild
        /// 명시한 사본(`--db`·`DJC_DB`)
        case explicitCopy
        /// 자가 테스트·측정·캡처 실행(릴리스 빌드에 준 `--auto-reflect-selftest`도 여기다)
        case diagnostic
        /// 사본 자가 테스트의 값이 비었거나 모르는 값이거나, 쓰기 전 확인(`SelfTestPlaces`)을 채우지 못했다
        case unsafeSelfTest
    }

    /// 자가 테스트가 쓰기 전에 확인하는 자리. 모두 링크를 푼 경로다(겹침은 링크를 푼 경로로 본다). 읽는 일은 조립 지점이 한다
    public struct SelfTestPlaces: Equatable, Sendable {
        /// 쓰기 대상 rekordbox 폴더(사본)
        public var target: URL
        /// 쓰기 대상 master.db(파일 링크까지 푼 경로)
        public var database: URL
        /// 쓰기 대상 분석 루트(share, 링크를 푼 경로)
        public var analysisRoot: URL
        /// `DJC_HOME`
        public var home: URL
        /// 임시 폴더(대상과 `DJC_HOME`이 이 아래에 있어야 한다)
        public var temporaryRoot: URL
        /// 실제 rekordbox 폴더(대상과 겹치면 안 된다)
        public var liveRekordbox: URL
        /// DJCrate 사용자 폴더(`DJC_HOME`과 겹치면 안 된다)
        public var userData: URL
        /// 사본 안 `share`·`share/PIONEER`·`share/PIONEER/USBANLZ` 가운데 링크이거나 확인하지 못한(없는) 단계가 있는지(SAFE-8)
        public var analysisIsLink: Bool
        /// 모든 자리의 링크를 풀었다(풀지 못한 자리가 있으면 쓰지 않는다)
        public var resolved = true

        public init(target: URL, database: URL, analysisRoot: URL, home: URL, temporaryRoot: URL, liveRekordbox: URL, userData: URL,
                    analysisIsLink: Bool, resolved: Bool = true) {
            self.target = target
            self.database = database
            self.analysisRoot = analysisRoot
            self.resolved = resolved
            self.home = home
            self.temporaryRoot = temporaryRoot
            self.liveRekordbox = liveRekordbox
            self.userData = userData
            self.analysisIsLink = analysisIsLink
        }

        /// 자가 테스트가 써도 되는 자리인지: 대상과 `DJC_HOME`이 임시 폴더 아래, 대상이 실제 rekordbox 폴더와 겹치지 않음,
        /// 사본 안 분석 폴더가 링크가 아님(SAFE-8), `DJC_HOME`이 DJCrate 사용자 폴더와 겹치지 않음
        public var allowsWriting: Bool {
            // 대상 폴더·DB 파일·분석 루트·DJC_HOME을 하나씩(링크를 푼 경로로) 본다: 파일 링크·상위 폴더 링크가 실제 자리를 가리키면 거른다
            let places = [target, database, analysisRoot, home]
            return resolved && !analysisIsLink && places.allSatisfy { Self.isInside($0, temporaryRoot) }
                && !places.contains { Self.overlaps($0, liveRekordbox) } && !Self.overlaps(home, userData)
        }

        /// `child`가 `parent` 아래(같은 폴더는 아래가 아니다). 링크를 푼 경로의 조각으로 견준다(`/tmp/a`와 `/tmp/ab`를 섞지 않게).
        /// Foundation 정규화는 `/private`를 떼어 어긋나므로 쓰지 않는다(조립 지점이 realpath로 푼 경로를 준다)
        static func isInside(_ child: URL, _ parent: URL) -> Bool {
            let child = components(child), parent = components(parent)
            return child.count > parent.count && Array(child.prefix(parent.count)) == parent
        }

        /// 한쪽이 다른 쪽과 같거나 그 아래다(대소문자를 가리지 않는다: 기본 볼륨은 대소문자를 가리지 않는다)
        static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
            let left = components(lhs).map { $0.lowercased() }, right = components(rhs).map { $0.lowercased() }
            let shorter = min(left.count, right.count)
            return Array(left.prefix(shorter)) == Array(right.prefix(shorter))
        }

        static func components(_ url: URL) -> [String] { url.path.split(separator: "/").map(String.init) }
    }

    /// 판정에 넣는 값(실행 인자·환경은 조립 지점이 읽어 넣는다)
    public struct Facts: Equatable, Sendable {
        public var isReleaseBuild: Bool
        public var arguments: [String]
        /// 명시한 사본으로 연 실행(`LibraryLocation.opensExplicitCopy`)
        public var opensExplicitCopy: Bool
        /// 진단 실행(`DiagnosticRun`)
        public var isDiagnosticRun: Bool
        /// 자가 테스트 확인 자리. 자가 테스트가 아니면 nil
        public var selfTestPlaces: SelfTestPlaces?

        public init(isReleaseBuild: Bool, arguments: [String], opensExplicitCopy: Bool, isDiagnosticRun: Bool,
                    selfTestPlaces: SelfTestPlaces? = nil) {
            self.isReleaseBuild = isReleaseBuild
            self.arguments = arguments
            self.opensExplicitCopy = opensExplicitCopy
            self.isDiagnosticRun = isDiagnosticRun
            self.selfTestPlaces = selfTestPlaces
        }
    }

    /// 실행 조건 판정(R18). 릴리스 빌드의 라이브 라이브러리만 자동 저장한다. 예외는 디버그 빌드의 사본 자가 테스트 하나다.
    /// - 자가 테스트 인자가 있으면(빈 값·모르는 값 포함) 릴리스 빌드는 진단 실행이고, 디버그 빌드는 경우를 알고 확인 자리를 모두 채울 때만 자가 테스트다.
    ///   명시한 사본(`--db`)과 함께 주면 쓰기 대상이 사본이 아니라서(RBW-15) 자가 테스트로 보지 않는다.
    /// - 그 밖의 진단 실행(측정·캡처·다른 자가 테스트), 명시한 사본, 디버그 빌드 일반 실행은 자동 저장하지 않는다.
    public static func decide(_ facts: Facts) -> Self {
        if AutoReflectSelfTest.isRequested(arguments: facts.arguments) {
            guard !facts.isReleaseBuild else { return .off(.diagnostic) }
            guard let test = AutoReflectSelfTest.requested(arguments: facts.arguments), !facts.opensExplicitCopy,
                  let places = facts.selfTestPlaces, places.allowsWriting else { return .off(.unsafeSelfTest) }
            return .selfTest(test)
        }
        if facts.isDiagnosticRun { return .off(.diagnostic) }
        if facts.opensExplicitCopy { return .off(.explicitCopy) }
        return facts.isReleaseBuild ? .live : .off(.debugBuild)
    }

    /// 자동 저장하는 실행인지
    public var autoSaves: Bool {
        if case .off = self { return false }
        return true
    }
}
