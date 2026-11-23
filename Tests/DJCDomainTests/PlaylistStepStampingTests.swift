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

    @Test func 도장이_없는_단계는_모름_도장을_받고_도장이_있는_단계는_그대로다() throws {
        let counter = Counter()
        var draft = try Self.draft([Self.add, Self.remove, Self.add])
        let ids = [counter.newID(), counter.newID()]
        draft.setStepIDs([ids[0], ids[1], nil])
        let result = try PlaylistStepStamping.adopt(draft, entries: [PlaylistStampEntry(id: ids[0], stamp: Self.stamp(1, [.human], draft, 0))],
                                                    newID: counter.newID, newRevision: counter.newRevision)
        let adopted = result.draft.stepIDs.compactMap { $0 }
        #expect(adopted.count == 3 && Set(adopted).count == 3 && Array(adopted.prefix(2)) == ids)
        #expect(result.entries[0].stamp.origins == [.human] && result.entries[0].stamp.revision == DraftRevision(1))
        #expect(result.entries[1].stamp.origins == [.unknown] && result.entries[2].stamp.origins == [.unknown])
    }

    /// 원칙: 단계의 동일성을 확인할 수 없으면 옛 판을 어떤 단계에도 붙이지 않는다. 단계 수가 같아도 같은 자리의 도장을 잇지 않는다
    /// 같은 식별자를 가진 단계가 둘 이상이면 어느 단계가 그 식별자의 단계인지 확인할 수 없다: 모두 새 식별자·새 판·모름을 받는다
    @Test func 식별자가_겹친_단계는_모두_새_식별자와_모름_도장을_받는다() throws {
        let counter = Counter()
        var written = try Self.draft([Self.add])
        let id = counter.newID()
        written.setStepIDs([id])
        let entries = [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.human], written, 0))]
        var outside = try Self.draft([.rename(playlist: .id("B"), name: "x"), Self.add])
        outside.setStepIDs([id, id])
        let result = try PlaylistStepStamping.adopt(outside, entries: entries, newID: counter.newID, newRevision: counter.newRevision)
        let ids = result.draft.stepIDs.compactMap { $0 }
        #expect(ids.count == 2 && Set(ids).count == 2 && !ids.contains(id))
        #expect(result.entries.allSatisfy { $0.stamp.origins == [.unknown] && $0.stamp.revision.value > 100 })
        // 저장하는 초안에서도 겹친 식별자는 어느 단계도 잇지 않는다(이번 출처와 모름)
        let saved = try PlaylistStepStamping.save(outside, previous: written, entries: entries, origin: .human,
                                                  newID: counter.newID, newRevision: counter.newRevision)
        #expect(!saved.draft.stepIDs.contains(id) && saved.entries.allSatisfy { $0.stamp.origins == [.human, .unknown] })
    }

    @Test func 식별자가_없으면_단계_수가_같아도_같은_자리의_도장을_잇지_않는다() throws {
        let counter = Counter()
        let before = try Self.draft([Self.add, .rename(playlist: .id("B"), name: "x")])
        let ids = [counter.newID(), counter.newID()]
        let entries = [PlaylistStampEntry(id: ids[0], stamp: Self.stamp(1, [.human], before, 0)),
                       PlaylistStampEntry(id: ids[1], stamp: Self.stamp(2, [.human], before, 1))]
        // 식별자를 모르는 쪽이 [쓴 A, 막힌 B]를 [막힌 B, 새 C]로 다시 썼다
        let rewritten = try Self.draft([.rename(playlist: .id("B"), name: "x"), .addTracks(playlist: .id("B"), contentIDs: ["7"])])
        let result = try PlaylistStepStamping.adopt(rewritten, entries: entries, newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries.allSatisfy { $0.stamp.origins == [.unknown] && $0.stamp.revision.value > 100 })
        #expect(Set(result.draft.stepIDs.compactMap { $0 }).isDisjoint(with: ids))
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

    @Test func 같은_내용의_단계가_둘이어도_식별자가_판을_가른다() throws {
        let counter = Counter()
        var disk = try Self.draft([Self.add, Self.remove, Self.add])
        let ids = [counter.newID(), counter.newID(), counter.newID()]
        disk.setStepIDs(ids)
        let entries = (0..<3).map { PlaylistStampEntry(id: ids[$0], stamp: Self.stamp(UInt64($0 + 1), [.human], disk, $0)) }
        // 정리가 첫 단계를 뺀 파일을 식별자를 받은 앱이 그대로 저장한다: 남은 두 단계는 자기 도장을 쓴다
        var remaining = disk
        remaining.removeSteps(at: [0])
        let result = try PlaylistStepStamping.save(remaining, previous: remaining, entries: [entries[1], entries[2]], origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.draft.stepIDs == [ids[1], ids[2]] && result.entries == [entries[1], entries[2]])
    }

    /// 원칙: 식별자 없는 메모리 초안의 단계는 지금 파일의 단계와 맞춰 보지 않는다. 내용이 같아도 새 단계(이번 출처 하나)다
    @Test func 식별자_없는_단계는_지금_파일의_단계와_맞춰_보지_않고_새_단계로_받는다() throws {
        let counter = Counter()
        var disk = try Self.draft([Self.add, Self.remove])
        let ids = [counter.newID(), counter.newID()]
        disk.setStepIDs(ids)
        let entries = (0..<2).map { PlaylistStampEntry(id: ids[$0], stamp: Self.stamp(UInt64($0 + 1), [.cli], disk, $0)) }
        let memory = try Self.draft([Self.add, Self.remove, Self.add])
        let result = try PlaylistStepStamping.save(memory, previous: disk, entries: entries, origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(Set(result.draft.stepIDs.compactMap { $0 }).isDisjoint(with: ids) && result.draft.stepIDs.compactMap { $0 }.count == 3)
        #expect(result.entries.allSatisfy { $0.stamp.origins == [.human] && $0.stamp.revision.value > 100 })
    }

    /// 식별자가 있는데 지금 파일에 없는 단계(정리로 빠진 단계를 낡은 메모리가 되살림)는 새 판에 모름을 더한다
    @Test func 정리로_빠진_단계를_낡은_메모리가_되살리면_모름을_더한다() throws {
        let counter = Counter()
        var memory = try Self.draft([Self.add])
        let id = counter.newID()
        memory.setStepIDs([id])
        let result = try PlaylistStepStamping.save(memory, previous: PlaylistDraft(), entries: [], origin: .human,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.draft.stepIDs == [id] && result.entries[0].stamp.origins == [.human, .unknown])
    }

    /// S3: 지금 파일을 읽지 못했으면(손상) 빈 파일과 다르다: 기존 도장의 출처를 잇고 모름을 더한다. 새 출처 하나만 받지 않는다
    @Test func 지금_파일을_읽지_못했으면_기존_출처를_잇고_모름을_더한다() throws {
        let counter = Counter()
        var memory = try Self.draft([Self.add])
        let id = counter.newID()
        memory.setStepIDs([id])
        try memory.append(.rename(playlist: .id("B"), name: "x"), rekordbox: Self.rekordbox)
        let entries = [PlaylistStampEntry(id: id, stamp: Self.stamp(1, [.cli], memory, 0))]
        let result = try PlaylistStepStamping.save(memory, previous: PlaylistDraft(), entries: entries, origin: .human, previousUnreadable: true,
                                                   newID: counter.newID, newRevision: counter.newRevision)
        #expect(result.entries[0].stamp.origins == [.cli, .human, .unknown] && result.entries[0].stamp.revision.value > 100)
        // 식별자가 없던 새 단계도 모름을 더한다
        #expect(result.entries[1].stamp.origins == [.human, .unknown])
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

    // MARK: 식별자 잇기(S2)

    /// 같은 대상의 마지막 편집만 쓰는 이름 바꾸기는 지운 단계의 식별자를 새 단계에 잇는다
    @Test func 이름을_다시_바꾸면_지운_단계의_식별자를_새_단계가_잇는다() throws {
        var draft = try Self.draft([.rename(playlist: .id("A"), name: "x"), Self.add])
        let ids = [UUID(), UUID()]
        draft.setStepIDs(ids)
        try draft.append(.rename(playlist: .id("A"), name: "y"), rekordbox: Self.rekordbox)
        #expect(draft.steps.map(\.edit) == [Self.add, .rename(playlist: .id("A"), name: "y")])
        #expect(draft.stepIDs == [ids[1], ids[0]])
        // 새 단계가 하나 더 붙는 편집은 식별자가 없다
        try draft.append(.rename(playlist: .id("B"), name: "z"), rekordbox: Self.rekordbox)
        #expect(draft.stepIDs.last! == nil)
        // rekordbox 이름으로 되돌리면 편집이 없다: 단계가 사라지고 식별자도 함께 사라진다
        var back = try Self.draft([.rename(playlist: .id("A"), name: "x")])
        back.setStepIDs([ids[0]])
        try back.append(.rename(playlist: .id("A"), name: "가"), rekordbox: Self.rekordbox)
        #expect(back.steps.isEmpty)
    }
}
