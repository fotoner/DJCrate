import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// USB 기기 재생 기록 보존 유스케이스(`ArchiveUsbHistories`, #43): 후보 → 계획 → 짝 다시 검증 → 기록마다 저장의 순서와
/// 저장 실패 때 채택할 기록을 가짜 파일(`MemoryUsbHistoryFiles`)로 본다. 보존·저장의 줄 세우기, 채택, 실패 알림(#251)은 가짜 화면
/// (`FakeUsbHistoryScreen`)으로 본다. 후보·계획의 규칙은 DJCDomainTests가, 화면 연결은 앱 시험(`UsbHistoryAppTests`)이 본다.
/// 곡·볼륨은 지어낸 값이다.
@MainActor
@Suite("USB 재생 기록 보존 유스케이스")
struct ArchiveUsbHistoriesTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)
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

    // MARK: - 줄 세우기·채택·실패 알림(#251, 옛 `LibraryStore+Histories`)

    /// 가짜 화면을 붙인 보존 흐름. `files`가 nil이면 보존 파일을 붙이지 않은 것이다(시험 기본·CLI)
    static func flow(_ files: MemoryUsbHistoryFiles?, screen: FakeUsbHistoryScreen) -> ArchiveUsbHistories {
        let counter = Counter()
        let archive = ArchiveUsbHistories(files: files?.files, now: { now }, newID: { "id\(counter.next())" })
        archive.screen = screen.port
        return archive
    }

    func startImport(_ archive: ArchiveUsbHistories) {
        archive.startImport(volumeKey: "SYNTH", volumeName: "합성 USB", library: Self.library(), matches: [1: "101", 2: "102"],
                            calendar: Self.utc)
    }

    /// 상태를 기다린다. 안전망(300초)은 판정이 오지 않는 잘못된 구현에서 시험이 멈추지 않게 할 뿐이다(TEST-30~32)
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(300)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    static func warning(_ title: String, _ detail: String?) -> UsbHistoryNotice {
        UsbHistoryNotice(kind: .warning, title: title, detail: detail)
    }

    @Test func 보존본_읽기를_줄_맨_앞에_세워_USB_보존은_읽은_보존본과_견준다() async throws {
        let files = MemoryUsbHistoryFiles()
        let earlier = try #require(await importFrom(Self.archive(files))).saved
        let screen = FakeUsbHistoryScreen()
        screen.state.local = Self.local()
        let archive = Self.flow(files, screen: screen)
        archive.startLoading()
        startImport(archive)
        await archive.waitUntilIdle()
        // 읽기가 끝난 뒤의 보존본과 견주므로 같은 USB 기록을 다시 보존하지 않고 알리지도 않는다
        #expect(screen.state.archived == earlier)
        #expect(files.saves.count == 2)
        #expect(screen.events == ["archived \(earlier.map(\.id).joined(separator: ","))", "loaded"])
        #expect(screen.notices.isEmpty)
    }

    @Test func 새로_보존한_기록은_저장된_것만_넣고_숨긴_기록을_뺀_수와_쓰기_대기에_올린_수를_알린다() async throws {
        // (쓰기 대기에 올릴 기록, 알림 둘째 줄)
        let cases: [(Set<String>, String)] = [
            (["HISTORY 001"], "합성 USB · rekordbox 쓰기 대기에 올렸습니다"),
            ([], "합성 USB"),
        ]
        for (queued, detail) in cases {
            let files = MemoryUsbHistoryFiles()
            let screen = FakeUsbHistoryScreen()
            screen.state.local = Self.local()
            // 앱의 조각처럼 보존본을 넣으면 고른다: HISTORY 002는 rekordbox도 가져온 기록이라 숨긴다
            screen.refresh = { state in
                state.shadowed = Set(state.archived.filter { $0.source.historyName == "HISTORY 002" }.map(\.id))
                state.pending = Set(state.archived.filter { queued.contains($0.source.historyName) }.map(\.id))
            }
            let archive = Self.flow(files, screen: screen)
            startImport(archive)
            await archive.waitUntilIdle()
            let ids = screen.state.archived.map(\.id)
            #expect(ids.count == 2 && Set(files.histories.map(\.id)) == Set(ids))
            let shown = try #require(screen.state.archived.first { $0.source.historyName == "HISTORY 001" }).id
            #expect(screen.imported?.shown == [shown])
            #expect(screen.imported?.saved == Set(ids))
            #expect(screen.notices == [UsbHistoryNotice(kind: .success, title: "USB에서 재생 기록 1개를 가져왔습니다", detail: detail)])
            #expect(screen.events == ["archived \(ids.joined(separator: ","))", "imported \(shown)"])
        }
    }

    @Test func 일부만_쓰기_대기에_올렸으면_그_수를_알린다() async {
        let files = MemoryUsbHistoryFiles()
        let screen = FakeUsbHistoryScreen()
        screen.refresh = { state in
            state.pending = Set(state.archived.filter { $0.source.historyName == "HISTORY 002" }.map(\.id))
        }
        let archive = Self.flow(files, screen: screen)
        startImport(archive)
        await archive.waitUntilIdle()
        #expect(screen.imported?.shown.count == 2)
        #expect(screen.notices == [UsbHistoryNotice(kind: .success, title: "USB에서 재생 기록 2개를 가져왔습니다",
                                                    detail: "합성 USB · 1개를 rekordbox 쓰기 대기에 올렸습니다")])
    }

    @Test func 보존하지_못하면_경고하고_저장된_기록만_넣되_가져왔다고_알리지_않는다() async {
        // 저장 전에 실패: 넣을 기록이 없다
        let failing = MemoryUsbHistoryFiles()
        failing.fail([ArchivedHistory.idPrefix + "id1"])
        let screen = FakeUsbHistoryScreen()
        let archive = Self.flow(failing, screen: screen)
        startImport(archive)
        await archive.waitUntilIdle()
        #expect(screen.events == ["notice USB 재생 기록을 보존하지 못했습니다"])
        #expect(screen.notices == [Self.warning("USB 재생 기록을 보존하지 못했습니다", "DJCrate 데이터 폴더의 usb-histories를 확인한 뒤 USB를 다시 연결하세요")])
        #expect(screen.state.archived.isEmpty)

        // rename 뒤 폴더 fsync만 실패: 같은 ID를 채택해 넣고 펼치지만 성공 알림은 하지 않는다
        let synced = MemoryUsbHistoryFiles()
        synced.fail([ArchivedHistory.idPrefix + "id1"], afterWrite: true)
        let other = FakeUsbHistoryScreen()
        let adopted = Self.flow(synced, screen: other)
        startImport(adopted)
        await adopted.waitUntilIdle()
        let id = ArchivedHistory.idPrefix + "id1"
        #expect(other.events == ["notice USB 재생 기록을 보존하지 못했습니다", "archived \(id)", "imported \(id)"])
        #expect(other.notices.map(\.kind) == [.warning])
    }

    @Test func 읽지_못한_보존_파일이_남으면_새_보존을_막고_해소되면_고친_상태를_지킨_채_새로_읽힌_기록만_더한다() async throws {
        let earlier = try #require(await importFrom(Self.archive(MemoryUsbHistoryFiles()))).saved
        let files = MemoryUsbHistoryFiles([earlier[0]])
        files.report(unreadable: ["b.json"])
        let screen = FakeUsbHistoryScreen()
        screen.state.local = Self.local()
        let archive = Self.flow(files, screen: screen)
        archive.startLoading()
        await archive.waitUntilIdle()
        let unreadable = Self.warning("USB 재생 기록 파일을 읽지 못했습니다. usb-histories 읽기 권한을 확인한 뒤 USB를 다시 연결하세요", "b.json")
        #expect(archive.unreadable == ["b.json"])
        #expect(screen.state.archived == [earlier[0]])
        #expect(screen.notices == [unreadable])

        // 읽지 못한 파일이 남아 있으면 다시 읽어 보고 새 ID로 보존하지 않는다(그 파일이 이 USB 기록일 수 있다)
        startImport(archive)
        await archive.waitUntilIdle()
        #expect(files.saves.isEmpty)
        #expect(screen.notices == [unreadable, unreadable])

        // 그사이 고친 쓰기 상태는 지키고, 이제 읽힌 파일의 기록만 더한 뒤 보존한다(이미 든 기록이라 새로 보존할 것은 없다)
        screen.state.archived[0].excludedFromRekordbox = true
        files.report()
        try files.files.save(earlier[1])
        startImport(archive)
        await archive.waitUntilIdle()
        var kept = earlier[0]
        kept.excludedFromRekordbox = true
        #expect(archive.unreadable.isEmpty)
        #expect(screen.state.archived == [kept, earlier[1]])
        #expect(files.saves == [earlier[1].id])
        #expect(screen.notices.count == 2)
    }

    @Test func 옮긴_보존_파일은_읽은_뒤_알린다() async {
        let files = MemoryUsbHistoryFiles()
        files.report(damaged: ["a.json", "c.json"])
        let screen = FakeUsbHistoryScreen()
        let archive = Self.flow(files, screen: screen)
        archive.startLoading()
        await archive.waitUntilIdle()
        #expect(screen.events == ["archived ", "loaded"])
        #expect(screen.notices == [Self.warning("읽지 못한 USB 재생 기록 파일 2개를 damaged-drafts로 옮겼습니다. 기록이 남은 USB를 다시 연결하면 다시 가져옵니다",
                                                "a.json, c.json")])
    }

    @Test func 쓰기_대기에서_빼면_바로_화면에_넣고_저장은_줄_차례의_보존본으로_하며_저장하지_못하면_알린다() async throws {
        let files = MemoryUsbHistoryFiles()
        let saved = try #require(await importFrom(Self.archive(files))).saved
        let screen = FakeUsbHistoryScreen()
        screen.state.archived = saved
        let archive = Self.flow(files, screen: screen)
        #expect(archive.exclude([saved[0].id, "없는 기록"], excluded: true) == [saved[0].id])
        #expect(screen.state.archived[0].excludedFromRekordbox)
        // 저장이 줄 차례를 기다리는 동안 다시 고친 값(쓴 표시)까지 저장한다
        screen.state.archived[0].rekordboxHistoryID = "rb-1"
        await archive.waitUntilIdle()
        let stored = try #require(files.histories.first { $0.id == saved[0].id })
        #expect(stored.excludedFromRekordbox && stored.rekordboxHistoryID == "rb-1")
        // 이미 그 상태면 바꾸지 않는다
        #expect(archive.exclude([saved[0].id], excluded: true).isEmpty)

        // 저장하지 못하면 알린다. 화면 상태는 되돌리지 않는다(다시 켜면 옛 상태로 읽힌다)
        files.fail([saved[1].id])
        #expect(archive.exclude([saved[1].id], excluded: true) == [saved[1].id])
        await archive.waitUntilIdle()
        try await waitUntil { !screen.notices.isEmpty }
        #expect(screen.notices == [Self.warning(ArchiveUsbHistories.queueSaveFailureTitle,
                                                "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 바꾸세요")])
        #expect(ArchiveUsbHistories.queueSaveFailureTitle == "재생 기록의 쓰기 대기 상태를 저장하지 못했습니다")
        #expect(screen.state.archived[1].excludedFromRekordbox)
    }

    @Test func rekordbox에_쓴_기록에_표시하고_다시_읽을_때까지_기다릴_ID를_알리며_표시를_저장하지_못하면_알릴_문장을_돌려준다() async throws {
        let files = MemoryUsbHistoryFiles()
        let saved = try #require(await importFrom(Self.archive(files))).saved
        let screen = FakeUsbHistoryScreen()
        screen.state.archived = saved
        screen.state.local = Self.local()
        let archive = Self.flow(files, screen: screen)
        let written = RekordboxHistoryOutcome(id: saved[0].id, name: saved[0].name, historyID: "rb-1", status: .written, reason: nil,
                                              entries: 2, skipped: 0)
        let blocked = RekordboxHistoryOutcome(id: saved[1].id, name: saved[1].name, historyID: nil, status: .blocked, reason: "막힘",
                                              entries: 0, skipped: 0)
        #expect(await archive.markWritten([written, blocked]) == nil)
        // 다시 읽을 때까지 기다릴 ID를 먼저 알리고(쓰기 대기를 다시 고른다) 표시한 보존본을 넣는다
        #expect(screen.events == ["awaiting rb-1", "archived \(saved.map(\.id).joined(separator: ","))"])
        #expect(screen.state.archived[0].rekordboxHistoryID == "rb-1")
        #expect(screen.state.archived[0].rekordboxLibraryID == String(Self.localDBID))
        #expect(files.histories.first { $0.id == saved[0].id }?.rekordboxHistoryID == "rb-1")
        // 막힌 결과만이면 아무것도 하지 않는다
        #expect(await archive.markWritten([blocked]) == nil)
        #expect(screen.events.count == 2)
        // 표시를 저장하지 못해도 rekordbox에는 쓴 뒤라 상태는 남기고 알릴 문장만 돌려준다
        files.fail([saved[1].id])
        let again = RekordboxHistoryOutcome(id: saved[1].id, name: saved[1].name, historyID: "rb-2", status: .unchanged, reason: nil,
                                            entries: 1, skipped: 1)
        #expect(await archive.markWritten([again]) == ArchiveUsbHistories.markFailureText(1))
        #expect(screen.state.archived[1].rekordboxHistoryID == "rb-2")
    }

    @Test func 채택한_스냅샷_키로_다시_짝지은_보존본만_저장하고_저장하지_못하면_알린다() async throws {
        let files = MemoryUsbHistoryFiles()
        let unmatched = try #require(await importFrom(Self.archive(files), local: nil)).saved
        let screen = FakeUsbHistoryScreen()
        screen.state.archived = unmatched
        let archive = Self.flow(files, screen: screen)
        // 키를 모르면 바뀌는 것이 없다
        archive.rematch()
        #expect(screen.events.isEmpty)
        screen.state.local = Self.local()
        archive.rematch()
        #expect(screen.state.archived.map { $0.entries.map(\.contentID) } == [["101", "102"], ["102", nil]])
        await archive.waitUntilIdle()
        #expect(files.histories.map { $0.entries.map(\.contentID) } == [["101", "102"], ["102", nil]])

        files.fail([unmatched[0].id])
        screen.state.archived = unmatched
        archive.rematch()
        await archive.waitUntilIdle()
        try await waitUntil { !screen.notices.isEmpty }
        #expect(screen.notices == [Self.warning("USB 재생 기록을 보존하지 못했습니다",
                                                "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 시도하세요")])
    }

    @Test func 보존_파일을_붙이지_않으면_읽기·보존·저장을_하지_않는다() async {
        let screen = FakeUsbHistoryScreen()
        let archive = Self.flow(nil, screen: screen)
        #expect(!archive.isEnabled)
        archive.startLoading()
        startImport(archive)
        await archive.waitUntilIdle()
        #expect(screen.events.isEmpty)
        #expect(await archive.load() == ArchivedHistoryLoad())
        #expect(await archive.importFrom(volumeKey: "SYNTH", volumeName: "합성 USB", library: Self.library(), matches: [:], existing: [],
                                         local: nil, calendar: Self.utc) == nil)
    }
}

/// 새 ID 뒷부분(차례대로 1, 2, …)
private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}
