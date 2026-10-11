import DJCDomain
import Testing

/// 곡 목록 투영(사이드바 대상 → 보이는 줄)과 선택 규칙. `LibraryStore`가 메인 스레드에서 그대로 부른다.
@Suite("곡 목록 투영")
struct TrackListProjectionTests {
    static func row(_ id: String, title: String = "곡", rating: Int = 0, color: String? = nil, path: String? = nil,
                    comment: String = "", cues: [Cue] = []) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: "\(title) \(id)", artist: "가수", album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 30,
                              folderPath: path ?? "/x/\(id).mp3", comment: comment, importedOn: nil, analysisDataPath: nil,
                              imagePath: nil, isDeleted: false, rating: rating, colorID: color),
                 cues: cues, playCount: 0)
    }

    static func index(_ rows: [TrackRow]) -> [TrackRow.ID: TrackRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func 사이드바_대상마다_줄을_고른다() {
        let rows = [Self.row("1"), Self.row("2", cues: [Cue(id: "c", contentID: "2", kind: 1, inMsec: 0, name: "", colorTableIndex: 0, color: 0)]),
                    Self.row("3")]
        let byID = Self.index(rows)
        #expect(TrackListProjection.base(.filter(.noCues), rows: rows, rowsByID: byID).map(\.track.id) == ["1", "3"])
        // 재생 목록 순서를 따르고 컬렉션에 없는 곡은 뺀다
        #expect(TrackListProjection.base(.playlist(trackIDs: ["3", "없음", "1"]), rows: rows, rowsByID: byID).map(\.track.id) == ["3", "1"])
        #expect(TrackListProjection.base(.pending(["uuid-2"]), rows: rows, rowsByID: byID).map(\.track.id) == ["2"])
        // 중복 후보는 같은 곡을 한 번만 둔다
        #expect(TrackListProjection.base(.duplicates(["1", "3", "1"]), rows: rows, rowsByID: byID).map(\.track.id) == ["1", "3"])
        #expect(TrackListProjection.base(.rows([Self.row("9")]), rows: rows, rowsByID: byID).map(\.track.id) == ["9"])
    }

    @Test func 반복된_곡은_줄마다_다른_ID를_붙인다() {
        let rows = [Self.row("1"), Self.row("2")]
        let byID = Self.index(rows)
        let iTunes = TrackListProjection.base(.iTunesPlaylist(id: "p", trackIDs: ["1", "2", "1"], numbers: [1, 2, 3]),
                                              rows: rows, rowsByID: byID)
        #expect(iTunes.map(\.id) == ["p:1:0", "p:2:0", "p:1:1"] && iTunes.map(\.playlistTrackNumber) == [1, 2, 3])
        let history = TrackListProjection.base(.history([.init(id: "a", contentID: "1", trackNumber: 1),
                                                         .init(id: "b", contentID: "없음", trackNumber: 2),
                                                         .init(id: "c", contentID: "1", trackNumber: 3)]),
                                               rows: rows, rowsByID: byID)
        #expect(history.map(\.id) == ["history:a", "history:c"] && history.map(\.track.id) == ["1", "1"])
    }

    @Test func 숨긴_스트리밍_줄은_따로_돌려준다() {
        let base = [Self.row("1"), Self.row("2", path: "spotify:track:2"), Self.row("3")]
        let hidden = TrackListProjection.hidingStreaming(base, hide: true)
        #expect(hidden.rows.map(\.track.id) == ["1", "3"] && hidden.hiddenIDs == ["2"])
        let shown = TrackListProjection.hidingStreaming(base, hide: false)
        #expect(shown.rows.count == 3 && shown.hiddenIDs.isEmpty && shown.hiddenCount == 0)
    }

    @Test func 숨긴_수는_같은_곡이_두_번_든_재생_목록에서_줄마다_센다() {
        // rekordbox 재생 목록의 줄 ID는 곡 ID라, 같은 스트리밍 곡 두 줄은 ID 하나지만 숨긴 줄은 둘이다
        let stream = Self.row("2", path: "spotify:track:2")
        let hidden = TrackListProjection.hidingStreaming([Self.row("1"), stream, stream], hide: true)
        #expect(hidden.hiddenIDs == ["2"] && hidden.hiddenCount == 2)
    }

    @Test func 검색과_평점과_곡_색으로_거른다() {
        let rows = [Self.row("1", title: "Alpha", rating: 2, color: "1"), Self.row("2", title: "Beta", rating: 4, color: "7"),
                    Self.row("3", title: "alphabet", rating: 5)]
        #expect(TrackListProjection.filtered(rows, search: "  ALPHA ", minimumRating: 0, color: nil).map(\.track.id) == ["1", "3"])
        #expect(TrackListProjection.filtered(rows, search: "", minimumRating: 4, color: nil).map(\.track.id) == ["2", "3"])
        #expect(TrackListProjection.filtered(rows, search: "alpha", minimumRating: 3, color: nil).map(\.track.id) == ["3"])
        #expect(TrackListProjection.filtered(rows, search: "", minimumRating: 0, color: "7").map(\.track.id) == ["2"])
        #expect(TrackListProjection.filtered(rows, search: "", minimumRating: 0, color: nil) == rows)
    }

    @Test func 중복_후보_검색은_비교_상대도_남긴다() {
        let rows = [Self.row("1", title: "Alpha"), Self.row("2", title: "Beta"), Self.row("3", title: "Gamma")]
        let groups = [["1", "2"], ["3"]]
        let byID = Self.index(rows)
        #expect(TrackListProjection.duplicateGroups(groups, members: { $0 }, search: "beta", rowsByID: byID) == [["1", "2"]])
        #expect(TrackListProjection.duplicateGroups(groups, members: { $0 }, search: " ", rowsByID: byID) == groups)
    }

    @Test func 덱에_올릴_곡은_표_순서로_첫_곡이다() {
        let rows = [Self.row("1"), Self.row("2"), Self.row("3")]
        let byID = Self.index(rows)
        #expect(TrackSelection.primary(selection: [], displayRows: rows, rowsByID: byID) == nil)
        #expect(TrackSelection.primary(selection: ["2"], displayRows: [], rowsByID: byID)?.track.id == "2")
        #expect(TrackSelection.primary(selection: ["3", "2"], displayRows: rows, rowsByID: byID)?.track.id == "2")
        // 재생 기록의 반복 행을 고르면 컬렉션 곡으로 올린다
        var repeated = Self.row("1")
        repeated.historyEntry = .init(id: "h", contentID: "1", trackNumber: 1)
        #expect(TrackSelection.primary(selection: [repeated.id, "3"], displayRows: [repeated, rows[2]], rowsByID: byID)?.id == "1")
    }

    @Test func 편집_대상은_곡마다_한_번이고_USB_곡은_뺀다() {
        let rows = [Self.row("1"), Self.row("2")]
        var repeated = Self.row("1")
        repeated.historyEntry = .init(id: "h", contentID: "1", trackNumber: 2)
        let usb = Self.row("usb:볼륨:1")
        #expect(TrackSelection.uniqueTracks([repeated, rows[0], usb, rows[1]], rowsByID: Self.index(rows)).map(\.id) == ["1", "2"])
    }

    @Test func 다시_읽은_뒤에는_있는_곡과_보이는_줄만_남긴다() {
        let rows = [Self.row("1")]
        var repeated = Self.row("1")
        repeated.historyEntry = .init(id: "h", contentID: "1", trackNumber: 1)
        let kept = TrackSelection.existing(["1", "지운 곡", repeated.id], rowsByID: Self.index(rows), displayRows: [repeated])
        #expect(kept == ["1", repeated.id])
        let streaming = Self.row("s", path: "spotify:track:s")
        #expect(TrackSelection.withoutHidden(["1", "s", "x"], hiddenIDs: ["x"], rowsByID: Self.index(rows + [streaming])) == ["1"])
    }

    @Test func 재생_기록_제목은_날짜와_이름이다() {
        #expect(RekordboxHistory(id: "1", name: "", dateCreated: "2026-09-20 21:00:00", entries: []).title == "2026-09-20")
        #expect(RekordboxHistory(id: "1", name: "2026-09-20", dateCreated: "2026-09-20", entries: []).title == "2026-09-20")
        #expect(RekordboxHistory(id: "1", name: "클럽", dateCreated: "2026-09-20", entries: []).title == "2026-09-20 · 클럽")
        #expect(RekordboxHistory(id: "1", name: "클럽", dateCreated: nil, entries: []).title == "날짜 없음 · 클럽")
    }
}
