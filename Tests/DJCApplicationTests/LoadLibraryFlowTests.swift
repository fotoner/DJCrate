import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 라이브러리 한 번 읽기의 흐름(유스케이스 `LoadLibrary.open`·`reconcileDrafts`). 옛 `LibraryStore+Loading`이 정하던 순서를 DB·앱 없이 본다:
/// 걸린 초안 저장 끝내기 → 손상 파일 옮기기 → (화면이 알리고 계속할지 정한다) → 사본 지문 → 읽기 → 사본 지문, 읽은 뒤 태그 초안 고르기·저장.
@MainActor
@Suite("라이브러리 읽기 흐름")
struct LoadLibraryFlowTests {
    typealias L = LoadLibraryTests

    /// 부른 차례
    final class Calls: Sendable {
        private let value = Mutex<[String]>([])
        func record(_ name: String) { value.withLock { $0.append(name) } }
        var list: [String] { value.withLock { $0 } }
    }

    nonisolated static let snapshot = L.snapshots.appending(path: "master-2026-01-01T000000.db")

    nonisolated static func provenance(_ inode: UInt64) -> UsbSyncSnapshotProvenance {
        UsbSyncSnapshotProvenance(sourceURL: snapshot, snapshotTime: "2026-01-01T000000",
                                  fingerprint: .init(device: 1, inode: inode, size: 10, modified: Date(timeIntervalSince1970: 0), digest: Data()))
    }

    /// 부른 차례를 남기는 읽기. `stamps`는 차례로 돌려줄 사본 지문(nil이면 뜨지 못함)
    static func loader(drafts: MemoryDrafts = MemoryDrafts(), calls: Calls, damaged: [DamagedDraftFile] = [],
                       stamps: [UsbSyncSnapshotProvenance?] = [], tracks: [Track] = [L.track("1"), L.track("2")]) -> LoadLibrary {
        var source = LibrarySource.memory([snapshot: L.library(tracks)])
        let read = source.library
        source.library = { calls.record("read"); return try read($0) }
        var store = drafts.store
        store.flush = { calls.record("flush") }
        store.preserveDamaged = { calls.record("damaged"); return damaged }
        let queue = Mutex(stamps)
        let usb = UsbSyncSnapshots(stamp: { _ in
            calls.record("stamp")
            guard let next = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw CocoaError(.fileNoSuchFile) }
            return next
        }, lease: { _, _ in throw CocoaError(.fileNoSuchFile) })
        return LoadLibrary(source: source, music: MemoryMusicLibrary().source, drafts: store, order: ITunesRefreshCoordinator(),
                           snapshots: SnapshotTaker { _ in snapshot }, usbSnapshots: usb)
    }

    static func request() -> LoadLibrary.Request { LoadLibrary.Request(snapshot: snapshot, fallbackDirectory: L.snapshots) }

    // MARK: - 읽기 차례

    @Test func 저장을_끝내고_손상_파일을_옮겨_알린_뒤_사본_지문_사이에서_읽는다() async throws {
        let calls = Calls()
        let damaged = DamagedDraftFile(name: "tag-drafts/u1.json", preserved: URL(filePath: "/x"), trackUUID: "u1")
        let loader = Self.loader(calls: calls, damaged: [damaged], stamps: [Self.provenance(7), Self.provenance(7)])

        let opened = try await loader.open(Self.request(), preservingDamaged: true, settled: { moved in
            calls.record("settled \(moved.map(\.name))")
            return true
        })

        #expect(calls.list == ["flush", "damaged", "settled [\"tag-drafts/u1.json\"]", "stamp", "read", "stamp"])
        #expect(opened?.loaded.rows.map(\.track.id) == ["1", "2"])
        #expect(opened?.usbSnapshot == Self.provenance(7), "읽는 동안 사본이 그대로면 그 지문이 USB 작업 사본의 출처다")
    }

    @Test func 화면이_그만두면_읽지_않는다() async throws {
        let calls = Calls()
        let loader = Self.loader(calls: calls, stamps: [Self.provenance(1)])
        let opened = try await loader.open(Self.request(), preservingDamaged: true, settled: { _ in false })
        #expect(opened == nil)
        #expect(calls.list == ["flush", "damaged"], "새 읽기가 시작됐으면 사본 지문도 뜨지 않고 읽지도 않는다")
    }

    @Test func 손상_파일을_옮기지_않는_저장소는_저장만_끝낸다() async throws {
        let calls = Calls()
        let loader = Self.loader(calls: calls, stamps: [Self.provenance(1), Self.provenance(1)])
        _ = try await loader.open(Self.request(), preservingDamaged: false, settled: { moved in
            calls.record("settled \(moved.count)")
            return true
        })
        #expect(calls.list == ["flush", "settled 0", "stamp", "read", "stamp"])
    }

    @Test(arguments: [[LoadLibraryFlowTests.provenance(1), LoadLibraryFlowTests.provenance(2)], [LoadLibraryFlowTests.provenance(1), nil],
                       [nil, LoadLibraryFlowTests.provenance(1)]])
    func 읽는_동안_사본이_바뀌었거나_지문을_뜨지_못하면_출처를_넘기지_않는다(stamps: [UsbSyncSnapshotProvenance?]) async throws {
        let loader = Self.loader(calls: Calls(), stamps: stamps)
        let opened = try await loader.open(Self.request(), preservingDamaged: false, settled: { _ in true })
        #expect(opened != nil && opened?.usbSnapshot == nil)
    }

    @Test func 사본을_읽지_못하면_던진다() async {
        let loader = Self.loader(calls: Calls(), stamps: [Self.provenance(1), Self.provenance(1)])
        await #expect(throws: (any Error).self) {
            _ = try await loader.open(LoadLibrary.Request(snapshot: URL(filePath: "/none.db"), fallbackDirectory: L.snapshots),
                                      preservingDamaged: false, settled: { _ in true })
        }
    }

    // MARK: - 읽은 뒤 초안 맞추기

    static func tag(_ uuid: String, base title: String, comment: String) -> TagDraft {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        draft.base.title = title
        draft.fields.title = title
        draft.fields.comment = comment
        return draft
    }

    @Test func 동기화면_충돌하지_않는_태그_초안의_base를_옮겨_저장하고_저장을_끝낸다() async throws {
        let calls = Calls(), drafts = MemoryDrafts()
        // 디스크의 태그 초안은 옛 제목을 base로 들었다(그 뒤 rekordbox에서 제목이 "곡 1"로 바뀌었다)
        drafts.save(Self.tag("u1", base: "옛 제목", comment: "새 코멘트"))
        let loader = Self.loader(drafts: drafts, calls: calls, stamps: [nil, nil])
        let loaded = try #require(try await loader.open(Self.request(), preservingDamaged: false, settled: { _ in true })?.loaded)
        var store = drafts.store
        store.saveTags = { tags in calls.record("save tags \(tags.map(\.trackUUID))"); for tag in tags { drafts.save(tag) } }
        let flushing = Calls()
        store.flush = { flushing.record("flush after \(calls.list.last ?? "")") }
        let after = LoadLibrary(source: .memory([:]), music: MemoryMusicLibrary().source, drafts: store, order: ITunesRefreshCoordinator(),
                                snapshots: SnapshotTaker { _ in Self.snapshot }, usbSnapshots: UsbSyncSnapshots(stamp: { _ in throw CocoaError(.fileNoSuchFile) },
                                                                                                                 lease: { _, _ in throw CocoaError(.fileNoSuchFile) }))

        let reconciled = after.reconcileDrafts(loaded, memoryTags: [:], editedDuringRead: false, failedTags: [], synchronizing: true,
                                               artworkChanged: false)

        #expect(reconciled.tags.rebased.map(\.trackUUID) == ["u1"])
        #expect(reconciled.tags.tags["u1"]?.base.title == "곡 1" && reconciled.tags.tags["u1"]?.fields.comment == "새 코멘트")
        #expect(drafts.tag("u1")?.base.title == "곡 1", "옮긴 base를 저장한다")
        #expect(flushing.list == ["flush after save tags [\"u1\"]"], "옮긴 초안을 저장한 뒤 저장을 끝낸다")
    }

    @Test func 동기화가_아니면_저장하지_않고_읽는_동안_고친_메모리를_쓴다() async throws {
        let calls = Calls(), drafts = MemoryDrafts()
        drafts.save(Self.tag("u1", base: "옛 제목", comment: "디스크"))
        let loader = Self.loader(drafts: drafts, calls: calls, stamps: [nil, nil])
        let loaded = try #require(try await loader.open(Self.request(), preservingDamaged: false, settled: { _ in true })?.loaded)
        let memory = ["u2": Self.tag("u2", base: "곡 2", comment: "메모리")]

        let reconciled = loader.reconcileDrafts(loaded, memoryTags: memory, editedDuringRead: true, failedTags: [], synchronizing: false,
                                                artworkChanged: false)

        #expect(reconciled.tags.tags.keys.sorted() == ["u2"] && reconciled.tags.rebased.isEmpty)
        #expect(calls.list.filter { $0 == "flush" }.count == 1, "옮긴 초안이 없으면 읽기 전 한 번만 끝낸다")
    }

    @Test func 합치기_초안은_다시_읽고_그림_초안은_읽는_동안_고쳤을_때만_디스크에서_다시_읽는다() async throws {
        let drafts = MemoryDrafts()
        let loader = Self.loader(drafts: drafts, calls: Calls(), stamps: [nil, nil])
        let loaded = try #require(try await loader.open(Self.request(), preservingDamaged: false, settled: { _ in true })?.loaded)
        // 읽은 뒤 그림 초안·합치기 초안이 디스크에 생겼다(읽는 동안 다른 동작이 저장했다)
        let artwork = ArtworkEdit(draft: ArtworkDraft(trackUUID: "u1", change: .delete, base: ArtworkBase(imagePath: "", files: [])), image: nil)
        try drafts.store.saveArtwork(artwork)
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "u1", title: "남김", duration: 1, offset: 0, cues: []),
                                        removing: [.init(contentID: "2", trackUUID: "u2", title: "뺌", duration: 1, offset: 0, cues: [])],
                                        base: "")
        try drafts.store.saveMergeDrafts([merge])

        let unchanged = loader.reconcileDrafts(loaded, memoryTags: [:], editedDuringRead: false, failedTags: [], synchronizing: false,
                                               artworkChanged: false)
        let changed = loader.reconcileDrafts(loaded, memoryTags: [:], editedDuringRead: false, failedTags: [], synchronizing: false,
                                             artworkChanged: true)

        #expect(unchanged.artworkDrafts.isEmpty, "읽는 동안 고치지 않았으면 읽은 값을 쓴다")
        #expect(changed.artworkDrafts.keys.sorted() == ["u1"])
        #expect(unchanged.mergeDrafts.map(\.id) == [merge.id])
    }
}
