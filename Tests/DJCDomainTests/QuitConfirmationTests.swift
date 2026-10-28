import DJCDomain
import Foundation
import Testing

/// 켜진 채 종료 시트(#326): 쓰기 대기가 있고 rekordbox(또는 rekordboxAgent)가 켜져 있을 때 사용자가 고른 종료에서만 한 번 묻는다.
/// 쓰는 중이면 묻지 않고 기존 종료 대기(#300)를 따른다. 로그아웃·재시작·전원 끔·업데이트 다시 켜기와 이유를 알 수 없는 종료도 묻지 않는다.
@Suite("켜진 채 종료 시트 판정")
struct QuitConfirmationTests {
    static let pending = PendingWriteCount(items: 3, playlistEdits: 0)

    static func confirmation(_ activity: AppWriteActivity = .idle, cause: AppQuitCause = .user, run: RekordboxRunState? = .running,
                             pending: PendingWriteCount = pending) -> QuitConfirmation? {
        AppQuitPolicy.confirmation(for: activity, cause: cause, run: run, pending: pending)
    }

    // MARK: - 묻는 경우

    @Test func 켜져_있고_쓰기_대기가_있고_사용자가_끄면_묻는다() throws {
        let sheet = try #require(Self.confirmation())
        #expect(sheet.running == .rekordbox)
        #expect(sheet.pending == Self.pending)
    }

    @Test func rekordbox는_꺼지고_Agent만_켜져_있어도_묻는다() throws {
        let sheet = try #require(Self.confirmation(run: .agentOnly))
        #expect(sheet.running == .agentOnly)
    }

    // MARK: - 묻지 않는 경우

    @Test func 쓰기_대기가_없으면_묻지_않는다() {
        #expect(Self.confirmation(pending: PendingWriteCount(items: 0, playlistEdits: 0)) == nil)
    }

    @Test func 재생_목록_편집만_있어도_쓰기_대기가_있는_것이다() throws {
        let sheet = try #require(Self.confirmation(pending: PendingWriteCount(items: 0, playlistEdits: 2)))
        #expect(sheet.pending.playlistEdits == 2)
    }

    @Test func 꺼져_있으면_묻지_않는다() {
        #expect(Self.confirmation(run: .stopped) == nil)
    }

    /// 감지에 실패했거나 아직 읽지 못했을 때 "켜져 있어"라고 거짓으로 말하지 않는다
    @Test func 모르면_묻지_않는다() {
        #expect(Self.confirmation(run: .unknown) == nil)
        #expect(Self.confirmation(run: nil) == nil)
    }

    /// 로그아웃·재시작·전원 끔·업데이트 다시 켜기를 막지 않는다. 이유를 알 수 없는 종료도 사용자 종료를 막는 쪽이 아니라 묻지 않는 쪽이다
    @Test(arguments: [AppQuitCause.systemShutdown, .updateRelaunch, .unknown])
    func 사용자가_고른_종료가_아니면_묻지_않는다(_ cause: AppQuitCause) {
        #expect(Self.confirmation(cause: cause) == nil)
        #expect(Self.confirmation(cause: cause, run: .agentOnly) == nil)
    }

    /// 쓰는 중이면 시트보다 기존 종료 대기(#300)가 앞선다. 미리 보기·확인 창·경고창·USB 쓰기도 기존 판정을 그대로 따른다
    @Test(arguments: [RekordboxWritePhase.cancellable, .confirming, .writing, .readingBack, .acknowledging])
    func 쓰기_단계가_있으면_묻지_않는다(_ phase: RekordboxWritePhase) {
        #expect(Self.confirmation(AppWriteActivity(rekordbox: phase, writingUsb: false)) == nil)
    }

    @Test func USB에_쓰는_중이면_묻지_않는다() {
        #expect(Self.confirmation(AppWriteActivity(rekordbox: .idle, writingUsb: true)) == nil)
    }

    // MARK: - 종료 이유

    /// 종료 이유('why?')의 값: 없으면(⌘Q·메뉴 종료는 Apple 이벤트가 아니다, Dock 종료는 이유를 싣지 않는다) 사용자가 고른 종료다
    @Test func 이유가_없거나_일반_종료면_사용자가_고른_종료다() {
        #expect(AppQuitCause.classify(quitReason: nil, isPoweringOff: false, isUpdateRelaunch: false) == .user)
        #expect(AppQuitCause.classify(quitReason: AppQuitCause.fourCC("quia"), isPoweringOff: false, isUpdateRelaunch: false) == .user)
    }

    @Test(arguments: ["rlgo", "logo", "rest", "shut", "rrst", "rsdn"])
    func 로그아웃_재시작_전원_끔_이유는_시스템_종료다(_ code: String) {
        #expect(AppQuitCause.classify(quitReason: AppQuitCause.fourCC(code), isPoweringOff: false, isUpdateRelaunch: false) == .systemShutdown)
    }

    @Test func 모르는_이유는_묻지_않는_쪽이다() {
        let cause = AppQuitCause.classify(quitReason: AppQuitCause.fourCC("zzzz"), isPoweringOff: false, isUpdateRelaunch: false)
        #expect(cause == .unknown && !cause.isUserChosen)
    }

    @Test func Mac을_끄는_중이라는_알림이_있으면_이유가_없어도_시스템_종료다() {
        #expect(AppQuitCause.classify(quitReason: nil, isPoweringOff: true, isUpdateRelaunch: false) == .systemShutdown)
        #expect(AppQuitCause.classify(quitReason: AppQuitCause.fourCC("quia"), isPoweringOff: true, isUpdateRelaunch: false) == .systemShutdown)
    }

    @Test func 업데이트_다시_켜기는_이유가_없어도_시스템_종료가_아니라_업데이트다() {
        #expect(AppQuitCause.classify(quitReason: nil, isPoweringOff: false, isUpdateRelaunch: true) == .updateRelaunch)
        // 둘이 겹치면 Mac을 끄는 중이 먼저다
        #expect(AppQuitCause.classify(quitReason: nil, isPoweringOff: true, isUpdateRelaunch: true) == .systemShutdown)
    }

    @Test func 종료_이유_열쇠는_why물음표다() {
        #expect(AppQuitCause.quitReasonKeyword == 0x7768_793F)
        #expect(AppQuitCause.fourCC("quia") == 0x7175_6961)
    }

    // MARK: - 문구

    @Test func 본문은_켜진_것과_쓰기_대기_수를_담는다() throws {
        let rekordbox = try #require(Self.confirmation())
        #expect(rekordbox.message == "rekordbox가 켜져 있어 쓰기 대기 3건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordbox를 끈 뒤 DJCrate에서 쓰세요")
        let agent = try #require(Self.confirmation(run: .agentOnly))
        #expect(agent.message == "rekordboxAgent가 켜져 있어 쓰기 대기 3건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordboxAgent를 종료한 뒤 DJCrate에서 쓰세요")
    }

    /// 칩과 같은 수·같은 단위: 곡이 있으면 「쓰기 대기 N건」, 재생 목록 편집만이면 「재생 목록 편집 N건」
    @Test func 재생_목록_편집만_있으면_편집_건수로_쓴다() throws {
        let sheet = try #require(Self.confirmation(pending: PendingWriteCount(items: 0, playlistEdits: 2)))
        #expect(sheet.message == "rekordbox가 켜져 있어 재생 목록 편집 2건을 아직 rekordbox에 쓰지 않았습니다. 편집은 DJCrate에 남아 있으니 rekordbox를 끈 뒤 DJCrate에서 쓰세요")
        let agent = try #require(Self.confirmation(run: .agentOnly, pending: PendingWriteCount(items: 0, playlistEdits: 2)))
        #expect(agent.message.hasPrefix("rekordboxAgent가 켜져 있어 재생 목록 편집 2건을"))
    }

    @Test func 곡과_재생_목록_편집이_함께_있으면_곡_수가_먼저다() {
        let both = PendingWriteCount(items: 4, playlistEdits: 2)
        #expect(both.text == "쓰기 대기 4건")
        #expect(PendingWriteCount(items: 0, playlistEdits: 2).text == "재생 목록 편집 2건")
        #expect(PendingWriteCount(items: 0, playlistEdits: 0).isEmpty)
        #expect(!both.isEmpty)
    }

    @Test func 제목과_단추는_짧고_자유_문구에_약속을_담지_않는다() throws {
        let sheet = try #require(Self.confirmation())
        #expect(sheet.title == "쓰기 대기가 남아 있습니다")
        #expect(QuitConfirmation.quitAnywayTitle == "그냥 종료")
        #expect(QuitConfirmation.cancelTitle == "취소")
        // 1차에는 자동 쓰기가 없어 "다시 열면 저장된다"고 쓰지 않는다
        #expect(!sheet.message.contains("다시 열"))
    }
}
