import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// USB 기기 재생 기록 보존 유스케이스(`ArchiveUsbHistories`, #43): 후보 → 계획 → 짝 다시 검증 → 기록마다 저장의 순서와
/// 저장 실패 때 채택할 기록을 가짜 파일(`MemoryUsbHistoryFiles`)로 본다. 후보·계획의 규칙은 DJCDomainTests가, 화면 연결은 앱 시험
/// (`UsbHistoryAppTests`)이 본다. 곡·볼륨은 지어낸 값이다.
@Suite("USB 재생 기록 보존 유스케이스")
struct ArchiveUsbHistoriesTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let localDBID: Int64 = 424_242
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func track(_ id: Int) -> UsbTrack {
        UsbTrack(id: id, presentIn: [.oneLibrary], title: "합성 곡 \(id)", path: "/Contents/합성/test\(id).mp3", fileName: "test\(id).mp3",
                 masterDbId: localDBID, masterContentId: Int64(500 + id))
    }

    /// OneLibrary 기록 둘(곡 1·2, 곡 2·3). 곡 3은 로컬에 없다
    static func library() -> UsbLibrary {
        UsbLibrary(formats: [.oneLibrary], property: UsbProperty(), tracks: [track(1), track(2), track(3)],
                   histories: [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [1, 2]),
                               UsbHistory(format: .oneLibrary, id: 2, name: "HISTORY 002", entries: [2, 3])])
    }

    /// 곡 1 ↔ 101, 2 ↔ 102
    static func local() -> LocalLibraryKeys {
        LocalLibraryKeys(localDBID: localDBID, tracks: [
            UsbLocalTrackKey(contentID: "101", masterSongID: "501", fileNameL: "test1.mp3"),
            UsbLocalTrackKey(contentID: "102", masterSongID: "502", fileNameL: "test2.mp3"),
        ], counters: [:])
    }

    static func archive(_ files: MemoryUsbHistoryFiles) -> ArchiveUsbHistories {
        let counter = Counter()
        return ArchiveUsbHistories(files: files.files, now: { now }, newID: { "id\(counter.next())" })
    }

    func importFrom(_ archive: ArchiveUsbHistories, existing: [ArchivedHistory] = [], local: LocalLibraryKeys? = local(),
                    matches: [Int: String] = [1: "101", 2: "102"]) async -> ArchiveUsbHistories.Imported? {
        await archive.importFrom(volumeKey: "SYNTH", volumeName: "합성 USB", library: Self.library(), matches: matches, existing: existing,
                                 local: local, calendar: Self.utc)
    }

    @Test func 새_기록을_기록마다_저장하고_원본_키로_다시_짝지은_보존본을_돌려준다() async throws {
        let files = MemoryUsbHistoryFiles()
        let imported = try #require(await importFrom(Self.archive(files)))
        #expect(!imported.failed)
        #expect(imported.added.map(\.source.historyName) == ["HISTORY 001", "HISTORY 002"])
        #expect(imported.saved.map(\.id) == imported.added.map(\.id))
        #expect(files.saves == imported.saved.map(\.id))
        #expect(files.histories == imported.saved)
        // 이름은 가져온 날(달력)로, 같은 날 둘째부터 번호(1부터)를 붙인다
        #expect(imported.saved.map(\.name) == ["HISTORY 2026-09-21", "HISTORY 2026-09-21 (1)"])
        #expect(imported.saved.allSatisfy { $0.importedAt == Self.now })
        // 짝은 넘긴 짝이 아니라 원본 키로 다시 검증한 값이다(곡 3은 짝이 없다)
        #expect(imported.saved.map { $0.entries.map(\.contentID) } == [["101", "102"], ["102", nil]])
    }

    @Test func 로컬_키를_모르면_짝을_비운_채_보존한다() async throws {
        let files = MemoryUsbHistoryFiles()
        let imported = try #require(await importFrom(Self.archive(files), local: nil))
        #expect(imported.saved.count == 2)
        #expect(imported.saved.allSatisfy { $0.entries.allSatisfy { $0.contentID == nil } })
    }

    @Test func 같은_USB를_다시_읽으면_보존할_것이_없고_기록이_없는_USB도_아무것도_하지_않는다() async throws {
        let files = MemoryUsbHistoryFiles()
        let archive = Self.archive(files)
        let first = try #require(await importFrom(archive))
        #expect(await importFrom(archive, existing: first.saved) == nil)
        #expect(files.saves.count == 2)
        let empty = await archive.importFrom(volumeKey: "SYNTH", volumeName: "합성 USB",
                                             library: UsbLibrary(formats: [.oneLibrary], property: UsbProperty()), matches: [:],
                                             existing: [], local: Self.local(), calendar: Self.utc)
        #expect(empty == nil && files.saves.count == 2)
    }

    @Test func 저장이_실패하면_그_뒤_기록은_저장하지_않고_저장된_것만_돌려준다() async throws {
        let files = MemoryUsbHistoryFiles()
        files.fail([ArchivedHistory.idPrefix + "id1"])
        let imported = try #require(await importFrom(Self.archive(files)))
        #expect(imported.failed)
        #expect(imported.added.count == 2)
        #expect(imported.saved.isEmpty && files.histories.isEmpty)
        #expect(files.saves == [ArchivedHistory.idPrefix + "id1"])
    }

    @Test func 저장_오류_뒤에도_파일_내용이_같으면_같은_ID로_채택하고_실패를_알린다() async throws {
        let files = MemoryUsbHistoryFiles()
        files.fail([ArchivedHistory.idPrefix + "id1"], afterWrite: true)
        let imported = try #require(await importFrom(Self.archive(files)))
        #expect(imported.failed)
        // 앞 기록은 채택하고, 실패에서 멈춰 뒤 기록은 저장하지 않는다
        #expect(imported.saved.map(\.id) == [ArchivedHistory.idPrefix + "id1"])
        #expect(files.histories.map(\.id) == [ArchivedHistory.idPrefix + "id1"])
    }

    @Test func 바뀐_보존본_저장은_기록마다_하고_저장하지_못한_수를_돌려준다() async throws {
        let files = MemoryUsbHistoryFiles()
        let archive = Self.archive(files)
        let saved = try #require(await importFrom(archive)).saved
        var changed = saved.map { history in
            var history = history
            history.excludedFromRekordbox = true
            return history
        }
        files.fail([changed[0].id])
        #expect(await archive.save(changed) == 1)
        #expect(files.histories.map(\.excludedFromRekordbox) == [false, true])
        files.fail([])
        changed[0].rekordboxHistoryID = "rb-1"
        #expect(await archive.save(changed) == 0)
        #expect(await archive.load().histories == changed)
        #expect(await archive.save([]) == 0)
    }

    @Test func 읽기는_옮긴_파일과_읽지_못한_파일을_그대로_넘긴다() async {
        let files = MemoryUsbHistoryFiles()
        files.report(damaged: ["a.json"], unreadable: ["b.json"])
        let loaded = await Self.archive(files).load()
        #expect(loaded == ArchivedHistoryLoad(histories: [], damaged: ["a.json"], unreadable: ["b.json"]))
    }
}

/// 새 ID 뒷부분(차례대로 1, 2, …)
private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}
