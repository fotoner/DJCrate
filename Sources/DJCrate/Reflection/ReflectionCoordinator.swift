import DJCApplication
import DJCDomain
import AppKit
import Observation
import SwiftUI

/// 창을 띄운다. 시험에서는 정해 둔 답을 돌려준다.
@MainActor
protocol ReflectionPrompter {
    /// 확인을 누르면 true
    func show(_ prompt: ReflectionPrompt) -> Bool
    /// 확인·둘째 동작·취소 중 무엇을 눌렀는지(둘째 동작이 없는 창은 `show`와 같다)
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice
    /// 막힌 초안 복구 시트(#232)를 띄우고 닫힐 때까지 기다린다. 시험에서는 시트 대신 정해 둔 줄 선택을 넣는다.
    /// 기본 구현이 없다: 시트를 띄우지 않는 프롬프터는 `HeadlessReflectionPrompter`를 따라 기다리지 않고 닫는다.
    func review(_ model: RecoverySheetModel) async
}

/// 복구 시트를 띄우지 않는 프롬프터(자가 테스트·캡처). 시트가 열려야 하는 흐름에 닿으면 기다리지 않고 닫는다.
@MainActor
protocol HeadlessReflectionPrompter: ReflectionPrompter {}

extension HeadlessReflectionPrompter {
    func review(_ model: RecoverySheetModel) async { model.cancel() }
}

extension ReflectionPrompter {
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { show(prompt) ? .confirm : .cancel }
}

struct AlertPrompter: ReflectionPrompter {
    func show(_ prompt: ReflectionPrompt) -> Bool {
        choose(prompt) == .confirm
    }

    /// 시트는 창을 모달로 막지 않고 `ContentView`(또는 곡 편집 창)가 `LibraryStore.recoverySheet`를 보고 띄운다.
    func review(_ model: RecoverySheetModel) async {
        model.present()
        await model.waitUntilClosed()
    }

    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        let response = makeAlert(prompt).runModal()
        guard prompt.confirm != nil else { return .cancel }
        switch response {
        case .alertFirstButtonReturn: return .confirm
        case .alertSecondButtonReturn where prompt.alternate != nil: return .alternate
        default: return .cancel
        }
    }

    func makeAlert(_ prompt: ReflectionPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        if !prompt.details.isEmpty { alert.accessoryView = makeDetailsView(prompt.details) }
        if prompt.critical { alert.alertStyle = .critical }
        guard let confirm = prompt.confirm else {
            alert.addButton(withTitle: String(ui: "확인"))
            return alert
        }
        let confirmButton = alert.addButton(withTitle: confirm)
        if let alternate = prompt.alternate { alert.addButton(withTitle: alternate) }
        // 번들이 없는 디버그 실행에서도 취소 단축키가 동작해야 한다.
        alert.addButton(withTitle: prompt.cancel ?? String(ui: "취소")).keyEquivalent = "\u{1b}"
        if prompt.destructive {
            confirmButton.hasDestructiveAction = true
            confirmButton.keyEquivalent = ""
        }
        return alert
    }

    private func makeDetailsView(_ details: [String]) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        // 목록이 입력 초점을 가져가면 자동으로 중간에 스크롤되고 Return을 가로챈다.
        textView.isSelectable = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize.height = .greatestFiniteMagnitude
        textView.setAccessibilityLabel(String(ui: "세부 내용"))
        textView.string = details.joined(separator: "\n")
        scroll.documentView = textView
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 2 * textView.textContainerInset.height
            // 짧은 목록은 줄이고, 곡이 많아도 확인·취소 버튼은 창 안에 둔다.
            let borderHeight = scroll.frame.height - scroll.contentSize.height
            scroll.setFrameSize(NSSize(width: 440, height: min(240, max(44, height + borderHeight))))
            textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(height, scroll.contentSize.height)))
        }
        return scroll
    }
}

/// 결과 보이기: 반영 세션이 알린 결과(`ReflectionOutcome`)를 토스트·결과 기록·심각 경고로 바꾼다(세션의 결과 포트).
@MainActor
final class ReflectionPresenter {
    weak var store: LibraryStore?
    let prompter: any ReflectionPrompter

    init(store: LibraryStore, prompter: any ReflectionPrompter) {
        self.store = store
        self.prompter = prompter
    }

    func publish(_ outcome: ReflectionOutcome) {
        switch outcome {
        case .busy, .declined: return
        case let .notice(title, text, lines): notify(title, text, lines: lines)
        case .cancelled: publishCancelled()
        case let .written(report, preview, followUp):
            publish(WriteResult.written(report, preview: preview).followedUp(followUp), undo: report.backup)
        case let .autoWritten(report, followUp):
            // 자동 저장은 토스트 없이 활동 기록에만 남긴다(R15의 처음 몇 번 토스트는 상태 줄 #404 몫)
            _ = store?.activityLog.record(WriteResult.written(report, preview: report).followedUp(followUp))
        case let .nothingWritable(preview, _):
            // 창 대신 결과에 제외한 초안까지 남긴다(#230).
            var result = WriteResult.written(preview.report, preview: preview.report)
            if !preview.exclusions.isEmpty {
                result.text = ([result.text, String(ui: "저장하지 않는 것:")].filter { !$0.isEmpty } + preview.exclusions).joined(separator: "\n")
                result.shortfall = result.shortfall ?? ReflectionPrompts.summaryLine(preview.exclusions, prefix: String(ui: "저장하지 않는 것"))
            }
            publish(result)
        case let .added(report, preview, followUp):
            // 넣기는 끝났지만 백업에 추가 목록·초안을 남기지 못했다는 경고는 결과와 나눠 덧붙인다(#202).
            publish(.tracks(report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis, unreadable: preview.unreadable)
                .followedUp(followUp), undo: report.backup)
        case let .nothingAdded(preview):
            publish(.tracks(preview.report, preview: preview.report, adding: true, withoutAnalysis: preview.withoutAnalysis, unreadable: preview.unreadable))
        case let .deleted(report, preview):
            publish(.tracks(report, preview: preview.report, adding: false), undo: report.backup)
        case let .nothingDeleted(preview):
            publish(.tracks(preview.report, preview: preview.report, adding: false))
        case let .restored(backup, saved, fileWarning, followUp):
            publish(WriteResult.restored(backup, saved: saved, fileWarning: fileWarning).followedUp(followUp))
        case let .failed(title, error, exclusions):
            fail(title, error, exclusions: exclusions)
        case let .restoreFailed(backup, error):
            store?.dismissToast()
            AppErrorMessage.log(error)
            let text = String(ui: "rekordbox 라이브러리 상태를 확인하지 못했으므로 rekordbox를 켜지 말고 백업 폴더의 위치와 접근 권한을 확인한 뒤 다시 복원하세요.")
            let title = String(ui: "복원하지 못했습니다")
            store?.activityLog.record(WriteResult(kind: .failure, title: title, text: text, backups: [backup.url]))
            acknowledge(ReflectionPrompt(title: title, text: text, critical: true))
        }
    }

    /// 복원까지 실패한 경고창을 띄워 확인을 기다린다. 확인하기 전에는 앱을 끄지 않는다(#300).
    private func acknowledge(_ alert: ReflectionPrompt) {
        guard let store else { _ = prompter.show(alert); return }
        _ = store.whileAwaitingAcknowledgement { prompter.show(alert) }
    }

    /// 작업을 취소했을 때의 결과. 미리 보기 단계에서만 취소할 수 있어 아무것도 쓰지 않았다.
    private func publishCancelled() {
        let text = String(ui: "rekordbox에 아무것도 저장하지 않았습니다.")
        publish(WriteResult(kind: .success, title: String(ui: "작업을 취소했습니다"), text: text), detail: text)
    }

    /// 결과 알림을 띄우고 결과를 활동 기록에 남긴다(기록을 보관하지 못했으면 알림에 덧붙는다, `LibraryStore.showToast`).
    private func publish(_ result: WriteResult, undo: String? = nil, detail: String? = nil) {
        guard let store else { return }
        var toast = result.toast
        if let detail { toast.detail = detail }
        toast.undoBackup = undo.map { URL(filePath: $0) }
        store.showToast(toast, for: result)
    }

    /// 아무것도 쓰지 않은 안내(지금은 못 함·할 것 없음): 창을 띄우지 않고 경고 토스트로 알린다(#230).
    /// 쓰기 결과가 아니라 결과 보기를 붙이지 않는다(활동 기록에는 안내로 남는다). 이유 줄은 앞 둘과 남은 수만 보인다.
    private func notify(_ title: String, _ text: String, lines: [String] = []) {
        store?.showToast(.notice(title, ([text] + [ReflectionPrompts.summaryLine(lines)].compactMap { $0 }).joined(separator: "\n")))
    }

    /// 쓰기 실패 알림. 자동 복원까지 실패했으면 사라지는 토스트가 아니라 닫아야 하는 경고 창으로 알린다.
    /// - Parameter exclusions: 미리 보기에서 제외한 초안. 따로 창을 띄우지 않고 이 알림과 결과 기록에 합친다(#230).
    private func fail(_ title: String, _ error: any Error, exclusions: [String] = []) {
        let excluded = ReflectionPrompts.summaryLine(exclusions, prefix: String(ui: "미리 보기에서 제외한 편집"))
        let excludedText = exclusions.isEmpty ? [] : [String(ui: "미리 보기에서 제외한 편집:")] + exclusions
        if var alert = ReflectionPrompts.restoreFailureAlert(error) {
            AppErrorMessage.log(error)
            store?.dismissToast()
            let backups: [URL]
            if case let DJCError.restoreFailed(_, _, backup, _) = error { backups = [URL(filePath: backup)] } else { backups = [] }
            store?.activityLog.record(WriteResult(kind: .failure, title: alert.title,
                                                    text: ([alert.text] + excludedText).joined(separator: "\n"), backups: backups))
            alert.details = excludedText
            acknowledge(alert)
        } else {
            let message = AppErrorMessage.message(for: error)
            publish(WriteResult(kind: .failure, title: title, text: ([message] + excludedText).joined(separator: "\n")),
                    detail: [message, excluded].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}

/// rekordbox 쓰기의 화면 쪽: 버튼·메뉴·토스트의 입구(시작 가능 판정, 한 번에 작업 하나), 반영 세션 부르기, 막힌 초안 복구 시트.
/// 흐름(대상·미리 보기·확인 정책·확인·쓰기·뒤처리·결과)은 DJCApplication `ReflectionSession`이 정하고, 결과는 `ReflectionPresenter`가 보인다.
/// 조립 지점(`AppComposition.reflection`)이 하나 만들어 메뉴·목록·사이드바·창에 넣는다.
@MainActor
final class ReflectionCoordinator {
    let session: ReflectionSession
    /// 쓰기 상태·작업·복구 시트를 보이는 화면 모델
    let store: LibraryStore
    let prompter: any ReflectionPrompter
    /// 자동 저장 엔진(#403). 있으면 모든 쓰기가 엔진의 차례(직렬 큐)를 받는다: 자동 저장 중에 누른 ⌘S는 그 저장이 끝난 뒤 곧 한다.
    /// 조립 지점이 실제 앱에만 붙인다(화면 시험·자가 테스트 조립은 nil이라 지금처럼 바로 쓴다)
    var engine: AutoReflection?
    /// 엔진이 알린 칩 상태와 조건(상태 줄 #404가 읽는다)
    let autoFeed = AutoReflectionFeed()
    /// USB에 쓰는 중인지(USB 쓰기·볼륨을 붙잡은 작업). 시험이 바꿔 넣는다
    lazy var isWritingUsb: @MainActor () -> Bool = { [unowned store] in store.writeActivity.writingUsb }

    init(session: ReflectionSession, store: LibraryStore, prompter: any ReflectionPrompter) {
        self.session = session
        self.store = store
        self.prompter = prompter
    }

    // MARK: - 입구(버튼·메뉴): 시작할 수 있으면 작업 하나로 돌린다

    /// 막힌 초안 비교 창이 열려 있으면 알리고 시작하지 않는다(#232). USB에 쓰는 중이면 이유를 알리고 시작하지 않는다(R3 3번 줄: USB 쓰기가
    /// 라이브 분석 파일을 읽는 동안 라이브러리를 바꾸지 않는다). 이미 쓰는 중이거나 다른 작업이 있으면 무시한다.
    /// 다만 자동 저장이 쓰는 중이면 그 뒤 차례로 넣는다(R3 5번 줄)
    private func canStart(blocked: Bool = false) -> Bool {
        if let refusal = store.writeRefusal {
            // Mac을 끄는 중이거나 종료를 기다리는 중(#300)에는 새 쓰기를 시작하지 않고 이유를 알린다
            store.showToast(.notice(refusal, nil))
            return false
        }
        if store.writesBlockedBySheet { store.announceWritesBlockedBySheet(); return false }
        if isWritingUsb() {
            store.showToast(.notice(String(ui: "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요"), nil))
            return false
        }
        let autoWriting = engine?.isWriting == true
        return !blocked && (!store.libraryBusy || autoWriting) && store.writeTask == nil
    }

    private func start(_ work: @escaping @MainActor () async -> Void) {
        let store = store
        store.writeTask = Task {
            defer { store.writeTask = nil }
            await work()
        }
    }

    /// 쓰기 하나를 엔진의 차례로 한다(엔진이 없으면 바로). 엔진은 결과로 멈춤을 풀거나(저장 성공) 멈춘다(복원)
    private func serialized<T>(_ work: @MainActor () async throws -> T) async rethrows -> T {
        guard let engine else { return try await work() }
        return try await engine.exclusive(work)
    }

    /// 초안을 쓰는 흐름(⌘S·저장 단추·곡 넣기)을 엔진의 차례로 한다. 앞 쓰기의 정리를 마치지 못했으면(미정리 목록이 남음) 쓰지 않고 알린다:
    /// 쓴 재생 목록 단계가 초안에 남아 다시 쓰면 같은 목록이 두 번 생긴다(R22). 복원은 고치는 쓰기라 막지 않는다
    private func serializedWrite(_ work: @MainActor () async -> ReflectionOutcome) async -> ReflectionOutcome {
        guard let engine else { return await work() }
        let session = session
        return await engine.exclusive(work, whenHeld: { holds in
            // 잠금 아래 판정을 하지 못했으면(rekordbox가 켜져 기록을 판정하지 못함·잠금·기록을 읽다 실패) rekordbox 종료나 디스크·권한을,
            // 정리를 마치지 못했으면 편집 보관을 확인하게 한다
            let outcome: ReflectionOutcome
            if holds == [.lockBusy], session.ports.runningApps.isRekordboxRunning() {
                outcome = .notice(title: String(ui: "rekordbox가 켜져 있어 저장하지 않았습니다"), text: ReflectionPrompts.quitRekordboxText, lines: [])
            } else {
                let text = holds == [.lockBusy] ? String(ui: "디스크 공간과 권한을 확인한 뒤 다시 시도하세요.") : ReflectionSession.playlistSaveFailureText
                outcome = .notice(title: String(ui: "rekordbox에 저장하지 않았습니다"), text: text, lines: [])
            }
            session.ports.results.publish(outcome)
            return outcome
        })
    }

    /// iTunes 동기화 쓰기(동기화 창). 다른 rekordbox 쓰기처럼 엔진의 차례로 한다(자동 저장과 겹쳐 쓰기 잠금·얼림을 풀지 않게)
    func syncITunes(_ change: ITunesSyncWrite) async throws -> (target: URL, syncData: Data) {
        let session = session
        return try await serialized { try await session.syncITunes(change) }
    }

    /// - Parameter playlists: 재생 목록 초안도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 false)
    func startWrite(rows: [TrackRow], playlists: Bool = true) {
        guard canStart() else { return }
        start { await self.write(rows: rows, playlists: playlists) }
    }

    /// 추가한 곡을 rekordbox 컬렉션에 바로 넣는다.
    func startAddTracks(rows: [TrackRow]) {
        guard canStart() else { return }
        start { await self.addTracks(rows: rows) }
    }

    /// rekordbox 컬렉션에서 곡을 뺀다(음원 파일은 그대로).
    func startDeleteTracks(rows: [TrackRow]) {
        guard canStart(blocked: store.isITunesSelection) else { return }
        start { await self.deleteTracks(rows: rows) }
    }

    func startRestoreLatest() {
        store.refreshWriteBackups()
        guard let backup = session.writeBackups().first(where: \.isWrite) else {
            // 메뉴는 백업이 있을 때만 열린다. 그 사이 백업이 정리됐으면 창 대신 토스트로 알린다(#230).
            store.showToast(.notice(String(ui: "복원할 저장 기록이 없습니다"), String(ui: "DJCrate가 rekordbox에 저장한 적이 없거나 백업이 정리됐습니다.")))
            return
        }
        guard canStart() else { return }
        start { await self.restore(backup) }
    }

    /// 쓰기 결과 토스트의 복원 단추. 누른 것이 확인이라 그 뒤 변경·초안 충돌이 없으면 묻지 않는다(#210).
    /// 백업은 쓰기가 남긴 이 저장소의 백업 폴더(`backupDirectory`)에서 찾는다(최근 쓰기 복원과 같은 곳).
    func startRestore(backupURL: URL) {
        guard let backup = Self.backup(matching: backupURL, in: session.writeBackups()) else {
            store.showToast(.notice(String(ui: "백업을 찾지 못했습니다"), backupURL.path))
            return
        }
        guard canStart() else { return }
        start { await self.restore(backup, confirmed: true) }
    }

    static func backup(matching url: URL, in backups: [RekordboxWriteBackup]) -> RekordboxWriteBackup? {
        guard url.isFileURL else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        // /tmp 별칭과 디렉터리 표기를 맞추되, 모호한 후보는 복원하지 않는다.
        let matches = backups.filter { $0.url.isFileURL && $0.url.resolvingSymlinksInPath().standardizedFileURL.path == path }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - 흐름(기다릴 수 있다: 시험·자가 테스트)

    /// - Parameter playlists: 재생 목록 초안도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 곡 초안만 쓴다)
    func write(rows: [TrackRow], playlists: Bool = true) async {
        let session = session
        let outcome = await serializedWrite { await session.write(rows: rows, playlists: playlists) }
        // 쓸 수 없게 된 곡·재생 목록의 초안은 창을 줄줄이 띄우지 않고 한 시트에서 줄마다 고친다(#232).
        // 고를 것이 없으면 창을 띄우지 않는다. 막힌 이유는 결과 토스트와 결과 보기에 있다(#230).
        guard case let .nothingWritable(preview, targets) = outcome else { return }
        let requests = Self.recoveryRequests(store: store, targets: targets, blocked: BlockedDrafts(report: preview.report))
        if !requests.isEmpty { await recover(requests: requests, staleOnly: true) }
    }

    func addTracks(rows: [TrackRow]) async {
        let session = session
        _ = await serializedWrite { await session.addTracks(rows: rows) }
    }

    func deleteTracks(rows: [TrackRow]) async {
        let session = session
        _ = await serialized { await session.deleteTracks(rows: rows) }
    }

    /// - Parameter confirmed: 쓰기 결과 토스트의 복원 단추로 불렀는지(그 백업을 보고 누른 것이라 확인으로 본다)
    func restore(_ backup: RekordboxWriteBackup, confirmed: Bool = false) async {
        let session = session
        _ = await serialized { await session.restore(backup, confirmed: confirmed) }
    }

    /// 시점 스냅샷 복원(#225): 대상은 쓰기와 같은 곳, 보관 일수는 설정. 복원하면 자동 저장이 멈춘다(R8)
    func restorePointSnapshot(_ entry: URL, snapshots: URL, changedTracks: Set<String>) async throws -> RekordboxPointRestoreReport {
        let session = session, days = Int(store.settings.value(SettingKeys.pointSnapshotAutoDays))
        let report = try await serialized {
            try await session.restorePointSnapshot(entry, snapshots: snapshots, autoDays: days, now: .now, changedTracks: changedTracks,
                                                   to: session.target)
        }
        engine?.restored()
        return report
    }
}

/// 자동 저장 엔진이 알린 칩 상태와 상태 줄·⌘S가 보는 조건(R3 표의 입력). 엔진(핵심부)은 관찰 값을 들지 않아 화면 쪽이 받아 든다.
/// 화면(상태 줄)은 이 값만 읽고 줄과 단추를 고른다(#404)
@MainActor
@Observable
final class AutoReflectionFeed {
    private(set) var status: AutoReflectionStatus = .saved
    private(set) var conditions = ReflectionConditions()

    func update(_ status: AutoReflectionStatus, _ conditions: ReflectionConditions) {
        if self.status != status { self.status = status }
        if self.conditions != conditions { self.conditions = conditions }
    }
}

extension EnvironmentValues {
    /// rekordbox 쓰기의 화면 쪽. 조립 지점이 주 창·곡 편집 창에 붙인다(붙이지 않은 화면(시험·미리 보기)에서는 nil이라 쓰기 단추가 아무것도 하지 않는다).
    @Entry var reflection: ReflectionCoordinator? = nil
}
