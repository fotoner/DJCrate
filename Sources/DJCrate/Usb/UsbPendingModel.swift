import DJCApplication
import DJCDomain
import Foundation
import Observation

/// USB 쓰기 대기 목록(순수 값): 초안 편집마다 설명과 상태(미리 판정·미리 보기 결과), 요약 줄, 쓰기 단추 상태
struct UsbPendingList: Equatable {
    enum Status: Equatable {
        /// 미리 보기 전, 막힐 까닭을 모름
        case waiting
        /// 미리 보기 전, 가벼운 판정으로 막힐 것 같음
        case expectedBlock(String)
        case written
        case unchanged
        case blocked(String)
        /// 라이브러리는 고치고 파일 지우기를 미룸
        case deferred(String)
    }

    struct Row: Identifiable, Equatable {
        /// 편집 번호(1부터, 초안 순서)
        var id: Int
        var text: String
        var status: Status

        var statusText: String? {
            switch status {
            case .waiting: nil
            case let .expectedBlock(reason): String(ui: "막힐 수 있음: \(reason)")
            case .written: String(ui: "쓸 예정")
            case .unchanged: String(ui: "바꿀 것 없음")
            case let .blocked(reason): String(ui: "막힘: \(reason)")
            case let .deferred(reason): String(ui: "쓸 예정 · 파일 지우기를 미룸: \(reason)")
            }
        }

        var isWarning: Bool {
            switch status {
            case .expectedBlock, .blocked: true
            case .waiting, .written, .unchanged, .deferred: false
            }
        }
    }

    var volumeName: String
    var isConnected: Bool
    var rows: [Row]
    /// 미리 보기 요약(미리 보기 전에는 빔)
    var summaryLines: [String]
    var canPreview: Bool
    var canWrite: Bool
    /// "USB에 쓰기…" 도움말(막혔으면 그 까닭과 할 일)
    var writeHelp: String

    /// - blockReason: 미리 보기 전의 가벼운 막힘 판정(`UsbEditRules.blockReason`). 편집과 그 앞 편집들을 받는다
    ///   (계획이 차례로 적용하므로 목록 항목 자리는 앞 편집까지 얹은 목록으로 본다, #240)
    init(volumeName: String, isConnected: Bool, edits: [UsbLibraryEdit], library: UsbLibrary?, summary: UsbEditSummary?, busy: Bool,
         blockReason: (UsbLibraryEdit, [UsbLibraryEdit]) -> String?) {
        self.volumeName = volumeName
        self.isConnected = isConnected
        let created = UsbEditText.createdNames(edits)
        rows = edits.enumerated().map { offset, edit in
            let number = offset + 1
            let status: Status
            switch summary?.outcomes[number] {
            case .written?: status = .written
            case .unchanged?: status = .unchanged
            case let .blocked(reason)?: status = .blocked(reason)
            case let .deferred(reason)?: status = .deferred(reason)
            case nil: status = blockReason(edit, Array(edits.prefix(offset))).map(Status.expectedBlock) ?? .waiting
            }
            return Row(id: number, text: UsbEditText.describe(edit, library: library, created: created), status: status)
        }
        if let summary {
            summaryLines = [String(ui: "쓸 편집 \(summary.writtenCount)건 · 막힌 편집 \(summary.blockedCount)건 · 바꿀 것 없는 편집 \(summary.unchangedCount)건")]
                + summary.stopping + UsbWriteFlow.editLines(summary, blockedEdits: false)
        } else {
            summaryLines = []
        }
        let stopping = summary?.stopping ?? []
        canPreview = isConnected && !edits.isEmpty && !busy
        // 미리 본 결과 쓸 것이 없으면 누른 뒤 알리지 않고 단추를 막는다(#230)
        let nothingToWrite = summary.map { $0.stopping.isEmpty && !$0.hasChanges } ?? false
        canWrite = canPreview && stopping.isEmpty && !nothingToWrite
        writeHelp = if !isConnected {
            UsbWriteFlow.Text.connectFirstDetail
        } else if busy {
            String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
        } else if edits.isEmpty {
            String(ui: "쓸 편집이 없습니다. 곡 목록·사이드바에서 USB 편집을 더하세요")
        } else if !stopping.isEmpty {
            stopping.joined(separator: "\n")
        } else if nothingToWrite {
            String(ui: "바꿀 것이 없거나 모든 편집이 막혔습니다. 목록의 막힌 이유를 확인하세요")
        } else {
            String(ui: "초안을 미리 본 뒤 USB에 씁니다. 쓰기 전에 Mac에 백업합니다.")
        }
    }
}

/// 화면과 합성 시험이 같은 pending 진입점을 쓴다. 원본 사본 소유권은 화면이 아닌 UsbStore에 있다.
@MainActor
struct UsbPendingWorkflow {
    let coordinator: UsbWriteCoordinator
    let volumeKey: String
    let database: URL?
    let share: URL?

    func preview() async -> UsbEditSummary? {
        await coordinator.previewDraft(volumeKey: volumeKey, database: database, share: share)
    }
    @discardableResult
    func write(reusing summary: UsbEditSummary?) async -> Bool {
        await coordinator.writeDraft(volumeKey: volumeKey, database: database, share: share, reusing: summary)
    }
}

/// 사이드바 "USB 쓰기 대기" 화면 모델: 이 볼륨의 초안 편집을 읽어 두고, 미리 보기·USB에 쓰기…·편집 빼기·초안 버리기를 부른다.
/// 볼륨이 빠져 있어도 초안은 보이고 고칠 수 있다(쓰기만 막힌다). 순서·판정은 쓰기 흐름(`UsbWriteCoordinator`)과 편집 동작(`UsbEditActions`)에 있다.
@MainActor @Observable
final class UsbPendingModel {
    /// 라이브러리 화면이 주는 것(부를 때마다 지금 값). 앱은 `LibraryStore`(`init(store:usb:volumeKey:)`), 시험은 가짜
    struct Ports {
        var actions: @MainActor () -> UsbEditActions?
        var coordinator: @MainActor () -> UsbWriteCoordinator?
        /// 앱이 연 로컬 스냅샷 사본
        var database: @MainActor () -> URL?
        /// 로컬 rekordbox share(읽기만)
        var share: @MainActor () -> URL
    }

    let volumeKey: String
    /// 화면이 보는 초안 편집(초안이 바뀔 때마다 다시 읽는다)
    private(set) var edits: [UsbLibraryEdit] = []
    /// 방금 본 미리 보기(초안이 바뀌면 버린다)
    private(set) var summary: UsbEditSummary?
    private(set) var isPreviewing = false
    @ObservationIgnored private let usb: UsbStore
    @ObservationIgnored private let ports: Ports

    init(volumeKey: String, usb: UsbStore, ports: Ports) {
        self.volumeKey = volumeKey
        self.usb = usb
        self.ports = ports
    }

    convenience init(store: LibraryStore, usb: UsbStore, volumeKey: String) {
        self.init(volumeKey: volumeKey, usb: usb,
                  ports: Ports(actions: { store.usbEdits }, coordinator: { store.usbCoordinator },
                               database: { store.snapshotURL }, share: { store.shareRoot }))
    }

    /// 초안이 바뀐 횟수(편집 동작·쓰기 뒤 늘어난다). 화면은 이것이 바뀔 때 다시 읽는다
    var draftRevision: Int { usb.draftRevisions[volumeKey] ?? 0 }

    /// 쓰는 중이라 편집 빼기·초안 버리기를 막는다
    var isBusy: Bool { usb.busyVolumes.contains(volumeKey) }

    /// 화면에 보일 목록(줄·요약·단추 상태)
    var list: UsbPendingList {
        let actions = ports.actions(), key = volumeKey
        return UsbPendingList(volumeName: usb.editName(key) ?? "USB", isConnected: usb.volume(key) != nil, edits: edits,
                              library: usb.editLibrary(key), summary: summary,
                              busy: usb.busyVolumes.contains(key) || usb.activeWrite != nil,
                              blockReason: { actions?.blockReason($0, volumeKey: key, after: $1) })
    }

    // MARK: - 의도

    /// 초안을 다시 읽고 앞의 미리 보기를 버린다(초안이 바뀔 때마다, 화면의 수명 작업이 부른다)
    func reload() async {
        edits = await ports.actions()?.draft(volumeKey: volumeKey)?.edits ?? []
        summary = nil
    }

    /// "미리 보기" 단추. 뷰는 기다리지 않는다
    @discardableResult
    func previewTapped() -> Task<Void, Never> { Task { await preview() } }

    /// "USB에 쓰기…" 단추. 방금 본 미리 보기가 있으면 다시 미리 보지 않는다
    @discardableResult
    func writeTapped() -> Task<Void, Never> { Task { await write() } }

    /// 편집 하나 빼기. 보고 있는 편집일 때만 뺀다(그 사이 초안이 바뀌었으면 번호가 다른 편집을 가리킨다)
    @discardableResult
    func removeTapped(_ number: Int) -> Task<Void, Never> {
        let shown = edits.indices.contains(number - 1) ? edits[number - 1] : nil
        return start(.removeEdit(number, volumeKey: volumeKey, matching: shown))
    }

    /// "초안 버리기" 단추(편집 › 실행 취소로 되살린다)
    @discardableResult
    func discardTapped() -> Task<Void, Never> { start(.discardDraft(volumeKey: volumeKey)) }

    private func start(_ intent: UsbEditActions.Intent) -> Task<Void, Never> {
        ports.actions()?.start(intent) ?? Task {}
    }

    private func preview() async {
        guard let pending = workflow() else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        let revision = usb.draftRevisions[volumeKey]
        let result = await pending.preview()
        // 기다리는 동안 초안이 바뀌었으면 버린다
        if usb.draftRevisions[volumeKey] == revision { summary = result }
    }

    private func write() async {
        guard let pending = workflow() else { return }
        await pending.write(reusing: summary)
    }

    /// 동기화 초안이면 그 작업의 share를 쓴다(초안을 만든 출처 그대로)
    private func workflow() -> UsbPendingWorkflow? {
        guard let coordinator = ports.coordinator() else { return nil }
        return UsbPendingWorkflow(coordinator: coordinator, volumeKey: volumeKey, database: ports.database(),
                                  share: usb.syncDraftSources[volumeKey]?.job.share ?? ports.share())
    }
}
