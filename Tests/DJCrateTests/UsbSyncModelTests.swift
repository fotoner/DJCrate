@testable import DJCrate
import DJCApplication
import DJCDomain
import Observation
import Synchronization
import Testing

/// 동기화 창 화면 모델(`UsbSyncModel`): 유스케이스(`UsbSync`)가 내보낸 상태·알림을 관찰 상태와 오류·안내 칸으로 옮긴다.
@Suite("USB 동기화 창 화면 모델")
@MainActor
struct UsbSyncModelTests {
    @Test func 알림을_오류와_안내_칸에_보이고_지운다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        model.show(.problem("막힘"))
        model.show(.info("결과"))
        #expect(model.error == "막힘" && model.message == "결과")
        model.show(.clearInfo)
        #expect(model.error == "막힘" && model.message == nil)
        model.show(.clearProblem)
        #expect(model.error == nil)
    }

    /// 유스케이스가 "다음 닫기까지 남김"을 돌려주면 보이던 이유 뒤에 안내를 붙인다(오류가 없으면 안내 칸에)
    @Test func 다음_닫기까지_남기면_보이던_이유_뒤에_안내를_붙인다() {
        let hint = "한 번 더 닫으면 USB에 쓰지 않고 닫습니다."
        let failed = UsbSyncModel(volumeKey: "synthetic")
        failed.show(.problem("rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요"))
        #expect(!failed.finishClose(.stayUntilNextClose))
        #expect(failed.error == "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요\n" + hint && failed.message == nil)
        let noticed = UsbSyncModel(volumeKey: "synthetic")
        noticed.show(.info("쓰기 결과 설명"))
        #expect(!noticed.finishClose(.stayUntilNextClose))
        #expect(noticed.error == nil && noticed.message == "쓰기 결과 설명\n" + hint)
        let quiet = UsbSyncModel(volumeKey: "synthetic")
        #expect(!quiet.finishClose(.stayUntilNextClose) && quiet.message == hint)
        #expect(quiet.finishClose(.close) && !quiet.finishClose(.stay))
        #expect(quiet.message == hint, "그냥 남길 때는 안내를 더 붙이지 않는다")
    }

    /// 동기화 후 미리 보기 칸의 문구(계획의 표시 값 → 화면 문구)
    @Test func 미리_보기_칸_표시_문구() {
        #expect(UsbSyncPreviewMark.created.note == "새로 만듦" && UsbSyncPreviewMark.moved.note == "옮김")
        #expect(UsbSyncPreviewMark.deleted.note == "지움")
        #expect(UsbSyncPreviewMark.unlinked.note == nil)
    }

    /// 흐린 줄의 뜻은 툴팁으로 말한다(#313). 새로 만듦·옮김은 줄 옆 글이 뜻이라 툴팁이 없다. 툴팁은 한 문장 75자 이내(STR-13)
    @Test func 흐린_줄과_지울_줄의_툴팁() {
        #expect(UsbSyncPreviewMark.unlinked.hint == "동기화에 이어지지 않아 USB에 그대로 남습니다")
        #expect(UsbSyncPreviewMark.deleted.hint == "동기화하면 USB에서 지웁니다")
        #expect(UsbSyncPreviewMark.created.hint == nil && UsbSyncPreviewMark.moved.hint == nil)
        let all = [UsbSyncPreviewMark.unlinked.hint, UsbSyncPreviewMark.deleted.hint, UsbSyncModel.currentUsbDimmedHint,
                   UsbSyncModel.selectionLockedHint].compactMap { $0 }
        // 한 문장: 문장 중간에 마침표가 없고 줄 바꿈이 없다
        #expect(all.count == 4 && all.allSatisfy { $0.count <= 75 && !$0.contains("\n") && !$0.contains(". ") })
    }

    /// 접힌 폴더 안의 변경은 폴더 줄이 건수로 알린다(펼침과 상관없이). 폴더가 옮김이면 안쪽 건수도 함께 보이고,
    /// 새로 만든·지울 폴더는 안쪽이 모두 같은 표시라 자기 표시만 보인다
    @Test func 폴더_줄은_안의_변경_건수를_알린다() throws {
        func item(_ id: String, parent: String = PlaylistLayout.root, folder: Bool = false) -> (item: PlaylistLayout.Item, seq: Int) {
            (PlaylistLayout.Item(id: id, name: id, parentID: parent, isFolder: folder), 0)
        }
        let tree = PlaylistOutlineNode.tree(PlaylistLayout([
            item("outer", folder: true), item("a", parent: "outer"), item("b", parent: "outer"),
            item("inner", parent: "outer", folder: true), item("c", parent: "inner"), item("d", parent: "inner"),
            item("empty", folder: true), item("z"),
        ]))
        func node(_ id: String) throws -> PlaylistOutlineNode { try #require(tree.lazy.compactMap { $0.find(id) }.first) }
        let outer = try node("outer"), inner = try node("inner"), created = try node("a"), gray = try node("b"), plain = try node("z")
        let empty = try node("empty")
        let marks: [String: UsbSyncPreviewMark] = ["a": .created, "c": .deleted, "d": .moved, "b": .unlinked]
        // 연결 없음(회색)은 바뀌는 것이 아니라 세지 않는다
        #expect(UsbSyncModel.note(of: outer, marks: marks) == "하위 3건 변경")
        #expect(UsbSyncModel.note(of: inner, marks: marks) == "하위 2건 변경")
        #expect(UsbSyncModel.note(of: created, marks: marks) == "새로 만듦")
        #expect(UsbSyncModel.note(of: gray, marks: marks) == nil)
        #expect(UsbSyncModel.note(of: plain, marks: marks) == nil)
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .deleted, "a": .deleted]) == "지움")
        // 새로 만든 폴더 안의 새 목록은 폴더 표시와 같아 세지 않지만, 기존 목록이 옮겨 들어오면 접힌 폴더에서도 보이게 센다
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .created, "a": .created]) == "새로 만듦")
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .created, "a": .created, "b": .moved]) == "새로 만듦 · 하위 1건 변경")
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .created, "a": .created]) == "새로 만듦")
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .moved, "c": .deleted]) == "옮김 · 하위 1건 변경")
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .moved]) == "옮김")
        #expect(UsbSyncModel.note(of: outer, marks: ["outer": .unlinked, "c": .deleted]) == "하위 1건 변경")
        #expect(UsbSyncModel.note(of: empty, marks: marks) == nil)
        #expect(UsbSyncModel.note(of: outer, marks: [:]) == nil)
    }

    /// 핵심부 유스케이스는 관찰 가능하지 않다. 체크를 바꾸면 유스케이스 상태가 화면 모델로 와서 관찰이 알린다
    @Test func 유스케이스_상태가_바뀌면_화면_모델의_관찰이_알린다() {
        let model = UsbSyncModel(volumeKey: "synthetic")
        let changed = Mutex(false)
        withObservationTracking { _ = model.selection } onChange: { changed.withLock { $0 = true } }
        model.selectAllRekordbox()
        #expect(changed.withLock { $0 })
        #expect(model.selection.selectedIDs.contains(UsbSyncSource.rekordboxSelectionID))
    }
}
