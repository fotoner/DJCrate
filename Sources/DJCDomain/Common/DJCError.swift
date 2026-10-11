import Foundation

public enum DJCError: Error, LocalizedError, CustomStringConvertible {
    case keyDerivationFailed
    case databaseOpenFailed(path: String, message: String)
    case queryFailed(sql: String, message: String)
    case rekordboxRunning
    case writeAheadLogPresent(path: String)
    case sourceChangedDuringCopy(path: String)
    case snapshotNotFound
    case invalidAnalysisFile(String)
    case invalidCueJSON
    case writeRefused(String)
    /// 커밋 전 확인 실패. 트랜잭션을 되돌려 rekordbox에는 아무것도 쓰지 않았다.
    case writeVerificationFailed(String)
    /// 커밋 뒤 확인·분석 파일 쓰기가 실패해 쓰기 전 백업으로 되돌렸다.
    case writeRolledBack(String)
    /// 커밋 뒤 확인·분석 파일 쓰기가 실패했고 백업으로 되돌리지도 못했다. master.db·분석 파일 상태를 알 수 없다.
    /// `database`는 사본 DB 경로, 라이브 DB면 nil(되돌리는 명령이 다르다).
    case restoreFailed(reason: String, restoreError: String, backup: String, database: String?)
    /// 시점 스냅샷 복원(#225) 도중 실패했고 복원 전으로 돌리지도 못했다. `snapshot`은 복원 직전 시점 스냅샷 ID,
    /// `database`는 사본 DB 경로(라이브면 nil).
    case pointRestoreFailed(reason: String, restoreError: String, snapshot: String, database: String?)
    /// 곡 편집(마디 구간 잇기)을 만들지 않았다. 원본 음원·rekordbox는 건드리지 않았다.
    case editRefused(String)

    /// 앱에는 원문·경로·명령 대신 이유와 할 일을 보여 준다. CLI의 상세 정보는 description에 남긴다.
    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: String(ui: "rekordbox 라이브러리의 잠금을 풀지 못했습니다")
        case .databaseOpenFailed: String(ui: "라이브러리 사본을 열지 못했습니다")
        case .queryFailed: String(ui: "라이브러리 정보를 읽지 못했습니다")
        case .rekordboxRunning: String(ui: "rekordbox가 실행 중입니다")
        case .writeAheadLogPresent: String(ui: "rekordbox의 변경 사항이 아직 저장되지 않았습니다")
        case .sourceChangedDuringCopy: String(ui: "복사하는 동안 라이브러리가 바뀌었습니다")
        case .snapshotNotFound: String(ui: "라이브러리 사본이 없습니다")
        case .invalidAnalysisFile: String(ui: "곡의 분석 파일을 읽지 못했습니다")
        case .invalidCueJSON: String(ui: "곡의 큐 정보를 읽지 못했습니다")
        case let .writeRefused(reason): reason
        case .writeVerificationFailed: String(ui: "쓰기 결과가 예상과 달라 변경을 취소했습니다")
        case .writeRolledBack: String(ui: "쓰기 결과를 확인하지 못해 쓰기 전 백업으로 복원했습니다")
        case .restoreFailed, .pointRestoreFailed: String(ui: "라이브러리와 분석 파일의 상태를 확인하지 못했습니다")
        case let .editRefused(reason): reason
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .keyDerivationFailed:
            String(ui: "rekordbox와 DJCrate의 지원 버전을 확인하세요.")
        case .databaseOpenFailed, .queryFailed, .sourceChangedDuringCopy:
            String(ui: "rekordbox를 종료한 뒤 스냅샷을 다시 뜨세요.")
        case .rekordboxRunning:
            String(ui: "rekordbox를 완전히 종료한 뒤 다시 시도하세요.")
        case .writeAheadLogPresent:
            String(ui: "rekordbox를 한 번 켰다가 완전히 종료한 뒤 스냅샷을 다시 뜨세요.")
        case .snapshotNotFound:
            String(ui: "‘스냅샷 뜨기’를 눌러 라이브러리를 불러오세요.")
        case .invalidAnalysisFile:
            String(ui: "rekordbox에서 트랙 분석을 다시 한 뒤 시도하세요.")
        case .invalidCueJSON:
            String(ui: "rekordbox에서 큐를 확인한 뒤 라이브러리를 다시 불러오세요.")
        case .writeRefused:
            String(ui: "안내된 조건과 DJCrate 업데이트를 확인한 뒤 다시 시도하세요.")
        case .writeVerificationFailed, .writeRolledBack:
            String(ui: "라이브러리를 다시 불러오고 초안을 확인한 뒤 다시 시도하세요.")
        case .restoreFailed:
            String(ui: "rekordbox를 켜지 말고 ‘rekordbox 쓰기 대기’의 ‘쓰기 전으로 복원…’으로 백업을 복원하세요.")
        case .pointRestoreFailed:
            String(ui: "rekordbox를 켜지 말고 rekordbox › 시점 스냅샷…에서 ‘복원 직전’ 스냅샷으로 복원하세요.")
        case .editRefused:
            String(ui: "안내된 마디 구간과 곡을 확인한 뒤 다시 시도하세요.")
        }
    }

    public var description: String {
        switch self {
        case .keyDerivationFailed:
            String(ui: "rekordbox DB 키를 풀지 못했습니다.")
        case let .databaseOpenFailed(path, message):
            String(ui: "DB를 열지 못했습니다 (\(path)): \(message)")
        case let .queryFailed(sql, message):
            String(ui: "쿼리 실패: \(message)\n\(sql)")
        case .rekordboxRunning:
            String(ui: "rekordbox가 실행 중입니다. 종료한 뒤 다시 시도하세요 (읽기 전용 스냅샷은 --force로 강행 가능).")
        case let .writeAheadLogPresent(path):
            String(ui: "WAL 파일이 남아 있습니다: \(path). rekordbox를 완전히 종료한 뒤 다시 시도하세요.")
        case let .sourceChangedDuringCopy(path):
            String(ui: "복사하는 동안 원본이 바뀌었습니다: \(path). 스냅샷을 버렸습니다.")
        case .snapshotNotFound:
            String(ui: "스냅샷이 없습니다. 먼저 `djc snapshot`을 실행하세요.")
        case let .invalidAnalysisFile(path):
            String(ui: "rekordbox 분석 파일 형식이 아닙니다: \(path)")
        case .invalidCueJSON:
            String(ui: "rekordbox 큐 JSON을 읽지 못했습니다.")
        case let .writeRefused(reason):
            String(ui: "rekordbox에 쓰지 않았습니다: \(reason)")
        case let .writeVerificationFailed(reason):
            String(ui: "쓴 결과가 의도와 달라 rekordbox에 쓰지 않았습니다: \(reason)")
        case let .writeRolledBack(reason):
            String(ui: "쓴 결과를 확인하지 못해 쓰기 전 백업으로 되돌렸습니다: \(reason)")
        case let .restoreFailed(reason, restoreError, backup, database):
            String(ui: """
            쓴 결과를 확인하지 못했고 백업으로 자동 복원도 하지 못했습니다. rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다.
            rekordbox를 켜지 말고 먼저 쓰기 전 백업으로 되돌리세요: \(Self.restoreCommand(backup: backup, database: database))
            확인 실패: \(reason)
            복원 실패: \(restoreError)
            """)
        case let .pointRestoreFailed(reason, restoreError, snapshot, database):
            String(ui: """
            시점 스냅샷 복원을 마치지 못했고 복원 전으로 자동으로 돌리지도 못했습니다. rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다.
            rekordbox를 켜지 말고 먼저 복원 직전 시점 스냅샷으로 되돌리세요: \(Self.pointRestoreCommand(snapshot: snapshot, database: database))
            실패: \(reason)
            되돌리기 실패: \(restoreError)
            """)
        case let .editRefused(reason):
            String(ui: "편집하지 않았습니다: \(reason)")
        }
    }

    /// 다른 오류 문구 안에 넣을 사유. 쓰기 확인 오류는 머리말을 빼고 사유만 넘긴다(머리말이 두 번 붙지 않게).
    /// 파일 오류는 UserInfo 덤프 대신 사람이 읽는 문장으로.
    public static func reason(of error: any Error) -> String {
        switch error as? DJCError {
        case let .writeVerificationFailed(reason)?, let .writeRolledBack(reason)?: reason
        default: (error as? CocoaError)?.localizedDescription ?? String(describing: error)
        }
    }

    /// 시점 스냅샷으로 되돌리는 djc 명령
    public static func pointRestoreCommand(snapshot: String, database: String?) -> String {
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        return "djc snapshot-point restore \(quoted(snapshot)) " + (database.map { "--db \(quoted($0))" } ?? "--live")
    }

    /// 백업으로 되돌리는 djc 명령. 경로에 빈칸이 있어도 그대로 붙여 쓸 수 있게 작은따옴표로 감싼다.
    public static func restoreCommand(backup: String, database: String?) -> String {
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        return "djc rekordbox-restore --backup \(quoted(backup)) " + (database.map { "--db \(quoted($0))" } ?? "--live")
    }
}
