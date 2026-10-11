import DJCDomain
import Foundation
import Testing

@Suite("앱 오류 문구")
struct DJCErrorTests {
    @Test func 실행_중_오류는_앱과_CLI_안내를_나눈다() {
        let error = DJCError.rekordboxRunning
        #expect(error.localizedDescription.contains("rekordbox"))
        #expect(!error.localizedDescription.contains("--force"))
        #expect(error.description.contains("--force"))
    }

    @Test func 조회_실패는_SQL과_기술_원문을_숨긴다() {
        let error = DJCError.queryFailed(sql: "SELECT private_field FROM fixture", message: "no such column: private_field")
        #expect(!error.localizedDescription.contains("SELECT"))
        #expect(!error.localizedDescription.contains("private_field"))
        #expect(error.localizedDescription.contains("라이브러리"))
        #expect(error.description.contains("SELECT private_field FROM fixture"))
    }

    @Test func 스냅샷_명령은_CLI에서만_안내한다() {
        #expect(!DJCError.snapshotNotFound.localizedDescription.contains("djc snapshot"))
        #expect(DJCError.snapshotNotFound.description.contains("djc snapshot"))
    }

    @Test(arguments: [
        DJCError.keyDerivationFailed,
        .databaseOpenFailed(path: "/fixture/private", message: "SQLITE_ERROR"),
        .queryFailed(sql: "SELECT private_field FROM fixture", message: "SQLITE_ERROR"),
        .rekordboxRunning, .writeAheadLogPresent(path: "/fixture/private"),
        .sourceChangedDuringCopy(path: "/fixture/private"), .snapshotNotFound,
        .invalidAnalysisFile("/fixture/private"), .invalidCueJSON,
        .writeRefused("지원하지 않는 버전입니다"),
        .writeVerificationFailed("SQLITE_ERROR"), .writeRolledBack("SQLITE_ERROR"),
        .restoreFailed(reason: "SQLITE_ERROR", restoreError: "NSCocoaErrorDomain", backup: "/fixture/private", database: nil),
    ])
    func 앱_오류에는_할_일이_있고_기술_세부_정보가_없다(error: DJCError) {
        let message = error.localizedDescription
        let recovery = (error as NSError).localizedRecoverySuggestion
        #expect(recovery?.isEmpty == false)
        for raw in ["/fixture/private", "SQLITE_ERROR", "SELECT", "NSCocoaErrorDomain", "--force", "djc "] {
            #expect(!message.contains(raw))
            #expect(recovery?.contains(raw) != true)
        }
    }

    @Test func 복원_실패는_현재_화면의_복원_버튼을_안내한다() {
        let error = DJCError.restoreFailed(reason: "fixture", restoreError: "fixture", backup: "/fixture/backup", database: nil)
        #expect(error.recoverySuggestion == "rekordbox를 켜지 말고 ‘rekordbox 쓰기 대기’의 ‘쓰기 전으로 복원…’으로 백업을 복원하세요.")
    }

    @Test func 쓰기_거부는_이유만_설명한다() {
        #expect(DJCError.writeRefused("지원하지 않는 버전입니다").localizedDescription == "지원하지 않는 버전입니다")
    }
}
