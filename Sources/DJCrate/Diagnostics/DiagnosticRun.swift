import Foundation

/// 자가 테스트·성능 측정·화면 캡처로 띄운 실행인지 가른다(개발용 실행 인자, 디버그 빌드에서만 도는 것들이다).
/// 이런 실행에는 측정·확인 중에 디스크 일을 끼우지 않으려고 뒤에서 도는 일(자동 시점 스냅샷, #228)을 돌리지 않는다.
/// 릴리스 빌드는 이 인자를 무시하지만 같은 판단을 쓴다(그 인자를 줘서 띄운 실행이면 보통 앱처럼 돌지 않는 쪽이 안전하다).
/// 새 개발용 인자는 이름 규칙(`--…-selftest`·`--…-capture(s)=`·`--…-perf…`)을 따르면 여기 따로 더하지 않아도 걸린다.
enum DiagnosticRun {
    /// 실행 인자 가운데 하나라도 개발용 시험·측정·캡처 인자면 true. 첫 인자(실행 파일 경로)는 보지 않는다.
    static func isActive(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.dropFirst().contains(where: isDiagnosticArgument)
    }

    static func isDiagnosticArgument(_ argument: String) -> Bool {
        guard argument.hasPrefix("--") else { return false }
        return argument.hasSuffix("-selftest") || argument.contains("-capture") || argument.contains("-perf")
            || argument == "--autoplay" || argument.hasPrefix("--reflection-layout=")
    }
}
