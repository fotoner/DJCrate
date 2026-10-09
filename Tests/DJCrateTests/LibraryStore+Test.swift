@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Synchronization

extension LibraryStore {
    /// 시험 저장소(조립 지점 대신). 주지 않은 값: 설정은 저장소마다 새 시험 영역(`TestDefaults`, 사용자 계정의 표준 영역을 쓰지 않는다),
    /// 초안·백업 폴더는 저장소마다 새 임시 폴더(공용 데이터 폴더를 쓰면 병렬로 도는 시험끼리 초안·백업이 섞인다),
    /// 쓰기 대상·스냅샷은 이 프로세스의 rekordbox 폴더(시험 프로세스는 임시 폴더, #182),
    /// 쓰기 관문은 실제 관문(`testReflection`으로 바꾼다).
    /// 저장 큐(`DraftWriter`)는 저장소마다 새로 만든다(다른 시험의 저장을 기다리지 않게). 같은 큐를 덱·시험과 나누려면 `writer`를 준다.
    /// - Parameters:
    ///   - arguments: 위치 값을 풀 실행 인자(명시 사본 `--db`)
    ///   - environment: 위치 값을 풀 환경(`DJC_REKORDBOX_DIR`·`DJC_DB`). 쓰기 대상·백업·초안 폴더는 따로 준 값(또는 이 프로세스의 값)이다
    ///   - backupDirectory: rekordbox 쓰기 백업 폴더. 앱 기본 폴더(`DJCPaths.rekordboxBackups`)를 볼 시험은 그 값을 준다
    ///   - draftHome: 초안 폴더. 주면 손상된 초안 파일도 옮긴다(앱처럼, `movesDamagedDrafts`로 바꿀 수 있다).
    ///     앱 데이터 폴더(`DJCPaths.userData`)를 나눠 쓸 시험은 그 값을 준다
    ///   - location: 실행 인자·환경 대신 직접 만든 위치(쓰기 대상·백업·초안 폴더는 위 인자가 덮는다)
    ///   - takeLiveSnapshot: 스냅샷 뜨기(주지 않으면 이 프로세스의 rekordbox 폴더에서 뜬다)
    ///   - ports: 라이브러리 포트(실제 구현)를 바꾼다(메모리 라이브러리·가짜 Music 등)
    static func test(settings: SettingsStore = SettingsStore(defaults: TestDefaults.make("library-store")),
                     resultHistory: WriteResultHistory? = nil,
                     reflectionBatches: ReflectionBatchStore? = nil,
                     feedback: AppFeedback = AppFeedback(),
                     saveTagDrafts: (([TagDraft]) -> Void)? = nil,
                     backupDirectory: URL? = nil,
                     playlistDraftSaver: ((PlaylistDraft) throws -> Void)? = nil,
                     mergeDraftSaver: (([DuplicateMergeDraft]) throws -> Void)? = nil,
                     playlistImportURL: URL? = PlaylistImportStore.url,
                     stagingSaver: (([StagedTrack]) throws -> Void)? = nil,
                     draftHome: URL? = nil,
                     movesDamagedDrafts: Bool? = nil,
                     writeGate: RekordboxWriteGate? = nil,
                     rekordboxDatabase: URL? = nil,
                     rekordboxShareRoot: URL? = nil,
                     arguments: [String] = ProcessInfo.processInfo.arguments,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     location: LibraryLocation? = nil,
                     takeLiveSnapshot: (@Sendable (Bool) throws -> URL)? = nil,
                     writer: DraftWriter = DraftWriter(),
                     launch: LibraryLaunchOptions = LibraryLaunchOptions(),
                     ports: ((inout LibraryPorts) -> Void)? = nil) -> LibraryStore {
        let home = draftHome ?? freshTestFolder("drafts")
        var location = location ?? LibraryLocation.resolve(arguments: arguments, environment: environment)
        location.database = rekordboxDatabase ?? RekordboxWriter.liveDatabase
        location.shareRoot = rekordboxShareRoot
        location.backupDirectory = backupDirectory ?? freshTestFolder("backups")
        location.draftHome = home
        location.movesDamagedDrafts = movesDamagedDrafts ?? (draftHome != nil)
        var drafts = DraftStore.live(writer: writer, home: home)
        if let saveTagDrafts { drafts.saveTags = { saveTagDrafts($0) } }
        if let playlistDraftSaver { drafts.savePlaylistDraft = { try playlistDraftSaver($0) } }
        if let mergeDraftSaver { drafts.saveMergeDrafts = { try mergeDraftSaver($0) } }
        let places = DraftLocations(home: home)
        // 라이브러리 포트는 조립 지점과 같은 실제 구현이다. 시험이 `ports`로 일부(라이브러리 읽기·Music 등)를 바꾼다.
        var libraryPorts = LibraryPorts.live(location: location, drafts: drafts,
                                             batches: reflectionBatches ?? .live(url: DraftLocations(home: home).reflection))
        if let stagingSaver { libraryPorts.staging.save = { try stagingSaver($0) } }
        // 재생 목록 연결 기록: 기본은 이 초안 폴더의 파일, nil이면 기록하지 않는다
        let importURL = playlistImportURL == PlaylistImportStore.url ? places.playlistImports : playlistImportURL
        libraryPorts.playlistImports = importURL.map { .live(url: $0) } ?? .none
        libraryPorts.snapshots = SnapshotTaker(take: takeLiveSnapshot ?? { try LibrarySnapshot.take(force: $0) })
        ports?(&libraryPorts)
        let store = LibraryStore(settings: settings, location: location, useCases: LibraryUseCases(ports: libraryPorts),
                                 resultHistory: resultHistory ?? WriteResultHistory(url: places.writeResult),
                                 feedback: feedback, launch: launch)
        testPortTable[ObjectIdentifier(store)] = (WeakStore(store: store), libraryPorts)
        // rekordbox 쓰기는 조립 지점과 같은 연결로 붙인다(iTunes 동기화 쓰기도 이 세션으로 간다). 관문은 `writeGate`, 없으면 실제 관문.
        if let writeGate { store.testReflection.gate = writeGate }
        _ = store.reflection
        return store
    }
}

/// 저장소마다 새 임시 폴더 자리(만들지는 않는다. 초안 저장·백업이 쓸 때 만든다)
private func freshTestFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "djc-test-library-store-\(UUID().uuidString)").appending(path: name)
}

/// 시험 저장소를 만들 때 쓴 라이브러리 포트(저장소는 포트를 들지 않는다. 시험만 이 표로 찾는다)
@MainActor private var testPortTable: [ObjectIdentifier: (store: WeakStore, ports: LibraryPorts)] = [:]

private struct WeakStore {
    weak var store: LibraryStore?
}

extension LibraryStore {
    /// 이 시험 저장소의 라이브러리 포트(초안 저장 큐·추가 목록 파일을 시험이 직접 보거나 고칠 때). `LibraryStore.test`로 만든 저장소만 있다
    var testPorts: LibraryPorts {
        guard let entry = testPortTable[ObjectIdentifier(self)], entry.store.store === self else {
            preconditionFailure("LibraryStore.test로 만든 저장소만 시험 포트가 있습니다")
        }
        return entry.ports
    }

    /// 이 시험 저장소의 초안 저장소(덱·반영과 같은 저장 큐)
    var testDrafts: DraftStore { testPorts.drafts }

    /// 이 저장소의 초안 파일 자리(시험이 디스크를 직접 확인할 때)
    var draftLocations: DraftLocations { DraftLocations(home: draftFolder) }
    var tagDraftDirectory: URL { draftLocations.tags }
    var artworkDirectory: URL { draftLocations.artwork }
    var mergeDraftURL: URL { draftLocations.merge }
    var stagedListURL: URL { draftLocations.staged }
}

extension LibraryStore {
    /// 시험: 반영 세션이 쓴 뒤 하는 재생 목록 정리(쓴 편집을 뺀 초안·새 목록 ID를 이은 연결 기록 저장, `EditPlaylists.finishWrite`)와 화면 맞추기
    func finishPlaylistWrite(_ written: PlaylistDraft, outcomes: [PlaylistOutcome]) {
        applyReflection(.playlistWritten(useCases.playlists.finishWrite(written, outcomes: outcomes, current: playlistDraft, imports: playlistImports,
                                                                         importsLoadFailed: playlistImportsLoadFailed)))
    }

    /// 시험: 곡 넣기를 되돌린 뒤 반영 세션이 하는 연결 기록·초안 편집 잊기(`EditPlaylists.resetImports`)와 화면 맞추기
    func resetPlaylistImports(contentIDs: Set<String>) {
        guard !contentIDs.isEmpty else { return }
        applyReflection(.playlistImportsReset(useCases.playlists.resetImports(contentIDs: contentIDs, draft: playlistDraft,
                                                                               rekordbox: rekordboxPlaylists, imports: playlistImports,
                                                                               importsLoadFailed: playlistImportsLoadFailed)))
    }

    /// 시험: 쓴 뒤·복원 뒤 반영 세션이 하는 태그 초안 저장(`ReflectionSession.replaceTagDrafts`, 넘길 초안이 있을 때만)과 화면 맞추기
    func replaceTagDraftsAfterWrite(_ tags: [TagDraft]) {
        guard !tags.isEmpty else { return }
        useCases.watch.saveTags(tags)
        applyReflection(.tagDrafts(tags))
    }

    /// 시험: 쓴 뒤 반영 세션이 하는 합치기 초안 저장과 화면 맞추기
    func saveMergeDraftsAfterWrite(_ drafts: [DuplicateMergeDraft]) {
        do {
            let moved = try useCases.merge.save(drafts, takingMovedFiles: location.movesDamagedDrafts)
            applyReflection(.mergeDrafts(drafts, failure: nil, moved: moved))
        } catch {
            applyReflection(.mergeDrafts(drafts, failure: error, moved: []))
        }
    }
}

/// 시험 중에 켜고 끄는 표시(스냅샷 뜨기 실패 등을 만드는 클로저가 읽는다)
final class TestSwitch: Sendable {
    private let value: Mutex<Bool>
    init(_ value: Bool = false) { self.value = Mutex(value) }
    var isOn: Bool { value.withLock { $0 } }
    func set(_ on: Bool) { value.withLock { $0 = on } }
}

extension DraftStore {
    /// 옛 `LoadedLibrary.load` 기본값과 같은 초안 저장소: 이 프로세스의 데이터 폴더(시험은 `DJC_HOME` 또는 임시 폴더)와 새 저장 큐
    static func dataFolder() -> DraftStore { .live(writer: DraftWriter(), home: DJCPaths.userData) }
}
