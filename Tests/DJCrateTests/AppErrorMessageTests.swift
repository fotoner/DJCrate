@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

@Suite("앱 오류 표시")
struct AppErrorMessageTests {
    @Test func 조회_오류는_원문_대신_스냅샷을_다시_뜨도록_안내한다() {
        let error = DJCError.queryFailed(sql: "SELECT private_field FROM fixture", message: "no such column: private_field")
        #expect(AppErrorMessage.message(for: error) == "라이브러리 정보를 읽지 못했습니다: rekordbox를 종료한 뒤 스냅샷을 다시 뜨세요.")
    }

    @Test func 실행_중_오류는_종료를_안내하고_CLI_옵션을_숨긴다() {
        #expect(AppErrorMessage.message(for: DJCError.rekordboxRunning) == "rekordbox가 실행 중입니다: rekordbox를 완전히 종료한 뒤 다시 시도하세요.")
    }

    @Test func 일본어_마침표도_안내_연결_전에_걷어낸다() {
        let message = AppErrorMessage.message(for: DJCError.writeRefused("もう一度お試しください。"))
        #expect(message == "もう一度お試しください: 안내된 조건과 DJCrate 업데이트를 확인한 뒤 다시 시도하세요.")
    }

    @Test func 알_수_없는_오류는_현지화_원문도_보여_주지_않는다() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                            userInfo: [NSLocalizedDescriptionKey: "Error Domain=NSCocoaErrorDomain fixture SQL",
                                       NSLocalizedRecoverySuggestionErrorKey: "Run fixture-command --force"])
        #expect(AppErrorMessage.message(for: error) == "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.")
    }

    @MainActor
    @Test func 라이브러리_로드_실패도_앱_문구로_표시한다() async throws {
        let fixture = try RekordboxFixture()
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("error"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), backupDirectory: fixture.backups,
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxDatabase: fixture.database,
                                 rekordboxShareRoot: fixture.shareRoot)
        let missing = fixture.root.appending(path: "missing.db")
        await store.load(snapshot: missing)
        guard case let .failed(message) = store.phase else {
            Issue.record("사본이 없으면 실패 화면을 보여야 한다")
            return
        }
        #expect(store.lastReadFailure == LibraryReadFailure(stage: .opening, keepsPreviousLibrary: false))
        #expect(message == "라이브러리 사본을 열지 못했으니 사본과 파일 접근 권한을 확인한 뒤 다시 불러오세요")
    }
}
