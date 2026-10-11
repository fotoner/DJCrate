import Foundation
import Testing
@testable import DJCDomain

/// 곡 목록·태그 시트에서 태그 칸을 고치는 순수 규칙: 어떤 칸이 어떤 태그인지, 글자 칸 흐름(Return·Tab), 고칠 수 없는 곡의 이유(#88·#204·#65).
@Suite("태그 칸 편집 규칙")
struct TrackListTagEditingRulesTests {
    /// 판정에 쓰는 곡 값만 고른 곡 행(추가한 곡은 `djc-` ID에 상태 칸이 없고, USB 곡은 USB ID, 스트리밍 곡은 파일 경로가 아니다)
    static func subject(state: Int? = 0, inPlaylist: Bool = false, staged: Bool = false, streaming: Bool = false,
                        usb: Bool = false) -> TrackRow {
        let id = usb ? TrackRow.usbIDPrefix + "1" : staged ? "djc-1" : "1"
        var row = TrackRow(track: Track(id: id, uuid: "uuid-1", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                                        composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 30,
                                        folderPath: streaming ? "spotify:track:1" : "/x/1.mp3", comment: "", importedOn: nil,
                                        analysisDataPath: nil, imagePath: nil, isDeleted: false, dataStatus: staged ? nil : state),
                           cues: [], playCount: 0)
        row.inPlaylist = inPlaylist
        return row
    }

    // MARK: 칸

    @Test func 태그_칸만_편집한다() {
        for key in TagFields.Key.allCases { #expect(TrackListTagEditing.key(forColumn: key.rawValue) == key) }
        #expect(TrackListTagEditing.key(forColumn: "key") == .musicalKey)
        for id in ["index", "thumb", "edited", "preview", "class", "bpm", "length", "format", "tempo",
                   "imported", "plays", "hotCues", "memoryCues"] {
            #expect(TrackListTagEditing.key(forColumn: id) == nil)
        }
        #expect(TrackListTagEditing.key(forColumn: "rating") == .rating && TrackListTagEditing.key(forColumn: "color") == .color)
        // 키·평점·곡 색 칸은 메뉴로 고른다(글자 칸 흐름에 끼지 않는다)
        for id in ["key", "rating", "color"] { #expect(TrackListTagEditing.isMenuColumn(id) && !TrackListTagEditing.isTextColumn(id)) }
        #expect(TrackListTagEditing.isTextColumn("title") && !TrackListTagEditing.isTextColumn("bpm") && !TrackListTagEditing.isMenuColumn("bpm"))
    }

    @Test func Return은_보이는_첫_태그_칸에서_시작한다() {
        #expect(TrackListTagEditing.firstColumn(in: ["index", "thumb", "edited", "artist", "title", "bpm"]) == "artist")
        #expect(TrackListTagEditing.firstColumn(in: ["index", "bpm"]) == nil)
        #expect(TrackListTagEditing.firstColumn(in: ["rating", "color", "title"]) == "title")
    }

    @Test func Tab은_보이는_옆_태그_칸으로_가고_끝에서_멈춘다() {
        let order = ["index", "title", "preview", "artist", "bpm", "comment"]
        #expect(TrackListTagEditing.column(after: "title", forward: true, in: order) == "artist")
        #expect(TrackListTagEditing.column(after: "artist", forward: true, in: order) == "comment")
        #expect(TrackListTagEditing.column(after: "comment", forward: true, in: order) == nil)
        #expect(TrackListTagEditing.column(after: "comment", forward: false, in: order) == "artist")
        #expect(TrackListTagEditing.column(after: "title", forward: false, in: order) == nil)
    }

    @Test func Return과_Tab의_글자_칸_흐름은_키_칸을_건너뛴다() {
        let order = ["index", "title", "artist", "key", "comment"]
        #expect(TrackListTagEditing.firstColumn(in: ["index", "key", "title"]) == "title")
        #expect(TrackListTagEditing.firstColumn(in: order, clicked: "key") == "key")
        #expect(TrackListTagEditing.firstColumn(in: order, clicked: "artist") == "title")
        #expect(TrackListTagEditing.firstColumn(in: ["title"], clicked: "key") == "title")
        // 글자 칸이 하나도 보이지 않으면 키 칸을 누르기 전에는 고칠 칸이 없다(Return이 키 메뉴를 열지 않는다)
        #expect(TrackListTagEditing.firstColumn(in: ["index", "bpm", "key"]) == nil)
        #expect(TrackListTagEditing.firstColumn(in: ["index", "bpm", "key"], clicked: "key") == "key")
        #expect(TrackListTagEditing.firstColumn(in: ["index", "bpm"], clicked: "key") == nil)
        #expect(TrackListTagEditing.column(after: "artist", forward: true, in: order) == "comment")
        #expect(TrackListTagEditing.column(after: "comment", forward: false, in: order) == "artist")
        #expect(TrackListTagEditing.column(after: "key", forward: true, in: order) == nil)
    }

    // MARK: 고칠 수 없는 곡

    @Test func 스트리밍_USB_곡과_읽기_전용_칸은_이유를_알린다() {
        let local = Self.subject()
        #expect(TrackListTagEditing.unavailableReason(local, key: .title) == nil)
        #expect(TrackListTagEditing.unavailableReason(Self.subject(streaming: true), key: .title)?.contains("스트리밍") == true)
        #expect(TrackListTagEditing.unavailableReason(local, key: nil)?.contains("태그 칸") == true)
        // USB 곡은 칸과 상관없이 읽기 전용이다
        #expect(TrackListTagEditing.unavailableReason(Self.subject(usb: true), key: .title)?.contains("USB") == true)
        #expect(TrackListTagEditing.unavailableReason(Self.subject(usb: true), key: nil)?.contains("USB") == true)
    }

    /// 쓰기 규칙은 rekordbox 7.2.18 실험(2026-10-04 묶음 2·#173 S1 T11·T12)에서 상태 0·256·257 곡을, R65(2026-10-09)에서 재생 목록에 든 곡을
    /// 확인했다(`TagWriteScope`). 그 밖의 상태(258 등)는 막는다.
    @Test func 상태_0·256·257_곡은_재생_목록에_들어도_평점과_곡_색을_고친다() {
        for subject in [Self.subject(), Self.subject(state: 256), Self.subject(state: 257), Self.subject(inPlaylist: true),
                        Self.subject(state: 256, inPlaylist: true)] {
            #expect(TrackListTagEditing.unavailableReason(subject, key: .rating) == nil, "\(subject.track.dataStatus as Any)")
            #expect(TrackListTagEditing.unavailableReason(subject, key: .color) == nil, "\(subject.track.dataStatus as Any)")
        }
        for (subject, words) in [(Self.subject(state: 258, inPlaylist: true), "rekordbox에서 직접 고치세요"), (Self.subject(staged: true), "넣은 뒤"),
                                 (Self.subject(streaming: true), "스트리밍")] {
            for key in [TagFields.Key.rating, .color] {
                #expect(TrackListTagEditing.unavailableReason(subject, key: key)?.contains(words) == true, "\(subject.track.id) \(key)")
            }
            // 아직 초안이 없는 칸에서 "초안을 버리세요"라고 하지 않는다
            #expect(TrackListTagEditing.unavailableReason(subject, key: .rating)?.contains("초안") != true)
            // 다른 태그 칸은 예전과 같다(스트리밍만 막는다)
            #expect((TrackListTagEditing.unavailableReason(subject, key: .title) == nil) == !subject.track.isStreaming)
        }
    }
}

/// 글자 대신 고르기로 고치는 태그 칸(키·평점·곡 색)의 값: 고르기 목록, 보일 글자·읽을 글자, 붙여넣기에서 받는 값(#204·#65).
@Suite("고르기 태그 칸 값")
struct TagChoiceTests {
    let colors = TrackColor.rekordboxDefaults

    @Test func 고르기_목록은_없음이_먼저고_고를_수_없는_현재_값은_맨_앞에_흐리게_둔다() {
        let keys = TagChoice.options(.musicalKey, current: "", colors: colors)
        #expect(keys.first == TagChoice.Option(value: "", title: "없음") && keys.count == 25 && keys[1].value == "1A")
        let legacy = TagChoice.options(.musicalKey, current: "Em", colors: colors)
        #expect(legacy.first == TagChoice.Option(value: "Em", title: "Em", enabled: false) && legacy.count == 26)
        #expect(TagChoice.options(.rating, current: "3", colors: colors).map(\.title) == ["없음", "★☆☆☆☆", "★★☆☆☆", "★★★☆☆", "★★★★☆", "★★★★★"])
        let unknown = TagChoice.options(.color, current: "9", colors: colors)
        #expect(unknown.first == TagChoice.Option(value: "9", title: "9", enabled: false))
        #expect(unknown.dropFirst().map(\.value) == ["", "1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(TagChoice.options(.title, current: "x", colors: colors).isEmpty)
    }

    @Test func 평점은_별로_곡_색은_이름으로_보이고_읽는다() {
        #expect(TagChoice.display(.rating, "3", colors: colors) == "★★★☆☆" && TagChoice.display(.rating, "", colors: colors).isEmpty)
        #expect(TagChoice.display(.color, "2", colors: colors) == "Red" && TagChoice.display(.color, "9", colors: colors) == "9")
        #expect(TagChoice.display(.title, "제목", colors: colors) == "제목")
        #expect(TagChoice.spoken(.rating, "3", colors: colors) == "별 3개" && TagChoice.spoken(.rating, "", colors: colors) == "없음")
        #expect(TagChoice.spoken(.color, "7", colors: colors) == "Blue")
    }

    @Test func 붙여넣기는_고를_수_있는_값이나_빈칸만_받는다() {
        #expect(TagChoice.accepted(.musicalKey, " 8a ", colors: colors) == "8A" && TagChoice.accepted(.musicalKey, "", colors: colors) == "")
        #expect(TagChoice.accepted(.musicalKey, "Em", colors: colors) == nil)
        #expect(TagChoice.accepted(.rating, "★★", colors: colors) == "2" && TagChoice.accepted(.rating, "7", colors: colors) == nil)
        #expect(TagChoice.accepted(.color, "blue", colors: colors) == "7" && TagChoice.accepted(.color, "빨강", colors: colors) == nil)
        #expect(TagChoice.accepted(.title, "아무 글자", colors: colors) == "아무 글자")
        // 건너뛴 칸 안내는 칸 종류와 칸 수를 적는다
        #expect(TagChoice.skippedMessage(.color, count: 2).contains("곡 색 칸 2칸"))
        #expect(TagChoice.skippedMessage(.musicalKey, count: 1).contains("키 칸 1칸"))
    }
}
