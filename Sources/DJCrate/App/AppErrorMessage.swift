import DJCApplication
import DJCDomain
import Foundation

/// 앱 문구는 우리가 정한 이유·할 일만 보여 주고, 진단 원문은 표준 오류에 남긴다.
enum AppErrorMessage {
    static func message(for error: any Error) -> String {
        // 백업 뒤 실패 표시(자동 저장 엔진이 본다)는 문구를 바꾸지 않는다: 감싼 원래 오류로 말한다
        if let marked = error as? RekordboxWriteGate.AfterBackupFailure { return message(for: marked.underlying) }
        log(error)
        guard let error = error as? DJCError else {
            return String(ui: "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.")
        }
        let description = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".。 \n"))
        guard let suggestion = error.recoverySuggestion else { return description }
        // 이유와 할 일을 잇는 모양이 언어마다 달라 한 문장 형식으로 둔다.
        return String(ui: "\(description): \(suggestion)")
    }

    static func log(_ error: any Error) {
        FileHandle.standardError.write(Data("[앱 오류] \(error)\n".utf8))
    }
}
