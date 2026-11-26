@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 동기화 창이 읽는 것(로컬 목록·USB·선택 파일)을 가짜로 채워 실제 읽기 순서(`UsbSync.load`)를 지난 화면 모델.
/// 선택 파일 행으로 이은 목록이 있어야 "동기화 후" 보기에 지울 목록이 생긴다. 화면 모델의 연결 시험 하나(TEST-8)이고
/// 계획 규칙은 `DJCApplicationTests`의 `UsbSyncPlanTests`가 본다.
@Suite("USB 동기화 후 보기의 지울 목록")
@MainActor
struct UsbSyncDeletedPreviewTests {
    /// 동기화가 부르는 것(지금 볼륨·DB 지문·관문·rekordbox 실행)만 답한다. 쓰기는 모두 거부한다.
    private struct Service: UsbWriting {
        func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo { volume }
        func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint {
            UsbFingerprint(files: ["exportLibrary.db": .init(size: 1, mtime: Date(timeIntervalSince1970: 0), sha256: "a")])
        }
        func isRekordboxRunning() -> Bool { false }
        var syncGate: UsbSyncSelectionGate { UsbSyncSelectionGate(gateBlock: { _, _ in nil }, productionBlock: { nil }, draftBlock: { _ in nil }) }
        func isScratchMount(_ mountPoint: String) -> Bool { true }
        func journal(volumeKey: String) -> UsbJournalInfo { .none }
        func preview(_ input: UsbExportInput) throws -> UsbExportSummary { throw UsbError.cancelled }
        func write(_ input: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport { throw UsbError.cancelled }
        func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary { throw UsbError.cancelled }
        func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                            isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten { throw UsbError.cancelled }
        func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport { throw UsbError.cancelled }
        func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport { throw UsbError.cancelled }
        func latestBackup(volumeKey: String) -> URL? { nil }
        func previewEdit(_ input: UsbEditInput) throws -> UsbEditSummary { throw UsbError.cancelled }
        func writeEdit(_ input: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                       isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten { throw UsbError.cancelled }
        func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                               rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan { throw UsbError.cancelled }
    }

    private static func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false,
                             seq: Int) -> (item: PlaylistLayout.Item, seq: Int) {
        (PlaylistLayout.Item(id: id, name: name, parentID: parent, isFolder: folder), seq)
    }

    /// 원본: 공연(오프닝·피크 타임·클로징)·워밍업·새 목록. USB: 공연(2·3·4)·워밍업(7)·옛 목록(8, 이은 적 없음).
    /// 선택 파일 행은 공연 폴더와 그 안 목록, 워밍업을 이었고 선택은 공연 폴더 전체와 워밍업이다.
    private func loadedModel() async throws -> UsbSyncModel {
        let layout = PlaylistLayout([
            Self.item("1001", "공연", folder: true, seq: 0), Self.item("1002", "오프닝", parent: "1001", seq: 0),
            Self.item("1003", "피크 타임", parent: "1001", seq: 1), Self.item("1004", "클로징", parent: "1001", seq: 2),
            Self.item("1008", "워밍업", seq: 1), Self.item("1009", "새 목록", seq: 2),
        ])
        let source = UsbSyncSource(layout: layout, rekordbox: layout, iTunes: PlaylistLayout([]), notices: [:], iTunesStatus: .ready)
        func list(_ id: Int, _ name: String, parent: Int = 0, folder: Bool = false, order: Int) -> UsbPlaylist {
            UsbPlaylist(id: id, name: name, parentID: parent, attribute: folder ? 1 : 0, presentIn: UsbFormat.defaultSet,
                        sortOrder: [.oneLibrary: order, .deviceLibrary: order])
        }
        var library = UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000"))
        library.playlists = [list(1, "공연", folder: true, order: 0), list(2, "오프닝", parent: 1, order: 0),
                             list(3, "피크 타임", parent: 1, order: 1), list(4, "클로징", parent: 1, order: 2),
                             list(7, "워밍업", order: 1), list(8, "옛 목록", order: 2)]
        let volume = FakeUsbVolume.diskImageFAT32()
        let snapshot = URL(filePath: "/private/tmp/djc-sync-deleted/snapshot.db")
        let provenance = UsbSyncSnapshotProvenance(sourceURL: snapshot, snapshotTime: "2026-11-12T00:00:00Z",
                                                   fingerprint: .init(device: 1, inode: 2, size: 3, modified: Date(timeIntervalSince1970: 0),
                                                                      digest: Data([1])))
        let resolution = UsbSyncSelectionResolution(
            selection: ITunesSyncSelection(selectedIDs: ["1001", "1008"]), enabled: true,
            playlistIDs: ["1001": 1, "1002": 2, "1003": 3, "1004": 4, "1008": 7], formatPlaylistIDs: [:],
            removedSourcePlaylistIDs: [], issues: [])
        let files = UsbSyncFiles(
            selection: { _, _ in UsbSyncNativeSelection(baseFiles: [.oneLibrary: Data("sync".utf8)], semanticFingerprint: "native-1") { _, _, _, _ in resolution } },
            masterNodes: { _ in [] },
            preferences: { _ in UsbSyncPreferencesFiles(load: { _ in nil }, save: { _ in }) })
        let ports = UsbSyncPorts(
            library: { UsbSyncLibraryState(snapshot: snapshot, revision: 1, readEpoch: 1, provenance: provenance,
                                           share: URL(filePath: "/private/tmp/djc-sync-deleted/share"), isLoading: false,
                                           isWriting: false, allowsInteraction: true) },
            sources: { source },
            leaseSnapshot: { UsbSyncSnapshotLease(database: snapshot, provenance: provenance, id: UUID(), release: {}) },
            localSkip: { _ in nil },
            volume: { UsbSyncVolumeState(volume: volume, library: library, isEmptyExportable: false, isWriting: false, isEjecting: false,
                                         draftEdits: []) },
            refreshUsb: {},
            service: Service(), files: files,
            localKeys: LocalLibraryKeysSource { _ in LocalLibraryKeys(localDBID: 42, tracks: [], counters: [:]) },
            preferences: nil,
            confirmation: UserConfirmation(confirm: { _ in false }, choose: { _ in .cancel }),
            drafts: nil, writer: nil,
            importCueGrid: { UsbCueGridImportSummary(cueCount: 0, gridCount: 0) },
            newPlaylistKey: { "never" },
            log: { _ in })
        let model = UsbSyncModel(volumeKey: volume.usbKey, library: library)
        await model.session.load(ports)
        try #require(model.error == nil && !model.isLoading)
        return model
    }

    @Test("선택에서 뺀 이은 목록은 동기화 후 보기의 원래 자리에 지움으로 남고 흐리게 보인다")
    func deselectedLinkedListsStayInPlaceAsDeleted() async throws {
        let model = try await loadedModel()
        // 처음 선택은 선택 파일 그대로라 바뀌는 것이 없다
        #expect(model.selection.selectedIDs == ["1001", "1008"])
        model.toggle("1004")   // 공연 안 클로징을 뺀다 → 공연 폴더는 일부 선택이 된다
        model.toggle("1008")   // 워밍업을 뺀다
        model.toggle("1009")   // 새 목록을 더한다
        model.targetDisplay = .afterSync

        let tree = model.targetTree
        #expect(tree.map(\.name) == ["공연", "워밍업", "옛 목록", "새 목록"])
        #expect(tree.first?.children?.map(\.name) == ["오프닝", "피크 타임", "클로징"])
        // 지울 클로징(4)·워밍업(7), 이은 적 없는 옛 목록(8)은 흐리고 나머지는 그대로다
        #expect(model.targetMarks["4"] == .deleted && model.targetMarks["7"] == .deleted && model.targetMarks["8"] == .unlinked)
        #expect(model.dimmedTargetIDs == ["4", "7", "8"])
        #expect(model.targetMarks.values.filter { $0 == .created }.count == 1)

        let style = model.targetRowStyle
        func flat(_ nodes: [PlaylistOutlineNode]) -> [PlaylistOutlineNode] { nodes.flatMap { [$0] + flat($0.children ?? []) } }
        let byName = Dictionary(uniqueKeysWithValues: flat(tree).map { ($0.name, $0) })
        let closing = try #require(byName["클로징"]), warmUp = try #require(byName["워밍업"]), fresh = try #require(byName["새 목록"])
        let show = try #require(byName["공연"]), old = try #require(byName["옛 목록"])
        #expect(style.note(of: closing) == "지움" && style.hint(of: closing) == UsbSyncPreviewMark.deleted.hint)
        #expect(style.note(of: warmUp) == "지움")
        #expect(style.note(of: fresh) == "새로 만듦" && style.hint(of: fresh) == nil)
        #expect(style.note(of: show) == "하위 1건 변경")
        #expect(style.note(of: old) == nil && style.hint(of: old) == UsbSyncPreviewMark.unlinked.hint)

        // 현재 USB 보기는 지금 USB 그대로이고 지움 표시가 없다
        model.targetDisplay = .currentUsb
        #expect(model.targetTree.map(\.name) == ["공연", "워밍업", "옛 목록"] && !model.targetMarks.values.contains(.deleted))
    }

    @Test("모든 선택을 해제하면 이은 목록이 모두 지움으로 남고 이은 적 없는 목록만 흐리게 남는다")
    func clearingEverythingMarksAllLinkedListsDeleted() async throws {
        let model = try await loadedModel()
        model.clearSelection()
        model.targetDisplay = .afterSync
        #expect(model.targetTree.map(\.name) == ["공연", "워밍업", "옛 목록"])
        // 폴더 공연은 안 목록까지 모두 지우니 폴더 하나가 지움이고 안쪽 줄도 지움이다
        #expect(model.targetMarks["1"] == .deleted && model.targetMarks["2"] == .deleted && model.targetMarks["4"] == .deleted)
        #expect(model.targetMarks["7"] == .deleted && model.targetMarks["8"] == .unlinked)
        #expect(model.targetEmptyMessage == "동기화할 목록을 선택하세요" && !model.targetTree.isEmpty)
    }
}
