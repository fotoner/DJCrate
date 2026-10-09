import DJCDomain
import Foundation
import Testing

/// 보존한 기기 재생 기록의 판정(#43, `UsbHistoryRules`·`HistoryTree.make`, 입출력 없음): 쓴 표시 검증, 트리·숨김·쓰기 대기,
/// 쓰기 입력, 쓴 표시·쓰기 대기 빼기 반영. 화면 연결은 앱 시험(`UsbHistoryAppTests`·`UsbHistoryWriteTests`)이 본다. 곡·ID는 지어낸 값이다.
@Suite("USB 재생 기록 판정")
struct UsbHistoryRulesTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let collection: Set<String> = ["101", "102"]
    static func inCollection(_ id: String) -> Bool { collection.contains(id) }

    /// 라이브러리 1의 곡 101·102(원본 곡 ID = ContentID, 파일 이름 history-<ID>.mp3)
    static let local = LocalLibraryKeys(localDBID: 1, tracks: [
        UsbLocalTrackKey(contentID: "101", masterSongID: "101", fileNameL: "history-101.mp3"),
        UsbLocalTrackKey(contentID: "102", masterSongID: "102", fileNameL: "history-102.mp3"),
    ], counters: [:])

    /// 보존 기록 하나. `contentIDs`의 nil은 컬렉션 짝이 없는 곡
    static func archived(_ key: String, _ contentIDs: [String?], sequence: Int = 1, name: String? = nil, excluded: Bool = false,
                         written: String? = nil, library: String? = "1") -> ArchivedHistory {
        let entries = contentIDs.enumerated().map { offset, contentID in
            let fileName = "history-\(contentID ?? "unmatched").mp3"
            return ArchivedHistory.Entry(trackNumber: offset + 1, usbContentID: offset + 1, contentID: contentID, title: "합성 곡 \(offset + 1)",
                                         artist: nil, path: "/Contents/\(fileName)", masterDbId: 1,
                                         masterContentId: contentID.flatMap(Int64.init) ?? -1, fileName: fileName)
        }
        return ArchivedHistory(id: ArchivedHistory.idPrefix + key, name: name ?? "HISTORY 2026-09-21 (\(sequence))", importedAt: now,
                               sequence: sequence,
                               source: .init(volumeKey: "SYNTH", volumeName: "합성 USB", format: "oneLibrary", historyID: sequence,
                                             historyName: "HISTORY \(sequence)"),
                               entries: entries, rekordboxHistoryID: written, rekordboxLibraryID: written == nil ? nil : library,
                               excludedFromRekordbox: excluded)
    }

    static func rekordbox(_ id: String, name: String, _ contentIDs: [String], date: String = "2026-09-21 23:00:00") -> RekordboxHistory {
        RekordboxHistory(id: id, name: name, dateCreated: date, folderNames: ["2026", "9"], seq: 1,
                         entries: contentIDs.enumerated().map { .init(id: "\(id)-\($0.offset)", contentID: $0.element, trackNumber: $0.offset + 1) })
    }

    func view(_ histories: [RekordboxHistory] = [], _ archived: [ArchivedHistory], local: LocalLibraryKeys? = local, queueOpen: Bool = true,
              awaitingReload: Set<String> = []) -> UsbHistoryView {
        UsbHistoryRules.view(histories: histories, archived: archived, local: local, inCollection: Self.inCollection, queueOpen: queueOpen,
                             awaitingReload: awaitingReload, calendar: Self.utc)
    }

    // MARK: - 쓴 표시

    @Test func 쓴_표시는_같은_라이브러리일_때만_믿는다() {
        let here = Self.archived("here", ["101"], written: "rb-1")
        let elsewhere = Self.archived("elsewhere", ["101"], written: "rb-1", library: "2")
        #expect(UsbHistoryRules.hasValidWrittenMarker(here, local: Self.local, rekordbox: [:], inCollection: Self.inCollection))
        #expect(!UsbHistoryRules.hasValidWrittenMarker(elsewhere, local: Self.local, rekordbox: [:], inCollection: Self.inCollection))
        // 스냅샷 키를 모르면 믿지 않는다
        #expect(!UsbHistoryRules.hasValidWrittenMarker(here, local: nil, rekordbox: [:], inCollection: Self.inCollection))
    }

    @Test func 라이브러리_ID_없는_옛_표시는_이름과_전체_곡_순서가_같은_rekordbox_기록이_있을_때만_믿는다() {
        let legacy = Self.archived("legacy", ["102", "101"], written: "rb-a", library: nil)
        let same = Self.rekordbox("rb-a", name: legacy.name, ["102", "101"])
        func valid(_ record: RekordboxHistory?, _ history: ArchivedHistory = legacy) -> Bool {
            UsbHistoryRules.hasValidWrittenMarker(history, local: Self.local, rekordbox: record.map { [$0.id: $0] } ?? [:],
                                                  inCollection: Self.inCollection)
        }
        #expect(valid(same))
        #expect(!valid(nil))
        #expect(!valid(Self.rekordbox("rb-a", name: "다른 이름", ["102", "101"])))
        #expect(!valid(Self.rekordbox("rb-a", name: legacy.name, ["101", "102"])))
        // 짝 없는 곡이 든 보존본은 순서가 같아도 믿지 않는다
        #expect(!valid(same, Self.archived("legacy", ["102", nil, "101"], written: "rb-a", library: nil)))
        // 믿지 못한 표시는 쓰기 대기를 고를 때 지운다
        #expect(UsbHistoryRules.validatedMarkers([legacy], local: Self.local, rekordbox: [:], inCollection: Self.inCollection)
            .first?.rekordboxHistoryID == nil)
    }

    // MARK: - 트리·숨김·쓰기 대기

    @Test func 쓰기_대기는_관문이_열리고_키를_알_때만_고르며_뺀_기록_짝_없는_기록_반복_곡_기록은_빼고_사라진_쓴_기록은_다시_올린다() {
        let pending = Self.archived("pending", ["102", nil, "101"], sequence: 1)
        let noMatch = Self.archived("nomatch", [nil, nil], sequence: 2)
        let excluded = Self.archived("excluded", ["101"], sequence: 3, excluded: true)
        let written = Self.archived("written", ["102"], sequence: 4, written: "rb-present")
        let restored = Self.archived("restored", ["102", "101"], sequence: 5, written: "rb-gone")
        let repeated = Self.archived("repeated", ["101", "102", "101"], sequence: 6)
        let all = [pending, noMatch, excluded, written, restored, repeated]
        let present = Self.rekordbox("rb-present", name: "다른 기록", ["102"], date: "2026-01-01 00:00:00")
        #expect(view([present], all).pending.map(\.id) == [pending.id, restored.id])
        #expect(view([present], all, queueOpen: false).pending.isEmpty)
        #expect(view([present], all, local: nil).pending.isEmpty)
        // 쓴 뒤 다시 읽기 전에는 쓴 ID를 rekordbox에 있는 것으로 본다
        #expect(view([present], all, awaitingReload: ["rb-gone"]).pending.map(\.id) == [pending.id])
    }

    @Test func rekordbox도_가져온_같은_기록은_트리와_쓰기_대기에서_숨기고_rekordbox_기록이_없어지면_다시_보인다() throws {
        let shadowed = Self.archived("shadowed", ["101", "102"], name: "HISTORY 2026-09-21")
        let record = Self.rekordbox("rb-usb", name: "HISTORY 2026-09-21", ["101", "102"])
        let hidden = view([record], [shadowed])
        #expect(hidden.shadowed == [shadowed.id] && hidden.pending.isEmpty)
        #expect(hidden.tree.folderIDs(containing: shadowed.id).isEmpty)
        #expect(hidden.tree.folderIDs(containing: "rb-usb") == [HistoryTree.yearID(2026), HistoryTree.monthID(year: 2026, month: 9)])
        let shown = view([], [shadowed])
        #expect(shown.shadowed.isEmpty && shown.pending.map(\.id) == [shadowed.id])
        #expect(shown.tree.folderIDs(containing: shadowed.id) == [HistoryTree.yearID(2026), HistoryTree.monthID(year: 2026, month: 9)])
        // 스냅샷 키를 모르면 아무것도 숨기지 않는다
        #expect(view([record], [shadowed], local: nil).shadowed.isEmpty)
    }

    @Test func 트리는_rekordbox_기록의_폴더_이름과_보존본의_가져온_날로_연_월을_정한다() {
        let older = RekordboxHistory(id: "old", name: "", dateCreated: "2025-01-05 10:00:00", folderNames: ["2025", "1"], seq: 1, entries: [])
        let undated = RekordboxHistory(id: "undated", name: "", dateCreated: nil, entries: [])
        let tree = HistoryTree.make(histories: [older, undated], archived: [Self.archived("a", ["101"])], calendar: Self.utc)
        #expect(tree.years.map(\.year) == [2025, 2026])
        #expect(tree.folderIDs(containing: ArchivedHistory.idPrefix + "a") == [HistoryTree.yearID(2026), HistoryTree.monthID(year: 2026, month: 9)])
        #expect(tree.undated.map(\.id) == ["undated"])
        #expect(tree.years.first?.months.first?.items.map(\.name) == ["2025-01-05"])
        #expect(tree.undated.map(\.name) == ["날짜 없음"])
    }

    // MARK: - 쓰기 입력과 결과 반영

    @Test func 쓰기_입력은_컬렉션_짝이_있는_곡만_재생_순서대로_넘기고_뺀_수와_원본_식별을_남긴다() throws {
        let history = Self.archived("skipped", ["102", nil, "missing", "101"], written: "rb-old")
        let input = try #require(UsbHistoryRules.imports([history], local: Self.local, inCollection: Self.inCollection).first)
        #expect(input.id == history.id && input.name == history.name && input.dateCreated == history.importedAt)
        #expect(input.contentIDs == ["102", "101"])
        #expect(input.skippedBeforeMatching == 2)
        #expect(input.expectedLibraryID == "1" && input.existingHistoryID == "rb-old")
        #expect(input.trackIdentities.map(\.contentID) == ["102", "101"])
        #expect(input.trackIdentities.map(\.fileName) == ["history-102.mp3", "history-101.mp3"])
        #expect(UsbHistoryRules.imports([history], local: nil, inCollection: Self.inCollection).first?.expectedLibraryID == nil)
    }

    @Test func 쓴_결과와_이미_있던_결과만_표시하고_막힌_결과는_표시하지_않는다() {
        let a = Self.archived("a", ["101"]), b = Self.archived("b", ["102"]), c = Self.archived("c", ["101"])
        let outcomes = [
            RekordboxHistoryOutcome(id: a.id, name: a.name, historyID: "rb-a", status: .written, reason: nil, entries: 1, skipped: 0),
            RekordboxHistoryOutcome(id: b.id, name: b.name, historyID: "rb-b", status: .unchanged, reason: nil, entries: 0, skipped: 0),
            RekordboxHistoryOutcome(id: c.id, name: c.name, historyID: nil, status: .blocked, reason: "막힘", entries: 0, skipped: 0),
        ]
        let marked = UsbHistoryRules.markWritten([a, b, c], outcomes: outcomes, local: Self.local)
        #expect(marked.historyIDs == ["rb-a", "rb-b"])
        #expect(marked.changed.map(\.id) == [a.id, b.id])
        #expect(marked.changed.map(\.rekordboxHistoryID) == ["rb-a", "rb-b"])
        #expect(marked.changed.allSatisfy { $0.rekordboxLibraryID == "1" })
    }

    @Test func 쓰기_대기_빼기는_상태가_바뀌는_것만_돌려준다() {
        let a = Self.archived("a", ["101"]), b = Self.archived("b", ["102"], excluded: true)
        #expect(UsbHistoryRules.excluding([a, b], ids: [a.id, b.id, "없음"], excluded: true).map(\.id) == [a.id])
        #expect(UsbHistoryRules.excluding([a, b], ids: [a.id, b.id], excluded: false).map(\.id) == [b.id])
        #expect(UsbHistoryRules.excluding([a, b], ids: [a.id], excluded: true).first?.excludedFromRekordbox == true)
    }

    @Test func 새로_보존한_기록은_끝에_더하고_있던_기록은_지금의_쓰기_상태를_남긴다() {
        let current = Self.archived("a", [nil], excluded: true, written: "rb-a")
        var rematched = Self.archived("a", ["101"])
        rematched.rekordboxHistoryID = nil
        let added = Self.archived("b", ["102"], sequence: 2)
        let merged = UsbHistoryRules.merging(saved: [rematched, added], into: [current])
        #expect(merged.map(\.id) == [current.id, added.id])
        #expect(merged[0].entries.map(\.contentID) == ["101"])
        #expect(merged[0].excludedFromRekordbox && merged[0].rekordboxHistoryID == "rb-a" && merged[0].rekordboxLibraryID == "1")
        // 바꾸기는 없는 ID를 더하지 않는다
        #expect(UsbHistoryRules.replacing([current], with: [added]) == [current])
        #expect(UsbHistoryRules.replacing([current], with: [rematched]) == [rematched])
    }
}
