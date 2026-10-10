import AppKit
import DJCApplication
import DJCDomain
import Foundation

/// 재생 목록 이름을 받는 창. 시험은 정해 둔 답을 돌려준다
@MainActor
protocol UsbNamePrompter {
    /// 확인하면 입력한 이름, 취소하면 nil
    func askName(title: String, text: String, initial: String, confirm: String) -> String?
}

struct AlertNamePrompter: UsbNamePrompter {
    func askName(title: String, text: String, initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(String(ui: "재생 목록 이름"))
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(ui: "취소")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// 편집을 더할 수 있는 USB(메뉴·끌어다 놓기 대상)
struct UsbEditTarget: Identifiable, Equatable {
    var volumeKey: String
    var name: String
    /// 빠진 볼륨이면 거짓(초안만 쌓는다)
    var isConnected: Bool
    var library: UsbLibrary

    var id: String { volumeKey }
}

/// 앱의 USB 편집: 곡 목록·사이드바의 동작을 USB 초안(`usb-drafts/<볼륨키>.json`)으로 쌓는다. USB에는 쓰지 않는다 —
/// 쓰기는 쓰기 대기 목록의 "USB에 쓰기…"(`UsbWriteCoordinator.writeDraft`)만 한다. 초안 파일 입출력은 메인 액터 밖에서 한다.
@MainActor
struct UsbEditActions {
    /// 알림 문구(흐름과 시험이 같은 이름으로 가리킨다)
    enum Text {
        static var appendedTitle: String { String(ui: "USB 쓰기 대기에 더했습니다") }
        static var notAppendedTitle: String { String(ui: "USB 쓰기 대기에 더하지 않았습니다") }
        static var draftFailedTitle: String { String(ui: "USB 초안을 고치지 못했습니다") }
        static var discardActionName: String { String(ui: "USB 초안 버리기") }
        static var nothingNewerTitle: String { String(ui: "로컬에서 더 고친 곡이 없습니다") }
        static var removedFromQueueTitle: String { String(ui: "USB 쓰기 대기에서 뺐습니다") }
        static var changedQueueTitle: String { String(ui: "USB 쓰기 대기를 고쳤습니다") }
    }

    let usb: UsbStore
    let host: any UsbWriteHost
    var prompter: any ReflectionPrompter = AlertPrompter()
    var namePrompter: any UsbNamePrompter = AlertNamePrompter()
    /// 초안 버리기를 되돌리는 곳(편집 › 실행 취소). 부를 때마다 지금 창의 것을 읽는다(nil이면 걸지 않는다)
    var undoManager: @MainActor () -> UndoManager? = { nil }
    /// 새 목록의 key(같은 초안 안에서 겹치지 않게)
    var newKey: () -> String = { "djc-" + UUID().uuidString.prefix(8).lowercased() }

    /// 사이드바 메뉴·쓰기 대기 단추가 시작하는 편집(`start`). 뷰는 기다리지 않는다
    enum Intent: Equatable {
        case createPlaylist(isFolder: Bool, parent: Int?, volumeKey: String)
        case renamePlaylist(Int, volumeKey: String)
        case deletePlaylist(Int, volumeKey: String)
        case movePlaylist(Int, by: Int, volumeKey: String)
        case refreshLocalChanges(volumeKey: String)
        /// 번호(1부터)의 편집 빼기. `matching`이 있으면 그 자리의 편집이 같을 때만 뺀다
        case removeEdit(Int, volumeKey: String, matching: UsbLibraryEdit?)
        case discardDraft(volumeKey: String)
    }

    /// 편집 동작을 시작한다(누른 차례대로 초안 줄에 선다)
    @discardableResult
    func start(_ intent: Intent) -> Task<Void, Never> {
        let actions = self
        return Task { await actions.perform(intent) }
    }

    func perform(_ intent: Intent) async {
        switch intent {
        case let .createPlaylist(isFolder, parent, key): await createPlaylist(isFolder: isFolder, parent: parent, volumeKey: key)
        case let .renamePlaylist(id, key): await renamePlaylist(id, volumeKey: key)
        case let .deletePlaylist(id, key): await deletePlaylist(id, volumeKey: key)
        case let .movePlaylist(id, step, key): await movePlaylist(id, by: step, volumeKey: key)
        case let .refreshLocalChanges(key): await refreshLocalChanges(volumeKey: key)
        case let .removeEdit(number, key, expected): await removeEdit(number, volumeKey: key, matching: expected)
        case let .discardDraft(key): await discardDraft(volumeKey: key)
        }
    }

    // MARK: - 대상

    /// 편집을 더할 수 있는 볼륨: 읽은 rekordbox USB, 이번 실행에서 읽은 뒤 빠진 초안 볼륨
    var targets: [UsbEditTarget] {
        let connected = usb.volumes.compactMap { volume -> UsbEditTarget? in
            let key = volume.usbKey
            guard usb.acceptsEdits(key), let library = usb.libraries[key] else { return nil }
            return UsbEditTarget(volumeKey: key, name: volume.name, isConnected: true, library: library)
        }
        let absent = usb.absentDrafts.values.sorted { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
            .compactMap { absent -> UsbEditTarget? in
                guard let library = absent.library, usb.acceptsEdits(absent.volume.usbKey) else { return nil }
                return UsbEditTarget(volumeKey: absent.volume.usbKey, name: absent.volume.name, isConnected: false, library: library)
            }
        return connected + absent
    }

    /// 새로 더할 편집이 막힐 까닭(모르면 nil). 메뉴 옆 도움말과 더하기 전 판정에 쓴다.
    /// 목록 항목 자리는 쓰기 전 초안을 얹은 차례로 본다(목록 줄과 같다, 계획도 초안을 차례로 적용한다)
    func blockReason(_ edit: UsbLibraryEdit, volumeKey: String) -> String? {
        UsbEditRules.blockReason(edit, volume: usb.volume(volumeKey), library: usb.projectedLibrary(volumeKey), info: usb.infos[volumeKey],
                                 isScratchMount: usb.isScratchMount, physicalGate: usb.physicalGate, syncGate: usb.syncGate)
    }

    /// 이미 초안에 있는 편집 하나가 막힐 까닭(쓰기 대기 목록): 그 앞 편집까지 얹은 목록으로 본다
    func blockReason(_ edit: UsbLibraryEdit, volumeKey: String, after earlier: [UsbLibraryEdit]) -> String? {
        UsbEditRules.blockReason(edit, volume: usb.volume(volumeKey),
                                 library: usb.editLibrary(volumeKey).map { UsbDraftProjection.library($0, edits: earlier) }, info: usb.infos[volumeKey],
                                 isScratchMount: usb.isScratchMount, physicalGate: usb.physicalGate, syncGate: usb.syncGate)
    }

    /// 동기화 묶음은 앞선 폴더 이동을 반영한 트리에서 차례로 검사한다.
    func blockReason(_ edits: [UsbLibraryEdit], volumeKey: String) -> String? {
        UsbEditRules.blockReason(edits, volume: usb.volume(volumeKey), library: usb.projectedLibrary(volumeKey), info: usb.infos[volumeKey],
                                 isScratchMount: usb.isScratchMount, physicalGate: usb.physicalGate, syncGate: usb.syncGate)
    }

    // MARK: - 초안

    /// 그 볼륨의 초안을 한 줄(`UsbStore.draftQueue`)로 고친다(`UsbDraftEditing.mutate`, 메인 액터 밖).
    /// 고쳤으면 그 전·뒤 편집, 그대로면 nil
    private func mutateDraft(_ volumeKey: String, _ change: @escaping @Sendable ([UsbLibraryEdit]) -> [UsbLibraryEdit]?) async
        -> Result<UsbDraftEditing.Change?, any Error> {
        guard let editing = usb.draftEditing else { return .success(nil) }
        let usb = usb
        return await usb.draftQueue(volumeKey) {
            let volume = usb.volume(volumeKey)
            let result = await BlockingWork.run { () -> Result<(edits: [UsbLibraryEdit], changed: UsbDraftEditing.Change?), any Error> in
                Result { try editing.mutate(volumeKey, volume: volume, change) }
            }
            switch result {
            case let .success((edits, changed)):
                // 그대로여도 파일과 다르면(다른 곳에서 고침) 맞춘다
                if changed != nil || (usb.draftEdits[volumeKey] ?? []) != edits { usb.setDraft(edits, for: volumeKey) }
                return .success(changed)
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    /// 편집 하나를 그 볼륨의 초안 끝에 더한다. 볼륨이 빠져 있어도 더한다(쓰기만 막힌다). 더하면 true
    @discardableResult
    func append(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        await append([edit], to: volumeKey, detail: UsbEditText.describe(edit, library: usb.editLibrary(volumeKey)))
    }

    /// 편집 여럿을 차례로 한 번에 더한다
    func append(_ edits: [UsbLibraryEdit], to volumeKey: String, detail: String) async -> Bool {
        guard !edits.isEmpty, usb.acceptsEdits(volumeKey) else { return false }
        let name = usb.editName(volumeKey) ?? "USB"
        switch await mutateDraft(volumeKey, { $0 + edits }) {
        case .success:
            host.toast = AppToast(kind: .success, title: Text.appendedTitle, detail: "\(name) · \(detail)", isUsb: true)
            return true
        case let .failure(error):
            draftFailed(error)
            return false
        }
    }

    /// 막힐 편집은 더하지 않고 이유를 알린다
    @discardableResult
    private func appendChecked(_ edit: UsbLibraryEdit, to volumeKey: String) async -> Bool {
        await appendChecked([edit], to: volumeKey, detail: UsbEditText.describe(edit, library: usb.editLibrary(volumeKey)))
    }

    /// 하나라도 막히면 모두 더하지 않는다
    @discardableResult
    private func appendChecked(_ edits: [UsbLibraryEdit], to volumeKey: String, detail: String) async -> Bool {
        if let reason = blockReason(edits, volumeKey: volumeKey) {
            warnNotAdded(reason)
            return false
        }
        return await append(edits, to: volumeKey, detail: detail)
    }

    private func warnNotAdded(_ reason: String) {
        host.toast = AppToast(kind: .warning, title: Text.notAppendedTitle, detail: reason, isUsb: true)
    }

    private func draftFailed(_ error: any Error) {
        AppErrorMessage.log(error)
        host.toast = AppToast(kind: .warning, title: Text.draftFailedTitle,
                              detail: String(ui: "DJCrate 데이터 폴더의 usb-drafts를 확인한 뒤 다시 시도하세요"), isUsb: true)
    }

    /// 그 볼륨의 초안(없으면 nil)
    func draft(volumeKey: String) async -> UsbDraft? {
        guard let files = usb.drafts else { return nil }
        return await BlockingWork.run { try? files.load(volumeKey) } ?? nil
    }

    /// 편집 하나를 초안에서 뺀다(번호는 1부터). `matching`을 주면 그 자리의 편집이 같을 때만 뺀다(그 사이 초안이 바뀌었으면 그대로).
    /// 남는 것이 없으면 초안을 지운다
    func removeEdit(_ number: Int, volumeKey: String, matching expected: UsbLibraryEdit? = nil) async {
        let result = await mutateDraft(volumeKey) { edits in
            guard edits.indices.contains(number - 1), expected.map({ edits[number - 1] == $0 }) ?? true else { return nil }
            var edits = edits
            edits.remove(at: number - 1)
            return edits
        }
        if case let .failure(error) = result { draftFailed(error) }
    }

    /// 초안 버리기. 쓰기 전 편집이라 묻지 않고 편집 › 실행 취소(⌘Z)로 되살린다(#237). USB는 바뀌지 않는다
    func discardDraft(volumeKey: String) async {
        guard usb.drafts != nil, (usb.draftCounts[volumeKey] ?? 0) > 0 else { return }
        let discarded = DiscardedDraft()
        if await replaceDraft(volumeKey, change: { { _ in nil } }, replaced: { discarded.draft = $0 }) {
            registerRestore(discarded, volumeKey: volumeKey)
        }
    }

    /// 버린 초안(실행 복귀로 다시 버리면 그때 채운다)
    @MainActor private final class DiscardedDraft { var draft: UsbDraft? }

    /// 실행 취소 → 되살리기. 반대 동작(실행 복귀)은 실행 취소 안에서 바로 걸어야 복귀 쪽에 쌓인다. 파일은 그 뒤 비동기로 고친다
    private func registerRestore(_ discarded: DiscardedDraft, volumeKey: String) {
        guard let undoManager = undoManager() else { return }
        let actions = self
        undoManager.registerUndo(withTarget: usb) { _ in
            actions.registerDiscardAgain(volumeKey: volumeKey)
            Task { @MainActor in
                // 처음 base·만든 때를 그대로 두고, 버린 뒤 더한 편집은 뒤에 남긴다
                await actions.replaceDraft(volumeKey, change: {
                    guard let draft = discarded.draft else { return { $0 } }
                    return { current in
                        UsbDraft(volumeKey: draft.volumeKey, base: draft.base, edits: draft.edits + (current?.edits ?? []),
                                 createdAt: draft.createdAt)
                    }
                })
            }
        }
        undoManager.setActionName(Text.discardActionName)
    }

    /// 실행 복귀 → 다시 버리기
    private func registerDiscardAgain(volumeKey: String) {
        guard let undoManager = undoManager() else { return }
        let actions = self
        undoManager.registerUndo(withTarget: usb) { _ in
            let discarded = DiscardedDraft()
            actions.registerRestore(discarded, volumeKey: volumeKey)
            Task { @MainActor in await actions.replaceDraft(volumeKey, change: { { _ in nil } }, replaced: { discarded.draft = $0 }) }
        }
        undoManager.setActionName(Text.discardActionName)
    }

    /// 그 볼륨의 초안 파일을 통째로 바꾼다(nil·빈 편집이면 지운다). `change`는 차례가 왔을 때 만들고, 바꾸기 전 초안은 `replaced`로 받는다.
    /// 고쳤으면 true
    @discardableResult
    private func replaceDraft(_ volumeKey: String, change: @escaping @MainActor () -> @Sendable (UsbDraft?) -> UsbDraft?,
                              replaced: @escaping @MainActor (UsbDraft?) -> Void = { _ in }) async -> Bool {
        guard let editing = usb.draftEditing else { return false }
        let usb = usb
        let result = await usb.draftQueue(volumeKey) { () -> Result<UsbDraft?, any Error> in
            let transform = change()
            let result = await BlockingWork.run { () -> Result<(old: UsbDraft?, new: UsbDraft?), any Error> in
                Result { try editing.replace(volumeKey, transform) }
            }
            switch result {
            case let .success((old, new)):
                usb.setDraft(new?.edits ?? [], for: volumeKey)
                replaced(old)
                return .success(old)
            case let .failure(error):
                return .failure(error)
            }
        }
        if case let .failure(error) = result {
            draftFailed(error)
            return false
        }
        return true
    }

    // MARK: - 곡

    /// 로컬 곡 → 곡 더하기 편집(추가한 곡·스트리밍·USB 곡은 뺀다). 목록이면 그 목록 끝에도 넣는다
    static func addTracksEdit(_ rows: [TrackRow], target: UsbSidebarTarget) -> UsbLibraryEdit? {
        var seen: Set<String> = []
        let ids = rows.filter { !$0.isUsb && !$0.isStaged && !$0.track.isStreaming }.map(\.track.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        switch target {
        case .collection: return .addTracks(localContentIDs: ids, playlist: nil)
        case let .playlist(_, id): return .addTracks(localContentIDs: ids, playlist: .id(String(id)))
        case .pending: return nil
        }
    }

    /// 로컬 곡을 USB 컬렉션·목록에 더한다(초안). 막힐 편집이면 더하지 않고 알린다
    @discardableResult
    func addTracks(_ rows: [TrackRow], to target: UsbSidebarTarget) async -> Bool {
        guard let edit = Self.addTracksEdit(rows, target: target) else { return false }
        return await appendChecked(edit, to: target.volumeKey)
    }

    /// 사이드바 USB 컬렉션·일반 재생 목록에만 곡을 놓는다
    func acceptsDrop(on target: UsbSidebarTarget) -> Bool {
        guard usb.acceptsEdits(target.volumeKey), let library = usb.editLibrary(target.volumeKey) else { return false }
        switch target {
        case .collection: return true
        case let .playlist(_, id): return library.playlists.first { $0.id == id }?.attribute == 0
        case .pending: return false
        }
    }

    /// 사이드바 줄에 놓은 로컬 곡을 더하기 시작한다(놓기 대리자는 기다리지 않는다)
    @discardableResult
    func startDrop(_ ids: [String], on target: UsbSidebarTarget, rows: [String: TrackRow]) -> Task<Void, Never> {
        let actions = self
        return Task { await actions.drop(ids, on: target, rows: rows) }
    }

    /// 끌어다 놓은 곡 ID(로컬 ContentID) → 곡 더하기 초안(편집 › 실행 취소로 뺀다)
    @discardableResult
    func drop(_ ids: [String], on target: UsbSidebarTarget, rows: [String: TrackRow]) async -> Bool {
        guard acceptsDrop(on: target), let edit = Self.addTracksEdit(ids.compactMap { rows[$0] }, target: target) else { return false }
        let name = if case .playlist = target { String(ui: "USB 재생 목록에 넣기") } else { String(ui: "USB 컬렉션에 더하기") }
        return await appendUndoable([edit], to: target.volumeKey, detail: UsbEditText.describe(edit, library: usb.editLibrary(target.volumeKey)),
                                    actionName: name)
    }

    // MARK: - USB 곡 끌어 놓기(#240)

    /// USB 곡을 놓을 수 있는 곳: 같은 USB의 일반 재생 목록. 컬렉션에는 이미 있고, 다른 USB로 옮기는 길은 없다
    func acceptsUsbDrop(from volumeKey: String?, on target: UsbSidebarTarget) -> Bool {
        guard case let .playlist(key, _) = target, key == volumeKey else { return false }
        return acceptsDrop(on: target)
    }

    /// 사이드바 줄에 놓은 USB 곡을 넣기 시작한다(놓기 대리자는 기다리지 않는다)
    func startDropUsbTracks(_ dragged: [UsbTrackDrag], on target: UsbSidebarTarget) {
        let actions = self
        Task { await actions.dropUsbTracks(dragged, on: target) }
    }

    /// 끌어 놓은 USB 곡을 같은 USB의 재생 목록 끝에 넣는다(초안, 편집 › 실행 취소로 뺀다). 이미 든 곡은 초안을 얹은 항목으로 본다
    @discardableResult
    func dropUsbTracks(_ dragged: [UsbTrackDrag], on target: UsbSidebarTarget) async -> Bool {
        guard case let .playlist(key, id) = target, dragged.allSatisfy({ $0.volumeKey == key }), acceptsUsbDrop(from: key, on: target),
              let library = usb.projectedLibrary(key), let playlist = library.playlists.first(where: { $0.id == id }) else { return false }
        let (ids, duplicates) = UsbEditRules.tracksToAdd(dragged.map(\.contentID), current: UsbSyncPlan.entries(of: playlist))
        guard !ids.isEmpty else {
            if duplicates > 0 { warnNotAdded(String(ui: "이미 들어 있는 곡이라 넣지 않았습니다")) }
            return false
        }
        let edit = UsbLibraryEdit.playlist(edit: .addTracks(playlist: .id(String(id)), contentIDs: ids.map(String.init)))
        var detail = UsbEditText.describe(edit, library: library)
        if duplicates > 0 { detail += " · " + String(ui: "이미 들어 있는 \(duplicates)곡은 넣지 않았습니다") }
        return await appendUndoable([edit], to: key, detail: detail, actionName: String(ui: "USB 재생 목록에 넣기"))
    }

    /// USB 목록 안에서 끌어 순서를 바꾼다(초안, 편집 › 실행 취소로 뺀다). 자리는 초안을 얹은 목록 기준이다
    @discardableResult
    func moveEntries(_ dragged: [UsbTrackDrag], before: Int?, volumeKey: String, playlist id: Int) async -> Bool {
        guard usb.acceptsEdits(volumeKey), let library = usb.projectedLibrary(volumeKey),
              let playlist = library.playlists.first(where: { $0.id == id }),
              let edit = UsbEditRules.moveEntriesEdit(UsbTrackDrag.entries(dragged, volumeKey: volumeKey, playlist: id), before: before,
                                                      entries: UsbSyncPlan.entries(of: playlist), playlist: id) else { return false }
        return await appendUndoable([edit], to: volumeKey, detail: UsbEditText.describe(edit, library: library),
                                    actionName: String(ui: "USB 곡 순서 바꾸기"))
    }

    /// 막힐 편집이 아니면 더하고, 편집 › 실행 취소로 그 편집을 빼게 한다(로컬 재생 목록 끌어 놓기와 같다)
    private func appendUndoable(_ edits: [UsbLibraryEdit], to volumeKey: String, detail: String, actionName: String) async -> Bool {
        guard await appendChecked(edits, to: volumeKey, detail: detail) else { return false }
        registerUndoAppend(edits, volumeKey: volumeKey, detail: detail, actionName: actionName)
        return true
    }

    /// 실행 취소 → 더한 편집 빼기. 반대 동작(실행 복귀 = 다시 더하기)은 실행 취소 안에서 바로 건다
    private func registerUndoAppend(_ edits: [UsbLibraryEdit], volumeKey: String, detail: String, actionName: String) {
        let actions = self
        registerUndoStep(actionName) {
            actions.registerRedoAppend(edits, volumeKey: volumeKey, detail: detail, actionName: actionName)
            Task { @MainActor in await actions.removeAppended(edits, volumeKey: volumeKey) }
        }
    }

    private func registerRedoAppend(_ edits: [UsbLibraryEdit], volumeKey: String, detail: String, actionName: String) {
        let actions = self
        registerUndoStep(actionName) {
            actions.registerUndoAppend(edits, volumeKey: volumeKey, detail: detail, actionName: actionName)
            Task { @MainActor in _ = await actions.appendChecked(edits, to: volumeKey, detail: detail) }
        }
    }

    /// 초안을 고친 뒤(비동기) 거는 실행 취소도 한 단계가 되게 따로 묶는다(태그 편집과 같다). 그렇지 않으면 같은 실행 루프 차례에
    /// 걸린 다른 편집과 한 단계로 합쳐진다. 실행 취소·복귀 안에서는 관리자가 묶는다
    private func registerUndoStep(_ actionName: String, _ handler: @escaping @MainActor () -> Void) {
        guard let undoManager = undoManager() else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: usb) { _ in handler() }
        undoManager.setActionName(actionName)
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// 초안 끝의 그 편집을 뺀다. 그 뒤에 다른 편집이 쌓였으면 뒤 편집의 자리가 어긋나므로 빼지 않고 알린다
    private func removeAppended(_ edits: [UsbLibraryEdit], volumeKey: String) async {
        let result = await mutateDraft(volumeKey) { current in
            current.count >= edits.count && Array(current.suffix(edits.count)) == edits ? Array(current.dropLast(edits.count)) : nil
        }
        switch result {
        case .success(nil):
            host.toast = AppToast(kind: .warning, title: String(ui: "실행 취소하지 않았습니다"),
                                  detail: String(ui: "그 뒤에 USB 쓰기 대기가 바뀌었습니다. USB 쓰기 대기에서 편집을 빼세요"), isUsb: true)
        case .success:
            break
        case let .failure(error):
            draftFailed(error)
        }
    }

    /// USB 곡 줄의 content_id(`usb:<볼륨키>:<id>`)
    static func usbContentID(_ row: TrackRow, volumeKey: String) -> Int? {
        let prefix = UsbLibraryRows.idPrefix + volumeKey + ":"
        guard row.track.id.hasPrefix(prefix) else { return nil }
        return Int(row.track.id.dropFirst(prefix.count))
    }

    static func usbContentIDs(_ rows: [TrackRow], volumeKey: String) -> [Int] {
        var seen: Set<Int> = []
        return rows.compactMap { usbContentID($0, volumeKey: volumeKey) }.filter { seen.insert($0).inserted }
    }

    /// USB 곡을 USB에서 뺀다(초안)
    func removeTracks(_ rows: [TrackRow], volumeKey: String) async {
        let ids = Self.usbContentIDs(rows, volumeKey: volumeKey)
        guard !ids.isEmpty else { return }
        await appendChecked(.removeTracks(usbContentIDs: ids), to: volumeKey)
    }

    /// USB 목록에서 고른 항목 → 그 목록에서 빼기 편집(자리와 그 자리의 곡)
    static func removeFromPlaylistEdit(_ rows: [TrackRow], volumeKey: String, playlist: Int) -> UsbLibraryEdit? {
        var seen: Set<Int> = []
        let entries = rows.compactMap { row -> PlaylistEntry? in
            guard let number = row.playlistOccurrence?.number, let id = usbContentID(row, volumeKey: volumeKey), seen.insert(number).inserted else {
                return nil
            }
            return PlaylistEntry(trackNo: number, contentID: String(id))
        }.sorted { $0.trackNo < $1.trackNo }
        return entries.isEmpty ? nil : .playlist(edit: .removeTracks(playlist: .id(String(playlist)), entries: entries))
    }

    func removeFromPlaylist(_ rows: [TrackRow], volumeKey: String, playlist: Int) async {
        guard let edit = Self.removeFromPlaylistEdit(rows, volumeKey: volumeKey, playlist: playlist) else { return }
        await appendChecked(edit, to: volumeKey)
    }

    /// 로컬에서 더 고친 곡(갱신 가능)의 content_id(목록 순서). rows가 있으면 그 줄만 본다
    func updatableTracks(volumeKey: String, rows: [TrackRow]? = nil) -> [Int] {
        let badges = usb.syncBadges[volumeKey] ?? [:]
        let candidates = rows.map { Self.usbContentIDs($0, volumeKey: volumeKey) } ?? (usb.editLibrary(volumeKey)?.tracks.map(\.id) ?? [])
        return candidates.filter { if case .localNewer? = badges[$0] { true } else { false } }
    }

    /// 로컬에서 더 고친 필드 → 갱신할 부분(곡 정보는 그림과 함께)
    static func refreshParts(_ fields: Set<UsbSyncStatus.Field>) -> Set<UsbRefreshPart> {
        var parts: Set<UsbRefreshPart> = []
        if fields.contains(.information) { parts.formUnion([.info, .artwork]) }
        if fields.contains(.analysis) { parts.insert(.grid) }
        if fields.contains(.cue) { parts.insert(.cues) }
        return parts
    }

    /// 로컬 변경 반영 편집: 갱신 가능한 곡을 곡마다 로컬에서 바뀐 부분으로 묶는다(바뀐 부분이 같은 곡끼리 편집 하나, 처음 나온 차례,
    /// 묶음 안은 목록 순서). 다른 곡 때문에 바뀌지 않은 부분까지 다시 쓰거나, 그 부분 때문에 곡이 막히지 않게
    func refreshEdits(volumeKey: String, rows: [TrackRow]? = nil) -> [UsbLibraryEdit] {
        let badges = usb.syncBadges[volumeKey] ?? [:]
        var groups: [(parts: Set<UsbRefreshPart>, ids: [Int])] = []
        for id in updatableTracks(volumeKey: volumeKey, rows: rows) {
            guard case let .localNewer(changed)? = badges[id] else { continue }
            let parts = Self.refreshParts(changed)
            if let index = groups.firstIndex(where: { $0.parts == parts }) { groups[index].ids.append(id) } else { groups.append((parts, [id])) }
        }
        return groups.map { .refreshTracks(usbContentIDs: $0.ids, parts: $0.parts) }
    }

    /// 로컬 변경 반영이 막힐 까닭(메뉴 옆 도움말)
    func refreshBlockReason(volumeKey: String, rows: [TrackRow]? = nil) -> String? {
        refreshEdits(volumeKey: volumeKey, rows: rows).lazy.compactMap { blockReason($0, volumeKey: volumeKey) }.first
    }

    /// 로컬 변경을 USB에 반영(초안): 갱신 가능한 곡만, 곡마다 로컬에서 바뀐 부분만. 기기에서 고친 곡·로컬에 없는 곡은 건드리지 않는다
    func refreshLocalChanges(volumeKey: String, rows: [TrackRow]? = nil) async {
        let edits = refreshEdits(volumeKey: volumeKey, rows: rows)
        guard !edits.isEmpty else {
            host.toast = AppToast(kind: .success, title: Text.nothingNewerTitle, detail: usb.editName(volumeKey), isUsb: true)
            return
        }
        let ids = edits.flatMap { edit -> [Int] in if case let .refreshTracks(ids, _) = edit { ids } else { [] } }
        await appendChecked(edits, to: volumeKey, detail: UsbEditText.describe(.refreshTracks(usbContentIDs: ids, parts: []), library: nil))
    }

    // MARK: - 재생 목록

    /// 새 목록·폴더(이름 창). parent가 nil이면 맨 위
    func createPlaylist(isFolder: Bool, parent: Int?, volumeKey: String) async {
        let name = usb.editName(volumeKey) ?? "USB"
        let title = isFolder ? String(ui: "\(name)에 새 폴더") : String(ui: "\(name)에 새 재생 목록")
        guard let entered = namePrompter.askName(title: title, text: String(ui: "USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."),
                                                 initial: isFolder ? String(ui: "새 폴더") : String(ui: "새 재생 목록"),
                                                 confirm: String(ui: "만들기")) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await appendChecked(.playlist(edit: .create(key: newKey(), name: trimmed, isFolder: isFolder,
                                                    parent: parent.map { .id(String($0)) } ?? .root)), to: volumeKey)
    }

    func renamePlaylist(_ id: Int, volumeKey: String) async {
        guard let playlist = usb.editLibrary(volumeKey)?.playlists.first(where: { $0.id == id }),
              let entered = namePrompter.askName(title: String(ui: "재생 목록 이름 바꾸기"),
                                                 text: String(ui: "USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."),
                                                 initial: playlist.name, confirm: String(ui: "이름 바꾸기")) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        await appendChecked(.playlist(edit: .rename(playlist: .id(String(id)), name: trimmed)), to: volumeKey)
    }

    func deletePlaylist(_ id: Int, volumeKey: String) async {
        await appendChecked(.playlist(edit: .delete(playlist: .id(String(id)))), to: volumeKey)
    }

    /// 같은 부모 안에서 사이드바 순서의 자리(0부터)와 형제 수. 초안의 목록 편집을 적용한 자리다(초안에서 지운 목록이면 nil)
    func siblingPosition(_ id: Int, volumeKey: String) -> (index: Int, count: Int)? {
        let ref = PlaylistRef.id(String(id))
        guard let library = usb.editLibrary(volumeKey),
              let siblings = UsbEditRules.siblingOrder(of: ref, library: library, edits: usb.draftEdits[volumeKey] ?? []),
              let index = siblings.firstIndex(of: ref) else { return nil }
        return (index, siblings.count)
    }

    func canMovePlaylist(_ id: Int, by step: Int, volumeKey: String) -> Bool {
        guard let position = siblingPosition(id, volumeKey: volumeKey) else { return false }
        return (0..<position.count).contains(position.index + step)
    }

    /// 한 칸 옮기기가 막힐 까닭(볼륨·대상). 옮길 자리가 있는지는 `canMovePlaylist`가 본다
    func moveBlockReason(_ id: Int, by step: Int, volumeKey: String) -> String? {
        let index = siblingPosition(id, volumeKey: volumeKey).map { $0.index + step } ?? 0
        return blockReason(.playlist(edit: .reorder(playlist: .id(String(id)), index: index)), volumeKey: volumeKey)
    }

    /// 같은 부모 안에서 한 칸 올리거나 내린다(초안)
    func movePlaylist(_ id: Int, by step: Int, volumeKey: String) async {
        guard usb.acceptsEdits(volumeKey), let library = usb.editLibrary(volumeKey), canMovePlaylist(id, by: step, volumeKey: volumeKey) else { return }
        if let reason = moveBlockReason(id, by: step, volumeKey: volumeKey) {
            warnNotAdded(reason)
            return
        }
        let name = usb.editName(volumeKey) ?? "USB"
        switch await mutateDraft(volumeKey, { UsbEditRules.movedDraft($0, playlist: id, by: step, library: library) }) {
        case let .success(change?):
            let created = UsbEditText.createdNames(change.after)
            if change.after.count < change.before.count {
                let playlist = library.playlists.first { $0.id == id }?.name ?? String(ui: "재생 목록 \(String(id))")
                host.toast = AppToast(kind: .success, title: Text.removedFromQueueTitle,
                                      detail: String(ui: "\(name) · ‘\(playlist)’ 순서를 처음대로 돌렸습니다"), isUsb: true)
            } else if let last = change.after.last {
                let detail = "\(name) · \(UsbEditText.describe(last, library: library, created: created))"
                host.toast = AppToast(kind: .success, title: change.after.count > change.before.count ? Text.appendedTitle
                                          : Text.changedQueueTitle, detail: detail, isUsb: true)
            }
        case .success(nil):
            break
        case let .failure(error):
            draftFailed(error)
        }
    }
}

extension LibraryStore {
    /// USB 목록에서 고른 줄(표 순서, 같은 곡이 목록에 여러 번 있으면 줄마다)
    var selectedUsbRows: [TrackRow] { displayRows.filter { $0.isUsb && selection.contains($0.id) } }

    /// 끌어서 곡 순서를 바꿀 수 있는 USB 목록(#240): 로컬 목록처럼 # 순으로 보고 검색으로 거르지 않을 때, 초안을 받는 일반 목록이고
    /// 초안을 얹은 항목을 정할 수 있을 때(쓰기 전에는 곡 번호를 모르는 로컬 곡 넣기 초안이 있으면 아니다)
    var usbReorderPlaylist: (volumeKey: String, id: Int)? {
        guard case let .usb(.playlist(key, id)) = sidebar, sortOrder.isEmpty, search.trimmingCharacters(in: .whitespaces).isEmpty,
              let usb, let actions = usbEdits, actions.acceptsDrop(on: .playlist(volumeKey: key, id: id)),
              let library = usb.editLibrary(key), let playlist = library.playlists.first(where: { $0.id == id }),
              UsbDraftProjection.entries(of: playlist, library: library, edits: usb.draftEdits[key] ?? []) != nil else { return nil }
        return (key, id)
    }
}
