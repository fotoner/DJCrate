@testable import DJCDomain
import Foundation
import Testing

/// 재생 목록 단계의 식별자·도장 규칙(R5·R22): 도장은 단계에 저장한 식별자로 단계를 잇고 해시로 다시 붙이지 않는다.
/// 식별자·판 번호는 부르는 쪽이 준다(핵심부는 만들지 않는다). 시험은 차례 번호를 준다.
@Suite("재생 목록 단계 식별자·도장 규칙")
struct PlaylistStepStampingTests {
    static let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])
    static let add = PlaylistEdit.addTracks(playlist: .id("A"), contentIDs: ["9"])
    static let remove = PlaylistEdit.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 1, contentID: "9")])

    static func draft(_ edits: [PlaylistEdit]) throws -> PlaylistDraft {
        var draft = PlaylistDraft()
        for edit in edits { try draft.append(edit, rekordbox: rekordbox) }
        return draft
    }

    /// 차례 번호를 주는 식별자·판 발급기
    final class Counter {
        var id: UInt64 = 0
        var revision: UInt64 = 100
        func newID() -> UUID {
            id += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", id))!
        }
        func newRevision() throws -> DraftRevision {
            revision += 1
            return DraftRevision(revision)
        }
    }

    static func stamp(_ revision: UInt64, _ origins: Set<DraftOrigin>, _ draft: PlaylistDraft, _ index: Int) -> DraftStamp {
        DraftStamp(revision: DraftRevision(revision), origins: origins, contentHash: PlaylistStepStamping.hash(draft.steps[index], in: draft))
    }

    // MARK: 단계 식별자

    @Test func 식별자는_같음과_해시에_들어가지_않는다() throws {
        let draft = try Self.draft([Self.add])
        var other = draft
        other.setStepIDs([UUID()])
        #expect(draft == other && draft.steps[0].hashValue == other.steps[0].hashValue)
        #expect(try DraftContentHash(step: draft.steps[0], in: draft) == DraftContentHash(step: other.steps[0], in: other))
        #expect(other.stepIDs[0] != nil && draft.stepIDs[0] == nil)
    }

    @Test func 식별자는_파일에_적히고_옛_파일은_식별자_없이_읽는다() throws {
        var draft = try Self.draft([Self.add])
        let id = UUID()
        draft.setStepIDs([id])
        let data = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(PlaylistDraft.self, from: data).stepIDs == [id])
        // 식별자가 없는 단계는 키를 적지 않는다: 옛 파일과 같은 모양이고 읽으면 nil이다
        let legacy = try Self.draft([Self.add])
        let legacyData = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("\"id\""))
        #expect(try JSONDecoder().decode(PlaylistDraft.self, from: legacyData).stepIDs == [nil])
    }

    @Test func 편집이_합쳐져도_단계_식별자는_그대로다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let id = UUID()
        draft.setStepIDs([id])
        try draft.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: Self.rekordbox)
        #expect(draft.steps.count == 1 && draft.stepIDs == [id])
    }

    // MARK: 맞추기(adopt)

    @Test func 식별자와_도장이_모두_맞으면_바뀌지_않는다() throws {
        let counter = Counter()
        var draft = try Self.draft([Self.add, Self.remove])
        let ids = [counter.newID(), counter.newID()]
        draft.setStepIDs(ids)
        let entries = [PlaylistStampEntry(id: ids[0], stamp: Self.stamp(1, [.human], draft, 0)),
                       PlaylistStampEntry(id: ids[1], stamp: Self.stamp(2, [.cli], draft, 1))]
        let result = try PlaylistStepStamping.adopt(draft, entries: entries, newID: counter.newID, newRevision: counter.newRevision)
        #expect(!result.changed && result.entries == entries && result.draft.stepIDs == ids)
    }

    @Test func 식별자가_없는_옛_파일은_새_식별자와_모름_도장을_받는다() throws {
        let counter = Counter()
        let draft = try Self.draft([Self.add, Self.remove])
        let result = try PlaylistStepStamping.adopt(draft, entries: [], newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.changed && Set(result.draft.stepIDs.compactMap { $0 }).count == 2)
        #expect(result.entries.allSatisfy { $0.stamp.origins == [.unknown] } && Set(result.entries.map(\.stamp.revision)).count == 2)
        #expect(zip(result.entries, result.draft.stepIDs).allSatisfy { $0.id == $1 })
        // 받은 결과를 다시 맞추면 바뀌지 않는다
        let again = try PlaylistStepStamping.adopt(result.draft, entries: result.entries, newID: counter.newID, newRevision: counter.newRevision)
        #expect(!again.changed)
    }

    @Test func 도장이_없는_단계는_모름이고_식별자가_겹치면_뒤_단계가_새_식별자를_받는다() throws {
        let counter = Counter()
        var draft = try Self.draft([Self.add, Self.remove, Self.add])
        let id = counter.newID()
        draft.setStepIDs([id, id, nil])
        let result = try PlaylistStepStamping.adopt(draft, entries: [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.human], draft, 0))],
                                                    newID: counter.newID, newRevision: counter.newRevision)
        let ids = result.draft.stepIDs.compactMap { $0 }
        #expect(ids.count == 3 && Set(ids).count == 3 && ids[0] == id)
        #expect(result.entries[0].stamp.origins == [.human])
        #expect(result.entries[1].stamp.origins == [.unknown] && result.entries[2].stamp.origins == [.unknown])
    }

    @Test func 식별자가_없고_수가_같으면_같은_자리의_도장을_잇는다() throws {
        let counter = Counter()
        let before = try Self.draft([Self.add, .rename(playlist: .id("B"), name: "x")])
        let ids = [counter.newID(), counter.newID()]
        let entries = [PlaylistStampEntry(id: ids[0], stamp: Self.stamp(1, [.human], before, 0)),
                       PlaylistStampEntry(id: ids[1], stamp: Self.stamp(2, [.human], before, 1))]
        // 식별자를 모르는 쪽이 둘째 단계의 내용만 고쳐 다시 썼다
        let outside = try Self.draft([Self.add, .rename(playlist: .id("B"), name: "y")])
        let result = try PlaylistStepStamping.adopt(outside, entries: entries, newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.draft.stepIDs == ids && result.entries == entries)
        // 도장은 그대로라 내용 해시가 어긋난다(제안·사본 대상)
        #expect(PlaylistStepStamping.hash(result.draft.steps[1], in: result.draft) != result.entries[1].stamp.contentHash)
    }

    @Test func 식별자가_없고_수가_다르면_해시로_잇지_않고_모두_모름으로_받는다() throws {
        let counter = Counter()
        let before = try Self.draft([Self.add])
        let entries = [PlaylistStampEntry(id: counter.newID(), stamp: Self.stamp(1, [.human], before, 0))]
        let after = try Self.draft([.rename(playlist: .id("B"), name: "x"), Self.add])
        let result = try PlaylistStepStamping.adopt(after, entries: entries, newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries.allSatisfy { $0.stamp.origins == [.unknown] && $0.stamp.revision.value > 100 })
        #expect(!result.draft.stepIDs.contains(entries[0].id))
    }

    // MARK: 저장(save)

    @Test func 같은_내용의_단계가_둘이어도_식별자와_판이_섞이지_않는다() throws {
        let counter = Counter()
        var disk = try Self.draft([Self.add, Self.remove, Self.add])
        let ids = [counter.newID(), counter.newID(), counter.newID()]
        disk.setStepIDs(ids)
        let entries = (0..<3).map { PlaylistStampEntry(id: ids[$0], stamp: Self.stamp(UInt64($0 + 1), [.human], disk, $0)) }
        // 정리가 첫 단계를 뺀 뒤 앱이 식별자 없는 메모리 초안(옛 세 단계)을 저장한다: 마지막 단계가 첫 단계의 식별자를 받지 않는다
        var remaining = disk
        remaining.removeSteps(at: [0])
        let stale = try Self.draft([Self.add, Self.remove, Self.add])
        let result = try PlaylistStepStamping.save(stale, previous: remaining, entries: [entries[1], entries[2]], origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        // 맞춘 둘은 자기 식별자와 도장을 쓰고, 맞지 않는 첫 단계가 새 식별자를 받는다
        #expect(Array(result.draft.stepIDs.suffix(2)) == [ids[1], ids[2]] && !ids.contains(result.draft.stepIDs[0]!))
        #expect(Array(result.entries.suffix(2)) == [entries[1], entries[2]])
    }

    @Test func 합쳐져_내용이_바뀐_단계는_새_판과_합친_출처를_받는다() throws {
        let counter = Counter()
        var disk = PlaylistDraft()
        try disk.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let id = counter.newID()
        disk.setStepIDs([id])
        let entries = [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.cli], disk, 0))]
        // 식별자를 읽은 앱 메모리가 이름을 바꿔(합쳐짐) 저장한다
        var edited = disk
        try edited.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: Self.rekordbox)
        let result = try PlaylistStepStamping.save(edited, previous: disk, entries: entries, origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries.count == 1 && result.entries[0].id == id && result.entries[0].stamp.revision.value > 1)
        #expect(result.entries[0].stamp.origins == [.cli, .human])
        #expect(result.entries[0].stamp.contentHash == PlaylistStepStamping.hash(result.draft.steps[0], in: result.draft))
    }

    /// 식별자 없는 메모리 초안(옛 파일을 앱이 읽은 채)에서 합쳐진 단계는 맞춘 단계 사이 빈틈의 1:1 짝으로 잇는다
    @Test func 식별자_없는_메모리의_합쳐진_단계는_빈틈_짝으로_잇고_모름을_유지한다() throws {
        let counter = Counter()
        var created = PlaylistDraft()
        try created.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        // 도장 없는 옛 파일: 지금 파일은 식별자가 없다
        var edited = created
        try edited.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: Self.rekordbox)
        let result = try PlaylistStepStamping.save(edited, previous: created, entries: [], origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries.count == 1 && result.entries[0].stamp.origins == [.unknown, .human])
    }

    @Test func 식별자_없는_메모리_저장은_지금_파일의_단계와_내용_차례로_맞춘다() throws {
        let counter = Counter()
        var disk = try Self.draft([Self.add, Self.remove])
        let ids = [counter.newID(), counter.newID()]
        disk.setStepIDs(ids)
        let entries = (0..<2).map { PlaylistStampEntry(id: ids[$0], stamp: Self.stamp(UInt64($0 + 1), [.human], disk, $0)) }
        let memory = try Self.draft([Self.add, Self.remove, Self.add])
        let result = try PlaylistStepStamping.save(memory, previous: disk, entries: entries, origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(Array(result.draft.stepIDs.prefix(2)) == ids && Array(result.entries.prefix(2)) == entries)
        #expect(result.entries[2].stamp.origins == [.human] && !ids.contains(result.entries[2].id))
    }

    @Test func 바깥에서_고친_단계는_덮어쓰기_전에_해시가_어긋나_모름이_섞인다() throws {
        let counter = Counter()
        var original = try Self.draft([Self.add])
        let id = counter.newID()
        original.setStepIDs([id])
        let entries = [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.human], original, 0))]
        // 바깥이 단계 내용만 고쳤다(식별자는 그대로, 도장은 옛것)
        var outside = try Self.draft([.addTracks(playlist: .id("A"), contentIDs: ["7"])])
        outside.setStepIDs([id])
        // 앱이 그 파일 위에 단계를 더해 저장한다
        var more = outside
        try more.append(.rename(playlist: .id("B"), name: "x"), rekordbox: Self.rekordbox)
        let result = try PlaylistStepStamping.save(more, previous: outside, entries: entries, origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries[0].stamp.origins == [.human, .unknown] && result.entries[0].stamp.revision.value > 1)
        #expect(result.entries[1].stamp.origins == [.human])
    }

    @Test func 내용이_그대로인_단계는_도장을_그대로_둔다() throws {
        let counter = Counter()
        var disk = try Self.draft([Self.add])
        let id = counter.newID()
        disk.setStepIDs([id])
        let entries = [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.cli], disk, 0))]
        let result = try PlaylistStepStamping.save(disk, previous: disk, entries: entries, origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries == entries)
    }

    @Test func 최장_공통_부분_수열은_차례를_지킨다() throws {
        func hashes(_ names: [String]) throws -> [DraftContentHash] { try names.map { try DraftContentHash(of: $0) } }
        let pairs = PlaylistStepStamping.commonSubsequence(try hashes(["rm", "add"]), try hashes(["add", "rm", "add"]))
        #expect(pairs.map(\.0) == [0, 1] && pairs.map(\.1) == [1, 2])
        #expect(PlaylistStepStamping.commonSubsequence([], try hashes(["a"])).isEmpty)
    }
}
