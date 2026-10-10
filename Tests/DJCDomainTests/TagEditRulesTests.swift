import Foundation
import Testing
@testable import DJCDomain

/// 태그 초안을 고치는 순수 규칙(#250): 곡의 지금 초안과 칸 값, 칸마다 받는 값, 충돌한 칸 고르기. 순서는 `EditTagsTests`(DJCApplicationTests)가 본다.
@Suite("태그 초안 편집 규칙")
struct TagEditRulesTests {
    /// 판정에 쓰는 값만 고른 곡 행(추가한 곡은 `djc-` ID, USB 곡은 USB ID, 스트리밍 곡은 파일 경로가 아니다)
    static func row(uuid: String = "uuid-1", key: String? = "5A", rating: Int = 0, colorID: String? = nil, state: Int? = 0,
                    staged: Bool = false, streaming: Bool = false, usb: Bool = false, title: String = "곡") -> TrackRow {
        let id = usb ? TrackRow.usbIDPrefix + "1" : staged ? "djc-1" : "1"
        return TrackRow(track: Track(id: id, uuid: uuid, title: title, artist: nil, album: nil, albumArtist: nil, genre: nil,
                                     composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 30,
                                     folderPath: streaming ? "spotify:track:1" : "/x/1.mp3", comment: "", importedOn: nil,
                                     analysisDataPath: nil, imagePath: nil, isDeleted: false, rating: rating, colorID: colorID,
                                     dataStatus: staged ? nil : state),
                        cues: [], playCount: 0)
    }

    let colors = TrackColor.rekordboxDefaults

    // MARK: 받는 값

    @Test func 스트리밍_곡과_USB_곡은_어떤_칸도_받지_않는다() {
        for subject in [Self.row(streaming: true), Self.row(usb: true)] {
            for key in TagFields.Key.allCases {
                #expect(TagEditRules.accepted("값", for: key, row: subject, base: subject.tagFields, colors: colors) == nil)
                #expect(TagEditRules.accepted(subject.tagFields[key], for: key, row: subject, base: subject.tagFields, colors: colors) == nil,
                        "기준 값으로 되돌리기도 받지 않는다")
            }
        }
    }

    @Test func 글자_칸은_값을_그대로_받는다() {
        let subject = Self.row()
        #expect(TagEditRules.accepted(" 새 제목 ", for: .title, row: subject, base: subject.tagFields, colors: colors) == " 새 제목 ")
        #expect(TagEditRules.accepted("", for: .comment, row: subject, base: subject.tagFields, colors: colors) == "")
    }

    @Test func 키는_Camelot_이름과_빈칸만_받고_기준_값으로_되돌리기는_옛_표기여도_받는다() {
        let subject = Self.row(key: "Em")
        let base = subject.tagFields
        #expect(TagEditRules.accepted(" 12b ", for: .musicalKey, row: subject, base: base, colors: colors) == "12B")
        #expect(TagEditRules.accepted("", for: .musicalKey, row: subject, base: base, colors: colors) == "")
        #expect(TagEditRules.accepted("Am", for: .musicalKey, row: subject, base: base, colors: colors) == nil)
        #expect(TagEditRules.accepted("Em", for: .musicalKey, row: subject, base: base, colors: colors) == "Em")
        // 추가한 곡도 키는 고를 수 있다(넣을 때 함께 쓴다, #5)
        let staged = Self.row(staged: true)
        #expect(TagEditRules.accepted("8A", for: .musicalKey, row: staged, base: staged.tagFields, colors: colors) == "8A")
    }

    @Test func 평점과_곡_색은_고르기_값만_받고_고칠_수_없는_곡에는_넣지_않는다() {
        let subject = Self.row()
        let base = subject.tagFields
        #expect(TagEditRules.accepted("★★★", for: .rating, row: subject, base: base, colors: colors) == "3")
        #expect(TagEditRules.accepted("6", for: .rating, row: subject, base: base, colors: colors) == nil)
        #expect(TagEditRules.accepted("0", for: .rating, row: subject, base: base, colors: colors) == "")
        let named = TagEditRules.accepted(colors[0].name, for: .color, row: subject, base: base, colors: colors)
        #expect(named == colors[0].id)
        #expect(TagEditRules.accepted("보라보라", for: .color, row: subject, base: base, colors: colors) == nil)
        // 추가한 곡과 쓰기를 확인하지 않은 상태의 곡(#65)
        for blocked in [Self.row(staged: true), Self.row(state: 258)] {
            #expect(TagEditRules.accepted("3", for: .rating, row: blocked, base: blocked.tagFields, colors: colors) == nil)
            #expect(TagEditRules.accepted(colors[0].id, for: .color, row: blocked, base: blocked.tagFields, colors: colors) == nil)
            #expect(TagEditRules.accepted(blocked.tagFields.rating, for: .rating, row: blocked, base: blocked.tagFields, colors: colors)
                    == blocked.tagFields.rating, "기준 값으로 되돌리기는 받는다")
        }
    }

    // MARK: 지금 초안과 칸 값

    @Test func 초안이_없으면_지금_값에서_새로_만들고_안_고친_독립_칸은_지금_값으로_맞춘다() {
        let subject = Self.row(key: "5A", rating: 2)
        let fresh = TagEditRules.draft(for: subject, in: [:])
        #expect(fresh.base == subject.tagFields && !fresh.hasChanges)
        // 키 칸이 없던 옛 초안(기준·내용 빈칸)과 제목만 고친 초안
        var legacy = TagDraft(trackUUID: subject.track.uuid, base: TagFields())
        legacy.fields.title = "새 제목"
        let drafts = [subject.track.uuid: legacy]
        let current = TagEditRules.draft(for: subject, in: drafts)
        #expect(current.base.musicalKey == "5A" && current.fields.musicalKey == "5A" && current.fields.rating == "2")
        #expect(TagEditRules.cell(subject, .musicalKey, in: drafts) == "5A", "독립 칸은 맞춘 값이 보인다")
        #expect(TagEditRules.cell(subject, .title, in: drafts) == "새 제목")
        #expect(TagEditRules.cell(subject, .comment, in: [:]) == subject.tagFields.comment)
        #expect(TagEditRules.isEdited(subject, .title, in: drafts) && !TagEditRules.isEdited(subject, .musicalKey, in: drafts))
        #expect(!TagEditRules.isEdited(subject, .title, in: [:]))
    }

    @Test func 여러_곡의_값은_모두_같을_때만_보이고_다르면_여러_값이다() {
        let a = Self.row(uuid: "a", key: "5A"), b = Self.row(uuid: "b", key: "5A"), c = Self.row(uuid: "c", key: "8B")
        #expect(TagEditRules.value(.musicalKey, rows: [a, b], in: [:]) == (value: "5A", mixed: false))
        #expect(TagEditRules.value(.musicalKey, rows: [a, b, c], in: [:]) == (value: "", mixed: true))
        #expect(TagEditRules.value(.musicalKey, rows: [], in: [:]) == (value: "", mixed: false))
        var draft = TagDraft(trackUUID: "c", base: c.tagFields)
        draft.fields.musicalKey = "5A"
        #expect(TagEditRules.value(.musicalKey, rows: [a, b, c], in: ["c": draft]) == (value: "5A", mixed: false), "초안 값으로 센다")
    }

    // MARK: 충돌

    @Test func 충돌한_칸_하나만_고르고_다른_칸의_충돌은_남긴다() throws {
        let subject = Self.row(title: "옛 제목")
        var draft = TagDraft(trackUUID: subject.track.uuid, base: subject.tagFields)
        draft.fields.title = "내 제목"
        draft.fields.comment = "내 코멘트"
        var current = subject.tagFields
        current.title = "rekordbox 제목"
        current.comment = "rekordbox 코멘트"
        #expect(Set(draft.conflictingKeys(with: current)) == [.title, .comment])

        let kept = try #require(TagEditRules.resolving(draft, key: .title, current: current, keepingDraft: true))
        #expect(kept.base.title == "rekordbox 제목" && kept.fields.title == "내 제목")
        #expect(kept.conflictingKeys(with: current) == [.comment], "코멘트 충돌은 그대로")
        let used = try #require(TagEditRules.resolving(draft, key: .title, current: current, keepingDraft: false))
        #expect(used.fields.title == "rekordbox 제목" && !used.changedKeys.contains(.title))
        #expect(TagEditRules.resolving(draft, key: .artist, current: current, keepingDraft: true) == nil, "충돌하지 않은 칸")
    }

    @Test func 마지막_충돌을_고르면_안_고친_칸을_지금_값으로_맞춘다() throws {
        let subject = Self.row(title: "옛 제목")
        var draft = TagDraft(trackUUID: subject.track.uuid, base: subject.tagFields)
        draft.fields.title = "내 제목"
        var current = subject.tagFields
        current.title = "rekordbox 제목"
        current.genre = "새 장르"
        let resolved = try #require(TagEditRules.resolving(draft, key: .title, current: current, keepingDraft: true))
        #expect(resolved.base == current && resolved.fields.genre == "새 장르" && resolved.fields.title == "내 제목")
    }

    // MARK: 메모리 초안에 넣기

    @Test func 고친_칸이_없어진_초안은_메모리에서_뺀다() {
        let subject = Self.row()
        var edited = TagDraft(trackUUID: "a", base: subject.tagFields)
        edited.fields.title = "새 제목"
        let reverted = TagDraft(trackUUID: "b", base: subject.tagFields)
        let kept = TagDraft(trackUUID: "c", base: TagFields())
        let updated = TagEditRules.applying(["a": edited, "b": reverted], to: ["b": edited, "c": kept])
        #expect(updated == ["a": edited, "c": kept])
    }
}
