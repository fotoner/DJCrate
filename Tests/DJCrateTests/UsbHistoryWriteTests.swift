@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// USB에서 보존한 재생 기록(#43)을 "rekordbox 쓰기 대기"에 올려 rekordbox에 쓰기(⇧⌘E) 때 rekordbox Histories에 넣는다.
/// 대기 고르기·빼기와 다시 넣기·쓰기 흐름(미리 보기 → 막힘이 있을 때만 확인 → 쓰기 → 다시 읽기 → 결과)·쓰기 전으로 복원 뒤 다시 대기를 본다.
/// 보존 저장소·rekordbox 사본은 임시 폴더다(사용자 폴더를 쓰지 않는다). 실제로 쓰는 시험은 `DJC_HOME`이 있을 때만 돈다.
@MainActor
@Suite("USB 재생 기록 rekordbox 쓰기 대기(앱)", .serialized)
struct UsbHistoryWriteTests {
    static let now = UsbHistoryAppTests.now

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbhistory-write-\(UUID().uuidString)")
    }

    /// 보존 기록 하나. `contentIDs`의 nil은 컬렉션 짝이 없는 곡
    static func archived(_ key: String, _ contentIDs: [String?], sequence: Int, name: String? = nil,
                         excluded: Bool = false, written: String? = nil) -> ArchivedHistory {
        let entries = contentIDs.enumerated().map { offset, contentID in
            let fileName = "history-\(contentID ?? "unmatched").mp3"
            return ArchivedHistory.Entry(trackNumber: offset + 1, usbContentID: offset + 1, contentID: contentID, title: "시험 곡 \(offset + 1)",
                                  artist: "시험 아티스트", path: "/Contents/\(fileName)", masterDbId: 1,
                                  masterContentId: contentID.flatMap(Int64.init) ?? -1, fileName: fileName)
        }
        return ArchivedHistory(id: ArchivedHistory.idPrefix + key, name: name ?? "HISTORY 2026-09-21 (\(sequence))", importedAt: now,
                               sequence: sequence,
                               source: .init(volumeKey: "TEST-VOLUME", volumeName: "시험 USB", format: "oneLibrary", historyID: sequence,
                                             historyName: "HISTORY \(sequence)"),
                               entries: entries, rekordboxHistoryID: written, rekordboxLibraryID: written == nil ? nil : "1",
                               excludedFromRekordbox: excluded)
    }

    @Test("같은 기록 ID가 다른 라이브러리에 있어도 쓴 표시로 오인하지 않는다")
    func writtenMarkerIsScopedToLibrary() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        // 이 보존본의 원본 곡은 현재 라이브러리에 있지만, 쓴 표시는 다른 라이브러리에서 남겼다.
        var target = Self.archived("foreign-marker", ["102", "101"], sequence: 1, written: "new-a")
        target.entries = target.entries.map { entry in
            var entry = entry
            entry.masterDbId = 2
            return entry
        }
        try fixture.execute("UPDATE djmdProperty SET DBID = '2'")
        let (store, _) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        #expect(store.archivedHistory(target.id)?.rekordboxLibraryID == "1")
        #expect(store.pendingHistoryIDs == [target.id])
        #expect(!store.shadowedArchiveIDs.contains(target.id))
    }

    @Test("라이브러리 ID 없는 옛 쓴 표시는 ID만으로 믿지 않고 이름·검증된 전체 곡 순서가 같을 때만 인정한다")
    func legacyWrittenMarkerRequiresSafeValidation() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        var target = Self.archived("legacy-marker", ["102", "101"], sequence: 1, written: "new-a")
        target.rekordboxLibraryID = nil
        let (store, saved) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        #expect(Self.savedHistory(saved, target.id)?.rekordboxLibraryID == nil)
        #expect(store.pendingHistoryIDs == [target.id])
        store.histories = [.init(id: "new-a", name: target.name, dateCreated: nil, entries: [
            .init(id: "same-1", contentID: "102", trackNumber: 1),
            .init(id: "same-2", contentID: "101", trackNumber: 2),
        ])]
        #expect(store.pendingHistories.isEmpty)
    }

    @Test("쓰기 입력은 짝 없음과 현재 컬렉션에 없는 항목을 함께 제외 수에 남긴다")
    func pendingImportsRetainUnmatchedCount() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let target = Self.archived("skipped", ["102", nil, "missing", "101"], sequence: 1)
        let (store, _) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        let input = try #require(store.pendingHistoryImports.first)
        #expect(input.contentIDs == ["102", "101"])
        #expect(input.skippedBeforeMatching == 2)
    }

    /// 합성 rekordbox 사본에 쓰고 다시 읽는 저장소(라이브 스냅샷 대신 사본 DB를 그대로 읽는다). 아직 읽지 않았다
    static func newStore(_ fixture: RekordboxFixture) throws -> LibraryStore {
        try fixture.execute("UPDATE djmdContent SET MasterSongID = ID, FileNameL = 'history-' || ID || '.mp3', MasterDBID = (SELECT DBID FROM djmdProperty LIMIT 1) WHERE ID IN ('101', '102')")
        let store = LibraryStore(settings: SettingsStore(defaults: UserDefaults(suiteName: "djc.test.historywrite.\(UUID())")!, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        let database = fixture.database
        store.takeLiveSnapshot = { _ in database }
        store.launchArguments = ["test"]
        store.launchEnvironment = [:]
        store.draftHome = fixture.root.appending(path: "drafts")
        store.rekordboxDatabase = database
        store.rekordboxShareRoot = fixture.shareRoot
        // 쓰기 대기·쓰기 흐름을 보려고 관문을 연다(앱은 사본 재현 전이라 닫혀 있다, `closedGateKeepsQueueEmpty`)
        store.writesHistories = true
        return store
    }

    /// 사본을 읽고, 임시 폴더의 보존 저장소에 `archived`를 저장해 앱처럼 읽어 들인 저장소
    static func makeStore(_ fixture: RekordboxFixture, scratch: URL, archived: [ArchivedHistory]) async throws -> (LibraryStore, UsbHistoryStore) {
        let store = try newStore(fixture)
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        let historyStore = UsbHistoryStore(directory: scratch.appending(path: "usb-histories"), home: scratch.appending(path: "home"))
        try historyStore.save(archived)
        store.usbHistoryStore = historyStore
        store.loadArchivedHistories()
        return (store, historyStore)
    }

    /// 쓸 수 있는 합성 기록 사본: 곡 101·102를 아직 동기화하지 않은 곡(상태 0, 재생 횟수 0)으로 둔다
    /// (rekordbox 쓰기는 클라우드 동기화 곡이 든 기록을 막는다. `RekordboxWriter+History`)
    static func writableFixture() throws -> RekordboxFixture {
        let fixture = try historyFixture()
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0, DJPlayCount = 0 WHERE ID IN ('101', '102')")
        // 새 연 폴더 쓰기는 확인하지 않아 막혀 있다. 쓰기 흐름 시험은 이미 있는 2026년 아래에서 한다.
        try fixture.insert("djmdHistory", ["ID": .text("2026"), "Name": .text("2026"), "UUID": .text("2026"),
                                           "ParentID": .text("root"), "Attribute": .int(1), "Seq": .int(1), "rb_local_deleted": .int(0)])
        return fixture
    }

    /// 트리에 보이는 기록 ID(연·월 아래 + 날짜 없는 것)
    static func treeIDs(_ tree: HistoryTree) -> Set<String> {
        Set(tree.years.flatMap { $0.months.flatMap { $0.items.map(\.id) } } + tree.undated.map(\.id))
    }

    static func savedHistory(_ store: UsbHistoryStore, _ id: String) -> ArchivedHistory? {
        store.load().histories.first { $0.id == id }
    }

    // MARK: - 쓰기 대기

    @Test("최신 미리 보기·실제 쓰기 대상에서 곡 ID가 재사용돼도 원본 식별로 막는다")
    func validatesIdentityInLatestTarget() async throws {
        let fixture = try Self.writableFixture(), scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = Self.archived("identity", ["101"], sequence: 1)
        let (store, _) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        let input = store.pendingHistoryImports
        #expect(input.first?.trackIdentities.first?.contentID == "101" && input.first?.expectedLibraryID == "1")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '999', FileNameL = 'other.mp3', FolderPath = '/synthetic/other.mp3' WHERE ID = '101'")
        let before = try Data(contentsOf: fixture.database)
        let preview = try await store.previewWrite(rows: [], playlists: true)
        #expect(preview.report.historyBlocked.first?.reason?.contains("원본") == true)
        let report = try await store.writeToRekordbox([], histories: input, to: fixture.database, shareRoot: nil)
        #expect(report.historyBlocked.first?.reason?.contains("원본") == true && report.backup == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test("rekordbox가 먼저 가져온 기록을 최신 미리 보기에서 연결하고 쓰기 대기에서 뺀다")
    func linksHistoryAlreadyImportedInLatestTarget() async throws {
        let fixture = try Self.writableFixture(), scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = Self.archived("already", ["101"], sequence: 1)
        let (store, archiveStore) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try fixture.insert("djmdHistory", ["ID": .text("9876543"), "Name": .text(target.name), "DateCreated": .text(formatter.string(from: target.importedAt)),
                                          "Attribute": .int(0), "ParentID": .text("202609"), "Seq": .int(1), "rb_local_deleted": .int(0)])
        try fixture.insert("djmdSongHistory", ["ID": .text("already-entry"), "HistoryID": .text("9876543"), "ContentID": .text("101"),
                                              "TrackNo": .int(1), "rb_local_deleted": .int(0)])
        try fixture.execute("UPDATE djmdContent SET DJPlayCount = 7 WHERE ID = '101'")
        let before = try Data(contentsOf: fixture.database)
        let preview = try await store.previewWrite(rows: [], playlists: true)
        #expect(preview.report.historyOutcomes?.first?.status == .unchanged)
        #expect(store.pendingHistories.isEmpty)
        #expect(Self.savedHistory(archiveStore, target.id)?.rekordboxHistoryID == "9876543")
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test("라이브러리를 읽은 뒤에만 대기에 올리고, 숨긴 기록·뺀 기록·짝 없는 기록·rekordbox에 있는 쓴 기록은 빼며 사라진 쓴 기록은 다시 올린다")
    func pendingQueue() async throws {
        let fixture = try historyFixture()
        let store = try Self.newStore(fixture)
        let pending = Self.archived("pending", ["102", nil, "101"], sequence: 1)
        let noMatch = Self.archived("nomatch", [nil, nil], sequence: 2)
        let excluded = Self.archived("excluded", ["101"], sequence: 3, excluded: true)
        // rekordbox에 있는 기록("new-a")으로 쓴 것과, 쓴 뒤 rekordbox에서 사라진 것(복원 등)
        let written = Self.archived("written", ["102"], sequence: 4, written: "new-a")
        let restored = Self.archived("restored", ["102", "101"], sequence: 5, written: "gone")
        // 같은 곡이 두 번 든 기록은 rekordbox 쓰기가 늘 막아 대기에 두지 않는다
        let repeated = Self.archived("repeated", ["101", "102", "101"], sequence: 7)
        let shadowed = Self.archived("shadowed", ["101", "102"], sequence: 6, name: UsbHistoryAppTests.expectedName())
        store.archivedHistories = [repeated, shadowed, restored, written, excluded, noMatch, pending]
        // 읽기 전에는 rekordbox에 이미 쓴 기록인지 몰라 올리지 않는다
        #expect(store.pendingHistories.isEmpty && !store.hasHistoryDrafts)

        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        #expect(store.pendingHistories.map(\.id) == [pending.id, restored.id, shadowed.id])

        // rekordbox도 같은 USB 기록을 가져왔으면(짝 곡 순서가 같은 "HISTORY …" 기록) 숨기고 대기에서도 뺀다
        store.histories.append(RekordboxHistory(id: "rb-usb", name: UsbHistoryAppTests.expectedName(),
                                                dateCreated: String(UsbHistoryAppTests.expectedName().dropFirst(8)) + " 23:00:00",
                                                folderNames: ["2026", "9"], seq: 1, entries: [
                                                    .init(id: "rb-1", contentID: "101", trackNumber: 1),
                                                    .init(id: "rb-2", contentID: "102", trackNumber: 2),
                                                ]))
        #expect(store.shadowedArchiveIDs == [shadowed.id])
        #expect(store.pendingHistories.map(\.id) == [pending.id, restored.id])
        #expect(store.pendingHistoryIDs == [pending.id, restored.id])
        #expect(store.hasHistoryDrafts)
        // 사이드바 배지는 쓸 곡 수에 대기 기록 수를 더하고, 곡 초안이 없어도 rekordbox에 쓰기를 누를 수 있다
        #expect(store.pendingWriteCount == store.pendingLibraryCount + 2)
        #expect(LibraryMenuAction.reflect.isEnabled(in: store))

        // 쓰기 입력: 컬렉션 짝이 있는 곡만 재생 순서대로(반복 재생 포함), 이름·만든 시각은 보존본 그대로
        let imports = store.pendingHistoryImports
        #expect(imports.map(\.id) == [pending.id, restored.id])
        #expect(imports.map(\.contentIDs) == [["102", "101"], ["102", "101"]])
        #expect(imports.map(\.skippedBeforeMatching) == [1, 0])
        #expect(imports.first?.name == pending.name && imports.first?.dateCreated == pending.importedAt)
    }

    @Test("쓰기 대기에서 빼고 다시 넣으면 보존 파일에 저장하고, 편집 › 실행 취소·실행 복귀로 되돌린다")
    func excludeAndInclude() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let target = Self.archived("toggle", ["102", "101"], sequence: 1)
        let (store, saved) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        #expect(store.pendingHistoryIDs == [target.id])
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        store.setHistoriesExcluded([target.id], excluded: true)
        #expect(store.pendingHistories.isEmpty && !store.hasHistoryDrafts)
        #expect(store.archivedHistory(target.id)?.excludedFromRekordbox == true)
        #expect(undo.undoActionName == "rekordbox 쓰기 대기에서 빼기")
        await store.waitForHistoryImports()
        #expect(Self.savedHistory(saved, target.id)?.excludedFromRekordbox == true)
        // 보존본은 그대로 트리에 남는다
        #expect(Self.treeIDs(store.historyTree).contains(target.id))

        undo.undo()
        #expect(store.pendingHistoryIDs == [target.id])
        await store.waitForHistoryImports()
        #expect(Self.savedHistory(saved, target.id)?.excludedFromRekordbox == false)
        undo.redo()
        #expect(store.pendingHistories.isEmpty)
        await store.waitForHistoryImports()
        #expect(Self.savedHistory(saved, target.id)?.excludedFromRekordbox == true)

        // 뺀 기록의 "rekordbox 쓰기 대기에 넣기"
        store.setHistoriesExcluded([target.id], excluded: false)
        #expect(undo.undoActionName == "rekordbox 쓰기 대기에 넣기")
        #expect(store.pendingHistoryIDs == [target.id])
        await store.waitForHistoryImports()
        #expect(Self.savedHistory(saved, target.id)?.excludedFromRekordbox == false)

        // 쓰는 동안은 바꾸지 않는다
        store.isWritingRekordbox = true
        store.setHistoriesExcluded([target.id], excluded: true)
        #expect(store.pendingHistoryIDs == [target.id])
        store.isWritingRekordbox = false
        #expect(store.toast == nil)
    }

    @Test("쓴 기록 표시: 다시 읽기 전에도 대기에서 빠지고 파일에 남으며, 다시 읽은 rekordbox에 그 기록이 없으면 다시 대기다")
    func recordWritten() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let target = Self.archived("mark", ["102", "101"], sequence: 1)
        let (store, saved) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        let outcome = RekordboxWriter.HistoryOutcome(id: target.id, name: target.name, historyID: "rb-new", status: .written,
                                                     reason: nil, entries: 2, skipped: 0)
        #expect(await store.recordWrittenHistories([outcome]) == nil)
        #expect(store.archivedHistory(target.id)?.rekordboxHistoryID == "rb-new")
        #expect(store.pendingHistories.isEmpty)
        #expect(Self.savedHistory(saved, target.id)?.rekordboxHistoryID == "rb-new")
        #expect(store.archivedHistory(target.id)?.rekordboxLibraryID == "1")
        #expect(Self.savedHistory(saved, target.id)?.rekordboxLibraryID == "1")

        // 사본에는 그 기록이 없다(복원으로 사라진 것과 같다): 새로 읽으면 다시 쓰기 대기
        await store.load(snapshot: fixture.database, arguments: ["test"], environment: [:])
        #expect(store.pendingHistoryIDs == [target.id])

        // 표시를 저장하지 못하면 알릴 문장을 돌려주고, 이번 실행 동안은 쓴 것으로 둔다
        let folder = scratch.appending(path: "usb-histories")
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        let again = RekordboxWriter.HistoryOutcome(id: target.id, name: target.name, historyID: "rb-again", status: .written,
                                                   reason: nil, entries: 2, skipped: 0)
        #expect(await store.recordWrittenHistories([again]) == LibraryStore.historyMarkFailureText(1))
        #expect(store.archivedHistory(target.id)?.rekordboxHistoryID == "rb-again")
        #expect(store.pendingHistories.isEmpty)
        // 막힌 결과는 표시하지 않는다
        let blocked = RekordboxWriter.HistoryOutcome(id: target.id, name: target.name, historyID: nil, status: .blocked,
                                                     reason: "막힘", entries: 0, skipped: 0)
        #expect(await store.recordWrittenHistories([blocked]) == nil)
        #expect(store.archivedHistory(target.id)?.rekordboxHistoryID == "rb-again")
    }

    @Test("쓰기 대기 상태 저장의 rename 뒤 fsync가 실패해도 같은 파일의 상태를 유지하고 실패를 알린다")
    func archiveStateSaveSyncFailureKeepsCurrentState() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let target = Self.archived("toggle-fsync", ["102", "101"], sequence: 1)
        let (store, _) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        let fileSystem = FaultyUsbFileSystem(root: scratch)
        fileSystem.failAt = (.syncDirectory, 1, .error)
        let saved = UsbHistoryStore(directory: scratch.appending(path: "usb-histories"), home: scratch, fileSystem: fileSystem)
        store.usbHistoryStore = saved
        store.setHistoriesExcluded([target.id], excluded: true)
        await store.waitForHistoryImports()
        try #require(await waitUntil(timeout: .seconds(5)) { store.toast?.kind == .warning })
        let current = try #require(store.archivedHistory(target.id))
        #expect(current.excludedFromRekordbox && store.pendingHistories.isEmpty)
        #expect(saved.containsExact(current))
        #expect(saved.load().histories.map(\.id) == [target.id])
        #expect(store.toast?.title == "재생 기록의 쓰기 대기 상태를 저장하지 못했습니다")
    }

    // MARK: - 반영 흐름(가짜 저장소)

    static func historyOutcome(_ key: String, _ status: RekordboxWriter.HistoryOutcome.Status, reason: String? = nil,
                               entries: Int = 2, skipped: Int = 0) -> RekordboxWriter.HistoryOutcome {
        RekordboxWriter.HistoryOutcome(id: ArchivedHistory.idPrefix + key, name: "HISTORY \(key)",
                                       historyID: status == .written ? "rb-\(key)" : nil, status: status, reason: reason,
                                       entries: status == .written ? entries : 0, skipped: skipped)
    }

    static func historyPreview(_ outcomes: [RekordboxWriter.HistoryOutcome],
                               cues: [RekordboxWriter.Outcome] = []) -> LibraryStore.WritePreview {
        var preview = ReflectionCoordinatorTests.preview(cues: cues)
        preview.report.historyOutcomes = outcomes
        preview.histories = outcomes.map { HistoryImport(id: $0.id, name: $0.name, dateCreated: now, contentIDs: ["1", "2"]) }
        return preview
    }

    @Test("곡 초안이 없어도 쓰기 대기 재생 기록만 묻지 않고 쓰고, 결과에 기록마다 한 줄을 남긴다")
    func writesHistoriesOnly() async {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.targets = []
        host.hasHistoryDrafts = true
        host.preview = .success(Self.historyPreview([Self.historyOutcome("a", .written)]))
        await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false }).write(rows: [])
        #expect(host.previewedPlaylists == true)
        #expect(prompter.shown.isEmpty)
        #expect(host.wroteHistories == [ArchivedHistory.idPrefix + "a"])
        #expect(host.toast?.title == "rekordbox에 썼습니다 · 재생 기록 1건" && host.toast?.kind == .success)
        #expect(host.resultHistory.latest?.text == "• HISTORY a — 재생 기록 쓰기 완료: 2곡")
        #expect(host.locks == [true, false])
    }

    @Test("막힌 재생 기록(쓰기 관문 닫힘 등)이 있으면 확인 창에 이유를 보이고, 쓸 수 있는 것만 쓴다")
    func blockedHistoryAsks() async throws {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.preview = .success(Self.historyPreview([Self.historyOutcome("b", .blocked, reason: "재생 기록 쓰기를 아직 열지 않았습니다")],
                                                    cues: [ReflectionCoordinatorTests.outcome("x", .written)]))
        host.hasHistoryDrafts = true
        await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
            .write(rows: [ReflectionCoordinatorTests.row("x")])
        let prompt = try #require(prompter.shown.first)
        #expect(prompt.title == "큐 1곡을 rekordbox에 쓸까요?")
        #expect(prompt.details == ["쓰지 않는 것 1:", "• HISTORY b: 재생 기록 쓰기를 아직 열지 않았습니다"])
        #expect(host.wrote?.drafts == ["x"] && host.wroteHistories == [])
        #expect(host.toast?.kind == .warning)
        #expect(host.toast?.detail == "재생 기록 1건은 쓰지 않았습니다 — 재생 기록 쓰기를 아직 열지 않았습니다")
        // 함께 쓸 수 있으면 제목에 함께 센다
        var both = Self.historyPreview([Self.historyOutcome("a", .written)], cues: [ReflectionCoordinatorTests.outcome("x", .written)])
        both.report.historyOutcomes?.append(Self.historyOutcome("b", .blocked, reason: "이유"))
        #expect(ReflectionCoordinator.confirmation(both.report).title == "큐 1곡 · 재생 기록 1건을 rekordbox에 쓸까요?")
    }

    @Test("재생 기록이 모두 막히면 창 없이 결과 토스트로 이유를 남기고 쓰지 않는다")
    func allBlockedNoPrompt() async {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.targets = []
        host.hasHistoryDrafts = true
        host.preview = .success(Self.historyPreview([Self.historyOutcome("b", .blocked, reason: "닫힘")]))
        await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false }).write(rows: [])
        #expect(prompter.shown.isEmpty && host.wrote == nil)
        #expect(host.toast?.title == "rekordbox에 쓴 것이 없습니다" && host.toast?.kind == .warning)
        #expect(host.resultHistory.latest?.text == "• HISTORY b — 재생 기록 쓰지 않음: 닫힘")
    }

    @Test("곡을 골라 쓰는 메뉴(곡 초안만)는 재생 기록을 넣지 않는다")
    func selectedTracksSkipHistories() async {
        let host = FakeReflectionHost(), prompter = ScriptedPrompter()
        host.targets = []
        host.hasHistoryDrafts = true
        await ReflectionCoordinator(host: host, prompter: prompter, isRekordboxRunning: { false })
            .write(rows: [ReflectionCoordinatorTests.row("a")], playlists: false)
        #expect(host.toast?.title == "쓸 초안이 없습니다" && host.previewedPlaylists == nil)
    }

    @Test("결과: 실제로 쓴 기록과 미리 보기에서 막힌 기록을 합치고, 컬렉션에 없어 뺀 곡을 적는다")
    func resultLines() {
        var preview = RekordboxWriter.Report(outcomes: [], backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        preview.historyOutcomes = [Self.historyOutcome("a", .written), Self.historyOutcome("b", .blocked, reason: "이유")]
        var report = RekordboxWriter.Report(outcomes: [], backup: "/tmp/b", dryRun: false, createdAt: "", finalUpdateCount: 1)
        report.historyOutcomes = [Self.historyOutcome("a", .written, entries: 2, skipped: 1)]
        let result = WriteResult.written(report, preview: preview)
        #expect(result.kind == .warning && result.title == "rekordbox에 썼습니다 · 재생 기록 1건")
        #expect(result.text.components(separatedBy: "\n") == [
            "• HISTORY a — 재생 기록 쓰기 완료: 2곡 · 컬렉션에 없는 1곡은 뺐습니다",
            "• HISTORY b — 재생 기록 쓰지 않음: 이유",
        ])
        #expect(result.shortfall == "재생 기록 1건은 쓰지 않았습니다 — 이유")
    }

    // MARK: - 합성 사본에 쓰기

    @Test("관문이 닫혀 있으면 보존·보기만 하고 쓰기 대기에 올리지 않아, rekordbox에 쓰기가 기록을 묻거나 쓰지 않는다")
    func closedGateKeepsQueueEmpty() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try Self.writableFixture()
        let target = Self.archived("closed", ["102", "101"], sequence: 1, name: "HISTORY 2026-09-22")
        let (store, saved) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        #expect(store.pendingHistoryIDs == [target.id])
        store.writesHistories = false
        #expect(store.pendingHistories.isEmpty && store.pendingHistoryIDs.isEmpty && !store.hasHistoryDrafts)
        #expect(store.archivedHistories.map(\.id) == [target.id])
        let histories = try fixture.rows("SELECT ID FROM djmdHistory ORDER BY ID")
        let songs = try fixture.rows("SELECT ID FROM djmdSongHistory ORDER BY ID")
        let counter = try fixture.localUpdateCount()

        let prompter = ScriptedPrompter()
        await ReflectionCoordinator(host: store, prompter: prompter, isRekordboxRunning: { false }).write(rows: [])
        #expect(prompter.shown.isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdHistory ORDER BY ID") == histories)
        #expect(try fixture.rows("SELECT ID FROM djmdSongHistory ORDER BY ID") == songs)
        #expect(try fixture.localUpdateCount() == counter)
        #expect(Self.savedHistory(saved, target.id)?.rekordboxHistoryID == nil)
        #expect(!store.isWritingRekordbox)
        // 관문을 열면(사본 재현 뒤) 보존해 둔 기록이 대기에 오른다
        store.writesHistories = true
        #expect(store.pendingHistoryIDs == [target.id])
    }

    @Test("관문을 열면 사본에 쓰고 기록·라이브러리 ID와 제외 수를 남기며, 짝 없는 항목이 든 보존본은 계속 보인다. 복원하면 다시 대기다",
          .enabled(if: LiveDraftHome.isIsolated))
    func writesAndRestores() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try Self.writableFixture()
        let target = Self.archived("write", ["102", nil, "101"], sequence: 1, name: "HISTORY 2026-09-21")
        let (store, saved) = try await Self.makeStore(fixture, scratch: scratch, archived: [target])
        store.writesHistories = true
        #expect(store.pendingHistoryIDs == [target.id])
        let plays = (store.rowsByID["101"]?.playCount ?? 0, store.rowsByID["102"]?.playCount ?? 0)
        let preview = try await store.previewWrite(rows: [], playlists: true)
        #expect(preview.report.historyWritten.first?.skipped == 1)

        let prompter = ScriptedPrompter()
        await ReflectionCoordinator(host: store, prompter: prompter, isRekordboxRunning: { false }).write(rows: [])
        // 막힘·제외·손실이 없으니 묻지 않고 쓴다(#210)
        #expect(prompter.shown.isEmpty)
        let result = try #require(store.resultHistory.latest)
        #expect(result.title == "rekordbox에 썼습니다 · 재생 기록 1건")
        #expect(result.text.hasPrefix("• \(target.name) — 재생 기록 쓰기 완료: "))
        #expect(result.text.contains("컬렉션에 없는 1곡은 뺐습니다"))
        #expect(store.toast?.undoBackup != nil)

        // 보존본(화면·파일)에 rekordbox 기록 ID를 남겼다
        let historyID = try #require(store.archivedHistory(target.id)?.rekordboxHistoryID)
        #expect(Self.savedHistory(saved, target.id)?.rekordboxHistoryID == historyID)
        #expect(Self.savedHistory(saved, target.id)?.rekordboxLibraryID == "1")
        // 다시 읽은 rekordbox 기록에는 짝 있는 곡만 있다. 짝 없는 곡이 든 보존본은 보이고 쓴 표시는 중복 쓰기를 막는다.
        let written = try #require(store.historyIndex[historyID])
        #expect(written.name == target.name)
        #expect(written.entries.sorted { $0.trackNumber < $1.trackNumber }.map(\.contentID) == ["102", "101"])
        #expect(Self.treeIDs(store.historyTree).contains(historyID))
        #expect(store.shadowedArchiveIDs.isEmpty && Self.treeIDs(store.historyTree).contains(target.id))
        #expect(store.pendingHistories.isEmpty && store.pendingWriteCount == store.pendingLibraryCount)
        // 그 기록의 곡은 rekordbox처럼 재생 횟수(DJPlayCount)가 1 늘고, 재생 기록 줄도 하나씩 늘었다(목록의 재생 횟수)
        let counts = try fixture.rows("SELECT ID, DJPlayCount FROM djmdContent WHERE ID IN ('101', '102') ORDER BY ID")
        #expect(counts.map { $0["DJPlayCount"] } == ["1", "1"])
        #expect(store.rowsByID["101"]?.playCount == plays.0 + 1)
        #expect(store.rowsByID["102"]?.playCount == plays.1 + 1)

        // 쓰기 전으로 복원하면 rekordbox에서 그 기록이 사라져 보존본이 다시 보이고 쓰기 대기에 오른다(따로 할 일 없음)
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first { $0.isWrite })
        #expect(WriteResult.restored(backup, saved: backup.url).text.contains("• \(target.name)"))
        try await store.restoreRekordbox(backup, keepingCurrentDrafts: true)
        #expect(store.historyIndex[historyID] == nil)
        #expect(try fixture.rows("SELECT ID FROM djmdHistory WHERE ID = ?", [.text(historyID)]).isEmpty)
        #expect(store.shadowedArchiveIDs.isEmpty && Self.treeIDs(store.historyTree).contains(target.id))
        #expect(store.pendingHistoryIDs == [target.id])
    }
}
