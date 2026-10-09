import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 초안 폴더 정리 흐름(유스케이스 `WatchDrafts`). 옛 `LibraryStore+UnlinkedDrafts`·`+DraftFiles`·`+DraftIndex`가 초안 저장 큐를 직접 부르던 순서를
/// 앱 없이 본다: 연결되지 않은 초안 버리기, 옮긴 손상 파일 뒤 메모리 입력 다시 저장하기, 실패한 태그 저장 다시 하기.
@MainActor
@Suite("초안 폴더 정리 흐름")
struct WatchDraftsUpkeepTests {
    /// 부른 차례를 남기는 메모리 초안 저장소
    final class Store: Sendable {
        let memory = MemoryDrafts()
        let calls = Mutex<[String]>([])
        let failedTags = Mutex<Set<String>>([])
        let failures = Mutex<[DraftSaveFailure]>([])
        let moved = Mutex<[DamagedDraftFile]>([])
        let unsaved = Mutex(UnsavedDrafts())
        let failingArtwork: Set<String>
        let failingPlaylist: Bool

        init(failingArtwork: Set<String> = [], failingPlaylist: Bool = false) {
            self.failingArtwork = failingArtwork
            self.failingPlaylist = failingPlaylist
        }

        func record(_ name: String) { calls.withLock { $0.append(name) } }
        var list: [String] { calls.withLock { $0 } }

        var port: DraftStore {
            var store = memory.store
            let saveCue = store.saveCue, saveGrid = store.saveGrid, saveGain = store.saveGain, saveTags = store.saveTags
            let removeArtwork = store.removeArtwork, savePlaylist = store.savePlaylistDraft
            store.flush = { self.record("flush") }
            store.saveCue = { draft, done in self.record("cue \(draft.trackUUID)"); saveCue(draft, done) }
            store.saveGrid = { draft, done in self.record("grid \(draft.trackUUID)"); saveGrid(draft, done) }
            store.saveGain = { gain, uuid, done in self.record("gain \(uuid)"); saveGain(gain, uuid, done) }
            store.saveTags = { tags in self.record("tags \(tags.map(\.trackUUID).sorted())"); saveTags(tags) }
            store.removeArtwork = { uuid in
                self.record("artwork \(uuid)")
                if self.failingArtwork.contains(uuid) { throw CocoaError(.fileWriteNoPermission) }
                try removeArtwork(uuid)
            }
            store.savePlaylistDraft = { draft in
                self.record("playlist")
                if self.failingPlaylist { throw CocoaError(.fileWriteNoPermission) }
                try savePlaylist(draft)
            }
            store.takeMovedFiles = { self.record("moved"); return self.moved.withLock { $0 } }
            store.failedTagSaves = { self.failedTags.withLock { $0 } }
            store.failures = { self.failures.withLock { $0 } }
            store.unsaved = { self.unsaved.withLock { $0 } }
            return store
        }
    }

    static func tag(_ uuid: String, comment: String = "고침") -> TagDraft {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        draft.fields.comment = comment
        return draft
    }

    static func cue(_ uuid: String) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .hot(0), time: 10))
        return draft
    }

    static func file(_ name: String, _ uuid: String?) -> DamagedDraftFile {
        DamagedDraftFile(name: name, preserved: URL(filePath: "/damaged/\(name)"), trackUUID: uuid)
    }

    // MARK: - 연결되지 않은 초안 버리기

    @Test func 고른_곡의_초안을_종류마다_지우고_태그는_빈_초안으로_저장한_뒤_저장을_끝낸다() throws {
        let store = Store()
        store.memory.save(Self.cue("a"))
        store.memory.save(gain: 1.5, "a")
        store.memory.save(Self.tag("b"))
        try store.memory.store.saveArtwork(ArtworkEdit(draft: ArtworkDraft(trackUUID: "b", change: .delete, base: ArtworkBase(imagePath: "")),
                                                       image: nil))
        store.memory.save(Self.cue("keep"))

        let result = WatchDrafts(drafts: store.port).discardUnlinked(["a", "b"], attemptedTags: [])

        #expect(store.list == ["cue a", "gain a", "artwork b", "tags [\"b\"]", "flush", "moved"])
        #expect(store.memory.cue("a") == nil && store.memory.gain("a") == nil && store.memory.tag("b") == nil)
        #expect(store.memory.cue("keep") != nil, "고르지 않은 곡은 그대로다")
        #expect(result.clearedTags == ["b"] && result.removedArtwork == ["b"] && result.failed.isEmpty)
    }

    @Test func 지우지_못한_곡을_모은다() throws {
        let store = Store(failingArtwork: ["b"])
        store.memory.save(Self.cue("a"))
        try store.memory.store.saveArtwork(ArtworkEdit(draft: ArtworkDraft(trackUUID: "b", change: .delete, base: ArtworkBase(imagePath: "")),
                                                       image: nil))
        store.memory.save(Self.tag("c"))
        store.failures.withLock { $0 = [DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 1, reason: "실패")] }
        store.failedTags.withLock { $0 = ["c", "other"] }

        let result = WatchDrafts(drafts: store.port).discardUnlinked(["a", "b", "c"], attemptedTags: ["other"])

        #expect(result.failed == ["a", "b", "c"], "큐 저장 실패·그림 지우기 실패·이번에 맡긴 태그 저장 실패")
        #expect(result.removedArtwork.isEmpty)
    }

    // MARK: - 옮긴 손상 파일 뒤

    @Test func 옮긴_태그_파일은_메모리_초안을_다시_저장하고_큐_그리드_그림_표시는_거둔다() {
        let store = Store()
        store.unsaved.withLock { $0 = UnsavedDrafts(cues: ["c2": Self.cue("c2")]) }
        let moved = [Self.file("tag-drafts/t.json", "t"), Self.file("cue-drafts/c1.json", "c1"), Self.file("cue-drafts/c2.json", "c2"),
                     Self.file("grid-drafts/g.json", "g"), Self.file("artwork-drafts/w.json", "w"), Self.file("tag-drafts/plain.json", "plain")]

        let recovery = WatchDrafts(drafts: store.port).recoverMoved(moved, memoryTags: ["t": Self.tag("t"), "plain": Self.tag("plain", comment: "")],
                                                                    memoryPlaylist: PlaylistDraft())

        #expect(recovery.steps == [.keepTag(Self.tag("t")), .clearCue("c1"), .clearGrid("g"), .clearArtwork("w")],
                "저장을 기다리는 큐 입력이 있는 곡(c2)과 고친 것이 없는 태그는 건드리지 않는다")
        #expect(store.list == ["tags [\"t\"]", "flush"])
        #expect(recovery.gainDraftUUIDs == nil && recovery.playlist == nil)
    }

    @Test func 게인_파일을_옮겼으면_저장_대기_입력을_얹어_다시_센다() {
        let store = Store()
        store.memory.save(gain: 1, "disk")
        store.memory.save(gain: 1, "removing")
        store.unsaved.withLock { $0 = UnsavedDrafts(gains: ["removing": nil, "new": 2]) }

        let recovery = WatchDrafts(drafts: store.port).recoverMoved([Self.file("gain-drafts.json", nil)], memoryTags: [:],
                                                                    memoryPlaylist: PlaylistDraft())

        #expect(recovery.gainDraftUUIDs == ["disk", "new"])
    }

    @Test func 재생_목록_파일을_옮겼으면_메모리_초안이_있을_때만_다시_저장한다() throws {
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: PlaylistRef("P"), name: "새 이름"),
                             rekordbox: PlaylistLayout(rekordbox: [RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1,
                                                                                      isFolder: false, trackIDs: [])]))
        let moved = [Self.file("playlist-drafts.json", nil)]
        let saving = Store(), empty = Store(), failing = Store(failingPlaylist: true)

        let saved = WatchDrafts(drafts: saving.port).recoverMoved(moved, memoryTags: [:], memoryPlaylist: draft)
        let skipped = WatchDrafts(drafts: empty.port).recoverMoved(moved, memoryTags: [:], memoryPlaylist: PlaylistDraft())
        let failed = WatchDrafts(drafts: failing.port).recoverMoved(moved, memoryTags: [:], memoryPlaylist: draft)

        #expect(saved.playlist?.draft == draft && saved.playlist?.error == nil && saving.memory.store.playlistDraft() == draft)
        #expect(skipped.playlist == nil && empty.list.isEmpty)
        #expect(failed.playlist?.error != nil)
    }

    // MARK: - 태그 저장 다시 하기

    @Test func 이번에_맡긴_태그_저장이_실패했으면_메모리_입력으로_다시_저장한다() {
        let store = Store()
        store.failedTags.withLock { $0 = ["a", "b", "other"] }

        let resaved = WatchDrafts(drafts: store.port).retryFailedTags(attempted: ["a", "b"], memory: ["a": Self.tag("a")])

        #expect(store.list == ["flush", "tags [\"a\", \"b\"]", "flush"])
        #expect(resaved.sorted { $0.trackUUID < $1.trackUUID } == [Self.tag("a"), TagDraft(trackUUID: "b", base: TagFields())],
                "메모리에 없는 곡은 실패한 지우기를 다시 한다")
    }

    @Test func 실패가_없으면_저장을_끝내기만_한다() {
        let store = Store()
        #expect(WatchDrafts(drafts: store.port).retryFailedTags(attempted: ["a"], memory: [:]).isEmpty)
        #expect(store.list == ["flush"])
    }
}
