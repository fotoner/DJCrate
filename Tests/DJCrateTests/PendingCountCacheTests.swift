@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 쓰기 대기 수 캐시(#324, #129): 사이드바 배지·상태 줄 칩·Dock 배지가 한 값을 읽고, 읽을 때마다 합집합을 새로 만들지 않는다.
/// 기준은 캐시를 두기 전의 계산(초안 여섯 종류의 합집합에서 추가한 곡을 뺀 수)이다.
@MainActor
@Suite("쓰기 대기 수 캐시")
struct PendingCountCacheTests {
    /// 추가한 곡은 ID가 `djc-`로 시작한다(`TrackRow.isStaged`)
    static func track(_ uuid: String, staged: Bool = false) -> TrackRow {
        TrackRow(track: Track(id: staged ? "djc-\(uuid)" : uuid, uuid: uuid, title: "곡 \(uuid)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "/x/\(uuid).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    static func merge(_ keeping: String, _ removing: String) -> DuplicateMergeDraft {
        .init(keeping: .init(contentID: keeping, trackUUID: keeping, title: keeping, duration: 30, offset: 0, cues: []),
              removing: [.init(contentID: removing, trackUUID: removing, title: removing, duration: 30, offset: 0, cues: [])], base: "base")
    }

    /// 캐시를 두기 전의 계산 그대로
    static func reference(_ store: LibraryStore) -> (uuids: Set<String>, library: Int, write: Int) {
        let uuids = store.cueDraftUUIDs.union(store.gridDraftUUIDs).union(store.gainDraftUUIDs).union(store.tagDrafts.keys)
            .union(store.artworkDrafts.keys).union(store.mergeDrafts.flatMap { $0.members.map(\.trackUUID) })
        let library = uuids.filter { store.rowsByUUID[$0].map { !$0.isStaged } ?? false }.count
        return (uuids, library, library + store.history.pendingHistories.count)
    }

    func expectSame(_ store: LibraryStore, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = Self.reference(store)
        #expect(store.pendingUUIDs == expected.uuids, Comment(rawValue: "집합 — \(note)"), sourceLocation: sourceLocation)
        #expect(store.pendingLibraryCount == expected.library, Comment(rawValue: "곡 수 — \(note)"), sourceLocation: sourceLocation)
        #expect(store.pendingWriteCount == expected.write, Comment(rawValue: "배지 — \(note)"), sourceLocation: sourceLocation)
    }

    @Test func 초안이_바뀔_때마다_캐시한_수가_기존_계산과_같다() throws {
        let store = LibraryStore.test(activityLog: .init(), saveTagDrafts: { _ in }, mergeDraftSaver: { _ in })
        expectSame(store, "처음")
        #expect(store.pendingWriteCount == 0)

        for uuid in ["a", "b", "c", "d", "e"] { store.rowsByUUID[uuid] = Self.track(uuid) }
        store.rowsByUUID["s"] = Self.track("s", staged: true)
        expectSame(store, "곡만 읽음")

        store.setDraftMark(.cue, trackUUID: "a", exists: true)
        expectSame(store, "큐 표시")
        store.setDraftMarks(grid: ["b", "a"], gain: ["c"])
        expectSame(store, "그리드·게인 표시")
        #expect(store.pendingLibraryCount == 3)

        // 추가한 곡의 초안은 집합에는 들지만 곡 수에서는 뺀다
        store.setDraftMark(.cue, trackUUID: "s", exists: true)
        expectSame(store, "추가한 곡 초안")
        #expect(store.pendingUUIDs.contains("s") && store.pendingLibraryCount == 3)

        store.tags.applyTagEdits([(Self.track("d"), .title, "새 제목")])
        store.rowsByUUID["d"] = Self.track("d")
        expectSame(store, "태그 초안")
        #expect(store.pendingLibraryCount == 4)

        store.artworkDrafts["e"] = ArtworkDraft(trackUUID: "e", change: .delete, base: ArtworkBase(imagePath: "/x"))
        expectSame(store, "그림 초안")
        #expect(store.pendingLibraryCount == 5)

        store.mergeDrafts = [Self.merge("f", "g")]
        expectSame(store, "합치기 초안(곡을 읽기 전)")
        store.rowsByUUID["f"] = Self.track("f")
        store.rowsByUUID["g"] = Self.track("g")
        expectSame(store, "합치기 초안(곡을 읽은 뒤)")
        #expect(store.pendingLibraryCount == 7)

        // 곡 목록을 통째로 바꾸면(다시 읽기) 읽지 못한 곡의 초안은 세지 않는다
        store.rowsByUUID = ["a": Self.track("a")]
        expectSame(store, "곡 목록 교체")
        #expect(store.pendingLibraryCount == 1)

        store.setDraftMarks(cue: [], grid: [], gain: [])
        store.tagDrafts = [:]
        store.artworkDrafts = [:]
        store.mergeDrafts = []
        expectSame(store, "초안 모두 버림")
        #expect(store.pendingWriteCount == 0)
    }

    @Test func 읽기만_하면_합집합을_다시_만들지_않고_초안이_바뀐_뒤_첫_읽기에서만_다시_만든다() {
        let store = LibraryStore.test(activityLog: .init(), saveTagDrafts: { _ in })
        for uuid in ["a", "b", "c"] { store.rowsByUUID[uuid] = Self.track(uuid) }
        store.setDraftMarks(cue: ["a", "b"])
        let start = store.pendingRebuildCount
        for _ in 0..<50 { _ = store.pendingWriteCount; _ = store.pendingLibraryCount; _ = store.pendingUUIDs }
        #expect(store.pendingRebuildCount - start <= 1, "첫 읽기에서 한 번만 만들고 그 뒤 49번은 캐시를 읽는다")

        let built = store.pendingRebuildCount
        for _ in 0..<50 { _ = store.pendingWriteCount }
        #expect(store.pendingRebuildCount == built)

        // 입력이 여러 번 바뀌어도 읽기 전에는 만들지 않는다(바뀔 때마다 O(n)을 치르지 않는다)
        store.setDraftMark(.grid, trackUUID: "c", exists: true)
        store.setDraftMark(.gain, trackUUID: "c", exists: true)
        store.rowsByUUID["d"] = Self.track("d")
        #expect(store.pendingRebuildCount == built)
        #expect(store.pendingLibraryCount == 3)
        #expect(store.pendingRebuildCount == built + 1)
    }

    @Test func 쓰기_대기_수가_바뀌면_관찰자에게_알린다() async {
        let store = LibraryStore.test(activityLog: .init(), saveTagDrafts: { _ in })
        store.rowsByUUID["a"] = Self.track("a")
        let fired = FireCount()
        func watch() {
            withObservationTracking { _ = store.pendingWriteCount } onChange: { fired.value += 1 }
        }
        watch()
        // 읽기 전에 이미 계산된 캐시여도, 입력이 바뀌면 관찰자는 깨어난다
        store.setDraftMark(.cue, trackUUID: "a", exists: true)
        #expect(fired.value == 1 && store.pendingWriteCount == 1)
        watch()
        store.setDraftMark(.cue, trackUUID: "a", exists: false)
        #expect(fired.value == 2 && store.pendingWriteCount == 0)
    }
}

/// `withObservationTracking`의 `onChange`는 보낼 수 있는 클로저라 값을 상자에 담아 센다
private final class FireCount: @unchecked Sendable {
    var value = 0
}
