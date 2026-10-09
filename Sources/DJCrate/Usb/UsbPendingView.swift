import DJCApplication
import DJCDomain
import SwiftUI

/// USB 쓰기 대기 목록(순수 모델): 초안 편집마다 설명과 상태(미리 판정·미리 보기 결과), 요약 줄, 쓰기 단추 상태
struct UsbPendingModel: Equatable {
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

/// 사이드바 "USB 쓰기 대기": 이 볼륨의 초안 편집 목록 · 미리 보기 · USB에 쓰기… · 편집 빼기 · 초안 버리기
/// 볼륨이 빠져 있어도 초안은 보이고 고칠 수 있다(쓰기만 막힌다)
struct UsbPendingView: View {
    let store: LibraryStore
    let usb: UsbStore
    let volumeKey: String
    @State private var edits: [UsbLibraryEdit] = []
    @State private var summary: UsbEditSummary?
    @State private var isPreviewing = false

    private var actions: UsbEditActions? { store.usbEdits }

    private var model: UsbPendingModel {
        let actions = actions
        return UsbPendingModel(volumeName: usb.editName(volumeKey) ?? "USB", isConnected: usb.volume(volumeKey) != nil, edits: edits,
                               library: usb.editLibrary(volumeKey), summary: summary,
                               busy: usb.busyVolumes.contains(volumeKey) || usb.activeWrite != nil,
                               blockReason: { actions?.blockReason($0, volumeKey: volumeKey, after: $1) })
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 0) {
            header(model)
            Divider()
            List {
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(row.id).").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.text)
                            if let status = row.statusText {
                                Label { Text(verbatim: status) } icon: {
                                    Image(systemName: row.isWarning ? WarningMark.symbol : "checkmark.circle")
                                }
                                .font(.caption)
                                .foregroundStyle(row.isWarning ? UIColors.warning.color : Color.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            // 보고 있는 편집일 때만 뺀다(그 사이 초안이 바뀌었으면 번호가 다른 편집을 가리킨다)
                            let shown = edits.indices.contains(row.id - 1) ? edits[row.id - 1] : nil
                            Task { await actions?.removeEdit(row.id, volumeKey: volumeKey, matching: shown) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(usb.busyVolumes.contains(volumeKey))
                        .help(.ui("이 편집을 초안에서 뺍니다"))
                        .accessibilityLabel(.ui("\(row.id)번 편집 빼기"))
                    }
                }
                if !model.summaryLines.isEmpty {
                    Section(.ui("미리 보기")) {
                        ForEach(Array(model.summaryLines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label(.ui("쓸 USB 편집이 없습니다"), systemImage: "externaldrive")
                    } description: {
                        Text(.ui("곡을 오른쪽 클릭해 ‘USB에 넣기’를 고르거나 USB 곡·재생 목록을 오른쪽 클릭해 편집을 더하세요."))
                    }
                }
            }
        }
        // 초안이 바뀌면(편집 동작·쓰기 뒤) 다시 읽고 앞의 미리 보기를 버린다
        .task(id: usb.draftRevisions[volumeKey] ?? 0) {
            edits = await actions?.draft(volumeKey: volumeKey)?.edits ?? []
            summary = nil
        }
    }

    private func header(_ model: UsbPendingModel) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(verbatim: model.volumeName)
            } icon: {
                Image(systemName: model.isConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
            }
            .font(.headline)
            if !model.isConnected {
                Text(.ui("연결 안 됨")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isPreviewing { ProgressView().controlSize(.small) }
            Button(.ui("미리 보기")) { Task { await preview() } }
                .disabled(!model.canPreview || isPreviewing)
                .help(.ui("초안을 지금 USB 상태로 계획해 편집마다 쓸지·막힐지 봅니다. USB에는 쓰지 않습니다."))
            Button(.ui("USB에 쓰기…")) { Task { await write() } }
                .disabled(!model.canWrite || isPreviewing)
                .help(model.writeHelp)
            Button(.ui("초안 버리기"), role: .destructive) {
                Task { await actions?.discardDraft(volumeKey: volumeKey) }
            }
            .disabled(model.rows.isEmpty || usb.busyVolumes.contains(volumeKey))
            .help(.ui("이 USB에 아직 쓰지 않은 편집을 모두 버립니다. 편집 › 실행 취소(⌘Z)로 되살립니다."))
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 8)
    }

    private func preview() async {
        guard let coordinator = store.usbCoordinator else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        let revision = usb.draftRevisions[volumeKey]
        let pending = UsbPendingWorkflow(coordinator: coordinator, volumeKey: volumeKey, database: store.snapshotURL,
                                         share: usb.syncDraftSources[volumeKey]?.job.share ?? store.shareRoot)
        let result = await pending.preview()
        // 기다리는 동안 초안이 바뀌었으면 버린다
        if usb.draftRevisions[volumeKey] == revision { summary = result }
    }

    private func write() async {
        guard let coordinator = store.usbCoordinator else { return }
        let pending = UsbPendingWorkflow(coordinator: coordinator, volumeKey: volumeKey, database: store.snapshotURL,
                                         share: usb.syncDraftSources[volumeKey]?.job.share ?? store.shareRoot)
        await pending.write(reusing: summary)
    }
}
