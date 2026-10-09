import Foundation

/// 어떤 볼륨을 읽을지(사본 뜨기 포함). 쓰기와 무관하게 읽기에도 건다.
enum UsbReadPolicy: Equatable, Sendable {
    /// 배포 빌드: 연결된 모든 USB(실물도 등록 없이)
    case all
    /// 자가 테스트·시험 실행: 디스크 이미지 볼륨만. 그 밖의 볼륨은 사이드바에 이름도 보이지 않는다
    case diskImagesOnly

    /// DEBUG 빌드에서 `DJC_HOME`이 비어 있지 않거나(임시 폴더로 띄운 시험 실행) `--usb-selftest` 인자가 있으면 `.diskImagesOnly`. 그 밖 `.all`.
    /// RELEASE 빌드는 늘 `.all`(사용자 앱).
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                        arguments: [String] = CommandLine.arguments) -> UsbReadPolicy {
        #if DEBUG
        if environment["DJC_HOME"]?.isEmpty == false || arguments.contains("--usb-selftest") { return .diskImagesOnly }
        #endif
        return .all
    }

    /// 실물 쓰기 동의: 앱의 쓰기 확인 창. 디스크 이미지만 읽는 실행(자가 테스트·DJC_HOME 시험 실행)은 실물에 쓰지 않는다
    var physicalWriteConsent: Bool { self == .all }

    /// 시작 줄·시험에 쓰는 이름(번역하지 않는다)
    var name: String {
        switch self {
        case .all: "all"
        case .diskImagesOnly: "diskImagesOnly"
        }
    }
}
