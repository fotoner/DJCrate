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
        /// `DJC_HOME`
        public var home: URL
        /// 임시 폴더(대상과 `DJC_HOME`이 이 아래에 있어야 한다)
        public var temporaryRoot: URL
        /// 실제 rekordbox 폴더(대상과 겹치면 안 된다)
        public var liveRekordbox: URL
        /// DJCrate 사용자 폴더(`DJC_HOME`과 겹치면 안 된다)
        public var userData: URL
        /// 사본 안 `share/PIONEER/USBANLZ`가 링크인지(SAFE-8)
        public var analysisIsLink: Bool

        public init(target: URL, home: URL, temporaryRoot: URL, liveRekordbox: URL, userData: URL, analysisIsLink: Bool) {
            self.target = target
            self.home = home
            self.temporaryRoot = temporaryRoot
            self.liveRekordbox = liveRekordbox
            self.userData = userData
            self.analysisIsLink = analysisIsLink
        }
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

    /// 실행 조건 판정(R18).
    /// 몸체는 W2-D(#403)가 채운다. 그 전에는 어느 실행도 자동 저장하지 않는다(지금 동작).
    public static func decide(_ facts: Facts) -> Self {
        .off(facts.isReleaseBuild ? .diagnostic : .debugBuild)
    }

    /// 자동 저장하는 실행인지
    public var autoSaves: Bool {
        if case .off = self { return false }
        return true
    }
}
