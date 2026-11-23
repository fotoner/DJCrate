import DJCDomain
import Foundation

/// 대상의 쓰기 기록 판정(R11). 판정은 쓰기 잠금을 쥔 채로만 하고(비차단으로 잡거나 부르는 쪽이 쥔 잠금을 넘긴다),
/// rekordbox·Agent가 꺼졌음을 확인한 뒤 카운터는 스냅샷 사본에서 읽는다(SAFE-6). 표시가 없는 카운터 쓰기의 기록이고
/// 지금 카운터가 시작 카운터와 같으면 조용히 지운다.
public enum RekordboxJournalVerdict: Equatable, Sendable {
    /// 기록이 없다(또는 판정이 조용히 지웠다)
    case none
    /// 다른 프로세스가 잠금을 쥐어 판정하지 않았다. 진행 중으로 본다(알리지 않는다)
    case inProgress
    /// 중단. 이 대상에 새로 쓰지 않는다(기록으로 복원과 "이대로 둔다"만 된다)
    case interrupted(RekordboxJournalFinding)
}

/// 판정이 찾은 중단 기록과 그때 본 대상 상태. 사용자 확인을 받은 뒤 `request`로 복원·"이대로 둔다"를 부른다
public struct RekordboxJournalFinding: Equatable, Sendable {
    public var journal: RekordboxWriteJournal
    /// 지금 master.db 크기·시각이 기록의 값(준비 사본의 값이 있으면 그 값도)과 모두 다르다. 카운터가 같아도 크기·시각이 다르면 참이다.
    /// 복원 확인 창에 "백업 뒤 rekordbox에서 바뀜" 경고를 띄우고 상태 줄은 "이대로 둔다"를 먼저 보인다
    public var changedSince: Bool
    /// 판정 때 본 지금 master.db 크기·시각(없으면 nil)
    public var database: RekordboxFileStamp?

    public init(journal: RekordboxWriteJournal, changedSince: Bool, database: RekordboxFileStamp?) {
        self.journal = journal
        self.changedSince = changedSince
        self.database = database
    }

    /// 사용자가 확인한 이 기록으로 복원·"이대로 둔다"를 부를 요청
    public var request: RekordboxJournalRequest { RekordboxJournalRequest(operationID: journal.operationID, database: database) }
}

/// 사용자가 확인한 중단 기록(기록으로 복원·"이대로 둔다"의 요청). 관문은 쓰기 잠금 안에서 남은 기록의 작업 ID와
/// 지금 master.db 크기·시각이 이 값과 같을 때만 한다. 다르면 아무것도 하지 않고 `.changed`로 다시 확인을 받게 한다
public struct RekordboxJournalRequest: Equatable, Sendable {
    public var operationID: String
    /// 확인할 때 본 master.db 크기·시각(없으면 nil: 그때 DB가 없었다)
    public var database: RekordboxFileStamp?

    public init(operationID: String, database: RekordboxFileStamp?) {
        self.operationID = operationID
        self.database = database
    }
}

/// 기록으로 복원한 결과(R11). 다시 하는 복원이 이미 목표 상태면 끝난 것으로 본다
public enum RekordboxJournalRestore: Equatable, Sendable {
    /// 복원할 기록이 없다
    case nothing
    /// 되돌렸다. 되돌리기 직전 상태를 남긴 백업(RBW-5, 없으면 nil)
    case restored(backup: URL?)
    /// 이미 목표 상태였다
    case alreadyRestored
    /// 잠금 안에서 본 기록의 작업 ID나 master.db 크기·시각이 요청과 달라 아무것도 하지 않았다(다시 판정해 확인을 받는다)
    case changed
}

/// "이대로 둔다"의 결과(R11)
public enum RekordboxJournalKeep: Equatable, Sendable {
    /// 기록을 지웠다
    case kept
    /// 지울 기록이 없다
    case nothing
    /// 잠금 안에서 본 기록의 작업 ID나 master.db 크기·시각이 요청과 달라 지우지 않았다(다시 판정해 확인을 받는다)
    case changed
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

/// 묶음이 쓰기를 마치는 방식(R12)
public enum DraftCommitPolicy: Equatable, Sendable {
    /// 쓸 수 있는 것만 쓴다(막힌 것은 초안으로 남는다). 지금 동작이다
    case writable
    /// 하나라도 막히면 아무것도 쓰지 않는다(여러 곡에 걸친 역편집). 적용은 W1-A(관문)·W3-F(세션)
    case allOrNothing
}

/// 묶음에 든 초안 하나: 읽어 넣은 때의 도장과 실제로 읽어 넣은 내용의 해시
public struct DraftBatchEntry: Equatable, Sendable {
    /// 묶음에 읽어 넣은 때의 도장(출처 판정용. 도장의 해시는 저장 때의 해시다)
    public var stamp: DraftStamp
    /// 묶음에 실제로 읽어 넣은 내용의 해시. 쓴 뒤 정리(R22)는 이 해시로 견준다(저장 때의 해시와 다르면 그 초안은 제안이었다)
    public var contentHash: DraftContentHash

    public init(stamp: DraftStamp, contentHash: DraftContentHash) {
        self.stamp = stamp
        self.contentHash = contentHash
    }

    public var revision: DraftRevision { stamp.revision }
}

/// 묶음에 든 초안의 판(R22). 쓰기 뒤 정리는 여기 적힌 판과 읽어 넣은 내용의 해시로 쓴 것만 지운다. 판을 모르는 초안은 빠진다
public struct DraftBatchRevisions: Equatable, Sendable {
    /// 곡 초안(종류, 곡) → 묶음에 든 초안
    public var tracks: [DraftKey: DraftBatchEntry]
    /// 재생 목록 단계(묶음의 `playlists.steps`와 같은 차례, 해시는 `DraftContentHash(step:in:)`). 모르면 빈 배열
    public var playlistSteps: [DraftBatchEntry]

    public init(tracks: [DraftKey: DraftBatchEntry] = [:], playlistSteps: [DraftBatchEntry] = []) {
        self.tracks = tracks
        self.playlistSteps = playlistSteps
    }

    public var isEmpty: Bool { tracks.isEmpty && playlistSteps.isEmpty }

    /// 그 초안들의 것만(재생 목록 단계는 그대로)
    public func restricted(to keys: Set<DraftKey>) -> Self {
        Self(tracks: tracks.filter { keys.contains($0.key) }, playlistSteps: playlistSteps)
    }

    /// 그 초안들을 쓴 초안으로(판을 모르는 초안은 빠진다). 해시는 읽어 넣은 내용의 해시다
    public func written(_ keys: some Sequence<DraftKey>) -> [WrittenDraft] {
        keys.compactMap { key in tracks[key].map { WrittenDraft(key: key, revision: $0.revision, contentHash: $0.contentHash) } }
            .sorted { $0.key < $1.key }
    }

    /// 그 차례(묶음의 `playlists.steps` 차례)의 단계를 쓴 단계로(판을 모르는 차례는 빠진다)
    public func writtenSteps(at offsets: some Sequence<Int>) -> [WrittenPlaylistStep] {
        offsets.compactMap { offset in
            playlistSteps.indices.contains(offset)
                ? WrittenPlaylistStep(revision: playlistSteps[offset].revision, contentHash: playlistSteps[offset].contentHash) : nil
        }
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
