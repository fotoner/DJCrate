import DJCApplication
import DJCDomain
import Testing

/// 태그 초안 편집 유스케이스(#250): 칸 바꾸기·초안 버리기·충돌 고르기를 되돌리기 한 단위로 만들고 저장 포트로 저장한다.
/// 칸마다 받는 값의 자세한 표는 `TagEditRulesTests`(DJCDomainTests)가 본다. 여기서는 순서와 거르기를 본다. 저장 포트는 메모리 구현이다.
@MainActor
@Suite("태그 초안 편집")
struct EditTagsTests {
    static func row(_ uuid: String, key: String? = "5A", rating: Int = 0, title: String = "곡", staged: Bool = false,
                    streaming: Bool = false, usb: Bool = false) -> TrackRow {
        let id = usb ? TrackRow.usbIDPrefix + uuid : staged ? "djc-\(uuid)" : "id-\(uuid)"
        return TrackRow(track: Track(id: id, uuid: uuid, title: title, artist: nil, album: nil, albumArtist: nil, genre: nil,
                                     composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 180,
                                     folderPath: streaming ? "spotify:track:\(uuid)" : "/x/\(uuid).mp3", comment: "", importedOn: nil,
                                     analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: rating,
                                     dataStatus: staged ? nil : 0),
                        cues: [], playCount: 0)
    }

    let memory = MemoryDrafts()
    var edit: EditTags { EditTags(drafts: memory.store) }
    let colors = TrackColor.rekordboxDefaults

    @Test func 여러_칸을_한_단위로_바꾸고_스트리밍과_USB_곡은_거른다() throws {
        let local = Self.row("a"), streaming = Self.row("s", streaming: true), usb = Self.row("u", usb: true)
        let change = try #require(edit.edit([EditTags.Change(row: local, key: .title, value: "새 제목"),
                                             EditTags.Change(row: local, key: .artist, value: "새 가수"),
                                             EditTags.Change(row: streaming, key: .title, value: "x"),
                                             EditTags.Change(row: usb, key: .title, value: "x")],
                                            drafts: [:], colors: colors))
        #expect(Set(change.before.keys) == ["a"] && Set(change.after.keys) == ["a"])
        #expect(change.before["a"] == TagDraft(trackUUID: "a", base: local.tagFields))
        #expect(change.after["a"]?.fields.title == "새 제목" && change.after["a"]?.fields.artist == "새 가수")
        #expect(memory.tag("a") == nil, "바꾸기만으로는 저장하지 않는다")
    }

    @Test func 같은_칸을_여러_번_바꾸면_앞은_처음_초안_뒤는_마지막_값이다() throws {
        let local = Self.row("a")
        var draft = TagDraft(trackUUID: "a", base: local.tagFields)
        draft.fields.comment = "있던 코멘트"
        let change = try #require(edit.edit([EditTags.Change(row: local, key: .title, value: "첫 값"),
                                             EditTags.Change(row: local, key: .title, value: "끝 값")],
                                            drafts: ["a": draft], colors: colors))
        #expect(change.before["a"] == draft)
        #expect(change.after["a"]?.fields.title == "끝 값" && change.after["a"]?.fields.comment == "있던 코멘트")
    }

    @Test func 바뀐_칸이_없으면_되돌리기_단위가_없다() {
        let local = Self.row("a", title: "곡")
        #expect(edit.edit([EditTags.Change(row: local, key: .title, value: "곡")], drafts: [:], colors: colors) == nil)
        #expect(edit.edit([EditTags.Change(row: Self.row("s", streaming: true), key: .title, value: "x")], drafts: [:], colors: colors) == nil)
        #expect(edit.edit([], drafts: [:], colors: colors) == nil)
    }

    @Test func 키_평점_곡_색은_고르기_값만_받는다() throws {
        let local = Self.row("a", key: "Em"), staged = Self.row("b", staged: true)
        let change = try #require(edit.edit([EditTags.Change(row: local, key: .musicalKey, value: " 12b "),
                                             EditTags.Change(row: local, key: .rating, value: "★★★"),
                                             EditTags.Change(row: local, key: .color, value: colors[1].name),
                                             EditTags.Change(row: staged, key: .musicalKey, value: "Am"),
                                             EditTags.Change(row: staged, key: .rating, value: "3")],
                                            drafts: [:], colors: colors))
        #expect(change.after["a"]?.fields.musicalKey == "12B" && change.after["a"]?.fields.rating == "3")
        #expect(change.after["a"]?.fields.color == colors[1].id)
        #expect(change.after["b"] == nil, "Camelot 이름이 아닌 키와 추가한 곡의 평점은 받지 않는다")
        // 기준 값으로 되돌리기는 옛 표기여도 받는다
        let reverted = try #require(edit.edit([EditTags.Change(row: local, key: .musicalKey, value: "Em")],
                                              drafts: change.after, colors: colors))
        #expect(reverted.after["a"]?.fields.musicalKey == "Em")
    }

    @Test func 초안_버리기는_모든_칸을_기준_값으로_돌린다() throws {
        let local = Self.row("a", key: "Em"), untouched = Self.row("b")
        var draft = TagDraft(trackUUID: "a", base: local.tagFields)
        draft.fields.title = "새 제목"
        draft.fields.musicalKey = "8A"
        let change = try #require(edit.revert([local, untouched], drafts: ["a": draft], colors: colors))
        #expect(change.before["a"] == draft)
        #expect(change.after["a"]?.hasChanges == false && change.after["a"]?.fields.musicalKey == "Em")
        #expect(change.after["b"]?.hasChanges == false, "초안이 없던 곡은 빈 초안 그대로다")
        #expect(edit.revert([untouched], drafts: ["a": draft], colors: colors) == nil, "초안이 없는 곡은 바뀌지 않는다")
    }

    @Test func 충돌은_고른_칸만_풀고_초안이_없거나_읽기_전용인_곡은_건너뛴다() throws {
        let old = Self.row("a", title: "옛 제목"), fresh = Self.row("a", title: "rekordbox 제목")
        var draft = TagDraft(trackUUID: "a", base: old.tagFields)
        draft.fields.title = "내 제목"
        let usb = Self.row("u", title: "옛 제목", usb: true)
        var usbDraft = TagDraft(trackUUID: "u", base: usb.tagFields)
        usbDraft.fields.title = "내 제목"
        let drafts = ["a": draft, "u": usbDraft]
        let current = ["a": fresh, "u": Self.row("u", title: "rekordbox 제목", usb: true)]

        let kept = try #require(edit.resolveConflict(.title, keepingDraft: true, rows: [old, usb, Self.row("b")], drafts: drafts, current: current))
        #expect(Set(kept.before.keys) == ["a"] && kept.before["a"] == draft)
        #expect(kept.after["a"]?.base == fresh.tagFields && kept.after["a"]?.fields.title == "내 제목", "목록의 새 값을 기준으로 다시 쌓는다")
        let used = try #require(edit.resolveConflict(.title, keepingDraft: false, rows: [old], drafts: drafts, current: current))
        #expect(used.after["a"]?.hasChanges == false)
        #expect(edit.resolveConflict(.artist, keepingDraft: true, rows: [old], drafts: drafts, current: current) == nil, "충돌하지 않은 칸")
        // 목록에 새 행이 없으면 고른 행을 지금 값으로 본다(충돌 없음)
        #expect(edit.resolveConflict(.title, keepingDraft: true, rows: [old], drafts: drafts, current: [:]) == nil)
    }

    @Test func 저장은_고친_초안을_두고_고친_칸이_없는_초안은_지운다() {
        let local = Self.row("a")
        var draft = TagDraft(trackUUID: "a", base: local.tagFields)
        draft.fields.title = "새 제목"
        edit.save(["a": draft])
        #expect(memory.tag("a") == draft)
        edit.save(["a": TagDraft(trackUUID: "a", base: local.tagFields)])
        #expect(memory.tag("a") == nil)
    }
}
