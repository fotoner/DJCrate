import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 추가 목록의 흐름(유스케이스 `StageTracks`). 옛 `LibraryStore+Staging`이 정하던 순서를 앱 없이 본다:
/// 넣기 결과 얹기 → 추가 목록 저장 → 재생 목록 연결 기록 더하기 → 저장, 다시 읽을 때 목록 읽기 → 가져온 뒤 확인 → 저장.
@MainActor
@Suite("추가 목록 흐름")
struct StageTracksFlowTests {
    /// 연결 기록 포트(메모리). 저장을 남기고, `failing`이면 저장이 던진다
    final class Imports: Sendable {
        let saved = Mutex<[PlaylistImports]>([])
        let failing: Bool
        init(failing: Bool = false) { self.failing = failing }
        var store: PlaylistImportsStore {
            PlaylistImportsStore(load: { PlaylistImports() }, save: { [self] imports in
                if failing { throw CocoaError(.fileWriteNoPermission) }
                saved.withLock { $0.append(imports) }
            })
        }
        var count: Int { saved.withLock { $0.count } }
    }

    static func track(_ name: String) -> StagedTrack {
        StagedTrack(uuid: "s-\(name)", path: "/m/\(name).mp3", title: name, duration: 60, addedOn: "2026-01-01")
    }

    static func stage(staging: MemoryStaging = MemoryStaging(), imports: Imports = Imports(), drafts: DraftStore = MemoryDrafts().store,
                      keys: [String] = ["k1", "k2", "k3"]) -> StageTracks {
        let queue = Mutex(keys)
        return StageTracks(files: StageTracksTests.Files().port,
                           analysis: StagingAnalysis(estimateGrid: { _, _ in nil }, timelineOffset: { _ in 0 }, mainKey: { _, _, _, _, _ in nil }),
                           drafts: drafts, source: .memory([:]), today: { "2026-10-09" }, staging: staging.store, imports: imports.store,
                           newKey: { queue.withLock { $0.isEmpty ? "K" : $0.removeFirst() } })
    }

    // MARK: - 넣기 결과 저장

    @Test func 넣기_결과를_지금_목록에_얹어_저장한다() {
        let staging = MemoryStaging([Self.track("old")])
        let stage = Self.stage(staging: staging)
        let addition = StageTracks.Addition(added: [Self.track("new")])

        let commit = stage.commit(addition, onto: [Self.track("old")], link: nil, imports: PlaylistImports(), importsLoadFailed: false,
                                  takingMovedFiles: true)

        #expect(commit.list?.map(\.title) == ["old", "new"])
        #expect(staging.tracks.map(\.title) == ["old", "new"])
        #expect(commit.listSaveError == nil && commit.link == nil)
    }

    @Test func 목록을_저장하지_못해도_얹은_목록을_돌려주고_이유를_남긴다() {
        let staging = MemoryStaging([], saveError: CocoaError(.fileWriteNoPermission))
        let commit = Self.stage(staging: staging).commit(StageTracks.Addition(added: [Self.track("new")]), onto: [], link: nil,
                                                         imports: PlaylistImports(), importsLoadFailed: false, takingMovedFiles: true)
        #expect(commit.list?.map(\.title) == ["new"] && commit.listSaveError != nil)
        #expect(staging.tracks.isEmpty)
    }

    @Test func 바꿀_것이_없으면_목록을_저장하지_않는다() {
        let staging = MemoryStaging([Self.track("old")], saveError: CocoaError(.fileWriteNoPermission))
        let commit = Self.stage(staging: staging).commit(StageTracks.Addition(stagedIDs: [Self.track("old").id]), onto: [Self.track("old")],
                                                         link: nil, imports: PlaylistImports(), importsLoadFailed: false, takingMovedFiles: true)
        #expect(commit.list == nil && commit.listSaveError == nil)
    }

    @Test func 저장이_손상된_옛_목록을_옮겼으면_데이터_폴더를_정한_저장소만_그_파일을_받는다() {
        let moved = DamagedDraftFile(name: "staged.json", preserved: URL(filePath: "/x"), trackUUID: nil)
        var drafts = MemoryDrafts().store
        drafts.takeMovedFiles = { [moved] }
        let taking = Self.stage(drafts: drafts).commit(StageTracks.Addition(added: [Self.track("a")]), onto: [], link: nil,
                                                       imports: PlaylistImports(), importsLoadFailed: false, takingMovedFiles: true)
        let leaving = Self.stage(drafts: drafts).commit(StageTracks.Addition(added: [Self.track("a")]), onto: [], link: nil,
                                                        imports: PlaylistImports(), importsLoadFailed: false, takingMovedFiles: false)
        #expect(taking.moved == [moved] && leaving.moved.isEmpty)
    }

    @Test func 재생_목록에_놓으면_넣은_곡과_이미_있는_곡을_연결_기록에_더해_저장한다() {
        let imports = Imports()
        let addition = StageTracks.Addition(added: [Self.track("new")], stagedIDs: [Self.track("old").id])
        let commit = Self.stage(imports: imports).commit(addition, onto: [Self.track("old")],
                                                         link: StageTracks.PlaylistLink(playlistID: "P"), imports: PlaylistImports(),
                                                         importsLoadFailed: false, takingMovedFiles: true)

        let link = try? #require(commit.link)
        #expect(link?.stored == true)
        #expect(link?.imports.requests.first?.target == PlaylistRef("P"))
        #expect(link?.imports.requests.first?.entries.map(\.path).sorted() == ["/m/new.mp3", "/m/old.mp3"])
        #expect(imports.count == 1)
    }

    @Test func Music_목록으로_만들면_출처마다_새_목록_열쇠를_받는다() {
        let imports = Imports()
        let origin = AppleMusicOrigin(libraryID: nil, trackID: 1, playlists: [.init(id: "M1", name: "Music 목록", parentID: nil, position: 0)])
        let addition = StageTracks.Addition(added: [Self.track("new")])
        let commit = Self.stage(imports: imports, keys: ["LIB", "key-1"]).commit(
            addition, onto: [], link: StageTracks.PlaylistLink(createPlaylists: true, origins: ["/m/new.mp3": [origin], "/m/other.mp3": [origin]]),
            imports: PlaylistImports(), importsLoadFailed: false, takingMovedFiles: true)

        let request = commit.link?.imports.requests.first
        #expect(request?.source?.libraryID == "LIB", "보관함 ID가 없는 출처는 새 ID 하나로 묶는다")
        #expect(request?.target == .new("key-1") && request?.name == "Music 목록")
        #expect(request?.entries.map(\.path) == ["/m/new.mp3"], "넣지 않은 경로는 잇지 않는다")
    }

    @Test func 연결_기록을_읽지_못했으면_저장하지_않는다() {
        let imports = Imports()
        let commit = Self.stage(imports: imports).commit(StageTracks.Addition(added: [Self.track("new")]), onto: [],
                                                         link: StageTracks.PlaylistLink(playlistID: "P"), imports: PlaylistImports(),
                                                         importsLoadFailed: true, takingMovedFiles: true)
        #expect(commit.link?.stored == false && imports.count == 0)
    }

    // MARK: - 다시 읽을 때

    @Test func 다시_읽으면_목록을_읽고_가져온_곡을_확인해_바뀐_목록을_저장한다() {
        let staged = Self.track("a")
        let staging = MemoryStaging([staged])
        let stage = Self.stage(staging: staging)
        let imported = StageTracksTests.row("1", path: staged.path, analysis: "/A/1.DAT")

        let reload = stage.reloadList(rows: [imported], shareRoot: URL(filePath: "/share"), takingMovedFiles: true)

        #expect(reload.list.first?.importCheck != nil, "같은 경로의 곡이 생기면 가져온 것으로 적는다")
        #expect(staging.tracks.first?.importCheck == reload.list.first?.importCheck, "적은 결과를 저장한다")
        #expect(reload.summary != nil && reload.saveError == nil)
    }

    @Test func 가져온_곡이_없으면_저장하지_않고_알릴_것도_없다() {
        let staging = MemoryStaging([Self.track("a")], saveError: CocoaError(.fileWriteNoPermission))
        let reload = Self.stage(staging: staging).reloadList(rows: [], shareRoot: URL(filePath: "/share"), takingMovedFiles: true)
        #expect(reload.list.map(\.title) == ["a"] && reload.summary == nil && reload.saveError == nil)
    }
}

/// 재생 목록 연결 기록·초안 저장 흐름(유스케이스 `EditPlaylists`). 옛 `LibraryStore+PlaylistImports`·`+Playlists`의 쓴 뒤·복원 뒤 저장 순서:
/// 초안 저장이 먼저이고, 초안을 저장하지 못하면 연결 기록을 저장하지 않는다(다음 읽기에서 다시 확인한다).
@MainActor
@Suite("재생 목록 연결 흐름")
struct EditPlaylistsFlowTests {
    typealias I = StageTracksFlowTests.Imports

    static func playlists(imports: I = I(), drafts: DraftStore = MemoryDrafts().store) -> EditPlaylists {
        EditPlaylists(imports: imports.store, drafts: drafts)
    }

    static let rekordbox = PlaylistLayout(rekordbox: [RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false,
                                                                        trackIDs: [])])

    static func pending(path: String = "/m/a.mp3") -> PlaylistImports {
        var imports = PlaylistImports()
        imports.addFiles([path], to: PlaylistRef("P"))
        return imports
    }

    @Test func 컬렉션에_들어간_곡을_초안에_넣어_저장한_뒤_연결_기록을_저장한다() throws {
        let imports = I(), memory = MemoryDrafts()
        var drafts = memory.store
        let order = Mutex<[String]>([])
        let saveDraft = drafts.savePlaylistDraft
        drafts.savePlaylistDraft = { order.withLock { $0.append("draft") }; try saveDraft($0) }
        let store = PlaylistImportsStore(load: { PlaylistImports() }, save: { order.withLock { $0.append("imports") }; try imports.store.save($0) })

        let resolution = try #require(EditPlaylists(imports: store, drafts: drafts).resolveImports(
            Self.pending(), draft: PlaylistDraft(), rekordbox: Self.rekordbox, contentIDsByPath: ["/m/a.mp3": "c1"], loadFailed: false))

        #expect(order.withLock { $0 } == ["draft", "imports"])
        #expect(resolution.draft?.project(onto: Self.rekordbox).layout.item("P")?.trackIDs == ["c1"])
        #expect(memory.store.playlistDraft() == resolution.draft)
        #expect(resolution.imports?.stored == true && resolution.imports?.imports.pendingCount == 0)
    }

    @Test func 초안을_저장하지_못하면_연결_기록은_그대로_둔다() {
        let imports = I()
        var drafts = MemoryDrafts().store
        drafts.savePlaylistDraft = { _ in throw CocoaError(.fileWriteNoPermission) }
        let resolution = Self.playlists(imports: imports, drafts: drafts).resolveImports(
            Self.pending(), draft: PlaylistDraft(), rekordbox: Self.rekordbox, contentIDsByPath: ["/m/a.mp3": "c1"], loadFailed: false)
        #expect(resolution?.draftError != nil && resolution?.draft == nil && resolution?.imports == nil)
        #expect(imports.count == 0)
    }

    @Test func 기다리는_연결이_없거나_기록을_읽지_못했으면_아무것도_하지_않는다() {
        let playlists = Self.playlists()
        #expect(playlists.resolveImports(PlaylistImports(), draft: PlaylistDraft(), rekordbox: Self.rekordbox, contentIDsByPath: [:],
                                         loadFailed: false) == nil)
        #expect(playlists.resolveImports(Self.pending(), draft: PlaylistDraft(), rekordbox: Self.rekordbox, contentIDsByPath: [:],
                                         loadFailed: true) == nil)
    }

    @Test func 연결_기록은_바뀌었을_때만_저장하고_읽지_못했으면_막는다() {
        let imports = I()
        let playlists = Self.playlists(imports: imports)
        let same = playlists.saveImports(Self.pending(), over: Self.pending(), loadFailed: false)
        let blocked = playlists.saveImports(Self.pending(), over: PlaylistImports(), loadFailed: true)
        let saved = playlists.saveImports(Self.pending(), over: PlaylistImports(), loadFailed: false)
        let failing = Self.playlists(imports: I(failing: true)).saveImports(Self.pending(), over: PlaylistImports(), loadFailed: false)

        #expect(same.stored && !blocked.stored && saved.stored && !failing.stored)
        #expect(imports.count == 1)
        if case .failed = failing.result {} else { Issue.record("저장 실패를 돌려준다") }
    }

    @Test func 쓴_뒤_쓴_편집을_초안에서_빼_저장하고_새_목록_ID를_연결_기록에_이어_저장한다() throws {
        let imports = I(), memory = MemoryDrafts()
        var draft = PlaylistDraft()
        _ = try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        var pending = PlaylistImports()
        pending.addFiles(["/m/a.mp3"], to: .new("k"))
        let outcome = PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "900", name: "새 목록", status: .written)

        let cleanup = Self.playlists(imports: imports, drafts: memory.store).finishWrite(draft, outcomes: [outcome], current: draft,
                                                                                           imports: pending, importsLoadFailed: false)

        #expect(cleanup.draft?.isEmpty == true && cleanup.draftError == nil && memory.store.playlistDraft().isEmpty)
        #expect(cleanup.ids == [PlaylistRef.new("k").layoutID: "900"])
        #expect(cleanup.imports?.imports.requests.first?.target == PlaylistRef("900") && cleanup.imports?.stored == true)
        #expect(imports.count == 1)
    }

    @Test func 쓰는_동안_초안이_바뀌었으면_초안은_그대로_두고_ID만_잇는다() throws {
        let memory = MemoryDrafts()
        var written = PlaylistDraft()
        _ = try written.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        var current = written
        _ = try current.append(.rename(playlist: PlaylistRef("P"), name: "새 이름"), rekordbox: Self.rekordbox)
        let outcome = PlaylistOutcome(edit: written.steps[0].edit, playlistID: "900", name: "새 목록", status: .written)

        let cleanup = Self.playlists(drafts: memory.store).finishWrite(written, outcomes: [outcome], current: current,
                                                                       imports: PlaylistImports(), importsLoadFailed: false)

        #expect(cleanup.draft == nil && memory.store.playlistDraft().isEmpty, "바뀐 초안은 저장하지 않는다")
        #expect(cleanup.ids.count == 1 && cleanup.imports?.stored == true)
    }

    @Test func 되돌린_곡의_연결과_초안_편집을_잊어_저장한다() throws {
        let imports = I(), memory = MemoryDrafts()
        var draft = PlaylistDraft()
        _ = try draft.append(.addTracks(playlist: PlaylistRef("P"), contentIDs: ["c1", "c2"]), rekordbox: Self.rekordbox)
        var linked = Self.pending()
        var resolved = draft
        _ = linked.reconcile(contentIDsByPath: ["/m/a.mp3": "c1"], draft: &resolved, rekordbox: Self.rekordbox)

        let reset = Self.playlists(imports: imports, drafts: memory.store).resetImports(contentIDs: ["c1"], draft: draft,
                                                                                        rekordbox: Self.rekordbox, imports: linked,
                                                                                        importsLoadFailed: false)

        #expect(reset.draftError == nil)
        #expect(reset.draft?.project(onto: Self.rekordbox).layout.item("P")?.trackIDs == ["c2"])
        #expect(memory.store.playlistDraft() == reset.draft)
        #expect(reset.imports?.imports.pendingCount == 1 && imports.count == 1, "되돌린 곡은 다시 기다리는 연결이 된다")
    }

    @Test func 복원_뒤_쓴_편집을_다시_쌓아_저장하고_새로_만들_목록의_연결을_되돌린다() throws {
        let imports = I(), memory = MemoryDrafts()
        var written = PlaylistImports()
        written.addFiles(["/m/a.mp3"], to: .new("k"))
        written.remapTargets([PlaylistRef.new("k").layoutID: "900"])

        let restored = Self.playlists(imports: imports, drafts: memory.store).restore(
            [.create(key: "k", name: "새 목록", isFolder: false, parent: .root)], onto: PlaylistDraft(), rekordbox: Self.rekordbox,
            imports: written, importsLoadFailed: false)

        #expect(restored.failed == 0 && restored.draftError == nil && memory.store.playlistDraft() == restored.draft)
        #expect(restored.imports.imports.requests.first?.target == .new("k") && imports.count == 1)
    }
}
