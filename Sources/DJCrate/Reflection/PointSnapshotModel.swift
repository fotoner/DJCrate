import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 시점 스냅샷 창의 화면 모델(#224·#225). 창의 단추는 `start…` 동기 메서드만 부르고, 일(`Task`)과 그 손잡이는 이 모델이 든다(MVVM-4).
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

    /// 단추가 마지막으로 시작한 일. 창을 닫아도 끝까지 간다(취소하지 않는다). 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    func startRefresh() { task = Task { await refresh() } }
    func startCreate() { task = Task { await create() } }
    func startTogglePin(_ row: PointSnapshotRow) { task = Task { await setPinned(!row.pinned, row) } }

    /// 고른 줄이 없으면 시작하지 않는다(아래 둘도 같다)
    func startCompare() {
        guard let row = selectedRow else { return }
        task = Task { _ = await compare(row) }
    }

    func startRestore() {
        guard let row = selectedRow else { return }
        task = Task { await restore(row) }
    }

    func startDelete() {
        guard let row = selectedRow else { return }
        task = Task { await delete(row) }
    }

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
