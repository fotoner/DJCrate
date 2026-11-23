import DJCDomain
import Foundation

/// 대상의 쓰기 기록 판정(R11). 판정은 쓰기 잠금을 비차단으로 잡은 뒤에만 하고, rekordbox·Agent가 꺼졌음을 확인한 뒤
/// 카운터는 스냅샷 사본에서 읽는다(SAFE-6). 표시가 없는 카운터 쓰기의 기록이고 지금 카운터가 시작 카운터와 같으면 조용히 지운다.
public enum RekordboxJournalVerdict: Equatable, Sendable {
    /// 기록이 없다(또는 판정이 조용히 지웠다)
    case none
    /// 다른 프로세스가 잠금을 쥐어 판정하지 않았다. 진행 중으로 본다(알리지 않는다)
    case inProgress
    /// 중단. 이 대상에 새로 쓰지 않는다(기록으로 복원과 "이대로 둔다"만 된다).
    /// `changedSince`: 지금 master.db 크기·시각이 기록의 값(준비 사본의 값이 있으면 그 값도)과 모두 다르다.
    /// 복원 확인 창에 "백업 뒤 rekordbox에서 바뀜" 경고를 띄우고 상태 줄은 "이대로 둔다"를 먼저 보인다
    case interrupted(RekordboxWriteJournal, changedSince: Bool)
}

/// 기록으로 복원한 결과(R11). 다시 하는 복원이 이미 목표 상태면 끝난 것으로 본다
public enum RekordboxJournalRestore: Equatable, Sendable {
    /// 복원할 기록이 없다
    case nothing
    /// 되돌렸다. 되돌리기 직전 상태를 남긴 백업(RBW-5, 없으면 nil)
    case restored(backup: URL?)
    /// 이미 목표 상태였다
    case alreadyRestored
}

/// 앱 쓰기의 정리 할 일을 적을 자리(R11·R22). 앱의 초안 쓰기·곡 넣기가 묶음에 실어 관문에 넘긴다.
/// 관문은 쓰기 기록에 초안의 판과 이 저장소 위치를 적고, 라이브러리 변경을 마친 뒤 기록을 지우기 직전에 미정리 목록을 적는다.
/// nil(CLI·시험)이면 미정리 목록을 적지 않는다.
public struct DraftWriteOperation: Equatable, Sendable {
    /// 작업 ID(쓰기 기록·미정리 목록이 같은 값을 쓴다)
    public var id: String
    /// 초안 저장소 위치(이 실행의 `DJC_HOME` 초안 폴더)
    public var draftHome: URL

    public init(id: String, draftHome: URL) {
        self.id = id
        self.draftHome = draftHome
    }
}

/// 묶음에 든 초안의 도장(R22). 쓰기 뒤 정리는 여기 적힌 판(과 그때의 해시)만 지운다. 판을 모르는 초안은 빠진다
public struct DraftBatchRevisions: Equatable, Sendable {
    /// 곡 초안(종류, 곡) → 묶음을 읽은 때의 도장
    public var tracks: [DraftKey: DraftStamp]
    /// 재생 목록 단계의 도장(묶음의 `playlists.steps`와 같은 차례). 모르면 빈 배열
    public var playlistSteps: [DraftStamp]

    public init(tracks: [DraftKey: DraftStamp] = [:], playlistSteps: [DraftStamp] = []) {
        self.tracks = tracks
        self.playlistSteps = playlistSteps
    }

    public var isEmpty: Bool { tracks.isEmpty && playlistSteps.isEmpty }

    /// 그 초안들의 도장만(재생 목록 단계는 그대로)
    public func restricted(to keys: Set<DraftKey>) -> Self {
        Self(tracks: tracks.filter { keys.contains($0.key) }, playlistSteps: playlistSteps)
    }

    /// 그 초안들을 쓴 초안으로(도장이 없는 초안은 빠진다)
    public func written(_ keys: some Sequence<DraftKey>) -> [WrittenDraft] {
        keys.compactMap { key in tracks[key].map { WrittenDraft(key: key, revision: $0.revision, contentHash: $0.contentHash) } }
            .sorted { $0.key < $1.key }
    }
}

/// 자동 저장의 백업 조건(R13). 실제 판정은 쓰기 백업과 같은 볼륨·여유 공간을 보는 DJCAdapters가 한다
public enum RekordboxBackupCondition: Equatable, Sendable {
    /// 백업 폴더가 대상과 같은 볼륨이라 클론이 되고 여유 공간도 넉넉하다
    case ready
    /// 백업 폴더가 대상과 다른 볼륨이라 클론이 안 된다
    case noClone
    /// 여유 공간이 모자라다(바이트)
    case lowSpace(available: Int64, required: Int64)
    /// 확인하지 못했다(자동 저장은 보류한다)
    case unknown

    /// 자동 저장에 필요한 여유 공간: 1GB와 master.db 크기의 3배 중 큰 값
    public static func requiredFreeSpace(databaseSize: Int64) -> Int64 {
        let gigabyte: Int64 = 1 << 30
        let (tripled, overflow) = databaseSize.multipliedReportingOverflow(by: 3)
        return overflow ? .max : max(gigabyte, tripled)
    }
}
