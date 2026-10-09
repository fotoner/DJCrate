import DJCDomain
import Foundation

/// rekordbox 라이브러리를 어디서 읽고 어디에 쓰는지와 DJCrate 초안 폴더(#182).
/// 조립 지점(앱 `AppComposition`, CLI `CLIComposition`)이 실행 인자·환경을 한 번 풀어 만든다(`LibraryLocation.resolve`, DJCAdapters).
/// 화면 모델·명령은 프로세스 인자·환경을 다시 읽지 않고 이 값만 본다: 읽기 출처·변경 확인·복구 출처·iTunes 동기화 대상이 모두 여기서 나온다.
public struct LibraryLocation: Sendable, Equatable {
    /// rekordbox 라이브러리 폴더(라이브 master.db·share). `DJC_REKORDBOX_DIR`이면 그 사본 폴더, 시험 프로세스는 임시 폴더(#182)
    public var rekordboxDirectory: URL
    /// `DJC_REKORDBOX_DIR`로 사본 rekordbox 폴더를 가리켰는지. 그러면 Music을 조회하지 않고, 명시한 사본으로 열어도 스냅샷을 뜬다
    public var rekordboxDirectoryOverridden: Bool
    /// 읽기용 스냅샷 사본 폴더
    public var snapshotDirectory: URL
    /// 명시한 사본(`--db PATH`·`DJC_DB`)으로 열라고 했는지. 그러면 라이브 변경을 확인하지 않고 그 사본을 다시 읽는다
    public var opensExplicitCopy: Bool
    /// 명시한 사본 경로(`--db` 뒤의 값, 없으면 `DJC_DB`)
    public var explicitCopy: URL?
    /// 쓰기·복원 대상 rekordbox DB(앱은 라이브 master.db, 시험은 합성 사본)
    public var database: URL
    /// 쓰기 대상의 분석 파일 뿌리. nil이면 대상 옆 share(쓰기 관문이 고른다)
    public var shareRoot: URL?
    /// 쓰기 전 백업 폴더
    public var backupDirectory: URL
    /// 초안 폴더(앱은 DJCrate 데이터 폴더)
    public var draftHome: URL
    /// 읽지 못하는 초안 파일을 `damaged-drafts`로 옮기고 알릴지. 앱만 켠다(#174: 시험이 사용자 폴더의 파일을 옮기지 않게)
    public var movesDamagedDrafts: Bool

    public init(rekordboxDirectory: URL, rekordboxDirectoryOverridden: Bool, snapshotDirectory: URL, opensExplicitCopy: Bool,
                explicitCopy: URL?, database: URL, shareRoot: URL?, backupDirectory: URL, draftHome: URL, movesDamagedDrafts: Bool) {
        self.rekordboxDirectory = rekordboxDirectory
        self.rekordboxDirectoryOverridden = rekordboxDirectoryOverridden
        self.snapshotDirectory = snapshotDirectory
        self.opensExplicitCopy = opensExplicitCopy
        self.explicitCopy = explicitCopy
        self.database = database
        self.shareRoot = shareRoot
        self.backupDirectory = backupDirectory
        self.draftHome = draftHome
        self.movesDamagedDrafts = movesDamagedDrafts
    }

    /// 라이브 master.db: 바뀌었는지 확인하고 스냅샷을 뜨는 원본(읽기만 한다)
    public var liveDatabase: URL { rekordboxDirectory.appending(path: "master.db") }
    /// 라이브 share: 복구가 현재값을 읽는 분석 파일 뿌리
    public var liveShare: URL { rekordboxDirectory.appending(path: "share") }

    /// 스냅샷을 새로 떠도 되는지. 명시한 사본으로 열었는데 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)가 없으면 거짓:
    /// 그때 뜨면 라이브 master.db를 원본으로 읽고 사용자 스냅샷 폴더에 새 사본을 만들고 옛 사본을 정리한다(`DJC_HOME`은 스냅샷을 옮기지 않는다).
    public var allowsSnapshot: Bool { !(opensExplicitCopy && !rekordboxDirectoryOverridden) }

    /// Music(iTunes) 목록을 조회해도 되는지(사본 rekordbox 폴더로 띄웠으면 조회하지 않는다)
    public var mayCaptureMusic: Bool { !rekordboxDirectoryOverridden }

    /// iTunes 동기화가 쓰는 rekordbox DB: 명시한 사본으로 열었으면 그 사본(`opened`), 아니면 라이브 master.db
    public func iTunesSyncTarget(opened: URL) -> URL { opensExplicitCopy ? opened : liveDatabase }
}

/// 라이브 rekordbox DB에서 읽기용 스냅샷 사본을 뜨는 일(포트). 실제 구현은 DJCAdapters(`SnapshotTaker.live(_:)`)가 주고 조립 지점이 고른다.
public struct SnapshotTaker: Sendable {
    /// 사본을 떠서 그 경로를 돌려준다. `force`면 rekordbox가 켜져 있거나 WAL이 남아 있어도 뜬다(사본 안에서 합친다)
    public var take: @Sendable (_ force: Bool) throws -> URL

    public init(take: @escaping @Sendable (_ force: Bool) throws -> URL) {
        self.take = take
    }
}
