import DJCDomain
import Foundation
import Testing

/// PRO DJ LINK 재생 기록: rekordbox의 "LINK HISTORY yyyy-MM-dd"처럼 세션마다 기록 하나를 만들고 CDJ가 알린 곡을 더한다.
/// 이름 규칙은 2026-10-16 rekordbox 7.2.x가 만든 "LINK HISTORY 2026-10-16"(스냅샷 비교)과 같다.
@Suite("LINK 재생 기록")
struct LinkHistoryTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    /// 2026-10-16 14:53:46 KST
    static let now = Date(timeIntervalSince1970: 1_792_130_026.4)

    static func entry(_ contentID: String) -> ArchivedHistory.Entry {
        ArchivedHistory.Entry(trackNumber: 0, usbContentID: 1, contentID: contentID, title: "곡 \(contentID)", artist: nil,
                              path: "/Users/dj/Music/\(contentID).mp3", masterDbId: 100, masterContentId: Int64(contentID) ?? 0,
                              fileName: "\(contentID).mp3")
    }

    static func record(_ contentID: String, session: String = "a-1", existing: [ArchivedHistory]) -> LinkHistory.Recorded {
        LinkHistory.record(entry(contentID), session: session, existing: existing, now: now, calendar: calendar, makeID: { "id\(existing.count)" })
    }

    @Test func 첫_곡은_LINK_HISTORY_날짜_이름의_새_기록을_만든다() {
        let recorded = Self.record("10", existing: [])
        #expect(recorded.isNew)
        #expect(recorded.history.name == "LINK HISTORY 2026-10-16")
        #expect(recorded.history.id.hasPrefix(ArchivedHistory.idPrefix))
        #expect(recorded.history.source.isLink)
        #expect(recorded.history.entries.map(\.trackNumber) == [1])
        // 저장 파일처럼 초 아래를 버린다
        #expect(recorded.history.importedAt.timeIntervalSince1970 == 1_792_130_026)
    }

    @Test func 같은_세션의_곡은_그_기록_끝에_차례로_더한다() {
        let first = Self.record("10", existing: []).history
        let second = Self.record("20", existing: [first])
        #expect(!second.isNew)
        #expect(second.history.id == first.id)
        #expect(second.history.matchedContentIDs == ["10", "20"])
        #expect(second.history.entries.map(\.trackNumber) == [1, 2])
    }

    @Test func 다른_세션이나_rekordbox에_쓴_기록에는_더하지_않고_번호를_붙인_새_기록을_만든다() {
        var first = Self.record("10", existing: []).history
        let other = Self.record("20", session: "a-3", existing: [first])
        #expect(other.isNew)
        #expect(other.history.name == "LINK HISTORY 2026-10-16 (1)")
        first.rekordboxHistoryID = "173539318"
        let afterWrite = Self.record("30", existing: [first])
        #expect(afterWrite.isNew)
        #expect(afterWrite.history.name == "LINK HISTORY 2026-10-16 (1)")
    }

    @Test func USB_기록과는_출처가_달라_섞이지_않는다() {
        let usb = ArchivedHistory(id: "usbhistory-x", name: "HISTORY 2026-10-16", importedAt: Self.now, sequence: 4,
                                  source: .init(volumeKey: "UUID-1", volumeName: "USB", format: "oneLibrary", historyID: 1,
                                                historyName: "a-1"),
                                  entries: [Self.entry("10")])
        let recorded = Self.record("20", existing: [usb])
        #expect(recorded.isNew)
        #expect(recorded.history.sequence == 5)
        #expect(!usb.source.isLink)
    }

    @Test func 뺀_곡은_그_곡의_마지막_줄을_빼고_번호를_다시_매긴다() throws {
        var history = Self.record("10", existing: []).history
        history = Self.record("20", existing: [history]).history
        history = Self.record("10", existing: [history]).history
        let removed = try #require(LinkHistory.remove(contentID: "10", session: "a-1", existing: [history]))
        #expect(removed.matchedContentIDs == ["10", "20"])
        #expect(removed.entries.map(\.trackNumber) == [1, 2])
        #expect(LinkHistory.remove(contentID: "99", session: "a-1", existing: [history]) == nil)
    }

    @Test func 쓰일_이름은_쓰기_관문처럼_번호를_뗀_바탕에_1부터_빈_번호를_붙인다() {
        #expect(HistoryNaming.writtenName("LINK HISTORY 2026-10-16 (1)",
                                          taken: ["LINK HISTORY 2026-10-16", "LINK HISTORY 2026-10-16 (1)"]) == "LINK HISTORY 2026-10-16 (2)")
        #expect(HistoryNaming.writtenName("LINK HISTORY 2026-10-16", taken: []) == "LINK HISTORY 2026-10-16")
        // 바탕 이름이 비어 있어도 바탕을 쓰지 않는다(쓰기 관문과 같다)
        #expect(HistoryNaming.writtenName("X (1)", taken: ["X (1)"]) == "X (2)")
        #expect(HistoryNaming.writtenName("HISTORY 2026-10-16 (1)", taken: ["HISTORY 2026-10-16"]) == "HISTORY 2026-10-16 (1)")
    }

    @Test func 연결_중인_세션의_기록은_쓰기_대기에_올리지_않고_끄면_올린다() {
        let history = Self.record("10", existing: []).history
        func pending(_ open: Set<String>) -> [String] {
            UsbHistoryRules.view(histories: [], archived: [history], local: LocalLibraryKeys(localDBID: 100, tracks: [], counters: [:]),
                                 inCollection: { _ in true }, queueOpen: true, awaitingReload: [], calendar: Self.calendar,
                                 openLinkSessions: open).pending.map(\.id)
        }
        #expect(LinkHistory.isOpen(history, openSessions: ["a-1"]))
        #expect(pending(["a-1"]).isEmpty)
        #expect(pending([]) == [history.id])
    }

    @Test func 곡이_여럿인_LINK_기록도_쓰기_대기에_오른다() {
        // 2026-10-16 rekordbox 실험(곡 세 개)과 사본 재현이 칸 단위로 맞았다(docs/rekordbox-internals.md "LINK 기록")
        let one = Self.record("10", existing: []).history
        let three = Self.record("30", existing: [Self.record("20", existing: [one]).history]).history
        let view = UsbHistoryRules.view(histories: [], archived: [three], local: LocalLibraryKeys(localDBID: 100, tracks: [], counters: [:]),
                                        inCollection: { _ in true }, queueOpen: true, awaitingReload: [], calendar: Self.calendar)
        #expect(view.pending.map(\.matchedContentIDs) == [["10", "20", "30"]])
    }

    @Test func 쓰지_않은_보존_기록은_rekordbox에_같은_이름이_있으면_rekordbox처럼_번호를_붙여_보인다() {
        let first = Self.record("10", existing: []).history
        let second = Self.record("20", session: "a-3", existing: [first]).history
        // rekordbox에 이미 "LINK HISTORY 2026-10-16"이 있다(2026-10-16 화면: DJCrate가 같은 이름을 하나 더 보였다)
        let rekordbox: Set<String> = ["LINK HISTORY 2026-10-16", "HISTORY 2026-10-16"]
        let names = HistoryNaming.displayNames(pending: [first, second], others: [], rekordboxNames: rekordbox)
        #expect(names[first.id] == "LINK HISTORY 2026-10-16 (1)")
        #expect(names[second.id] == "LINK HISTORY 2026-10-16 (2)")
        // 대기에 없는 기록(뺀 기록 등)은 대기 기록의 자리를 차지하지 않는다: 대기 기록은 쓰기 관문이 쓸 이름 그대로다
        let others = HistoryNaming.displayNames(pending: [second], others: [first], rekordboxNames: rekordbox)
        #expect(others[second.id] == nil)
        #expect(others[first.id] == "LINK HISTORY 2026-10-16 (2)")
        #expect(HistoryNaming.displayNames(pending: [first], others: [], rekordboxNames: []).isEmpty)
    }

    @Test func 기록_줄의_원본_키는_그_곡_자신이라_USB_기록과_같은_검증을_지난다() {
        let row = TrackRow(track: Track(id: "246339343", uuid: "u", title: "Song", artist: "Artist", album: nil, albumArtist: nil,
                                        genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 128, lengthSeconds: 200,
                                        folderPath: "/Users/dj/Music/Song.mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                                        imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        let keys = LocalLibraryKeys(localDBID: 555, tracks: [UsbLocalTrackKey(contentID: "246339343", masterSongID: "246339343",
                                                                             fileNameL: "Song.mp3", folderPath: "/Users/dj/Music/Song.mp3")],
                                    counters: [:])
        let entry = LinkHistory.entry(row: row, keys: keys, linkID: 7)
        #expect(entry.contentID == "246339343")
        #expect(entry.masterDbId == 555)
        #expect(entry.masterContentId == 246_339_343)
        #expect(entry.fileName == "Song.mp3")
        #expect(entry.usbContentID == 7)
        // 다시 읽은 스냅샷으로 짝을 검증해도 같은 곡이다
        let history = ArchivedHistory(id: "usbhistory-link-1", name: "LINK HISTORY 2026-10-16", importedAt: Self.now, sequence: 1,
                                      source: LinkHistory.source(session: "a-1"), entries: [entry])
        #expect(UsbHistoryMatches.rematch([history], localDBID: 555, local: keys.tracks).first?.matchedContentIDs == ["246339343"])
        // 키를 모르면 짝을 두지 않는다(보존만 하고 rekordbox에는 쓰지 않는다)
        #expect(LinkHistory.entry(row: row, keys: nil, linkID: 7).contentID == nil)
    }
}
