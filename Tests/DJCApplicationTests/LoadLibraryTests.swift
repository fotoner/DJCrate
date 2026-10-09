import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 라이브러리 읽기(유스케이스). 암호화 DB·Music 없이 메모리 라이브러리·메모리 Music·메모리 초안으로 시험한다.
@Suite("라이브러리 읽기")
struct LoadLibraryTests {
    static let root = URL(filePath: "/fake/rekordbox")
    static let snapshots = URL(filePath: "/fake/snapshots")

    static func location(explicitCopy: URL? = nil, overridden: Bool = false) -> LibraryLocation {
        LibraryLocation(rekordboxDirectory: root, rekordboxDirectoryOverridden: overridden, snapshotDirectory: snapshots,
                        opensExplicitCopy: explicitCopy != nil, explicitCopy: explicitCopy, database: root.appending(path: "master.db"),
                        shareRoot: nil, backupDirectory: URL(filePath: "/fake/backups"), draftHome: URL(filePath: "/fake/home"),
                        movesDamagedDrafts: false)
    }

    static func track(_ id: String, path: String? = nil, analysis: String? = nil, length: Int = 180, deleted: Bool = false) -> Track {
        Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: "가수", album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 128, lengthSeconds: length, folderPath: path ?? "/music/\(id).mp3",
              comment: "", importedOn: "2026-01-01", analysisDataPath: analysis, imagePath: nil, isDeleted: deleted)
    }

    static func library(_ tracks: [Track], playlists: [RekordboxPlaylist] = [], cues: [Cue] = []) -> RekordboxLibrary {
        RekordboxLibrary(allTracks: tracks, cues: cues, playCounts: ["1": 3], playlists: playlists)
    }

    static func grid(_ bpms: [Double]) -> BeatGrid {
        BeatGrid(beats: bpms.enumerated().map { BeatGrid.Beat(number: $0.offset % 4 + 1, bpm: $0.element, time: Double($0.offset) * 0.5) })
    }

    static func catalog() -> [ITunesLibrarySnapshot.Playlist] {
        [ITunesLibrarySnapshot.Playlist(id: "A", name: "목록 A", paths: ["/music/1.mp3"]),
         ITunesLibrarySnapshot.Playlist(id: "B", name: "목록 B", paths: ["/music/2.mp3"])]
    }

    static func loader(_ libraries: [URL: RekordboxLibrary], music: MemoryMusicLibrary = MemoryMusicLibrary(),
                       drafts: MemoryDrafts = MemoryDrafts(), grids: [String: BeatGrid] = [:], latest: URL? = nil,
                       changed: Bool = false) -> LoadLibrary {
        LoadLibrary(source: .memory(libraries, grids: grids, latest: latest, changed: changed), music: music.source,
                    drafts: drafts.store, order: ITunesRefreshCoordinator(), snapshots: SnapshotTaker { _ in throw DJCError.snapshotNotFound },
                    usbSnapshots: UsbSyncSnapshots(stamp: { _ in throw DJCError.snapshotNotFound }, lease: { _, _ in throw DJCError.snapshotNotFound }))
    }

    // MARK: - 읽기

    @Test func 사본을_읽어_곡_줄_재생_목록_변속_초안_중복을_한_값으로_만든다() throws {
        let snapshot = Self.snapshots.appending(path: "master-2026-01-01T000000.db")
        let tracks = [Self.track("1", analysis: "/A/1.DAT"), Self.track("2"), Self.track("3", path: "/music/1 copy.mp3"),
                      Self.track("9", deleted: true)]
        let playlist = RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false, trackIDs: ["2"])
        let drafts = MemoryDrafts()
        var tag = TagDraft(trackUUID: "u2", base: TagFields())
        tag.fields.title = "새 제목"
        drafts.save(tag)
        let loader = Self.loader([snapshot: Self.library(tracks, playlists: [playlist])], drafts: drafts,
                                 grids: ["/A/1.DAT": Self.grid(Array(repeating: 120, count: 16) + Array(repeating: 130, count: 16))])

        let loaded = try loader.read(LoadLibrary.Request(snapshot: snapshot, fallbackDirectory: Self.snapshots))

        #expect(loaded.rows.map(\.track.id) == ["1", "2", "3"])
        #expect(loaded.rows.first { $0.track.id == "2" }?.inPlaylist == true)
        #expect(loaded.rows.first { $0.track.id == "1" }?.inPlaylist == false)
        #expect(loaded.rows.first { $0.track.id == "1" }?.playCount == 3)
        #expect(loaded.rows.first { $0.track.id == "1" }?.tempoChanges == [120, 130])
        #expect(loaded.playlists.item("P")?.trackIDs == ["2"])
        #expect(loaded.tagDrafts["u2"]?.fields.title == "새 제목")
        #expect(loaded.filterCounts[.all] == 3)
        #expect(loaded.report.liveTracks == 3 && loaded.report.deletedRows == 1)
        // 음원을 읽지 않은 사본 옆 목록이 없으면 미캡처
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
    }

    @Test func 사본을_읽지_못하면_던진다() {
        let loader = Self.loader([:])
        #expect(throws: (any Error).self) {
            try loader.read(LoadLibrary.Request(snapshot: URL(filePath: "/none.db"), fallbackDirectory: Self.snapshots))
        }
    }

    @Test func 읽기_전에_저장을_끝내고_앱만_손상_파일을_옮긴다() {
        let drafts = MemoryDrafts()
        let loader = Self.loader([:], drafts: drafts)
        #expect(loader.settleDrafts(preservingDamaged: false).isEmpty)
        #expect(loader.settleDrafts(preservingDamaged: true).isEmpty)
    }

    // MARK: - 어떤 사본을 읽을지

    @Test func 명시한_사본이_있으면_그_사본을_연다() {
        let copy = URL(filePath: "/copies/master.db")
        #expect(Self.loader([:]).initialRead(location: Self.location(explicitCopy: copy), snapshotDirectory: Self.snapshots)
            == .explicitCopy(copy))
    }

    @Test func 스냅샷이_없으면_읽지_않는다() {
        #expect(Self.loader([:]).initialRead(location: Self.location(), snapshotDirectory: Self.snapshots) == .none)
    }

    @Test func 사본_옆_목록이_지금_선택과_같으면_Music을_바로_읽지_않는다() {
        let latest = Self.snapshots.appending(path: "master-2026-01-02T000000.db")
        let music = MemoryMusicLibrary()
        music.setSelection(["A"], in: Self.root)
        var cached = ITunesLibrarySnapshot(sourcePlaylists: Self.catalog())
        cached.syncData = MemoryMusicLibrary.syncData(["A"])
        music.setCached(cached, for: latest)
        let loader = Self.loader([:], music: music, latest: latest)
        let liveDB = Self.root.appending(path: "master.db")

        #expect(loader.initialRead(location: Self.location(), snapshotDirectory: Self.snapshots)
            == .latest(latest, refreshMusic: false, sourceDatabase: liveDB, hasCurrentCatalog: true))
        // 동기화 선택이 바뀌었으면 Music을 함께 읽는다
        music.setSelection(["B"], in: Self.root)
        #expect(loader.initialRead(location: Self.location(), snapshotDirectory: Self.snapshots)
            == .latest(latest, refreshMusic: true, sourceDatabase: liveDB, hasCurrentCatalog: false))
        // 사본 rekordbox 폴더(`DJC_REKORDBOX_DIR`)면 Music을 읽지 않는다
        #expect(loader.initialRead(location: Self.location(overridden: true), snapshotDirectory: Self.snapshots)
            == .latest(latest, refreshMusic: false, sourceDatabase: liveDB, hasCurrentCatalog: false))
        // 다른 폴더의 사본은 원본 DB를 모른다
        let elsewhere = URL(filePath: "/other")
        #expect(loader.initialRead(location: Self.location(), snapshotDirectory: elsewhere)
            == .latest(latest, refreshMusic: true, sourceDatabase: nil, hasCurrentCatalog: false))
    }

    @Test func 라이브러리가_바뀌면_새_사본_선택만_바뀌면_Music만_다시_읽는다() {
        let snapshot = Self.snapshots.appending(path: "master-2026-01-02T000000.db")
        let music = MemoryMusicLibrary()
        music.setSelection(["A"], in: Self.root)
        let unchanged = Self.loader([:], music: music)
        let same = MemoryMusicLibrary.syncData(["A"])
        #expect(unchanged.change(since: snapshot, location: Self.location(), musicSyncData: same, refreshingMusic: false) == .none)
        #expect(unchanged.change(since: snapshot, location: Self.location(), musicSyncData: nil, refreshingMusic: false) == .musicSelection)
        // 이미 이 읽기의 Music 최신화가 돌고 있거나 사본 폴더 실행이면 Music을 다시 읽지 않는다
        #expect(unchanged.change(since: snapshot, location: Self.location(), musicSyncData: nil, refreshingMusic: true) == .none)
        #expect(unchanged.change(since: snapshot, location: Self.location(overridden: true), musicSyncData: nil, refreshingMusic: false) == .none)
        let changed = Self.loader([:], music: music, changed: true)
        #expect(changed.change(since: snapshot, location: Self.location(), musicSyncData: same, refreshingMusic: true) == .library)
    }

    @Test func 원본_DB는_라이브에서_뜬_사본만_안다() {
        let loader = Self.loader([:])
        let inSnapshots = Self.snapshots.appending(path: "master-1.db")
        #expect(loader.sourceDatabase(of: inSnapshots, location: Self.location()) == Self.root.appending(path: "master.db"))
        #expect(loader.sourceDatabase(of: URL(filePath: "/elsewhere/master-1.db"), location: Self.location()) == nil)
        #expect(loader.sourceDatabase(of: inSnapshots, location: Self.location(explicitCopy: inSnapshots)) == nil)
    }

    @Test func 새_사본을_뜨기_전에_지금_목록을_붙든다() {
        let current = Self.snapshots.appending(path: "master-1.db")
        let music = MemoryMusicLibrary()
        music.setCached(ITunesLibrarySnapshot(playlists: Self.catalog()), for: current)
        let loader = Self.loader([:], music: music)
        let previous = loader.previousMusic(current: current, snapshotDirectory: Self.snapshots, location: Self.location(), refreshMusic: false)
        #expect(previous?.source == current && previous?.preferOverCurrent == true && previous?.contents.status == .ready)
        #expect(loader.previousMusic(current: current, snapshotDirectory: Self.snapshots, location: Self.location(), refreshMusic: true)?
            .preferOverCurrent == false)
        // 명시한 사본·다른 폴더의 사본은 붙들지 않는다
        #expect(loader.previousMusic(current: current, snapshotDirectory: Self.snapshots,
                                     location: Self.location(explicitCopy: current), refreshMusic: false) == nil)
        #expect(loader.previousMusic(current: URL(filePath: "/other/master-1.db"), snapshotDirectory: Self.snapshots,
                                     location: Self.location(), refreshMusic: false) == nil)
    }

    // MARK: - Music 결과 채택

    @Test func 조회한_Music을_동기화_선택에_맞춰_사본_옆에_남긴다() {
        let snapshot = Self.snapshots.appending(path: "master-2.db")
        let music = MemoryMusicLibrary()
        music.setCapture(ITunesLibrarySnapshot(sourcePlaylists: Self.catalog()))
        music.setSelection(["B"], in: Self.snapshots)
        let loader = Self.loader([:], music: music)

        let result = loader.readMusic(snapshot: snapshot, refreshMusic: true, fallbackDirectory: Self.snapshots)

        #expect(music.captureCount == 1)
        #expect(result.status == .ready)
        #expect(result.playlists.map(\.id) == ["B"])
        #expect(music.cached(snapshot) == result)
    }

    @Test func Music을_읽지_못하면_같은_폴더의_이전_목록을_낡음으로_쓴다() {
        let snapshot = Self.snapshots.appending(path: "master-3.db")
        let older = Self.snapshots.appending(path: "master-2.db")
        let music = MemoryMusicLibrary()
        music.setCapture(ITunesLibrarySnapshot(status: .unavailable))
        music.setCached(ITunesLibrarySnapshot(playlists: Self.catalog()), for: older)
        let loader = Self.loader([older: Self.library([]), snapshot: Self.library([])], music: music)

        let result = loader.readMusic(snapshot: snapshot, refreshMusic: true, fallbackDirectory: Self.snapshots)

        #expect(result.status == .stale)
        #expect(result.playlists.map(\.id) == ["A", "B"])
        // 새 사본(목록이 없던 곳)에만 낡음 표시를 남긴다
        #expect(music.cached(snapshot)?.status == .stale)
        #expect(music.cached(older)?.status == .ready)
    }

    @Test func 이전_목록도_없으면_읽지_못함이다() {
        let snapshot = Self.snapshots.appending(path: "master-3.db")
        let music = MemoryMusicLibrary()
        let loader = Self.loader([:], music: music)
        #expect(loader.readMusic(snapshot: snapshot, refreshMusic: true, fallbackDirectory: Self.snapshots).status == .unavailable)
    }

    @Test func 순서가_지난_요청은_결과를_저장하지_않고_지금_사본을_쓴다() {
        let snapshot = Self.snapshots.appending(path: "master-4.db")
        let music = MemoryMusicLibrary()
        music.setCapture(ITunesLibrarySnapshot(sourcePlaylists: Self.catalog()))
        let loader = Self.loader([:], music: music)
        let stale = loader.musicTicket(snapshot: snapshot, sourceDatabase: nil)
        _ = loader.musicTicket(snapshot: snapshot, sourceDatabase: nil)

        let result = loader.readMusic(snapshot: snapshot, refreshMusic: true, fallbackDirectory: Self.snapshots, ticket: stale)

        #expect(result.status == .notCaptured)
        #expect(music.savedDatabases.isEmpty)
    }

    @Test func 동기화_원문을_읽지_못하면_정상_목록도_낡음으로_본다() {
        let snapshot = Self.snapshots.appending(path: "master-5.db")
        let music = MemoryMusicLibrary()
        music.setCached(ITunesLibrarySnapshot(sourcePlaylists: Self.catalog()), for: snapshot)
        music.setUnreadableSelection(in: Self.snapshots)
        #expect(Self.loader([:], music: music).readMusic(snapshot: snapshot, fallbackDirectory: Self.snapshots).status == .stale)
    }

    @Test func 선택_창_첫_선택은_맨_위_선택을_원문에서_본다() {
        let loader = Self.loader([:])
        var snapshot = ITunesLibrarySnapshot(playlists: Self.catalog(), sourcePlaylists: Self.catalog(), selectedIDs: ["A"])
        snapshot.syncData = MemoryMusicLibrary.syncData(["0", "A"])
        #expect(loader.initialSelection(of: snapshot).selectedIDs == ["0", "A"])
        snapshot.syncData = MemoryMusicLibrary.syncData(["A"])
        #expect(loader.initialSelection(of: snapshot).selectedIDs == ["A"])
    }

    // MARK: - iTunes 동기화 뒤

    @Test func 동기화한_선택을_지금_사본_옆에_남기고_실패를_알린다() throws {
        let active = Self.snapshots.appending(path: "master-6.db")
        let live = Self.root.appending(path: "master.db")
        let music = MemoryMusicLibrary()
        let loader = Self.loader([:], music: music)
        let source = ITunesLibrarySnapshot(sourcePlaylists: Self.catalog())

        let synced = try loader.publishSync(source: source, syncData: MemoryMusicLibrary.syncData(["A"]), database: active,
                                            target: live, active: active, location: Self.location())
        #expect(synced.selected.playlists.map(\.id) == ["A"])
        #expect(synced.sameSource && !synced.saveFailed)
        #expect(music.cached(active)?.playlists.map(\.id) == ["A"])

        music.failSave(for: active)
        let failed = try loader.publishSync(source: source, syncData: MemoryMusicLibrary.syncData(["B"]), database: active,
                                            target: live, active: active, location: Self.location())
        #expect(failed.saveFailed)
    }

    @Test func 명시한_사본으로_열면_화면_목록을_다른_출처로_보지_않는다() throws {
        let copy = URL(filePath: "/copies/master.db")
        let music = MemoryMusicLibrary()
        let synced = try Self.loader([:], music: music).publishSync(
            source: ITunesLibrarySnapshot(sourcePlaylists: Self.catalog()), syncData: MemoryMusicLibrary.syncData(["A"]),
            database: copy, target: copy, active: copy, location: Self.location(explicitCopy: copy))
        #expect(!synced.sameSource)
        // 동기화한 사본 옆에는 남긴다(라이브 rekordbox 폴더 밖)
        #expect(music.cached(copy)?.playlists.map(\.id) == ["A"])
    }
}
