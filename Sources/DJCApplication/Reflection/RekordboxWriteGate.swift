import DJCDomain
import Foundation

/// rekordbox 쓰기 관문(포트). `RekordboxWriter`·`RekordboxTrackWriter`를 얇게 감쌀 뿐,
/// 관문의 사전 확인·백업·트랜잭션·검증·복원은 그대로다. 반영 세션이 메인 스레드 밖에서 부른다.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 시험은 가짜를 넣는다.
public struct RekordboxWriteGate: Sendable {
    /// 자동 저장 묶음(`DraftWriteBatch.isAutoSave`)을 쓰려는데 다른 쪽이 쓰기 잠금을 쥐고 있었다(기다리지 않았다, R9)
    public struct LockBusy: Error, Equatable, Sendable {
        public init() {}
    }

    /// 앱의 쓰기(작업이 실린 묶음)가 백업을 뜬 뒤 실패했다는 표시(R7: 자동 저장 엔진이 멈춘다). 오류 문구는 감싼 오류 그대로다
    public struct AfterBackupFailure: LocalizedError, Sendable {
        public let underlying: any Error

        public init(_ underlying: any Error) { self.underlying = underlying }

        public var errorDescription: String? { underlying.localizedDescription }
        public var failureReason: String? { (underlying as? any LocalizedError)?.failureReason }
        public var recoverySuggestion: String? { (underlying as? any LocalizedError)?.recoverySuggestion }
    }

    /// 초안을 쓴다(`dryRun`이면 끝까지 해 보고 되돌린다)
    public var write: @Sendable (DraftWriteBatch, [String: RekordboxAnalysisInput], RekordboxWriteTarget, Bool) throws -> RekordboxWriteReport
    /// 원본의 DB·분석 파일 사본을 떠서 그 사본에 써 보고 사본을 지운다. 사본을 만든 뒤 `copied`를 부른다.
    public var preview: @Sendable (DraftWriteBatch, [String: RekordboxAnalysisInput], RekordboxWriteTarget,
                                   @escaping @Sendable () async -> Void) async throws -> RekordboxWriteReport
    /// 백업 폴더로 되돌린다. 되돌리기 직전 상태를 남긴 백업을 돌려준다.
    public var restore: @Sendable (URL, RekordboxWriteTarget) throws -> URL
    public var addTracks: @Sendable (TrackAddBatch, RekordboxWriteTarget, Bool) throws -> RekordboxTrackWriteReport
    public var deleteTracks: @Sendable ([String], RekordboxWriteTarget, Bool) throws -> RekordboxTrackWriteReport
    /// 시점 스냅샷(스냅샷 폴더 안의 항목)으로 되돌린다(자동 스냅샷 보관 일수, 지금 시각)
    public var restorePointSnapshot: @Sendable (URL, RekordboxWriteTarget, URL, Int, Date) throws -> RekordboxPointRestoreReport
    /// 재생 목록 편집을 적힌 순서대로 쓴다(`djc playlist-write`, DB 옆 `masterPlaylists6.xml`도 고친다)
    public var writePlaylists: @Sendable ([PlaylistEdit], RekordboxWriteTarget, Bool) throws -> RekordboxWriteReport
    /// iTunes 동기화 선택을 쓰고 rekordbox 동기화 파일(`playlists3.sync`)을 다시 읽어 돌려준다
    public var syncITunes: @Sendable (ITunesSyncWrite, RekordboxWriteTarget) throws -> Data

    // MARK: 쓰기 기록(R11)·미정리 목록(R22). 기본값은 지금 동작(기록·목록이 없다)이다. 실제 구현은 `.live`가 채운다(W1-A).

    /// 대상의 쓰기 기록을 판정한다. 판정·정리는 쓰기 잠금을 쥔 채로만 한다.
    /// - `hold`가 nil이면 관문이 비차단으로 잡는다. 못 잡으면 `.inProgress`다.
    /// - 부르는 쪽이 쥔 잠금(`RekordboxWriteLock.Hold`)을 넘기면 그 잠금 아래에서 판정한다(잠금은 다시 들어갈 수 없어서다).
    ///   엔진·시점 스냅샷은 잡기 → 판정 → 스냅샷을 한 잠금 아래에서 한다(R13). 넘긴 잠금의 키가 대상의 키와 다르면 던진다
    public var journal: @Sendable (RekordboxWriteTarget, _ hold: RekordboxWriteLock.Hold?) throws -> RekordboxJournalVerdict = { _, _ in .none }
    /// 사용자가 확인한 중단 기록으로 복원한다(입구에 따라: 쓰기 전 백업으로 되돌리기, 같은 복원 다시 하기, `playlists3.sync`만 되돌리기).
    /// 쓰기 잠금 안에서 기록의 작업 ID와 master.db 크기·시각이 요청과 다르면 아무것도 하지 않고 `.changed`다.
    /// 백업 사슬 검사를 타지 않고 기록의 근거와 파일 목록만으로 한다. 시작할 때 "복원 중"을 적고, 검증이 끝나면 그 쓰기의 미정리 목록을
    /// 먼저 지우고 기록은 마지막에 지운다. 다시 멈추면 같은 기록으로 다시 복원한다
    public var restoreJournal: @Sendable (RekordboxWriteTarget, RekordboxJournalRequest) throws -> RekordboxJournalRestore = { _, _ in .nothing }
    /// "이대로 둔다"(R11). 한 쓰기 잠금 안에서 이 차례로 한다.
    /// 1. 요청(작업 ID·master.db 크기·시각)을 남은 기록·지금 DB와 다시 견준다. 다르면 아무것도 하지 않고 `.changed`(`apply`를 부르지 않는다).
    ///    기록이 없으면 `.nothing`(`apply`를 부르지 않는다).
    /// 2. 같으면 부르는 쪽이 넘긴 일 `apply`를 부른다: 그 쓰기의 미정리 목록을 지우고, 기록에 적힌 판의 초안을 제안으로 바꾼다
    ///    (`DraftStore.markSuggestions`). `apply`가 던지면 기록을 지우지 않고 그 오류를 던진다(다시 고를 수 있다).
    /// 3. 쓰기 기록을 마지막에 지우고 `.kept`.
    /// `apply`는 잠금을 쥔 채 메인 액터 밖에서 불린다. 그 안에서 쓰기 잠금을 잡는 입구(쓰기·복원·`journal(_, nil)`)를 부르지 않는다
    public var keepJournal: @Sendable (RekordboxWriteTarget, RekordboxJournalRequest, _ apply: @Sendable () throws -> Void) throws -> RekordboxJournalKeep =
        { _, _, _ in .nothing }
    /// 대상의 미정리 목록 가운데 이 초안 저장소의 것(대상·저장소가 다른 목록은 건드리지 않는다). 읽지 못하는 목록이 있으면 던진다
    public var cleanupLists: @Sendable (RekordboxWriteTarget, _ draftHome: URL) throws -> [DraftCleanupList] = { _, _ in [] }
    /// 정리를 모두 마친 목록을 지운다(초안과 연결 ID를 다 저장한 뒤). 쓰기 잠금을 잡지 않는다("이대로 둔다"의 `apply` 안에서도 부른다)
    public var removeCleanupList: @Sendable (DraftCleanupList, RekordboxWriteTarget) throws -> Void = { _, _ in }

    public init(write: @escaping @Sendable (DraftWriteBatch, [String: RekordboxAnalysisInput], RekordboxWriteTarget, Bool) throws -> RekordboxWriteReport,
                preview: @escaping @Sendable (DraftWriteBatch, [String: RekordboxAnalysisInput], RekordboxWriteTarget,
                                              @escaping @Sendable () async -> Void) async throws -> RekordboxWriteReport,
                restore: @escaping @Sendable (URL, RekordboxWriteTarget) throws -> URL,
                addTracks: @escaping @Sendable (TrackAddBatch, RekordboxWriteTarget, Bool) throws -> RekordboxTrackWriteReport,
                deleteTracks: @escaping @Sendable ([String], RekordboxWriteTarget, Bool) throws -> RekordboxTrackWriteReport,
                restorePointSnapshot: @escaping @Sendable (URL, RekordboxWriteTarget, URL, Int, Date) throws -> RekordboxPointRestoreReport,
                writePlaylists: @escaping @Sendable ([PlaylistEdit], RekordboxWriteTarget, Bool) throws -> RekordboxWriteReport,
                syncITunes: @escaping @Sendable (ITunesSyncWrite, RekordboxWriteTarget) throws -> Data) {
        self.write = write
        self.preview = preview
        self.restore = restore
        self.addTracks = addTracks
        self.deleteTracks = deleteTracks
        self.restorePointSnapshot = restorePointSnapshot
        self.writePlaylists = writePlaylists
        self.syncITunes = syncITunes
    }
}
