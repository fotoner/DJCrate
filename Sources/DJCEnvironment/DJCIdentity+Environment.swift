import DJCDomain
import Foundation

/// 이 프로세스의 실제 데이터 위치. 환경 변수·시험 여부·사용자 폴더를 읽으므로 순수 규칙(`DJCDomain`)과 나눠 둔다.
extension DJCIdentity {
    /// rekordbox 환경설정에 한 번 지정하는 연동 XML 파일("XML 만들기"가 늘 덮어쓴다). 다른 XML 내보내기가 이 자리를 쓰지 않게 비교할 때도 쓴다.
    public static var linkedXMLFile: URL {
        URL.documentsDirectory.appending(path: "\(name)/djcrate-rekordbox.xml")
    }

    /// 설치한 앱이 쓰는 실제 사용자 폴더(`~/Library/Application Support/DJCrate`). 환경·시험 여부와 상관없이 늘 이 경로다.
    public static var userSupportDirectory: URL { URL.applicationSupportDirectory.appending(path: name) }

    /// `~/Library/Application Support/DJCrate`: 초안·스냅샷·백업·분석 캐시. 시험 프로세스는 임시 폴더를 쓴다(사용자 백업을 지우지 않게, #182).
    /// `DJC_HOME`을 따르지 않는다(실물 USB 거부 목록 같은 안전 목록의 고정 위치). 초안·캐시는 `dataDirectory`로 찾는다.
    public static var supportDirectory: URL {
        TestProcess.isRunning ? TestProcess.sandbox.appending(path: "support") : userSupportDirectory
    }

    /// 초안·백업·캐시(파형·분석·음량)의 뿌리. `DJC_HOME`을 주면 그쪽(시험·자가 테스트가 사용자 폴더를 건드리지 않게, #195),
    /// 없으면 `supportDirectory`. 이 뿌리를 정하는 곳은 여기 한 곳이다(곡 편집본 위치는 `DJCPaths.editOutput`이 따로 정한다).
    public static var dataDirectory: URL {
        dataDirectory(environment: ProcessInfo.processInfo.environment, support: supportDirectory)
    }

    /// 설치한 앱의 로그 폴더(`~/Library/Logs/DJCrate`). 환경·시험 여부와 상관없이 늘 이 경로다.
    public static var userLogsDirectory: URL { URL.libraryDirectory.appending(path: "Logs/\(name)") }

    /// 오디오 사건 기록 같은 로그의 폴더. `DJC_HOME`을 주면 그 아래 `logs/`, 시험 프로세스는 임시 폴더,
    /// 아니면 `userLogsDirectory`(#218: 시험·자가 테스트가 실제 로그에 썼다).
    public static var logsDirectory: URL {
        logsDirectory(environment: ProcessInfo.processInfo.environment,
                      fallback: TestProcess.isRunning ? TestProcess.sandbox.appending(path: "logs") : userLogsDirectory)
    }

    /// 라이브 DB 읽기 스냅샷 폴더. `DJC_REKORDBOX_DIR`(사본 rekordbox 폴더)을 주면 그 안 `djc-snapshots`(사용자 스냅샷과 섞이지 않게),
    /// 아니면 `supportDirectory/snapshots`. `DJC_HOME`은 따르지 않는다.
    public static var snapshotsDirectory: URL {
        snapshotsDirectory(environment: ProcessInfo.processInfo.environment, support: supportDirectory)
    }
}
