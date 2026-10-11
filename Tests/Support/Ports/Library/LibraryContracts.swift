import DJCApplication
import DJCDomain
import Foundation
import Testing

func contractCueDraft(_ uuid: String, changed: Bool) -> CueDraft {
    var draft = CueDraft(trackUUID: uuid)
    if changed { draft.place(EditableCue(kind: .hot(1), time: 4)) }
    return draft
}

func contractGridDraft(_ uuid: String, changed: Bool) -> GridDraft {
    let base = [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)]
    return GridDraft(trackUUID: uuid, base: base, segments: changed ? [GridSegment(start: 0.2, bpm: 124, firstBeatNumber: 1)] : base)
}

func contractTagDraft(_ uuid: String, comment: String?) -> TagDraft {
    var draft = TagDraft(trackUUID: uuid, base: TagFields())
    if let comment { draft.fields.comment = comment }
    return draft
}

/// 초안 저장소(`DraftStore`): 고친 초안은 남고 고친 것이 없는 초안 저장은 지우기다. 게인은 모든 곡이 한 묶음, 저장이 끝나면 대기·실패가 없다
/// (adv4 T7: 가짜만 고친 것이 없는 초안을 남겨 실제와 갈렸다).
@MainActor
public func draftStoreContract(_ store: DraftStore) throws {
    #expect(store.cueDraftUUIDs().isEmpty && store.currentCue("a") == nil && store.currentGain("a") == nil)
    let before = store.saveRevision()

    let cue = contractCueDraft("a", changed: true)
    store.saveCue(cue)
    store.flush()
    #expect(store.cueDraft("a") == cue && store.currentCue("a") == cue && store.cueDraftUUIDs() == ["a"])
    #expect(store.saveRevision() > before)
    store.saveCue(contractCueDraft("a", changed: false))
    store.flush()
    #expect(store.cueDraft("a") == nil && store.cueDraftUUIDs().isEmpty)

    // 그리드: 같은 규칙, 지우기는 빈 초안 저장
    let grid = contractGridDraft("g", changed: true)
    store.saveGrid(grid)
    store.saveGrid(contractGridDraft("h", changed: false))
    store.flush()
    #expect(store.gridDraft("g") == grid && store.currentGrid("g") == grid && store.gridDraftUUIDs() == ["g"])
    store.removeGrid("g")
    store.flush()
    #expect(store.gridDraft("g") == nil && store.gridDraftUUIDs().isEmpty)

    // 게인: nil은 지우기
    store.saveGain(-3, trackUUID: "x")
    store.saveGain(-5, trackUUID: "y")
    store.removeGain("x")
    store.flush()
    #expect(try store.gainDrafts() == ["y": -5] && store.gainDraftUUIDs() == ["y"] && store.currentGain("y") == -5)

    let tag = contractTagDraft("t", comment: "코멘트")
    store.saveTags([tag, contractTagDraft("u", comment: nil)])
    store.flush()
    #expect(store.tagDraft("t") == tag && store.tagDraftUUIDs() == ["t"] && store.failedTagSaves().isEmpty)

    #expect(store.unsavedUUIDs().isEmpty && store.unsaved().isEmpty && store.failures().isEmpty)

    // 화면이 들고 있는 메모리 초안
    var playlist = PlaylistDraft()
    _ = try playlist.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
    try store.savePlaylistDraft(playlist)
    #expect(store.playlistDraft() == playlist)
    try store.saveMergeDrafts([])
    #expect(store.mergeDrafts().isEmpty)
}

/// 추가 목록(`StagingStore`): 저장한 목록을 그대로 읽고, 경로는 NFC로 견주며, 고치기는 읽기·고치기·저장 한 번이다
@MainActor
public func stagingStoreContract(_ staging: StagingStore) throws {
    #expect(staging.tracks().isEmpty)
    let staged = [StagedTrack(uuid: "s", path: "/곡.mp3", title: "곡", duration: 60, addedOn: "2026-10-09")]
    try staging.save(staged)
    #expect(staging.tracks() == staged)
    #expect(staging.contains(path: "/곡.mp3".decomposedStringWithCanonicalMapping))
    try staging.update { $0.removeAll() }
    #expect(staging.tracks().isEmpty)
}

/// 곡별 초안 파일(`DraftFiles`, XML 가져오기·CLI 초안 고치기): 고친 것이 없는 초안 저장은 파일을 남기지 않고, 저장한 것을 같게 읽으며, 지우면 없다
public func draftFilesContract(_ files: DraftFiles) throws {
    #expect(!files.exists(.cue, "u") && !files.exists(.playlist, "u") && files.isPlainPath(.tag, "u"))
    #expect(try files.cue("u") == nil)
    #expect(try files.tag("u") == nil)
    var cue = CueDraft(trackUUID: "u")
    try files.saveCue(cue)
    #expect(!files.exists(.cue, "u"))
    cue.cues = [EditableCue(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, kind: .memory, time: 3)]
    var tag = TagDraft(trackUUID: "u", base: TagFields())
    tag.fields.title = "제목"
    try files.saveCue(cue)
    try files.saveTag(tag)
    try files.saveGrid(GridDraft(trackUUID: "u", base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]))
    #expect(files.exists(.cue, "u") && files.exists(.tag, "u") && files.exists(.grid, "u"))
    #expect(try files.cue("u") == cue)
    #expect(try files.tag("u") == tag)
    try files.removeTag("u")
    #expect(!files.exists(.tag, "u"))
    #expect(try files.tag("u") == nil)
    var playlist = PlaylistDraft()
    try playlist.append(.create(key: "k", name: "목록", isFolder: false, parent: PlaylistRef(PlaylistLayout.root)), rekordbox: PlaylistLayout())
    #expect(files.playlist().isEmpty)
    try files.savePlaylist(playlist)
    #expect(files.playlist() == playlist)
}

/// 재생 목록 연결 기록(`PlaylistImportsStore`): 처음은 비어 있고, 기억하는 구현은 저장한 것을 그대로 읽는다(`.none`은 늘 비어 있다)
public func playlistImportsContract(_ store: PlaylistImportsStore, remembers: Bool) throws {
    #expect(try store.load() == PlaylistImports())
    var imports = PlaylistImports()
    imports.addFiles(["/m/a.mp3"], to: PlaylistRef("P"))
    try store.save(imports)
    #expect(try store.load() == (remembers ? imports : PlaylistImports()))
}

/// 라이브러리 읽기(`LibrarySource`): `newest`가 가장 최근 사본인 폴더 `directory`, 곡 `ids`가 든 라이브러리.
/// 없는 사본은 던지고, 분석 파일 경로가 없거나 파일이 없으면 그리드도 없다
public func librarySourceContract(_ source: LibrarySource, directory: URL, newest: URL, ids: Set<String>) throws {
    #expect(Set(try source.library(newest).tracks.map(\.id)) == ids)
    #expect(throws: (any Error).self) { try source.library(directory.appending(path: "master-없음.db")) }
    // 폴더 나열은 `/private` 같은 실제 경로로 돌려줄 수 있어 이름으로 견준다
    #expect(try source.latestSnapshot(directory).lastPathComponent == newest.lastPathComponent)
    #expect(source.snapshots(directory).map(\.lastPathComponent).contains(newest.lastPathComponent))
    #expect(source.grid(nil, directory) == nil && source.grid("/PIONEER/USBANLZ/없음/ANLZ0000.DAT", directory) == nil)
    #expect(source.tempoChanges(try source.library(newest).tracks, directory).allSatisfy(\.isEmpty))
}

/// Music 목록 사본(`MusicLibrarySource`): 목록 사본을 둘 DB `database`, 동기화 파일이 없는 rekordbox 폴더 `directory`.
/// 저장한 사본을 같게 읽고, 동기화 파일이 없으면 원문이 없으며, 해석할 수 없는 원문은 적용하지 않는다
public func musicLibrarySourceContract(_ music: MusicLibrarySource, database: URL, directory: URL) throws {
    #expect(music.cached(database).status == .notCaptured)
    var snapshot = ITunesLibrarySnapshot(playlists: [.init(id: "A1", name: "목록", paths: ["/music/a.mp3"])])
    snapshot.syncData = Data("선택".utf8)
    try music.save(snapshot, database)
    #expect(music.cached(database) == snapshot)
    #expect(music.syncFile(directory) == nil)
    #expect(!music.selectionChanged(nil, directory))
    #expect(music.selectionChanged(Data("선택".utf8), directory))
    #expect(throws: (any Error).self) { try music.applySelection(snapshot, Data([0xFF, 0xFE])) }
}

/// rekordbox XML 파일(`XMLFiles`)의 파일 쪽 약속: 없는 파일 읽기는 `XMLReadError`, 자리의 종류(없음·파일·폴더),
/// 내보낼 자리 확인(이름은 .xml이고 있는 폴더 안, 폴더 자체는 거부), 추가한 곡 XML을 쓰면 그 자리에 파일이 생긴다.
/// `folder`는 비어 있는 폴더. 형식(요소·값)은 어댑터 시험이 따로 본다
public func xmlFilesContract(_ files: XMLFiles, folder: URL) throws {
    let out = folder.appending(path: "추가.xml")
    #expect(files.item(out) == .none && files.item(folder) == .directory)
    #expect(throws: XMLReadError.self) { try files.read(out) }
    try files.checkOutput(out)
    #expect(throws: LibraryXMLOutputError.self) { try files.checkOutput(folder.appending(path: "추가.txt")) }
    #expect(throws: LibraryXMLOutputError.self) { try files.checkOutput(folder.appending(path: "없는-폴더/추가.xml")) }
    #expect(throws: LibraryXMLOutputError.self) { try files.checkOutput(folder) }
    let track = StagedTrack(uuid: "s", path: "/music/곡.mp3", title: "곡", duration: 60, addedOn: "2026-10-09")
    try files.writeStaged([StagedXMLEntry(track: track, tempos: [], cues: [])], "DJCrate 추가", out)
    #expect(files.item(out) == .file)
}
