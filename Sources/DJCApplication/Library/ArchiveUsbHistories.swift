import DJCDomain
import Foundation

/// USB 기기 재생 기록 보존(유스케이스, #43): 보존한 기록 읽기, USB에서 읽은 새 기록의 보존(후보 → 계획 → 짝 다시 검증 → 저장),
/// 바뀐 보존본(쓰기 대기에서 빼기·rekordbox에 쓴 표시) 저장. USB·rekordbox 라이브러리에는 쓰지 않는다.
/// 판정은 순수 규칙(`UsbHistoryImport`·`UsbHistoryRules`)에 있다. 보존과 보존본 저장을 한 줄로 세우는 일, 저장한 기록의 채택, 실패 알림은
/// 여기서 정한다(#251). 화면 상태는 들지 않는다: 보존본·짝짓기 키는 화면(`screen`)에서 읽고 바꿀 것을 알린다(앱: 재생 기록 조각).
/// 파일 읽기·쓰기는 메인 밖에서 한다.
@MainActor
public final class ArchiveUsbHistories {
    /// 보존 파일. nil이면 읽기·보존·저장을 하지 않는다(시험 기본·CLI: 사용자 폴더를 건드리지 않게 앱의 조립 지점만 붙인다)
    let files: UsbHistoryFiles?
    /// 가져온 시각(이름 "HISTORY yyyy-MM-dd"와 트리 자리)
    let now: @Sendable () -> Date
    /// 새 기록 ID 뒷부분(앱은 UUID)
    let newID: @Sendable () -> String
    /// 흐름이 보는 재생 기록 화면. 화면 쪽 조각이 만들 때 붙인다(붙이지 않으면 보존본이 없는 것으로 보고 결과를 버린다)
    public var screen: UsbHistoryScreen?
    /// 보존·보존본 저장(쓰기 대기에서 빼기·rekordbox에 쓴 표시)을 한 줄로 세운다
    /// (USB 읽기와 로컬 짝 다시 계산이 겹쳐도 같은 기록을 두 번 보존하지 않고, 파일 쓰기가 서로 겹치지 않게)
    private var line: Task<Void, Never>?
    /// 읽지 못해 그 자리에 남은 보존 파일. 해소될 때까지 새 ID 보존을 막아 중복을 만들지 않는다.
    public private(set) var unreadable: [String] = []

    public nonisolated init(files: UsbHistoryFiles?, now: @escaping @Sendable () -> Date, newID: @escaping @Sendable () -> String) {
        self.files = files
        self.now = now
        self.newID = newID
    }

    /// 보존 파일을 붙였는지
    public var isEnabled: Bool { files != nil }

    private var state: UsbHistoryState { screen?.state() ?? UsbHistoryState() }

    private func apply(_ change: UsbHistoryChange) { screen?.apply(change) }

    // MARK: - 줄 세우기

    /// 보존한 기록 읽기를 줄 맨 앞에 세운다(USB를 읽으면 그와 견줘 새 기록만 보존한다)
    public func startLoading() {
        guard isEnabled else { return }
        enqueue { [weak self] in await self?.reload() }
    }

    /// USB의 새 기기 재생 기록을 보존해 화면에 넣는다(USB를 읽었거나 로컬 짝을 다시 계산한 뒤, 앱은 `UsbStore.onLibraryEvaluated`).
    /// 한 줄로 세워 차례로 한다: 계획은 앞선 보존이 끝난 뒤의 보존본으로 세우고, 파일 쓰기(fsync)는 메인 액터 밖에서 한다
    /// - Parameter calendar: 가져온 날짜를 정할 달력(앱은 이 Mac의 달력)
    public func startImport(volumeKey: String, volumeName: String, library: UsbLibrary, matches: [Int: String], calendar: Calendar) {
        guard isEnabled else { return }
        enqueue { [weak self] in
            await self?.performImport(volumeKey: volumeKey, volumeName: volumeName, library: library, matches: matches, calendar: calendar)
        }
    }

    /// 고친 보존본을 화면에 바로 넣고, 파일 저장은 줄에 세운다.
    /// 저장은 줄 차례가 왔을 때의 보존본(그사이 가져오기가 짝을 채웠거나 다시 바꾼 것까지)을 메인 액터 밖에서 쓴다.
    /// - Returns: 저장하지 못한 기록 수를 돌려주는 작업
    @discardableResult
    public func update(_ updated: [ArchivedHistory]) -> Task<Int, Never> {
        apply(.archived(UsbHistoryRules.replacing(state.archived, with: updated)))
        let ids = updated.map(\.id)
        let previous = line
        let save = Task { @MainActor [weak self] () -> Int in
            await previous?.value
            guard let self else { return 0 }
            let current = Dictionary(self.state.archived.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            return await self.save(ids.compactMap { current[$0] })
        }
        line = Task { @MainActor in _ = await save.value }
        return save
    }

    /// 줄 선 보존·저장이 모두 끝날 때까지(시험·자가 테스트)
    public func waitUntilIdle() async {
        while let task = line {
            await task.value
            // 기다리는 동안 새로 줄을 서지 않았으면 끝
            if line == task { return }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = line
        line = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: - 읽기·채택·알림

    /// 보존한 기록을 읽어 화면에 넣는다. 읽지 못한 파일은 `files`가 damaged-drafts로 옮기고 여기서 알린다.
    /// - Parameter preservingCurrent: 기다리는 동안 고친 쓰기 상태는 지키고, 앞서 읽지 못했던 파일에서 알아낸 기록만 더한다
    public func reload(preservingCurrent: Bool = false) async {
        guard isEnabled else { return }
        let loaded = await load()
        unreadable = loaded.unreadable
        if preservingCurrent {
            let current = state.archived
            let known = Set(current.map(\.id))
            apply(.archived(current + loaded.histories.filter { !known.contains($0.id) }))
        } else {
            apply(.archived(loaded.histories))
        }
        rematch()
        var notice: UsbHistoryNotice?
        if !loaded.unreadable.isEmpty {
            notice = .warning(String(ui: "USB 재생 기록 파일을 읽지 못했습니다. usb-histories 읽기 권한을 확인한 뒤 USB를 다시 연결하세요"),
                              loaded.unreadable.joined(separator: ", "))
        } else if !loaded.damaged.isEmpty {
            notice = .warning(String(ui: "읽지 못한 USB 재생 기록 파일 \(loaded.damaged.count)개를 damaged-drafts로 옮겼습니다. 기록이 남은 USB를 다시 연결하면 다시 가져옵니다"),
                              loaded.damaged.joined(separator: ", "))
        }
        apply(.loaded(notice))
    }

    /// 저장됐거나 현재 파일 내용이 일치하는 기록만 채택하고, 내구 쓰기 실패는 알린다.
    private func performImport(volumeKey: String, volumeName: String, library: UsbLibrary, matches: [Int: String], calendar: Calendar) async {
        guard isEnabled else { return }
        if !unreadable.isEmpty {
            await reload(preservingCurrent: true)
            guard unreadable.isEmpty else { return }
        }
        let before = state
        guard let imported = await importFrom(volumeKey: volumeKey, volumeName: volumeName, library: library, matches: matches,
                                              existing: before.archived, local: before.local, calendar: calendar) else { return }
        if imported.failed {
            apply(.notice(.warning(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                                   String(ui: "DJCrate 데이터 폴더의 usb-histories를 확인한 뒤 USB를 다시 연결하세요"))))
        }
        guard !imported.saved.isEmpty else { return }
        let savedIDs = Set(imported.saved.map(\.id))
        // 파일 쓰기를 기다리는 동안 채택한 새 스냅샷에도 맞춘다(그 저장은 이 보존 뒤에 줄을 선다).
        apply(.archived(UsbHistoryRules.merging(saved: imported.saved, into: state.archived)))
        rematch()
        let after = state
        // rekordbox도 가져온 기록(숨김)은 새로 가져왔다고 알리지 않는다
        let shown = imported.added.filter { savedIDs.contains($0.id) && !after.shadowed.contains($0.id) }
        var notice: UsbHistoryNotice?
        // 일부만 보존했으면 앞의 경고를 남긴다
        if !shown.isEmpty, !imported.failed {
            // 보존본을 넣으면서 화면이 쓰기 대기를 다시 골랐다. 대기에 오른 기록은 그 사실을 함께 알린다
            let queued = shown.filter { after.pending.contains($0.id) }.count
            let detail = queued == 0 ? volumeName
                : queued == shown.count ? String(ui: "\(volumeName) · rekordbox 쓰기 대기에 올렸습니다")
                : String(ui: "\(volumeName) · \(queued)개를 rekordbox 쓰기 대기에 올렸습니다")
            notice = UsbHistoryNotice(kind: .success, title: String(ui: "USB에서 재생 기록 \(shown.count)개를 가져왔습니다"), detail: detail)
        }
        apply(.imported(shown: shown.map(\.id), saved: savedIDs, notice: notice))
    }

    /// USB를 뺀 뒤에도 채택한 스냅샷의 원본 키로 보존본을 다시 검증한다. 바뀐 보존본만 저장하고, 저장하지 못하면 알린다
    public func rematch() {
        let current = state
        let changed = zip(current.archived, UsbHistoryRules.rematch(current.archived, local: current.local))
            .compactMap { old, new in old == new ? nil : new }
        guard !changed.isEmpty else { return }
        let save = update(changed)
        Task { @MainActor [weak self] in
            guard await save.value > 0 else { return }
            self?.apply(.notice(.warning(String(ui: "USB 재생 기록을 보존하지 못했습니다"),
                                         String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 시도하세요"))))
        }
    }

    /// 보존본을 rekordbox 쓰기 대기에서 빼거나 다시 넣는다(보존본은 그대로). 화면 상태는 바로 바꾸고 파일 저장은 줄에 세운다.
    /// 저장하지 못하면 알린다(다시 켜면 옛 상태로 읽힌다).
    /// - Returns: 바꾼 기록 ID(이미 그 상태면 빠진다. 화면이 되돌리기에 쓴다)
    public func exclude(_ ids: [String], excluded: Bool) -> [String] {
        let changed = UsbHistoryRules.excluding(state.archived, ids: ids, excluded: excluded)
        guard !changed.isEmpty else { return [] }
        let save = update(changed)
        Task { @MainActor [weak self] in
            guard await save.value > 0 else { return }
            self?.apply(.notice(.warning(Self.queueSaveFailureTitle,
                                         String(ui: "DJCrate 데이터 폴더의 usb-histories 쓰기 권한을 확인한 뒤 다시 바꾸세요"))))
        }
        return changed.map(\.id)
    }

    /// rekordbox에 쓴(또는 최신 대상에 이미 있던) 보존 기록에 rekordbox 기록 ID를 남긴다(반영 세션이 쓴 뒤 다시 읽기 전에 부른다).
    /// 다시 읽을 때까지는 쓴 ID를 rekordbox에 있는 것으로 보게 화면에 알린다(다시 읽지 못해도 같은 기록을 또 쓰지 않게).
    /// 그 기록이 나중에 rekordbox에서 사라지면(쓰기 전으로 복원 등) `HistoryWriteQueue`가 다시 쓰기 대기로 돌린다.
    /// - Returns: 표시를 저장하지 못했을 때 알릴 문장(rekordbox 쓰기는 끝났다)
    public func markWritten(_ outcomes: [RekordboxHistoryOutcome]) async -> String? {
        let current = state
        let marked = UsbHistoryRules.markWritten(current.archived, outcomes: outcomes, local: current.local)
        guard !marked.historyIDs.isEmpty else { return nil }
        apply(.awaitingReload(marked.historyIDs))
        let failed = await update(marked.changed).value
        return failed == 0 ? nil : Self.markFailureText(failed)
    }

    public static func markFailureText(_ count: Int) -> String {
        String(ui: "rekordbox에는 썼지만 보존한 재생 기록 \(count)건에 쓴 표시를 저장하지 못했으니, 다시 켠 뒤 그 기록이 쓰기 대기에 오르면 사이드바에서 쓰기 대기에서 빼세요.")
    }

    public static var queueSaveFailureTitle: String { String(ui: "재생 기록의 쓰기 대기 상태를 저장하지 못했습니다") }

    // MARK: - 파일(메인 밖)
    // 아래는 메인 액터에 묶지 않는다: 곡이 많은 USB의 후보·계획·짝 다시 검증이 메인을 멈추지 않게 한다

    /// 보존한 기록을 읽는다(메인 밖에서)
    public nonisolated func load() async -> ArchivedHistoryLoad {
        guard let files else { return ArchivedHistoryLoad() }
        return (try? await LoadLibrary.background(qos: .utility) { files.load() }) ?? ArchivedHistoryLoad()
    }

    /// 한 번 보존한 결과
    public struct Imported: Sendable, Equatable {
        /// 계획이 새로 보존하려던 기록(저장하지 못한 것도 든다. 알림은 `saved`와 견줘 고른다)
        public var added: [ArchivedHistory]
        /// 저장됐거나 현재 파일 내용이 일치해 채택할 기록(새 기록과 짝을 채운 보존본)
        public var saved: [ArchivedHistory]
        /// 내구 쓰기에 실패한 기록이 있다(그 뒤 기록은 저장하지 않았다)
        public var failed: Bool
    }

    /// USB 라이브러리의 새 기기 기록을 보존한다. 같은 USB 기록은 다시 보존하지 않고 모르던 로컬 짝만 채운다(`UsbHistoryImport.plan`).
    /// 이름은 보존본끼리 매긴다(rekordbox 이름을 피하면 같은 이름으로 중복을 검증할 수 없다. rekordbox에 쓸 때의 이름 충돌은 쓰기 관문이 푼다).
    /// 기록마다 따로 저장해 저장된 것만 돌려준다: 한꺼번에 저장하다 중간에 실패하면 디스크에는 남았는데 상태에 없는 기록이 생기고,
    /// 다음 시도가 새 ID로 또 저장해 다시 켤 때 같은 기록이 둘이 된다. 보존할 것이 없으면 nil.
    /// - Parameters:
    ///   - matches: 합친 라이브러리의 USB content_id → 로컬 ContentID(`UsbStore.localMatches`)
    ///   - existing: 지금 보존한 기록 전부(앞선 보존이 끝난 뒤의 상태)
    ///   - local: 채택한 스냅샷의 짝짓기 키(짝을 다시 검증한다)
    ///   - calendar: 가져온 날짜를 정할 달력(앱은 이 Mac의 달력)
    public nonisolated func importFrom(volumeKey: String, volumeName: String, library: UsbLibrary, matches: [Int: String],
                                       existing: [ArchivedHistory], local: LocalLibraryKeys?, calendar: Calendar) async -> Imported? {
        guard let files else { return nil }
        let candidates = UsbHistoryCandidates.make(library: library, volumeKey: volumeKey, volumeName: volumeName, matches: matches)
        guard !candidates.isEmpty else { return nil }
        let plan = UsbHistoryImport.plan(existing: existing, candidates: candidates, reservedNames: [], now: now(), calendar: calendar,
                                         makeID: newID)
        guard !plan.isEmpty else { return nil }
        let pending = UsbHistoryRules.rematch(plan.updated + plan.added, local: local)
        let (saved, failed) = (try? await LoadLibrary.background(qos: .utility) { () -> ([ArchivedHistory], Bool) in
            var done: [ArchivedHistory] = []
            for history in pending {
                let result = Self.saveOne(history, files: files)
                if result.accepted { done.append(history) }
                if result.failed { return (done, true) }
            }
            return (done, false)
        }) ?? ([], true)
        return Imported(added: plan.added, saved: saved, failed: failed)
    }

    /// 보존본을 기록마다 따로 내구 쓰기한다(메인 밖에서). 저장하지 못한 기록 수.
    /// 화면에는 이미 이 상태가 있다. 파일 일치 확인이 돼도 실패로 세어 경고를 남기고, 상태는 되돌리지 않는다
    public nonisolated func save(_ histories: [ArchivedHistory]) async -> Int {
        guard let files, !histories.isEmpty else { return 0 }
        return (try? await LoadLibrary.background(qos: .utility) { () -> Int in
            histories.reduce(0) { failed, history in Self.saveOne(history, files: files).failed ? failed + 1 : failed }
        }) ?? histories.count
    }

    /// 기록 하나 저장. rename 뒤 폴더 fsync만 실패했다면 같은 ID의 파일을 채택해(`accepted`) 다음 가져오기가 새 ID를 만들지 않게 한다
    nonisolated static func saveOne(_ history: ArchivedHistory, files: UsbHistoryFiles) -> (accepted: Bool, failed: Bool) {
        do {
            try files.save(history)
            return (true, false)
        } catch {
            return (files.containsExact(history), true)
        }
    }
}
