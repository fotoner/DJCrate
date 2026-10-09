@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

extension UsbTestData {
    /// 수정 미리 보기 요약(지어낸 값)
    static func editSummary(editCount: Int = 3, outcomes: [Int: UsbEditSummary.Outcome]? = nil, stopping: [String] = [],
                            skipped: [UsbEditSummary.Count] = [], formats: [UsbEditSummary.FormatResult]? = nil, removals: Int = 0,
                            deferred: [String] = [], notes: [String] = [], rules: [UsbProvisionalRule] = [], hasChanges: Bool = true,
                            testVolume: Bool = true, formatDrift: Bool = false) -> UsbEditSummary {
        UsbEditSummary(editCount: editCount, outcomes: outcomes ?? Dictionary(uniqueKeysWithValues: (1...max(editCount, 1)).map { ($0, .written) }),
                       stopping: stopping, skipped: skipped,
                       formats: formats ?? [.init(format: .oneLibrary, written: true, blocked: nil), .init(format: .deviceLibrary, written: true, blocked: nil)],
                       removals: removals, deferred: deferred, notes: notes, warnings: [], rules: rules, hasChanges: hasChanges,
                       isTestVolume: testVolume, formatDrift: formatDrift)
    }
}

@MainActor
@Suite("USB 쓰기 대기(UsbPendingView)")
struct UsbPendingTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let prompter = ScriptedPrompter()
    let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-usbpending-\(UUID().uuidString)")

    var key: String { image.usbKey }

    func cleanUp() { try? FileManager.default.removeItem(at: drafts) }

    @Test("대기 목록은 편집마다 설명과 막힘(미리 판정·미리 보기 결과)을 보이고, USB 전체 막힘이면 쓰기를 막는다")
    func pendingListShowsEditsAndBlocks() throws {
        let library = UsbEditTestData.mixedLibrary()
        let edits: [UsbLibraryEdit] = [
            .addTracks(localContentIDs: ["11", "12"], playlist: .id("10")),
            .removeTracks(usbContentIDs: [2]),
            .playlist(edit: .addTracks(playlist: .id("4"), contentIDs: ["1"])),
            .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .id("5"))),
            .playlist(edit: .rename(playlist: .new("k1"), name: "또 새 이름")),
            .playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 2, contentID: "1")])),
            .refreshTracks(usbContentIDs: [1, 3], parts: [.info]),
            .playlist(edit: .reorder(playlist: .id("10"), index: 1)),
            .playlist(edit: .delete(playlist: .id("5"))),
        ]
        let blockReason: (UsbLibraryEdit) -> String? = {
            UsbEditRules.blockReason($0, volume: image, library: library, info: nil, isScratchMount: { _ in true }, syncGate: .live)
        }
        let waiting = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: nil, busy: false,
                                      blockReason: blockReason)
        // 편집 설명은 `UsbEditText.describe`(같은 초안에서 만든 목록은 그 이름으로)
        #expect(waiting.rows.map(\.text) == edits.map { UsbEditText.describe($0, library: library, created: ["k1": "새 목록"]) })
        #expect(waiting.rows.map(\.id) == Array(1...9))
        let differ = UsbEditRules.Reason.entriesDiffer
        // 미리 보기 전: 막힐 편집만 이유를 단다
        #expect(waiting.rows[2].status == .expectedBlock(differ))
        #expect(waiting.rows.filter { $0.status != .waiting }.count == 1)
        #expect(waiting.canWrite)
        #expect(waiting.canPreview)
        #expect(waiting.summaryLines.isEmpty)

        // 미리 보기 뒤: 편집별 결과, 빼고 쓰는 곡·형식별 결과·지울 파일·미룸
        var outcomes = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, UsbEditSummary.Outcome.written) })
        outcomes[3] = .blocked(differ)
        outcomes[8] = .unchanged
        outcomes[2] = .deferred("Device Library가 막혀 파일 지우기를 미뤘습니다")
        let summary = UsbTestData.editSummary(editCount: 9, outcomes: outcomes,
                                              skipped: [.init(message: "rekordbox 분석이 스냅샷 뒤에 바뀌었습니다. 새 스냅샷을 뜬 뒤 다시 시도하세요", count: 1)],
                                              formats: [.init(format: .oneLibrary, written: true, blocked: nil),
                                                        .init(format: .deviceLibrary, written: false, blocked: "CDJ가 쓴 기록·목록이 있어 Device Library는 아직 고칠 수 없습니다")],
                                              removals: 4, deferred: ["Device Library가 막혀 파일 지우기를 미뤘습니다"],
                                              notes: ["USB가 그 사이 바뀌어 다시 계획했습니다"], formatDrift: true)
        let previewed = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: summary, busy: false,
                                        blockReason: blockReason)
        #expect(previewed.rows[0].status == .written)
        #expect(previewed.rows[1].status == .deferred("Device Library가 막혀 파일 지우기를 미뤘습니다"))
        #expect(previewed.rows[2].status == .blocked(differ))
        #expect(previewed.rows[7].status == .unchanged)
        // 요약: 편집 수 한 줄 + 수정 요약 줄(막힌 편집은 줄마다 보이므로 뺀다)
        #expect(summary.writtenCount == 7 && summary.blockedCount == 1 && summary.unchangedCount == 1)
        #expect(Array(previewed.summaryLines.dropFirst()) == UsbWriteFlow.editLines(summary, blockedEdits: false))
        // 미룬 까닭은 알림에 한 번만, 다시 계획한 알림은 그대로
        let lines = UsbWriteFlow.editLines(summary, blockedEdits: false)
        #expect(lines.filter { $0.contains(summary.deferred[0]) }.count == 1)
        #expect(lines.contains(summary.notes[0]))
        #expect(previewed.canWrite)

        // USB 전체 막힘: 쓰기를 막고 이유를 보인다
        let stopped = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library,
                                      summary: UsbTestData.editSummary(editCount: 9, stopping: [UsbEditRules.Reason.trackIDsDiffer],
                                                                       hasChanges: false),
                                      busy: false, blockReason: blockReason)
        #expect(!stopped.canWrite)
        #expect(stopped.writeHelp == UsbEditRules.Reason.trackIDsDiffer)
        // 쓰는 중·빈 초안
        let busy = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library, summary: nil, busy: true,
                                   blockReason: blockReason)
        #expect(!busy.canWrite && !busy.canPreview)
        let empty = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: [], library: library, summary: nil, busy: false,
                                    blockReason: blockReason)
        #expect(!empty.canWrite && !empty.canPreview)
        // 미리 본 결과 쓸 것이 없으면 누르기 전에 막고 이유를 도움말로 보인다(#230)
        let unchanged = UsbPendingModel(volumeName: "B13T", isConnected: true, edits: edits, library: library,
                                        summary: UsbTestData.editSummary(editCount: 9, outcomes: [1: .unchanged], hasChanges: false),
                                        busy: false, blockReason: blockReason)
        #expect(!unchanged.canWrite && unchanged.canPreview)
        #expect(unchanged.writeHelp != waiting.writeHelp)
    }

    @Test("USB에 쓰기…는 코디네이터 흐름(미리 보기 → 확인 → 쓰기 → 토스트)을 타고, 쓴 뒤 초안 수를 다시 읽는다")
    func writeDraftUsesCoordinator() async throws {
        defer { cleanUp() }
        let usbHost = FakeUsbHost([image])
        usbHost.serve(image, library: UsbTestData.library())
        let usb = UsbTestData.store(usbHost, service: service)
        usb.drafts = .live(directory: drafts)
        await usb.refresh()
        let actions = UsbEditActions(usb: usb, host: host, prompter: prompter, namePrompter: ScriptedNamePrompter())
        await actions.append(.removeTracks(usbContentIDs: [2]), to: key)
        await actions.append(.playlist(edit: .rename(playlist: .id("10"), name: "새 이름")), to: key)
        await actions.append(.playlist(edit: .addTracks(playlist: .id("10"), contentIDs: ["9"])), to: key)
        #expect(usb.draftCounts[key] == 3)

        var outcomes: [Int: UsbEditSummary.Outcome] = [1: .written, 2: .written, 3: .blocked(UsbEditRules.Reason.missingTarget)]
        let summary = UsbTestData.editSummary(editCount: 3, outcomes: outcomes, removals: 3, rules: [.editRemoveTracks])
        let drafts = drafts, key = key
        service.update {
            $0.editSummary = summary
            $0.drafts = drafts
            // 실제 세션처럼 막힌 편집만 초안에 남긴다
            $0.onWriteEdit = {
                let store = UsbDraftStore(directory: drafts)
                if var draft = try? store.load(volumeKey: key), draft.edits.count == 3 {
                    draft.edits = [draft.edits[2]]
                    try? store.save(draft)
                }
            }
            $0.editWriteProgress = [UsbProgress(phase: .files, completedItems: 1, totalItems: 2, cancellable: true)]
        }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        let database = URL(filePath: "/tmp/djc-fixture/m.db"), share = URL(filePath: "/tmp/djc-fixture/share")

        // 확인 창에서 취소하면 쓰지 않는다
        prompter.answer = false
        await coordinator.writeDraft(volumeKey: key, database: database, share: share, snapshotTime: "2026-01-01T00:00:00Z")
        #expect(service.current.previewed && !service.current.wrote)
        // 미리 본 요약으로 만든 확인 창(막힌 편집·지울 파일·확인 안 된 항목 줄은 `editLines`가 정한다)
        var previewedSummary = summary
        previewedSummary.edits = try #require(try UsbDraftStore(directory: drafts).load(volumeKey: key)).edits
        #expect(prompter.shown.last == UsbWriteFlow.editConfirmation(previewedSummary, volume: image))
        #expect(service.current.editJobs.last?.database == database)
        #expect(service.current.editJobs.last?.share == share)
        #expect(service.current.editJobs.last?.snapshotTime == "2026-01-01T00:00:00Z")
        #expect(service.current.editJobs.last?.volume == image)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)

        // 확인하면 쓰고, 끝나면 토스트([꺼내기])와 남은 초안 수
        prompter.answer = true
        service.update { $0.calls = [] }
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(service.current.previewedBeforeWrite)
        #expect(host.toast?.title == UsbWriteFlow.Text.editWrittenTitle(count: 2))
        #expect(host.toast?.detail?.hasPrefix(image.name) == true)
        #expect(host.toast?.action == .ejectUsb(volumeKey: key))
        #expect(usb.draftCounts[key] == 1)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)

        // 대기 목록에서 방금 본 미리 보기(지금 초안의 편집을 계획한 것)는 다시 보지 않는다
        var reused = summary
        reused.edits = try #require(try UsbDraftStore(directory: drafts).load(volumeKey: key)).edits
        service.update { $0.calls = [] }
        await coordinator.writeDraft(volumeKey: key, database: database, share: share, reusing: reused)
        #expect(service.current.wrote && !service.current.previewed)

        // USB 전체 막힘이면 쓰지 않고 이유를 알린다
        outcomes = [1: .blocked("x")]
        service.update {
            $0.editSummary = UsbTestData.editSummary(editCount: 1, outcomes: outcomes, stopping: [UsbEditRules.Reason.trackIDsDiffer], hasChanges: false)
            $0.calls = []
        }
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(service.current.previewed && !service.current.wrote)
        #expect(prompter.shown.last?.title == UsbWriteFlow.Text.cannotWriteTitle)
        #expect(prompter.shown.last?.text == UsbEditRules.Reason.trackIDsDiffer)

        // 쓸 것이 없으면(모두 막힘·바꿀 것 없음) 쓰지 않고 알린다
        service.update {
            $0.editSummary = UsbTestData.editSummary(editCount: 1, outcomes: [1: .unchanged], hasChanges: false)
            $0.calls = []
        }
        await coordinator.writeDraft(volumeKey: key, database: database, share: share)
        #expect(!service.current.wrote)
        #expect(host.toast?.title == UsbWriteFlow.Text.nothingToWriteTitle && host.toast?.kind == .warning)

        // rekordbox가 켜져 있으면 미리 보기도 하지 않는다
        service.update { $0.calls = [] }
        let running = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { true })
        await running.writeDraft(volumeKey: key, database: database, share: share)
        #expect(await running.previewDraft(volumeKey: key, database: database, share: share) == nil)
        #expect(service.current.calls.isEmpty)
    }
}
