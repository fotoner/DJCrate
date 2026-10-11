import DJCDomain
import Foundation

/// rekordbox 쓰기 관문(포트, H2 설계의 `RekordboxLibraryWriter`). `RekordboxWriter`·`RekordboxTrackWriter`를 얇게 감쌀 뿐,
/// 관문의 사전 확인·백업·트랜잭션·검증·복원은 그대로다. 반영 세션이 메인 스레드 밖에서 부른다.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 시험은 가짜를 넣는다.
public struct RekordboxWriteGate: Sendable {
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
