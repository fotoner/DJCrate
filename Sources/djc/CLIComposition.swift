import DJCAdapters
import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCStorage
import Foundation
import RekordboxKit

/// CLI 조립 지점: 환경을 한 번 풀어 라이브러리 위치(라이브 DB·백업·초안 폴더)를 정하고, 명령이 쓰는 포트의 실제 구현
/// (rekordbox 쓰기 관문·초안 저장소)을 만든다. 앱의 `AppComposition`과 같은 어댑터(DJCAdapters)를 쓴다.
/// 명령은 실제 구현을 스스로 고르지 않고 여기서 받는다. rekordbox 쓰기 명령은 앱과 같은 반영 세션(`reflection`)을 쓴다.
struct CLIComposition: Sendable {
    /// 위치. CLI의 `--db`는 명령마다 고르는 쓰기·읽기 대상이라 위치 값의 명시 사본으로 풀지 않는다(환경만 본다).
    let location: LibraryLocation
    /// 데이터 폴더의 초안 저장소(이 프로세스의 저장 큐 하나)
    let drafts: DraftStore
    /// rekordbox 쓰기 관문
    let writeGate: RekordboxWriteGate

    init(environment: [String: String]) {
        location = .resolve(arguments: [], environment: environment)
        drafts = .live(writer: DraftWriter(), home: location.draftHome)
        writeGate = .live()
    }

    /// 이 프로세스의 조립(처음 쓸 때 한 번 만든다)
    static let live = CLIComposition(environment: ProcessInfo.processInfo.environment)

    /// 옛 이름(anicue) 데이터 폴더 옮기기(명령을 실행하기 전에 한 번)
    static func migrateLegacyData() { LegacyMigration.run() }

    /// 라이브 쓰기 전 확인(`djc compat`): 설치된 rekordbox와 라이브러리 사본을 읽기만 한다
    static var compatibilityCheck: CompatibilityCheck { CompatibilityCheck(ports: .live) }

    /// 이 프로세스의 캐시 자리(`DJC_HOME`을 따른다)와 캐시 폴더(`djc cache`)
    static var cachePaths: DJCCachePaths { .current }
    static var cache: CacheFiles { .live }

    /// 데이터 폴더의 시점 스냅샷 폴더(`djc snapshot-point --live`)
    static var pointSnapshotsDirectory: URL { DJCPaths.pointSnapshots }

    /// 자동 시점 스냅샷 보관 일수: 앱 설정(설정 › 저장 공간)이 데이터 폴더의 공유 파일에 적어 둔 값(시험은 파일을 바꿔 넣는다)
    static func pointSnapshotAutoDays(sharedSettings: URL? = nil) -> Int {
        Int(SharedSettingsFile.value(SettingKeys.pointSnapshotAutoDays, in: sharedSettings ?? SharedSettingsFile.file))
    }

    /// 시점 스냅샷 유스케이스(앱 창과 같은 것). 대상·스냅샷 폴더는 명령이 고른다
    /// - Parameter files: 라이브 판정을 바꿔 시험하는 명령만 준다
    func pointSnapshots(_ target: RekordboxWriteTarget, directory: URL, files: PointSnapshotFiles? = nil) -> PointSnapshots {
        PointSnapshots(database: target.database, shareRoot: target.shareRoot, directory: directory, backupDirectory: target.backups,
                       files: files ?? .live(), backups: .live())
    }

    /// 라이브 rekordbox 분석 폴더(share). 쓰기 명령의 거부 판정(`CLIGuards.refuseLiveShare`)이 비교한다
    static var liveShare: URL { LibrarySnapshot.rekordboxDirectory.appending(path: "share") }

    /// 라이브러리 유스케이스(XML 가져오기·내보내기 …): 앱과 같은 포트 실제 구현. `home`을 주면 그 초안 폴더(시험·`xml-diff --draft`)
    func library(home: URL? = nil) -> LibraryUseCases {
        var location = location
        var drafts = drafts
        if let home {
            location.draftHome = home
            drafts = .live(writer: DraftWriter(), home: home)
        }
        return LibraryUseCases(ports: .live(location: location, drafts: drafts,
                                            batches: .live(url: DraftLocations(home: location.draftHome).reflection)))
    }

    /// 곡 파트 분석(`djc analyze`): 사본을 주지 않으면 위치 값의 스냅샷 폴더에서 최신 스냅샷을 읽는다
    func analyzeParts() -> AnalyzeParts {
        AnalyzeParts(source: .live, files: .live, tools: .live, snapshotDirectory: location.snapshotDirectory)
    }

    /// 곡 넣기 준비(`djc track-add`): 태그·넣기 계획·그리드 추정·음량(캐시 없이 매번 잰다)
    static func trackAddPreparation() -> PrepareTrackAdd {
        PrepareTrackAdd(audio: .measuring, analysis: .live, measureLoudness: { try Loudness.measure(fileAt: $0) })
    }

    /// 사본 DB의 구조(CREATE 문)와 DB 버전(`djc schema-dump`)
    static func schema(of database: String) throws -> (statements: [String], version: String) {
        try RekordboxSchema.dump(database: database)
    }

    /// 초안을 쓸 데이터 폴더(DJC_HOME, 없으면 사용자 데이터 폴더)의 실제 경로
    static var resolvedDraftHome: URL { DJCPaths.userData.resolvingSymlinksInPath().standardizedFileURL }

    /// 초안을 쓸 데이터 폴더(DJC_HOME, 없으면 사용자 데이터 폴더). 링크를 따라 초안 폴더 밖을 고치지 않는다(`djc draft`와 같은 확인).
    static func checkedDraftHome() throws -> URL {
        let home = resolvedDraftHome
        for name in ["cue-drafts", "grid-drafts", "tag-drafts", "playlist-drafts.json"] {
            let url = home.appending(path: name)
            guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
                throw ReadFailure("invalid_arguments", String(ui: "초안 폴더나 파일의 심볼릭 링크를 해제하세요"))
            }
        }
        return home
    }

    /// 라이브 판정(`RekordboxWriteGuard`)을 바꿔 시험하는 명령의 관문(시점 스냅샷 복원)
    func writeGate(guard writeGuard: RekordboxWriteGuard) -> RekordboxWriteGate { .live(guard: writeGuard) }

    /// rekordbox 쓰기 명령의 반영 세션: 앱과 같은 유스케이스, 같은 관문·백업 폴더·초안 저장소. CLI는 화면이 없어 잠금·다시 읽기·결과 알리기가 없고,
    /// 확인은 플래그가 곧 동의다. 쓴 초안 정리·복원 때 되살리기는 하지 않는다(`liveCLI`, 앱과 다름, 사용자 결정 대기).
    /// - Parameter gate: 라이브 판정을 바꿔 시험하는 명령만 준다(시점 스냅샷 복원)
    @MainActor
    func reflection(gate: RekordboxWriteGate? = nil) -> ReflectionSession {
        ReflectionSession(location: location,
                          ports: ReflectionPorts(gate: gate ?? writeGate, backups: .live(), drafts: drafts, snapshots: .live(location), audio: .measuring,
                                                 library: .none, reload: .none, lock: .none, confirmation: .agreeing, results: .none,
                                                 runningApps: .live, playlistImports: .none),
                          options: .liveCLI)
    }
}
