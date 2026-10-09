import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization

/// 동기화 창 시험의 USB 쓰기 창구 가짜: 동기화가 부르는 것(지금 볼륨·DB 지문·관문·rekordbox 실행)만 답한다. 쓰기는 `UsbSyncWorld.writer`가 받는다.
final class SyncFakeService: UsbWriting, Sendable {
    struct State {
        var rekordboxRunning = false
        var base = UsbFingerprint(files: ["exportLibrary.db": .init(size: 1, mtime: Date(timeIntervalSince1970: 0), sha256: "a")])
        var gateBlock: UsbBlock?
        var volumeError: UsbError?
    }
    let state = Mutex(State())

    func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo {
        if let error = state.withLock({ $0.volumeError }) { throw error }
        return volume
    }
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint { state.withLock { $0.base } }
    func isRekordboxRunning() -> Bool { state.withLock { $0.rekordboxRunning } }
    var syncGate: UsbSyncSelectionGate {
        let block = state.withLock { $0.gateBlock }
        return UsbSyncSelectionGate(gateBlock: { _, _ in block }, productionBlock: { nil }, draftBlock: { _ in nil })
    }
    func isScratchMount(_ mountPoint: String) -> Bool { true }

    // 동기화 창이 부르지 않는 것
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

/// 동기화 창이 보는 세상(라이브러리 화면·USB 화면·파일·창·쓰기 흐름)의 가짜. 시험이 상태를 바꾸고, 부른 것을 차례로 적는다.
@MainActor
final class UsbSyncWorld {
    nonisolated static let snapshot = URL(filePath: "/private/tmp/djc-sync/snapshot.db")
    nonisolated static let copy = URL(filePath: "/private/tmp/djc-sync/copies/1/snapshot.db")
    nonisolated static let share = URL(filePath: "/private/tmp/djc-sync/share")
    nonisolated static let localDBID: Int64 = 42
    nonisolated static let provenance = UsbSyncSnapshotProvenance(sourceURL: snapshot, snapshotTime: "2026-10-09T00:00:00Z",
                                                      fingerprint: .init(device: 1, inode: 2, size: 3, modified: Date(timeIntervalSince1970: 0),
                                                                         digest: Data([1])))

    var library = UsbSyncLibraryState(snapshot: snapshot, revision: 1, readEpoch: 1, provenance: provenance, share: share,
                                      isLoading: false, isWriting: false, allowsInteraction: true)
    var sources: UsbSyncSource
    var volume: UsbVolumeInfo? = FakeUsbVolume.diskImageFAT32()
    var usbLibrary: UsbLibrary?
    var isEmptyExportable = false
    var isWriting = false
    var draftEdits: [UsbLibraryEdit] = []
    /// 메인 액터 밖에서 읽는 파일 쪽 상태
    let box = SyncFileBox()
    struct Native: Sendable {
        var baseFiles: [UsbFormat: Data] = [.oneLibrary: Data("sync".utf8), .deviceLibrary: Data("sync".utf8)]
        var fingerprint: String? = "native-1"
        var selection = ITunesSyncSelection()
        var enabled: Bool? = true
        var playlistIDs: [String: Int] = [:]
        var issues: [UsbSyncSelectionIssue] = []
        var reads = 0
    }
    let service = SyncFakeService()
    var preferencesFail = false
    /// 창에 보인 확인과 답
    var prompts: [ReflectionPrompt] = []
    var answers: [Bool] = []
    var calls: [String] = []
    var appended: [[UsbLibraryEdit]] = []
    var appendSucceeds = true
    var exported: [UsbExportJob] = []
    var written: [(UsbEditJob, [UsbLibraryEdit])] = []
    /// 쓰기가 성공했는지(성공하면 초안을 비우고 USB 라이브러리는 그대로 둔다)
    var writeSucceeds = true
    var leaseCount = 0
    /// 사본을 빌릴 때 부른다(그 사이 라이브러리가 바뀌는 시험)
    var onLease: (@MainActor () -> Void)?
    var importSummary = UsbCueGridImportSummary(cueCount: 2, gridCount: 1)
    /// 유스케이스가 내보낸 알림을 화면처럼 받은 오류·안내 칸과 받은 차례
    var problem: String?
    var info: String?
    var notices: [UsbSyncNotice] = []
    /// 유스케이스가 내보낸 상태(바뀔 때마다)
    var published: [UsbSyncState] = []

    init(sources: UsbSyncSource, usbLibrary: UsbLibrary?) {
        self.sources = sources
        self.usbLibrary = usbLibrary
    }

    /// 화면 쪽 출력: 상태는 모으고, 알림은 오류·안내 칸에 놓는다(앱 화면 모델과 같은 규칙)
    var output: UsbSyncOutput {
        UsbSyncOutput(changed: { self.published.append($0) }, notice: { notice in
            self.notices.append(notice)
            switch notice {
            case let .problem(text): self.problem = text
            case let .info(text): self.info = text
            case .clearProblem: self.problem = nil
            case .clearInfo: self.info = nil
            }
        })
    }

    var files: UsbSyncFiles {
        let box = box
        return UsbSyncFiles(
            selection: { _, _ in
                box.native.withLock { state in
                    state.reads += 1
                    let resolved = UsbSyncSelectionResolution(selection: state.selection, enabled: state.enabled, playlistIDs: state.playlistIDs,
                                                              formatPlaylistIDs: [:], removedSourcePlaylistIDs: [], issues: state.issues)
                    return UsbSyncNativeSelection(baseFiles: state.baseFiles, semanticFingerprint: state.fingerprint) { _, _, _, _ in resolved }
                }
            },
            masterNodes: { _ in
                [MasterPlaylistNode(id: "A", parentID: "0", attribute: 0, timestamp: 1, libType: 0, checkType: 0)]
            },
            preferences: { _ in
                box.preferences.files
            })
    }

    func ports(preferences: Bool = true) -> UsbSyncPorts {
        let fail = preferencesFail
        let files = files
        var preferencesFiles = files.preferences(URL(filePath: "/private/tmp/djc-sync/prefs"))
        if fail { preferencesFiles.load = { _ in throw UsbError.readFailed(detail: "망가진 설정") } }
        return UsbSyncPorts(
            library: { self.library },
            sources: { self.sources },
            leaseSnapshot: {
                self.leaseCount += 1
                self.calls.append("lease")
                self.onLease?()
                return UsbSyncSnapshotLease(database: Self.copy, provenance: Self.provenance, id: UUID(), release: {})
            },
            localSkip: { _ in nil },
            volume: {
                UsbSyncVolumeState(volume: self.volume, library: self.usbLibrary, isEmptyExportable: self.isEmptyExportable,
                                   isWriting: self.isWriting, isEjecting: false, draftEdits: self.draftEdits)
            },
            refreshUsb: { self.calls.append("refresh usb") },
            service: service,
            files: files,
            localKeys: LocalLibraryKeysSource { _ in LocalLibraryKeys(localDBID: Self.localDBID, tracks: [], counters: [:]) },
            preferences: preferences ? preferencesFiles : nil,
            confirmation: UserConfirmation(confirm: { prompt in
                self.prompts.append(prompt)
                return self.answers.isEmpty ? true : self.answers.removeFirst()
            }, choose: { _ in .cancel }),
            drafts: UsbSyncDrafts(blockReason: { _ in nil }, append: { edits, _ in
                self.calls.append("append")
                self.appended.append(edits)
                if self.appendSucceeds { self.draftEdits += edits }
                return self.appendSucceeds
            }),
            writer: UsbSyncWriter(export: { job in
                self.calls.append("export")
                self.exported.append(job)
                return self.writeSucceeds
            }, writeSyncDraft: { job, edits in
                self.calls.append("write")
                self.written.append((job, edits))
                if self.writeSucceeds { self.draftEdits = [] }
                return self.writeSucceeds
            }, lastNoticeDetail: { "쓰기 결과 설명" }),
            importCueGrid: {
                self.calls.append("import")
                return self.importSummary
            },
            newPlaylistKey: { "sync-new" },
            log: { _ in })
    }
}

/// 선택 파일 원문(형식별)과 그 선택을 푼 결과, 저장한 설정(메모리 구현, 저장한 차례는 `preferences.saves`)
final class SyncFileBox: Sendable {
    let native = Mutex(UsbSyncWorld.Native())
    let preferences = MemoryUsbSyncPreferences()
}

/// 동기화 시험 재료: rekordbox 목록 두 개(A·B)와 그 목록이 있는 USB
enum UsbSyncSamples {
    static func source() -> UsbSyncSource {
        let layout = PlaylistLayout([
            (item: PlaylistLayout.Item(id: "10", name: "목록 A", parentID: PlaylistLayout.root, isFolder: false,
                                       entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), seq: 0),
            (item: PlaylistLayout.Item(id: "11", name: "목록 B", parentID: PlaylistLayout.root, isFolder: false,
                                       entries: [PlaylistEntry(trackNo: 1, contentID: "2")]), seq: 1),
        ])
        return UsbSyncSource(layout: layout, rekordbox: layout, iTunes: PlaylistLayout([]), notices: [:], iTunesStatus: .ready)
    }

    static func usb() -> UsbLibrary {
        var library = UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000"))
        library.playlists = [UsbPlaylist(id: 1, name: "목록 A", parentID: 0, attribute: 0, presentIn: UsbFormat.defaultSet,
                                         sortOrder: [.oneLibrary: 0, .deviceLibrary: 0], entries: [.oneLibrary: [100], .deviceLibrary: [100]])]
        library.tracks = [UsbTrack(id: 100, presentIn: UsbFormat.defaultSet)]
        return library
    }
}
