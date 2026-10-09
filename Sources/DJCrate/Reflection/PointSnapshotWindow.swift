import AppKit
import DJCApplication
import DJCDomain
import Observation
import SwiftUI

/// 시점 스냅샷 창(#224·#225): 지금 상태를 이름 붙여 남기고, 시점 스냅샷과 쓰기 전 백업을 한 목록에서 보고, 스냅샷을 고정한다.
/// 고른 스냅샷을 지금과 비교하고, 확인 창 하나를 거쳐 그 시점으로 복원한다(되돌릴 수 없는 외부 쓰기라 묻는다).
/// 쓰기 전 백업은 따로 정리되고 '쓰기 전으로 복원…'으로 되돌리므로 여기서는 보기만 한다(#223 결정).
@MainActor
final class PointSnapshotWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: PointSnapshotModel?
    /// 저장소의 대상(쓰기·복원과 같은 곳)으로 시점 스냅샷 유스케이스를 만든다(조립 지점이 실제 구현을 고른다)
    private let points: @MainActor (LibraryStore) -> PointSnapshots

    init(points: @escaping @MainActor (LibraryStore) -> PointSnapshots) {
        self.points = points
    }

    func open(store: LibraryStore, reflection: ReflectionCoordinator) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            Task { await model?.refresh() }
            return
        }
        let model = PointSnapshotModel(store: store, reflection: reflection, points: points(store))
        let window = NSWindow(contentViewController: NSHostingController(rootView: PointSnapshotView(model: model)))
        window.title = String(ui: "시점 스냅샷")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 520))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.isWorking != true }
}

@MainActor @Observable
final class PointSnapshotModel {
    private(set) var rows: [PointSnapshotRow] = []
    var selection: PointSnapshotRow.ID?
    var newName = ""
    private(set) var isWorking = false
    /// 마지막 동작 결과 한 줄(실패면 `isError`)
    private(set) var message: String?
    private(set) var isError = false
    /// 같은 디스크가 아니라 클론이 안 될 때의 안내
    private(set) var cloneNote: String?
    /// 마지막으로 비교한 스냅샷과 결과
    private(set) var comparison: RekordboxPointSnapshotDiff?
    private(set) var comparedID: PointSnapshotRow.ID?

    /// 시점 스냅샷 유스케이스(대상 라이브러리·스냅샷 폴더·쓰기 전 백업 폴더는 조립 지점이 정한다)
    let points: PointSnapshots
    @ObservationIgnored private let autoDays: () -> Int
    @ObservationIgnored private let busy: () -> String?
    @ObservationIgnored private let prompter: any ReflectionPrompter
    @ObservationIgnored private let now: () -> Date
    /// 복원(앱은 반영 세션 `restorePointSnapshot`: 쓰기 잠금·다시 읽기까지, 대상은 쓰기와 같은 곳)
    @ObservationIgnored private let restoreAction: @MainActor (RekordboxPointSnapshotEntry, Set<String>) async throws -> RekordboxPointRestoreReport

    /// - Parameter restore: 시점 스냅샷으로 되돌린다(바뀌는 곡을 받는다)
    init(points: PointSnapshots, autoDays: @escaping () -> Int = { Int(SettingKeys.pointSnapshotAutoDays.defaultValue) },
         busyReason: @escaping () -> String? = { nil }, prompter: any ReflectionPrompter = AlertPrompter(), now: @escaping () -> Date = { .now },
         restore: @escaping @MainActor (RekordboxPointSnapshotEntry, Set<String>) async throws -> RekordboxPointRestoreReport) {
        self.points = points
        self.autoDays = autoDays
        self.busy = busyReason
        self.prompter = prompter
        self.now = now
        restoreAction = restore
    }

    /// 앱 창이 쓰는 모델: 쓰기·복원 대상은 반영 세션의 위치(`LibraryStore.rekordboxDatabase`와 같은 곳)로 조립 지점이 만든 유스케이스다.
    convenience init(store: LibraryStore, reflection: ReflectionCoordinator, points: PointSnapshots) {
        let settings = store.settings, snapshots = points.directory
        self.init(points: points, autoDays: { Int(settings.value(SettingKeys.pointSnapshotAutoDays)) },
                  busyReason: { [weak store] in
                      store?.isWritingRekordbox == true ? String(ui: "rekordbox에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 누르세요") : nil
                  },
                  restore: { [weak reflection] entry, changed in
                      guard let reflection else { throw CancellationError() }
                      return try await reflection.restorePointSnapshot(entry.url, snapshots: snapshots, changedTracks: changed)
                  })
    }

    var selectedRow: PointSnapshotRow? { rows.first { $0.id == selection } }

    /// 만들기 단추를 막는 이유(도움말)
    var blockReason: String? { busy() }

    func refresh() async {
        let result = await points.load()
        rows = result.rows
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
        cloneNote = result.canClone ? nil : String(ui: "DJCrate 데이터 폴더가 rekordbox와 다른 디스크라 스냅샷마다 라이브러리 전체를 복사합니다.")
    }

    func create() async {
        guard !isWorking else { return }
        if let reason = blockReason { show(reason, error: true); return }
        isWorking = true
        defer { isWorking = false }
        do {
            let entry = try await points.create(name: newName, autoDays: autoDays(), now: now())
            newName = ""
            await refresh()
            selection = PointSnapshotRow.pointID(entry)
            show(String(ui: "시점 스냅샷을 남겼습니다."), error: false)
        } catch {
            AppErrorMessage.log(error)
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    func setPinned(_ pinned: Bool, _ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        do {
            try points.setPinned(pinned, entry)
            await refresh()
            show(pinned ? String(ui: "고정했습니다. 자동 정리에서 지우지 않습니다.") : String(ui: "고정을 풀었습니다."), error: false)
        } catch {
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    /// 지운 스냅샷은 되살릴 수 없어 한 번 묻는다(고정한 것은 묻지 않고 이유를 보인다).
    func delete(_ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        switch await points.delete(entry, confirmation: prompter.confirmation, working: { [weak self] in self?.isWorking = $0 }) {
        case let .refused(refusal): show(refusal.message, error: true)
        case .cancelled: break
        case .deleted:
            await refresh()
            show(String(ui: "시점 스냅샷을 지웠습니다."), error: false)
        case let .failed(error):
            show(AppErrorMessage.message(for: error), error: true)
        }
    }

    /// 고른 스냅샷과 지금 라이브러리를 견준다(읽기만).
    @discardableResult
    func compare(_ row: PointSnapshotRow) async -> RekordboxPointSnapshotDiff? {
        guard let entry = row.entry, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let diff = try await points.compare(entry)
            showComparison(diff, of: row)
            return diff
        } catch {
            AppErrorMessage.log(error)
            show(AppErrorMessage.message(for: error), error: true)
            return nil
        }
    }

    /// 비교한 뒤 확인 창 하나로 묻고 그 시점으로 되돌린다(순서는 유스케이스). 복원 직전 상태는 시점 스냅샷으로 남는다.
    func restore(_ row: PointSnapshotRow) async {
        guard let entry = row.entry, !isWorking else { return }
        let outcome = await points.restore(entry, blockReason: blockReason, confirmation: prompter.confirmation,
                                           compared: { [weak self] in self?.showComparison($0, of: row) },
                                           working: { [weak self] in self?.isWorking = $0 }, perform: restoreAction)
        switch outcome {
        case let .refused(refusal):
            show(refusal.message, error: true)
        case let .compareFailed(error):
            AppErrorMessage.log(error)
            show(AppErrorMessage.message(for: error), error: true)
        case .cancelled:
            break
        case let .restored(report):
            comparison = nil
            comparedID = nil
            await refresh()
            selection = row.id
            show(String(ui: "‘\(entry.displayName)’ 시점으로 복원했습니다. 복원 전 상태는 ‘복원 직전’ 스냅샷(\(report.beforeRestore.metadata.createdAt.formatted(date: .omitted, time: .shortened)))으로 남겼습니다."),
                 error: false)
        case let .failed(error):
            AppErrorMessage.log(error)
            let text = AppErrorMessage.message(for: error)
            show(text, error: true)
            if case DJCError.pointRestoreFailed = error {
                _ = prompter.show(ReflectionPrompt(title: String(ui: "복원하지 못했습니다"), text: text, critical: true))
            }
            await refresh()
        }
    }

    /// 복원 확인 창(`PointSnapshots.restoreConfirmation`)
    static func restoreConfirmation(_ entry: RekordboxPointSnapshotEntry, diff: RekordboxPointSnapshotDiff) -> ReflectionPrompt {
        PointSnapshots.restoreConfirmation(entry, diff: diff)
    }

    private func showComparison(_ diff: RekordboxPointSnapshotDiff, of row: PointSnapshotRow) {
        comparison = diff
        comparedID = row.id
        message = nil
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}

struct PointSnapshotView: View {
    @State var model: PointSnapshotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(.ui("이름(선택)"), text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.create() } }
                    .frame(maxWidth: 320)
                Button(.ui("지금 스냅샷 남기기")) { Task { await model.create() } }
                    .disabled(model.isWorking || model.blockReason != nil)
                    .help(model.blockReason ?? String(ui: "rekordbox 라이브러리(DB·분석 파일·앨범아트)를 지금 시점으로 남깁니다"))
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(.ui("rekordbox가 꺼져 있을 때만 남깁니다. 수동·고정 스냅샷은 지우지 않고, 쓰기 전 백업은 따로 정리됩니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.cloneNote {
                Label { Text(verbatim: note) } icon: { Image(systemName: "externaldrive") }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(model.rows, selection: $model.selection) {
                TableColumn(.ui("시각")) { row in
                    Text(verbatim: row.date.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 130, ideal: 150)
                TableColumn(.ui("이름")) { row in
                    Text(verbatim: row.name.isEmpty ? "—" : row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.entry == nil ? .secondary : .primary)
                }
                .width(min: 140, ideal: 240)
                TableColumn(.ui("종류")) { row in Text(verbatim: row.kind) }
                    .width(min: 80, ideal: 100)
                TableColumn(.ui("크기")) { row in
                    Text(verbatim: row.bytes.map { $0.formatted(.byteCount(style: .file).locale(UIStrings.locale)) } ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
                TableColumn(.ui("고정")) { row in
                    if row.entry != nil {
                        Button {
                            Task { await model.setPinned(!row.pinned, row) }
                        } label: {
                            Image(systemName: row.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(row.pinned ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(row.pinned ? String(ui: "고정 풀기") : String(ui: "고정하면 자동 정리에서 지우지 않습니다"))
                        .accessibilityLabel(row.pinned ? Text(.ui("고정 풀기")) : Text(.ui("고정")))
                    }
                }
                .width(44)
            }
            if let diff = model.comparison, model.comparedID == model.selection {
                PointSnapshotComparisonView(diff: diff)
            }
            HStack {
                if let message = model.message {
                    Label { Text(verbatim: message) } icon: {
                        Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    }
                    .foregroundStyle(model.isError ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(.ui("현재와 비교")) {
                    if let row = model.selectedRow { Task { await model.compare(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.isWorking)
                .help(String(ui: "이 시점으로 복원하면 무엇이 바뀌는지 봅니다"))
                Button(.ui("이 시점으로 복원…")) {
                    if let row = model.selectedRow { Task { await model.restore(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.isWorking || model.blockReason != nil)
                .help(model.blockReason ?? String(ui: "rekordbox 라이브러리를 고른 시점으로 되돌립니다(rekordbox를 끈 뒤)"))
                Button(.ui("지우기…")) {
                    if let row = model.selectedRow { Task { await model.delete(row) } }
                }
                .disabled(model.selectedRow?.entry == nil || model.selectedRow?.pinned == true || model.isWorking)
                .help(model.selectedRow?.pinned == true ? String(ui: "고정을 푼 뒤 지우세요") : String(ui: "고른 시점 스냅샷을 지웁니다"))
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 400)
        .task { await model.refresh() }
    }
}

/// 비교 결과: 요약 줄과 펼쳐 보기
struct PointSnapshotComparisonView: View {
    let diff: RekordboxPointSnapshotDiff

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if diff.isEmpty {
                    Text(.ui("지금 라이브러리와 다른 곳이 없습니다."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: diff.summary.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(.ui("자세히")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(diff.details(), id: \.title) { group in
                                    Text(verbatim: group.title).font(.callout.bold())
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { item in
                                        Text(verbatim: "• " + item.element).font(.callout)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(.ui("복원하면 바뀌는 것"))
        }
    }
}
