import DJCDomain
import Foundation
import Testing

/// USB 기기 재생 기록 보존(#43): 같은 기록을 다시 읽으면 짝만 채우고, 새 기록은 rekordbox처럼 가져온 날짜로 이름을 짓는다.
@Suite("USB 재생 기록 가져오기")
struct UsbHistoryImportTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    /// 2026-08-01 23:12:27 KST
    static let now = Date(timeIntervalSince1970: 1_785_593_547)

    static func source(_ id: Int, name: String = "HISTORY 001", volume: String = "VOL-A", format: String = "oneLibrary") -> ArchivedHistory.Source {
        ArchivedHistory.Source(volumeKey: volume, volumeName: "USB", format: format, historyID: id, historyName: name)
    }

    static func entries(_ ids: [Int], matched: [Int: String] = [:]) -> [ArchivedHistory.Entry] {
        ids.enumerated().map { offset, id in
            ArchivedHistory.Entry(trackNumber: offset + 1, usbContentID: id, contentID: matched[id], title: "곡 \(id)", artist: nil,
                                  path: "/Contents/\(id).mp3", masterDbId: 1, masterContentId: Int64(id), fileName: "\(id).mp3")
        }
    }

    static func plan(existing: [ArchivedHistory] = [], _ candidates: [UsbHistoryImport.Candidate], reserved: Set<String> = [],
                     now: Date = now) -> UsbHistoryImport.Plan {
        // 보존본 다음 번호부터(ID가 겹치지 않게)
        var counter = existing.count
        return UsbHistoryImport.plan(existing: existing, candidates: candidates, reservedNames: reserved, now: now, calendar: calendar) {
            counter += 1
            return "id\(counter)"
        }
    }

    @Test func 새_기록은_가져온_날짜로_이름을_짓고_같은_날은_번호를_붙인다() {
        let plan = Self.plan([
            .init(source: Self.source(1), entries: Self.entries([10, 11])),
            .init(source: Self.source(2, name: "HISTORY 002"), entries: Self.entries([12])),
            .init(source: Self.source(3, name: "HISTORY 003"), entries: Self.entries([13])),
        ], reserved: ["HISTORY 2026-08-01"])
        #expect(plan.added.map(\.name) == ["HISTORY 2026-08-01 (1)", "HISTORY 2026-08-01 (2)", "HISTORY 2026-08-01 (3)"])
        #expect(plan.added.map(\.id) == ["usbhistory-id1", "usbhistory-id2", "usbhistory-id3"])
        #expect(plan.added.map(\.sequence) == [1, 2, 3])
        #expect(plan.added.allSatisfy { $0.importedAt == Self.now })
        #expect(plan.updated.isEmpty)
    }

    @Test func 곡이_없는_기록은_건너뛴다() {
        let plan = Self.plan([.init(source: Self.source(1), entries: [])])
        #expect(plan.isEmpty)
    }

    @Test func 순번은_1부터_다시_매기고_반복_재생을_남긴다() {
        var entries = Self.entries([10, 11, 10])
        entries[0].trackNumber = 4
        entries[1].trackNumber = 9
        entries[2].trackNumber = 12
        let plan = Self.plan([.init(source: Self.source(1), entries: entries)])
        #expect(plan.added.first?.entries.map(\.trackNumber) == [1, 2, 3])
        #expect(plan.added.first?.entries.map(\.usbContentID) == [10, 11, 10])
    }

    @Test func 같은_기록을_다시_읽으면_아무것도_하지_않는다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a"]))])
        let again = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a"]))])
        #expect(again.isEmpty)
    }

    @Test func 다시_읽을_때_모르던_짝을_채우고_아는_짝은_지우지_않는다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a"]))])
        let again = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [11: "b"]))])
        #expect(again.added.isEmpty)
        #expect(again.updated.count == 1)
        #expect(again.updated.first?.id == first.added.first?.id)
        #expect(again.updated.first?.entries.map(\.contentID) == ["a", "b"])
        #expect(again.updated.first?.name == first.added.first?.name)
    }

    @Test func 같은_USB_곡_번호를_다른_곡에_재사용하면_안정_식별로_구분해_새로_보존한다() {
        let original = Self.entries([10, 11])
        let first = Self.plan([.init(source: Self.source(1), entries: original)])
        var variants = Array(repeating: original, count: 4)
        variants[0][1].masterDbId += 1
        variants[1][1].masterContentId += 1
        variants[2][1].path = "/Contents/다른/11.mp3"
        variants[3][1].fileName = "다른11.mp3"
        for changed in variants {
            let again = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: changed)])
            #expect(again.updated.isEmpty)
            #expect(again.added.map(\.entries) == [changed])
            #expect(again.added.first?.id != first.added.first?.id)
            let both = first.added + again.added
            #expect(Self.plan(existing: both, [.init(source: Self.source(1), entries: original)]).isEmpty)
            #expect(Self.plan(existing: both, [.init(source: Self.source(1), entries: changed)]).isEmpty)
        }
    }

    @Test func 곡의_표시_정보나_로컬_짝만_바뀌면_새_기록을_만들지_않는다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10]))])
        var changed = Self.entries([10], matched: [10: "a"])
        changed[0].title = "고친 제목"
        changed[0].artist = "고친 아티스트"
        changed[0].bpm = 128
        changed[0].lengthSeconds = 200
        let again = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: changed)])
        #expect(again.added.isEmpty)
        #expect(again.updated.first?.id == first.added.first?.id)
        #expect(again.updated.first?.entries.first?.contentID == "a")
        #expect(again.updated.first?.entries.first?.title == first.added.first?.entries.first?.title)
    }

    /// 기기는 꽂을 때마다 새 기록을 만든다. rekordbox가 기록을 지운 뒤 같은 번호·이름을 다시 쓴 기록이 우연히 같은 곡으로
    /// 시작해도 옛 보존본에 이어 붙이거나 건너뛰지 않고 새로 보존한다
    @Test func 앞부분만_같은_기록은_이어_붙이지_않고_새로_보존한다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11]))])
        let later = Date(timeInterval: 86_400, since: Self.now)
        let longer = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([10, 11, 12]))], now: later)
        #expect(longer.updated.isEmpty)
        #expect(longer.added.map { $0.entries.map(\.usbContentID) } == [[10, 11, 12]])
        #expect(longer.added.first?.name == "HISTORY 2026-08-02")
        #expect(first.added.first?.entries.map(\.usbContentID) == [10, 11])

        let shorter = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([10]))], now: later)
        #expect(shorter.updated.isEmpty)
        #expect(shorter.added.map { $0.entries.map(\.usbContentID) } == [[10]])
    }

    @Test func 번호를_다시_쓴_USB의_옛_기록이_다시_보여도_다시_보존하지_않는다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11]))])
        let second = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([20]))])
        #expect(second.added.count == 1)
        // 옛 기록(백업에서 되살린 USB 등)과 새 기록 모두 이미 보존한 것이다
        let both = first.added + second.added
        #expect(Self.plan(existing: both, [.init(source: Self.source(1), entries: Self.entries([10, 11]))]).isEmpty)
        #expect(Self.plan(existing: both, [.init(source: Self.source(1), entries: Self.entries([20]))]).isEmpty)
    }

    @Test func 번호가_같아도_앞부분이_다르면_새_기록이다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11]))])
        let again = Self.plan(existing: first.added, [.init(source: Self.source(1), entries: Self.entries([20, 21]))])
        #expect(again.added.count == 1)
        #expect(again.added.first?.name == "HISTORY 2026-08-01 (1)")
        #expect(again.added.first?.sequence == 2)
        // 그다음에는 새것과 견준다
        let third = Self.plan(existing: first.added + again.added, [.init(source: Self.source(1), entries: Self.entries([20, 21]))])
        #expect(third.isEmpty)
    }

    @Test func 다른_볼륨_다른_형식은_다른_기록이다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10]))])
        let again = Self.plan(existing: first.added, [
            .init(source: Self.source(1, volume: "VOL-B"), entries: Self.entries([10])),
            .init(source: Self.source(1, format: "deviceLibrary"), entries: Self.entries([10])),
        ])
        #expect(again.added.count == 2)
    }

    @Test func 볼륨_이름이_바뀌어도_같은_기록이다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10]))])
        var renamed = Self.source(1)
        renamed.volumeName = "새 이름"
        #expect(Self.plan(existing: first.added, [.init(source: renamed, entries: Self.entries([10]))]).isEmpty)
    }

    @Test func 이름은_보존본_이름과도_겹치지_않는다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10]))])
        let again = Self.plan(existing: first.added, [.init(source: Self.source(2, name: "HISTORY 002"), entries: Self.entries([11]))])
        #expect(first.added.first?.name == "HISTORY 2026-08-01")
        #expect(again.added.first?.name == "HISTORY 2026-08-01 (1)")
    }

    @Test func 보존본은_JSON으로_왕복한다() throws {
        let history = try #require(Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a"]))]).added.first)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ArchivedHistory.self, from: encoder.encode(history)) == history)
    }

    // MARK: - rekordbox도 가져온 기록

    @Test func 날짜_이름과_모든_곡의_순서가_같으면_숨기고_짝없는_항목은_남긴다() {
        let plan = Self.plan([
            .init(source: Self.source(1), entries: Self.entries([10, 11, 12], matched: [10: "a", 12: "c"])),
            .init(source: Self.source(2, name: "HISTORY 002"), entries: Self.entries([13], matched: [13: "d"])),
            .init(source: Self.source(3, name: "HISTORY 003"), entries: Self.entries([14])),
        ])
        let hidden = HistoryDuplicates.shadowedArchiveIDs(archived: plan.added, rekordbox: [
            .init(id: "1", name: plan.added[0].name, dateCreated: "2026-08-01 23:12:27", contentIDs: ["a", "c"]),
            .init(id: "2", name: plan.added[1].name, dateCreated: "2026-08-01 23:12:27", contentIDs: ["d"]),
            .init(id: "3", name: plan.added[2].name, dateCreated: "2026-08-01 23:12:27", contentIDs: []),
        ])
        #expect(hidden == ["usbhistory-id2"])
    }

    @Test func 다른_날이나_이름이_다른_기록은_같은_곡_배열이어도_숨기지_않는다() {
        let saved = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a", 11: "b"]))]).added
        for record in [
            HistoryDuplicates.Record(id: "old", name: "HISTORY 2026-07-31", dateCreated: "2026-07-31 23:12:27", contentIDs: ["a", "b"]),
            .init(id: "old-date", name: saved[0].name, dateCreated: "2026-07-31 23:12:27", contentIDs: ["a", "b"]),
            .init(id: "other-name", name: "HISTORY 2026-08-01 (9)", dateCreated: "2026-08-01 23:12:27", contentIDs: ["a", "b"]),
            .init(id: "undated", name: saved[0].name, dateCreated: nil, contentIDs: ["a", "b"]),
            .init(id: "invalid-date", name: saved[0].name, dateCreated: "날짜 없음", contentIDs: ["a", "b"]),
        ] {
            #expect(HistoryDuplicates.shadowedArchiveIDs(archived: saved, rekordbox: [record]).isEmpty)
        }
    }

    @Test func 곡_순서와_반복_횟수가_다르면_숨기지_않는다() {
        let saved = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11, 10], matched: [10: "a", 11: "b"]))]).added
        for ids in [["a", "b"], ["a", "a", "b"], ["b", "a", "a"]] {
            let record = HistoryDuplicates.Record(id: "rb", name: saved[0].name, dateCreated: "2026-08-01", contentIDs: ids)
            #expect(HistoryDuplicates.shadowedArchiveIDs(archived: saved, rekordbox: [record]).isEmpty)
        }
        let exact = HistoryDuplicates.Record(id: "rb", name: saved[0].name, dateCreated: "2026-08-01", contentIDs: ["a", "b", "a"])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: saved, rekordbox: [exact]) == [saved[0].id])
    }

    @Test func 하나의_rekordbox_기록은_하나의_보존본만_숨긴다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10], matched: [10: "a"]))]).added[0]
        var second = first
        second.id = "usbhistory-second"
        second.sequence = 2
        let record = HistoryDuplicates.Record(id: "rb", name: first.name, dateCreated: "2026-08-01", contentIDs: ["a"])
        // 입력 순서가 바뀌어도 먼저 보존한 기록을 짝짓는다
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [second, first], rekordbox: [record]) == [first.id])
    }

    @Test func 확정_쓰기_ID의_짝을_먼저_차지하고_날짜나_이름이_바뀌어도_알아본다() {
        let first = Self.plan([.init(source: Self.source(1), entries: Self.entries([10], matched: [10: "a"]))]).added[0]
        var written = first
        written.id = "usbhistory-written"
        written.sequence = 2
        written.rekordboxHistoryID = "rb"
        let record = HistoryDuplicates.Record(id: "rb", name: first.name, dateCreated: "2026-08-01", contentIDs: ["a"])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [first, written], rekordbox: [record]) == [written.id])
        let renamed = HistoryDuplicates.Record(id: "rb", name: "바꾼 이름", dateCreated: nil, contentIDs: ["a"])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [written], rekordbox: [renamed]) == [written.id])
    }

    @Test func 쓴_ID가_없거나_내용이_달라졌거나_짝없는_곡이_있으면_보존본을_남긴다() {
        var saved = Self.plan([.init(source: Self.source(1), entries: Self.entries([10, 11], matched: [10: "a", 11: "b"]))]).added[0]
        saved.rekordboxHistoryID = "written"
        let other = HistoryDuplicates.Record(id: "other", name: saved.name, dateCreated: "2026-08-01", contentIDs: ["a", "b"])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [saved], rekordbox: [other]).isEmpty)
        let changed = HistoryDuplicates.Record(id: "written", name: saved.name, dateCreated: "2026-08-01", contentIDs: ["a"])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [saved], rekordbox: [changed]).isEmpty)
        saved.entries[1].contentID = nil
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: [saved], rekordbox: [changed]).isEmpty)
    }

    @Test func USB_가져오기_이름만_견줄_대상이다() {
        #expect(HistoryDuplicates.isUsbImportName("HISTORY 2026-08-01"))
        #expect(HistoryDuplicates.isUsbImportName("HISTORY 2026-08-01 (2)"))
        #expect(!HistoryDuplicates.isUsbImportName("LINK HISTORY 2026-06-05"))
        #expect(!HistoryDuplicates.isUsbImportName("내 기록"))
        #expect(!HistoryDuplicates.isUsbImportName("HISTORY"))
    }

    @Test func rekordbox_기록이_없으면_숨기지_않는다() {
        let plan = Self.plan([.init(source: Self.source(1), entries: Self.entries([10], matched: [10: "a"]))])
        #expect(HistoryDuplicates.shadowedArchiveIDs(archived: plan.added, rekordbox: []).isEmpty)
    }
}

/// rekordbox 쓰기 대기(#43): 보존한 기록 중 rekordbox에 아직 없는 것만, 가져온 차례로.
@Suite("재생 기록 rekordbox 쓰기 대기")
struct HistoryWriteQueueTests {
    static func history(_ id: String, sequence: Int, matched: [Int: String] = [10: "a"], written: String? = nil,
                        excluded: Bool = false) -> ArchivedHistory {
        ArchivedHistory(id: id, name: "HISTORY 2026-08-01", importedAt: UsbHistoryImportTests.now, sequence: sequence,
                        source: UsbHistoryImportTests.source(sequence), entries: UsbHistoryImportTests.entries([10, 11], matched: matched),
                        rekordboxHistoryID: written, excludedFromRekordbox: excluded)
    }

    @Test func 숨김_뺀_것_컬렉션_곡이_없는_것은_대기가_아니다() {
        let all = [
            Self.history("c", sequence: 3),
            Self.history("a", sequence: 1),
            Self.history("shadowed", sequence: 2),
            Self.history("excluded", sequence: 4, excluded: true),
            Self.history("unmatched", sequence: 5, matched: [:]),
        ]
        let pending = HistoryWriteQueue.pending(all, shadowed: ["shadowed"], rekordboxHistoryIDs: [])
        #expect(pending.map(\.id) == ["a", "c"])
    }

    @Test func 같은_곡이_두_번_든_기록은_대기가_아니다() {
        let repeated = Self.history("r", sequence: 1, matched: [10: "a", 11: "a"])
        #expect(HistoryWriteQueue.hasRepeatedTracks(repeated))
        #expect(HistoryWriteQueue.pending([repeated], shadowed: [], rekordboxHistoryIDs: []).isEmpty)
        // 짝 없는 곡은 세지 않는다(rekordbox가 빼고 넣는다)
        #expect(!HistoryWriteQueue.hasRepeatedTracks(Self.history("n", sequence: 2, matched: [10: "a"])))
    }

    @Test func 쓴_기록이_rekordbox에_있으면_대기가_아니고_사라지면_다시_대기다() {
        let written = Self.history("w", sequence: 1, written: "2063847119")
        #expect(HistoryWriteQueue.pending([written], shadowed: [], rekordboxHistoryIDs: ["2063847119"]).isEmpty)
        // 쓰기 전으로 복원해 rekordbox에서 사라졌다
        #expect(HistoryWriteQueue.pending([written], shadowed: [], rekordboxHistoryIDs: []).map(\.id) == ["w"])
    }

    @Test func 쓰기_상태_칸이_없는_보존_파일도_읽는다() throws {
        let history = Self.history("old", sequence: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(history)) as? [String: Any])
        object["rekordboxHistoryID"] = nil
        object["excludedFromRekordbox"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ArchivedHistory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == history)
        #expect(decoded.rekordboxHistoryID == nil && !decoded.excludedFromRekordbox)
    }
}

/// 사이드바 재생 기록 트리: rekordbox처럼 연 › 월 › 기록, 오래된 것부터.
@Suite("재생 기록 트리")
struct HistoryTreeTests {
    typealias Item = HistoryTree.Item

    static func item(_ id: String, year: Int?, month: Int?, key: String, sequence: Int = 0) -> Item {
        Item(id: id, name: id, year: year, month: month, sortKey: key, sequence: sequence)
    }

    @Test func 연_월_기록을_오래된_것부터_놓는다() {
        let tree = HistoryTree.build([
            Self.item("c", year: 2026, month: 8, key: "2026-08-01 23:12:27", sequence: 3),
            Self.item("a", year: 2026, month: 8, key: "2026-08-01 23:12:27", sequence: 1),
            Self.item("b", year: 2026, month: 8, key: "2026-08-01 23:12:27", sequence: 2),
            Self.item("d", year: 2026, month: 6, key: "2026-06-05 19:29:12"),
            Self.item("e", year: 2020, month: 12, key: "2020-12-21 22:02:21"),
            Self.item("x", year: nil, month: nil, key: ""),
        ])
        #expect(tree.years.map(\.year) == [2020, 2026])
        #expect(tree.years.last?.months.map(\.month) == [6, 8])
        #expect(tree.years.last?.months.last?.items.map(\.id) == ["a", "b", "c"])
        #expect(tree.undated.map(\.id) == ["x"])
        #expect(tree.latestFolderIDs == ["history-year-2026", "history-month-2026-8"])
        #expect(tree.folderIDs(containing: "d") == ["history-year-2026", "history-month-2026-6"])
        #expect(tree.folderIDs(containing: "x").isEmpty)
    }

    @Test func 같은_달의_rekordbox_기록과_보존_기록은_시각_순으로_섞인다() {
        let tree = HistoryTree.build([
            Self.item("usb", year: 2026, month: 8, key: "2026-08-02 10:00:00", sequence: 1),
            Self.item("rb-late", year: 2026, month: 8, key: "2026-08-03 09:00:00", sequence: 2),
            Self.item("rb-early", year: 2026, month: 8, key: "2026-08-01 23:12:27", sequence: 1),
        ])
        #expect(tree.years.first?.months.first?.items.map(\.id) == ["rb-early", "usb", "rb-late"])
    }

    @Test func 빈_트리() {
        let tree = HistoryTree.build([])
        #expect(tree.isEmpty)
        #expect(tree.latestFolderIDs.isEmpty)
    }

    static func yearMonth(_ folders: [String], _ date: String?) -> [Int]? {
        HistoryTree.yearMonth(folderNames: folders, dateCreated: date).map { [$0.year, $0.month] }
    }

    @Test func rekordbox_폴더_이름에서_연_월을_읽는다() {
        #expect(Self.yearMonth(["2026", "8"], "2025-01-01 00:00:00") == [2026, 8])
        // 폴더가 연·월 모양이 아니면 DateCreated
        #expect(Self.yearMonth(["내 폴더"], "2025-11-26 18:10:31") == [2025, 11])
        #expect(Self.yearMonth(["2026", "13"], "2024-02-18") == [2024, 2])
        #expect(Self.yearMonth([], nil) == nil)
        #expect(Self.yearMonth([], "날짜") == nil)
        #expect(Self.yearMonth([], "2026/08/01") == nil)
    }

    @Test func 보존_기록의_정렬_키는_rekordbox_DateCreated와_같은_모양이다() {
        #expect(HistoryTree.sortKey(UsbHistoryImportTests.now, calendar: UsbHistoryImportTests.calendar) == "2026-08-01 23:12:27")
    }

    @Test func 이름_번호는_비어_있는_첫_번호를_쓴다() {
        let calendar = UsbHistoryImportTests.calendar
        let now = UsbHistoryImportTests.now
        #expect(HistoryNaming.name(for: now, calendar: calendar, taken: []) == "HISTORY 2026-08-01")
        #expect(HistoryNaming.name(for: now, calendar: calendar, taken: ["HISTORY 2026-08-01", "HISTORY 2026-08-01 (1)"])
            == "HISTORY 2026-08-01 (2)")
        // LINK HISTORY는 다른 이름이다
        #expect(HistoryNaming.name(for: now, calendar: calendar, taken: ["LINK HISTORY 2026-08-01"]) == "HISTORY 2026-08-01")
    }
}
