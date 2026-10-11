@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 태그 인스펙터 화면 모델(#250): 고른 곡의 칸 값·초안 표시·충돌·잠금 이유를 화면 값으로 바꾸고, 고친 값을 태그 편집 조각(`TagEditStore`)에 넘긴다.
/// 받는 값 규칙은 `TagEditRulesTests`·`EditTagsTests`가 본다. 여기서는 연결과 화면 값만 본다(초안 저장은 가짜, DB 없음).
@Suite("태그 인스펙터 화면 모델")
@MainActor
struct TagInspectorModelTests {
    static func row(_ id: String, key: String? = "5A", title: String? = nil, comment: String = "", staged: Bool = false,
                    streaming: Bool = false, usb: Bool = false) -> TrackRow {
        let trackID = usb ? TrackRow.usbIDPrefix + id : staged ? "djc-\(id)" : id
        return TrackRow(track: Track(id: trackID, uuid: "uuid-\(id)", title: title ?? "곡 \(id)", artist: "가수", album: nil,
                                     albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120,
                                     lengthSeconds: 30, folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: comment,
                                     importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false,
                                     dataStatus: staged || streaming ? nil : 0),
                        cues: [], playCount: 0)
    }

    let store = LibraryStore.test(saveTagDrafts: { _ in })

    @Test func 칸_값은_모두_같을_때만_보이고_고친_칸은_초안으로_표시한다() {
        let model = TagInspectorModel(store: store)
        let a = Self.row("a"), b = Self.row("b"), c = Self.row("c", key: "8B")
        #expect(model.field(.musicalKey, rows: [a, b]) == TagInspectorModel.Field(value: "5A", mixed: false, edited: false))
        #expect(model.field(.musicalKey, rows: [a, c]) == TagInspectorModel.Field(value: "", mixed: true, edited: false))
        model.setText(.title, "새 제목", rows: [a, b])
        #expect(model.field(.title, rows: [a, b]) == TagInspectorModel.Field(value: "새 제목", mixed: false, edited: true))
        #expect(model.field(.title, rows: [a, c]).edited, "고른 곡 가운데 하나라도 고쳤으면 초안 표시")
        #expect(model.draftCount([a, b, c]) == 2)
    }

    @Test func USB와_스트리밍_곡이_섞이면_이유를_보이고_모두면_글자_칸을_막는다() {
        let model = TagInspectorModel(store: store)
        let local = Self.row("a"), usb = Self.row("u", usb: true), streaming = Self.row("s", streaming: true)
        let reason = TrackListTagEditing.unavailableReason(usb, key: .title)
        #expect(model.lockReason([local]) == nil && reason != nil)
        #expect(model.lockReason([local, usb]) == reason)
        #expect(!model.isTextLocked([local, usb]) && model.isTextLocked([usb, streaming]))
        #expect(model.textHelp(.title, rows: [usb, local]) == reason && model.textHelp(.title, rows: [local]) == TagFields.Key.title.label)
        model.setText(.title, "새 제목", rows: [local, usb, streaming])
        #expect(Set(store.tagDrafts.keys) == [local.track.uuid], "고칠 수 없는 곡은 빼고 쓴다")
    }

    @Test func 키와_평점_곡_색_고르기는_고칠_수_있는_곡에만_넣는다() {
        let model = TagInspectorModel(store: store)
        let local = Self.row("a"), staged = Self.row("b", staged: true), streaming = Self.row("s", streaming: true)
        model.pickKey("8A", rows: [local, staged, streaming])
        #expect(Set(store.tagDrafts.keys) == [local.track.uuid, staged.track.uuid], "추가한 곡도 키는 고른다")
        model.pick(.rating, "3", rows: [local, staged])
        #expect(store.tagDrafts[local.track.uuid]?.fields.rating == "3")
        #expect(store.tagDrafts[staged.track.uuid]?.fields.rating == "", "추가한 곡의 평점은 넣은 뒤 고친다")
        #expect(model.trackColors == store.trackColors)
    }

    @Test func 충돌한_칸은_곡_하나일_때만_보이고_고르면_풀린다() {
        let model = TagInspectorModel(store: store)
        let old = Self.row("a", title: "옛 제목"), fresh = Self.row("a", title: "rekordbox 제목")
        var draft = TagDraft(trackUUID: old.track.uuid, base: old.tagFields)
        draft.fields.title = "내 제목"
        store.tagDrafts[old.track.uuid] = draft
        store.rowsByUUID[old.track.uuid] = fresh
        #expect(model.conflict(.title, rows: [fresh]) == TagInspectorModel.Conflict(current: "rekordbox 제목", draft: "내 제목"))
        #expect(model.conflict(.title, rows: [fresh, Self.row("b")]) == nil, "여러 곡이면 보이지 않는다")
        #expect(model.conflict(.artist, rows: [fresh]) == nil)
        model.resolveConflict(.title, keepingDraft: true, rows: [fresh])
        #expect(model.conflict(.title, rows: [fresh]) == nil)
        #expect(store.tagDrafts[old.track.uuid]?.fields.title == "내 제목" && store.tagDrafts[old.track.uuid]?.base.title == "rekordbox 제목")
    }

    @Test func 쓰기_전_문제와_현재값_가져오기와_코멘트_분류를_보인다() {
        let model = TagInspectorModel(store: store)
        let a = Self.row("a"), b = Self.row("b", comment: "다른 코멘트")
        #expect(model.issues([a]) == nil && model.recoverableRow([a]) == nil)
        model.setText(.year, "올해", rows: [a])
        #expect(model.issues([a]) == "연도를 숫자로 고친 뒤 rekordbox에 쓰세요")
        #expect(model.recoverableRow([a]) == a && model.recoverableRow([a, b]) == nil)
        #expect(!model.isRecoveringDraft)
        #expect(model.commentEvaluation([a]) == nil, "프리셋이 없으면 분류하지 않는다")
        store.commentPreset = .anisong
        #expect(model.commentEvaluation([a]) == CommentPreset.anisong.rule?.evaluate(""))
        #expect(model.commentEvaluation([a, b]) == nil, "여러 값이면 분류하지 않는다")
    }

    @Test func 초안_버리기와_되돌리기는_조각의_한_단위다() {
        let model = TagInspectorModel(store: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let a = Self.row("a")
        model.setText(.title, "새 제목", rows: [a])
        model.revert(rows: [a])
        #expect(store.tagDrafts.isEmpty)
        #expect(undo.undoActionName == "태그 편집")
        undo.undo()
        #expect(store.tagDrafts[a.track.uuid]?.fields.title == "새 제목")
    }

    @Test func 쓰기를_시작하면_태그_되돌리기_단계를_지운다() {
        // 되돌리기 대상은 공유 핵심이다. 쓰기 잠금이 핵심을 대상으로 지우므로 조각이 대상이면 쓴 뒤에도 옛 초안을 되살릴 수 있다.
        let model = TagInspectorModel(store: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        model.setText(.title, "새 제목", rows: [Self.row("a")])
        #expect(undo.canUndo)
        store.isWritingRekordbox = true
        #expect(!undo.canUndo)
    }

    @Test func 글자_칸_정체는_고른_곡이_바뀌면_바뀐다() {
        let model = TagInspectorModel(store: store)
        store.selection = ["a"]
        let first = model.fieldID(.title)
        #expect(model.fieldID(.artist) != first)
        store.selection = ["b"]
        #expect(model.fieldID(.title) != first)
    }

    @Test func 조립_지점은_인스펙터_모델을_한_번_만들어_둔다() {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts(), settings: store.settings), runsAnalysis: false)
        let app = AppComposition(store: store, deck: deck)
        #expect(app.tagInspector === app.tagInspector)
        app.tagInspector.setText(.title, "새 제목", rows: [Self.row("a")])
        #expect(store.tagDrafts["uuid-a"] != nil, "조립 지점의 모델은 그 저장소를 고친다")
    }
}
