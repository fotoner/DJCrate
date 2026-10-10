import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 재생 목록 초안 편집 유스케이스의 규칙(#251): 최근 목록 줄 세우기, 넣기 전 나누기, 재생 기록으로 목록을 만들 때 원본 고르기.
/// 화면(`PlaylistEditStore`)은 이 결과로 초안·안내·설정 저장만 한다. 규칙은 값만 받으므로 포트 없이 본다.
@Suite("재생 목록 초안 편집 — 규칙")
struct EditPlaylistsTests {
    static func row(_ id: String, staged: Bool = false) -> TrackRow {
        TrackRow(track: Track(id: staged ? "djc-\(id)" : id, uuid: "u-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "/x/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false, dataStatus: staged ? nil : 0),
                 cues: [], playCount: 0)
    }

    // MARK: - 최근 목록

    @Test func 곡을_넣은_목록은_맨_앞에_한_번만_다섯_개까지_남는다() {
        #expect(EditPlaylists.touchingRecent("C", in: ["A", "B", "C"]) == ["C", "A", "B"])
        #expect(EditPlaylists.touchingRecent("N", in: []) == ["N"])
        let full = ["1", "2", "3", "4", "5"]
        #expect(EditPlaylists.touchingRecent("6", in: full) == ["6", "1", "2", "3", "4"])
        #expect(EditPlaylists.recentLimit == 5)
    }

    @Test func 쓴_뒤_새_목록의_임시_ID는_받은_rekordbox_ID로_바뀌고_나머지는_그대로다() {
        #expect(EditPlaylists.remappingRecent(["new:a", "B", "new:c"], ids: ["new:a": "101"]) == ["101", "B", "new:c"])
        #expect(EditPlaylists.remappingRecent(["A"], ids: [:]) == ["A"])
    }

    // MARK: - 넣기 전 나누기

    @Test func 넣을_곡을_새_곡_이미_든_곡_추가한_곡으로_나눈다() {
        let item = PlaylistLayout.Item(id: "P", name: "세트", entries: [PlaylistEntry(trackNo: 1, contentID: "1")])
        let plan = EditPlaylists.addPlan([Self.row("1"), Self.row("2"), Self.row("s", staged: true), Self.row("3")], to: item)
        #expect(plan.new == ["2", "3"])
        #expect(plan.duplicates == ["1"])
        #expect(plan.staged == 1)
    }

    @Test func 새_목록에는_추가한_곡을_빼고_넣는다() {
        #expect(EditPlaylists.creatableTrackIDs([Self.row("1"), Self.row("s", staged: true), Self.row("2")]) == ["1", "2"])
    }

    // MARK: - 재생 기록으로 목록 만들기

    @Test func rekordbox_기록은_튼_순서대로_컬렉션_곡만_고르고_이름은_기록_제목이다() throws {
        let history = RekordboxHistory(id: "H", name: "2026-10-01", dateCreated: nil, entries: [
            .init(id: "e2", contentID: "2", trackNumber: 2), .init(id: "e1", contentID: "1", trackNumber: 1),
            .init(id: "e3", contentID: "없음", trackNumber: 3), .init(id: "e4", contentID: "1", trackNumber: 4),
        ])
        let rows = ["1": Self.row("1"), "2": Self.row("2")]
        let source = try #require(EditPlaylists.historySource("H", histories: ["H": history], archived: [:], rows: rows))
        #expect(source.name == history.title)
        // 반복 재생도 그대로 둔다(넣을 때 처음 한 번만 남는다)
        #expect(source.rows.map(\.track.id) == ["1", "2", "1"])
    }

    @Test func USB에서_보존한_기록은_컬렉션_짝이_있는_곡만_고르고_이름은_기록_이름이다() throws {
        func entry(_ number: Int, _ contentID: String?) -> ArchivedHistory.Entry {
            ArchivedHistory.Entry(trackNumber: number, usbContentID: number, contentID: contentID, title: "곡", artist: nil, path: "/x",
                                  masterDbId: 1, masterContentId: 1, fileName: "x")
        }
        let archived = ArchivedHistory(id: "A", name: "HISTORY 001", importedAt: Date(timeIntervalSince1970: 0), sequence: 0,
                                       source: .init(volumeKey: "V", volumeName: "USB", format: "oneLibrary", historyID: 1, historyName: "HISTORY 001"),
                                       entries: [entry(2, "2"), entry(1, nil), entry(3, "1")])
        let rows = ["1": Self.row("1"), "2": Self.row("2")]
        let source = try #require(EditPlaylists.historySource("A", histories: [:], archived: ["A": archived], rows: rows))
        #expect(source.name == "HISTORY 001")
        #expect(source.rows.map(\.track.id) == ["2", "1"])
    }

    @Test func 같은_ID면_rekordbox_기록을_먼저_고르고_없는_기록이면_nil이다() {
        let history = RekordboxHistory(id: "X", name: "rekordbox", dateCreated: nil, entries: [])
        let archived = ArchivedHistory(id: "X", name: "보존", importedAt: Date(timeIntervalSince1970: 0), sequence: 0,
                                       source: .init(volumeKey: "V", volumeName: "USB", format: "oneLibrary", historyID: 1, historyName: "H"),
                                       entries: [])
        #expect(EditPlaylists.historySource("X", histories: ["X": history], archived: ["X": archived], rows: [:])?.name == history.title)
        #expect(EditPlaylists.historySource("없음", histories: [:], archived: [:], rows: [:]) == nil)
    }
}
