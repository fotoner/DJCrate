import DJCDomain
import Foundation
import Testing

/// 재생 목록 얼리기(R21, #402): 쓰고 있는 단계(앞 N개)는 `fold`에서 빼고, 쓰는 동안 들어온 새 편집은 뒤에 쌓는다.
/// 쓰는 동안 더한 단계는 쓰는 단계가 만든 모양을 기준(`recoveryBase`)으로 삼아, 쓴 뒤 rekordbox 상태와 맞는다.
@Suite("재생 목록 초안 — 얼리기")
struct PlaylistDraftFreezeTests {
    static let rekordbox = PlaylistDraftTests.library()

    /// 지금 있는 단계를 쓰는 단계로 얼린다: 저장소가 부여하는 식별자를 흉내 내 주고, 얼릴 식별자를 돌려준다
    static func freeze(_ draft: inout PlaylistDraft) -> Set<UUID> {
        let ids = draft.steps.map { _ in UUID() }
        draft.setStepIDs(ids)
        return Set(ids)
    }

    // MARK: - fold에서 뺀다

    @Test func 얼리지_않으면_같은_목록의_이름은_마지막_것만_남는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "라"), rekordbox: Self.rekordbox)
        try draft.append(.rename(playlist: .id("C"), name: "마"), rekordbox: Self.rekordbox)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "마")])
    }

    @Test func 쓰고_있는_이름_바꾸기_단계에는_합치지_않고_뒤에_쌓는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "라"), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.rename(playlist: .id("C"), name: "마"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "라"), .rename(playlist: .id("C"), name: "마")])
    }

    @Test func 쓰고_있는_이름을_rekordbox_이름으로_되돌려도_편집이_사라지지_않는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "라"), rekordbox: Self.rekordbox)
        // 얼리지 않으면 되돌린 이름은 편집이 없다(앞 이름 바꾸기도 함께 빠진다)
        var plain = draft
        try plain.append(.rename(playlist: .id("C"), name: "다"), rekordbox: Self.rekordbox)
        #expect(plain.isEmpty)
        // 앞 단계를 쓰고 있으면 쓴 뒤 이름은 '라'라서 '다'로 되돌리는 단계가 남아야 한다
        let frozen = Self.freeze(&draft)
        try draft.append(.rename(playlist: .id("C"), name: "다"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "라"), .rename(playlist: .id("C"), name: "다")])
    }

    @Test func 쓰고_있는_만들기_단계에는_이름을_합치지_않고_뒤에_쌓는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.rename(playlist: .new("k"), name: "고친 이름"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.create(key: "k", name: "새 목록", isFolder: false, parent: .root),
                                .rename(playlist: .new("k"), name: "고친 이름")])
    }

    @Test func 쓰고_있는_만들기_단계는_지워도_없던_일로_하지_않는다() throws {
        var plain = PlaylistDraft()
        try plain.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        var writing = plain
        let frozen = Self.freeze(&writing)
        try plain.append(.delete(playlist: .new("k")), rekordbox: Self.rekordbox)
        #expect(plain.isEmpty, "얼리지 않으면 만든 편집부터 없던 일이다")
        try writing.append(.delete(playlist: .new("k")), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(writing.edits == [.create(key: "k", name: "새 목록", isFolder: false, parent: .root), .delete(playlist: .new("k"))])
    }

    @Test func 쓰고_있는_단계_뒤에_쌓은_단계끼리는_전처럼_합친다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "쓰는 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.create(key: "j", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox, frozen: frozen)
        try draft.append(.rename(playlist: .new("j"), name: "고친 이름"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.create(key: "k", name: "쓰는 목록", isFolder: false, parent: .root),
                                .create(key: "j", name: "고친 이름", isFolder: false, parent: .root)])
        try draft.append(.delete(playlist: .new("j")), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.create(key: "k", name: "쓰는 목록", isFolder: false, parent: .root)], "쓰고 있지 않은 만들기는 지우면 없던 일이다")
    }

    @Test func 쓰는_단계가_이어져_있지_않아도_쓰는_단계만_얼린다() throws {
        // 쓰는 묶음이 한 목록의 단위일 때(K행 나눠 쓰기): 가운데 다른 목록의 단계는 이번에 쓰지 않는다
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "라"), rekordbox: Self.rekordbox)
        try draft.append(.rename(playlist: .id("A"), name: "가나"), rekordbox: Self.rekordbox)
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        let ids = draft.steps.map { _ in UUID() }
        draft.setStepIDs(ids)
        let frozen: Set<UUID> = [ids[0], ids[2]]
        try draft.append(.rename(playlist: .id("C"), name: "마"), rekordbox: Self.rekordbox, frozen: frozen)
        try draft.append(.rename(playlist: .id("A"), name: "가다"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "라"), .addTracks(playlist: .id("C"), contentIDs: ["7"]),
                                .rename(playlist: .id("C"), name: "마"), .rename(playlist: .id("A"), name: "가다")],
                "쓰지 않는 A의 이름은 전처럼 마지막 것만 남고, 쓰는 C의 이름은 따로 쌓인다")
    }

    // MARK: - 쓰는 동안 더한 단계의 기준

    /// 앞 단계를 쓴 뒤의 rekordbox 모양
    static func afterWriting(_ edits: [PlaylistEdit]) throws -> PlaylistLayout {
        var layout = rekordbox
        for edit in edits { try layout.apply(edit) }
        return layout
    }

    @Test func 쓰고_있는_단계가_바꾸는_목록에_더한_단계는_쓴_뒤_모양을_기준으로_삼는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["8"]), rekordbox: Self.rekordbox, frozen: frozen)
        let written = try Self.afterWriting([.addTracks(playlist: .id("C"), contentIDs: ["7"])])

        // 쓰는 중(옛 사본 위에 보인다): 두 단계 모두 쓸 수 있고 목록에 7과 8이 다 든다
        let during = draft.project(onto: Self.rekordbox, frozen: frozen)
        #expect(during.blocked == [nil, nil])
        #expect(during.layout.item("C")?.trackIDs == ["5", "7", "8"])

        // 쓴 뒤: 앞 단계를 빼면 남은 단계는 쓴 사본 위에서 막히지 않는다
        var remaining = draft
        remaining.removeSteps(at: [0])
        #expect(remaining.edits == [.addTracks(playlist: .id("C"), contentIDs: ["8"])])
        #expect(remaining.project(onto: written).blocked == [nil])
        #expect(remaining.project(onto: written).layout.item("C")?.trackIDs == ["5", "7", "8"])
    }

    @Test func 앞_단계를_쓰지_못했으면_그_결과를_기준으로_한_단계는_낡은_것으로_막힌다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["8"]), rekordbox: Self.rekordbox, frozen: frozen)
        // 앞 단계를 쓰지 못해 두 단계가 모두 남고 rekordbox는 그대로다: 앞 단계는 쓸 수 있고, 그 결과를 기준으로 한 단계는 막힌다
        let blocked = draft.project(onto: Self.rekordbox).blocked
        #expect(blocked[0] == nil)
        #expect(blocked[1] != nil)
    }

    @Test func 쓰고_있는_단계가_건드리지_않은_목록의_단계는_공유_기준을_쓴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.rename(playlist: .id("A"), name: "바꾼 이름"), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.steps[1].recoveryBase == nil)
        #expect(draft.base["A"] != nil)
    }

    // MARK: - 버리기

    @Test func 목록의_초안을_버려도_쓰고_있는_단계는_남는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["8"]), rekordbox: Self.rekordbox, frozen: frozen)
        try draft.append(.rename(playlist: .id("A"), name: "바꾼 이름"), rekordbox: Self.rekordbox, frozen: frozen)
        draft.discard(playlist: "C", rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.addTracks(playlist: .id("C"), contentIDs: ["7"]), .rename(playlist: .id("A"), name: "바꾼 이름")])
        draft.discard(playlist: "A", rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.addTracks(playlist: .id("C"), contentIDs: ["7"])])
    }

    @Test func 쓰고_있는_만들기_단계가_만든_목록을_버려도_그_목록의_쓰는_단계는_남고_뒤_단계만_버린다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.addTracks(playlist: .new("k"), contentIDs: ["7"]), rekordbox: Self.rekordbox, frozen: frozen)
        draft.discard(playlist: "new:k", rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.edits == [.create(key: "k", name: "새 목록", isFolder: false, parent: .root)])
    }

    @Test func 막힌_편집을_버려도_쓰고_있는_단계는_남는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "라"), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.rename(playlist: .id("A"), name: "바꾼 이름"), rekordbox: Self.rekordbox, frozen: frozen)
        // rekordbox에서 C와 A가 모두 바뀌었다
        let changed = PlaylistLayout([(PlaylistDraftTests.item("F", "폴더", folder: true), 1),
                                      (PlaylistDraftTests.item("A", "다른", parent: "F", tracks: ["1", "2", "3"]), 1),
                                      (PlaylistDraftTests.item("C", "다른 다", tracks: ["5"]), 2)])
        var plain = draft
        plain.discardBlocked(rekordbox: changed)
        #expect(plain.isEmpty)
        draft.discardBlocked(rekordbox: changed, frozen: frozen)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "라")], "쓰고 있는 앞 단계는 그대로, 뒤 단계만 버린다")
    }

    // MARK: - 새 목록 ID 옮기기

    @Test func 남은_단계의_대상과_목적지의_새_목록_키를_받은_ID로_옮긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "a", name: "폴더", isFolder: true, parent: .root), rekordbox: Self.rekordbox)
        try draft.append(.create(key: "b", name: "목록", isFolder: false, parent: .new("a")), rekordbox: Self.rekordbox)
        try draft.append(.addTracks(playlist: .new("b"), contentIDs: ["7"]), rekordbox: Self.rekordbox)
        try draft.append(.move(playlist: .id("C"), into: .new("a")), rekordbox: Self.rekordbox)
        try draft.append(.rename(playlist: .id("A"), name: "그대로"), rekordbox: Self.rekordbox)
        let ids = draft.stepIDs
        let remapped = draft.remapped([PlaylistRef.new("a").layoutID: "900", PlaylistRef.new("b").layoutID: "901"])
        #expect(remapped.edits == [.create(key: "a", name: "폴더", isFolder: true, parent: .root),
                                   .create(key: "b", name: "목록", isFolder: false, parent: .id("900")),
                                   .addTracks(playlist: .id("901"), contentIDs: ["7"]),
                                   .move(playlist: .id("C"), into: .id("900")),
                                   .rename(playlist: .id("A"), name: "그대로")])
        #expect(remapped.stepIDs == ids, "식별자는 그대로다")
    }

    @Test func 옮길_ID가_없으면_초안은_그대로다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "a", name: "목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        #expect(draft.remapped([:]) == draft)
        #expect(draft.remapped([PlaylistRef.new("zzz").layoutID: "900"]) == draft)
    }

    // MARK: - 리뷰 1라운드(S3·S4·S5)

    @Test func S3_폴더_이름을_쓰는_동안_그_폴더_안_순서를_바꿔도_쓰는_단계의_공유_기준과_해시는_그대로다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("F"), name: "바꾼 폴더"), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        let hash = try DraftContentHash(step: draft.steps[0], in: draft)
        let shared = draft.base["F"]

        try draft.append(.reorder(playlist: .id("B"), index: 0), rekordbox: Self.rekordbox, frozen: frozen)

        #expect(draft.base["F"] == shared, "쓰는 단계가 기대는 공유 기준에 자식 순서를 더하지 않는다")
        #expect(try DraftContentHash(step: draft.steps[0], in: draft) == hash, "쓰는 단계의 해시가 바뀌지 않아 쓴 뒤 정리가 판으로 찾는다")
        let base = try #require(draft.steps[1].recoveryBase?["F"])
        #expect(base.name == "바꾼 폴더" && base.childIDs == ["A", "B"], "새 순서 편집의 기준은 그 단계 안에 쓴 뒤 모양으로 둔다")
        // 쓴 뒤 앞 단계를 빼면 남은 순서 편집은 막히지 않는다
        let written = try Self.afterWriting([.rename(playlist: .id("F"), name: "바꾼 폴더")])
        var remaining = draft
        remaining.removeSteps(at: [0])
        #expect(remaining.project(onto: written).blocked == [nil])
    }

    @Test func S4_쓰는_동안_맨_위에_새_목록이_생기면_순서_편집_기준의_새_목록_키도_받은_ID로_옮긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        try draft.append(.reorder(playlist: .id("C"), index: 0), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.steps[1].recoveryBase?[PlaylistLayout.root]?.childIDs == ["new:k", "F", "C", "S"])
        // 쓴 뒤 rekordbox: 새 목록이 맨 위에 실제 ID(900)로 생겼다
        let written = PlaylistDraftTests.library(extra: [(PlaylistDraftTests.item("900", "새 목록"), 0)])
        var remaining = draft
        remaining.removeSteps(at: [0])

        let moved = remaining.remapped(["new:k": "900"])

        #expect(moved.steps[0].recoveryBase?[PlaylistLayout.root]?.childIDs == ["900", "F", "C", "S"])
        #expect(moved.project(onto: written).blocked == [nil], "정상 순서 편집이 막히지 않는다")
    }

    @Test func S4_기준의_부모_ID에_든_새_목록_키도_옮긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "a", name: "폴더", isFolder: true, parent: .root), rekordbox: Self.rekordbox)
        try draft.append(.move(playlist: .id("C"), into: .new("a")), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)
        // 새 폴더로 옮겨 쓰는 동안 그 목록의 곡을 고친다: 곡 편집의 기준(쓴 뒤 C)은 부모가 새 폴더다
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["9"]), rekordbox: Self.rekordbox, frozen: frozen)
        #expect(draft.steps[2].recoveryBase?["C"]?.parentID == "new:a")
        var remaining = draft
        remaining.removeSteps(at: [0, 1])

        let moved = remaining.remapped(["new:a": "900"])

        #expect(moved.steps[0].recoveryBase?["C"]?.parentID == "900")
        // 쓴 뒤 rekordbox: 새 폴더(900) 안에 C가 있다
        let written = PlaylistDraftTests.library(extra: [(PlaylistDraftTests.item("900", "폴더", folder: true), 0)])
        var layout = written
        try layout.apply(.move(playlist: .id("C"), into: .id("900")))
        #expect(moved.project(onto: layout).blocked == [nil])
    }

    @Test func S5_목록을_폴더로_옮겨_쓰는_동안_그_폴더를_지우면_쓴_뒤_구조의_하위_목록_기준을_남긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.move(playlist: .id("C"), into: .id("F")), rekordbox: Self.rekordbox)
        let frozen = Self.freeze(&draft)

        try draft.append(.delete(playlist: .id("F")), rekordbox: Self.rekordbox, frozen: frozen)

        let step = draft.steps[1]
        #expect(Set(step.depends) == ["F", "A", "B", "C"], "방금 들어온 C도 삭제 기준에 든다")
        #expect(step.recoveryBase?["C"]?.parentID == "F")
        let written = try Self.afterWriting([.move(playlist: .id("C"), into: .id("F"))])
        var remaining = draft
        remaining.removeSteps(at: [0])
        #expect(remaining.project(onto: written).blocked == [nil], "쓴 뒤 구조에서는 삭제가 막히지 않는다")
        // 쓴 뒤 rekordbox에서 C에 곡이 더해졌으면 지우지 않는다
        var changed = written
        try changed.apply(.addTracks(playlist: .id("C"), contentIDs: ["9"]))
        #expect(remaining.project(onto: changed).blocked[0] != nil)
    }
}
