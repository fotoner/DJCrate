import DJCApplication
import DJCDomain
import SwiftUI

enum LibraryMenuAction: CaseIterable {
    case addFiles, importAppleMusic, snapshot, exportXML, exportLibraryXML, importRekordboxXML, reflect, pending, activityLog, restore, pointSnapshots, removeTracks, find, integrationGuide

    static let fileActions: [Self] = [.addFiles, .importAppleMusic, .snapshot, .exportXML, .exportLibraryXML, .importRekordboxXML]
    static let rekordboxActions: [Self] = [.reflect, .pending, .activityLog, .restore, .pointSnapshots, .removeTracks]
    static let editActions: [Self] = [.find]
    /// 도움말 메뉴의 항목. 연동 안내(#315)는 이 메뉴에만 있다. 저장 전으로 복원은 rekordbox 메뉴 항목을 다시 보인다:
    /// 툴바 쓰기 메뉴가 없어진 뒤(#325) 문제가 생긴 사용자가 복원 입구를 한 곳 더 찾을 수 있게 한다.
    /// 같은 항목을 그대로 부르므로 이름·켜짐 조건·꺼진 이유가 rekordbox 메뉴와 같다.
    static let helpActions: [Self] = [.integrationGuide, .restore]

    var title: String {
        switch self {
        case .addFiles: String(ui: "곡 추가…")
        case .importAppleMusic: String(ui: "Apple Music XML 가져오기…")
        case .snapshot: String(ui: "rekordbox와 동기화")
        case .exportXML: String(ui: "XML 만들기")
        // 연동 파일을 만드는 "XML 만들기"와 달리 라이브러리 전체를 고른 파일로 내보낸다(저장 위치를 고르므로 …).
        case .exportLibraryXML: String(ui: "라이브러리 XML 내보내기…")
        // 다른 도구가 만든 rekordbox XML과의 차이를 보고 고른 것만 초안으로 만든다(#72, 열기 창을 여므로 …).
        case .importRekordboxXML: String(ui: "rekordbox XML 가져오기…")
        case .reflect: String(ui: "rekordbox에 저장")
        case .pending: String(ui: "저장 대기 목록 보기")
        case .activityLog: String(ui: "활동 기록…")
        case .restore: String(ui: "저장 전으로 복원…")
        // 라이브러리 읽기 사본(스냅샷)과 달리 DB·분석 파일·앨범아트를 한 시점으로 남기고 되돌린다(#224).
        case .pointSnapshots: String(ui: "복원 시점…")
        case .removeTracks: String(ui: "rekordbox에서 빼기…")
        case .find: String(ui: "찾기")
        // rekordbox·Apple Music과 이어 쓰는 절차를 한 창에 모았다. 처음 한 번만 뜨던 안내를 언제든 다시 연다(#315)
        case .integrationGuide: String(ui: "연동 안내")
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .addFiles: KeyboardShortcut("o", modifiers: .command)
        case .snapshot: KeyboardShortcut("r", modifiers: .command)
        case .reflect: KeyboardShortcut("s", modifiers: .command)
        case .find: KeyboardShortcut("f", modifiers: .command)
        default: nil
        }
    }

    @MainActor func menuTitle(in window: LibraryWindowModel) -> String { title }

    /// rekordbox 라이브러리에 쓰는 동작(막힌 초안 비교 창이 열려 있는 동안은 막는다, #232)
    private var writesLibrary: Bool { self == .reflect || self == .restore || self == .removeTracks }

    /// 쓰는 동안 이 항목을 막는 잠금. 화면만 옮기는 항목(쓰기 대기 목록·활동 기록)은 편집 잠금, 읽기·쓰기·가져오기는 라이브러리 내부 배타를 따른다.
    @MainActor private func isLocked(by store: LibraryStore) -> Bool {
        switch self {
        case .pending, .activityLog: store.editsFrozen
        // 읽기만 하는 안내 창이라 읽는 동안·쓰는 동안에도 연다
        case .integrationGuide: false
        default: store.libraryBusy
        }
    }

    /// 메뉴 막대·툴바는 주 창 모델로 메뉴 항목을 보고 부른다. 판정은 공유 핵심의 값을, XML 가져오기는 주 창 모델이 든 가져오기를 본다
    @MainActor func isEnabled(in window: LibraryWindowModel) -> Bool {
        let store = window.store
        // 엔진이 있으면 ⌘S는 R3 표의 줄이 정한다(쓰는 중·이유를 보이는 줄에서도 켜 둔다)
        if self == .reflect, let row = window.saveRow { return Self.reflectEnabled(row, in: window) }
        guard !isLocked(by: store) else { return false }
        if writesLibrary, store.writesBlockedBySheet { return false }
        switch self {
        case .addFiles: return !store.rows.isEmpty
        case .importAppleMusic: return !store.isLoading
        case .snapshot: return store.canSynchronizeLibrary
        case .exportXML: return store.sidebar == .staged ? !store.staging.staged.isEmpty : !store.reflectionTargets.isEmpty
        case .exportLibraryXML:
            guard case .loaded = store.phase else { return false }
            return store.snapshotURL != nil && !store.isLoading && !store.staging.hasXMLExportJob
        case .importRekordboxXML:
            guard case .loaded = store.phase else { return false }
            return store.snapshotURL != nil && !store.isLoading && !window.xmlImport.isBusy
        case .reflect: return store.pendingLibraryCount > 0 || store.playlists.hasPlaylistDrafts || store.history.hasHistoryDrafts
        case .pending, .activityLog, .integrationGuide: return true
        case .restore: return store.hasWriteBackup
        case .pointSnapshots: return true
        case .removeTracks: return !store.deleteTargets(store.selectedRows).isEmpty
        case .find:
            // 머리 줄 검색칸이 있는 화면: 목록을 읽은 뒤 검색이 걸리는 목록. 쓰는 동안은 위의 잠금이 막는다
            guard case .loaded = store.phase else { return false }
            return store.listIsSearchable
        }
    }

    /// - Parameters:
    ///   - windows: 창을 여는 항목(Apple Music 가져오기·시점 스냅샷)이 쓸 앱 창. 메뉴 막대는 늘 준다.
    ///   - reflection: rekordbox 쓰기 항목(쓰기·복원·빼기·시점 스냅샷)이 부를 화면 쪽. 없으면(조립 지점 없이 띄운 화면) 그 항목은 아무것도 하지 않는다.
    @MainActor func perform(in window: LibraryWindowModel, windows: AppWindows? = nil, reflection: ReflectionCoordinator? = nil) {
        let store = window.store
        if self == .reflect, let row = window.saveRow { Self.performReflect(row, in: window, reflection: reflection); return }
        if writesLibrary, store.writesBlockedBySheet { store.announceWritesBlockedBySheet(); return }
        guard isEnabled(in: window) else {
            if let reason = disabledReason(in: window) { store.showToast(.notice(text: reason, kind: .warning)) }
            return
        }
        switch self {
        case .addFiles: StagingPanels.chooseFiles(store: store)
        case .importAppleMusic: windows?.appleMusicImport.open(store: store)
        case .snapshot: window.startSynchronizeLibrary()
        case .exportXML:
            if store.sidebar == .staged { StagingPanels.exportXML(store: store) }
            else { ReflectionPanels.export(store: store, rows: store.reflectionPreviewRows) }
        case .exportLibraryXML: LibraryXMLPanels.export(store: store)
        case .importRekordboxXML: LibraryXMLPanels.importXML(into: window.xmlImport)
        case .reflect: reflection?.startWrite(rows: store.reflectionPreviewRows)
        case .pending: store.sidebar = .pending
        case .activityLog: window.showActivityLog()
        case .restore: reflection?.startRestoreLatest()
        case .pointSnapshots: if let reflection { windows?.pointSnapshots.open(store: store, reflection: reflection) }
        case .removeTracks: reflection?.startDeleteTracks(rows: store.selectedRows)
        case .find: window.focusSearch()
        case .integrationGuide: store.showIntegrationGuide?(.rekordbox)
        }
    }

    // MARK: - ⌘S(R3 표)

    static var noEditsReason: String { String(ui: "저장할 편집이 없으니 곡을 편집하거나 재생 목록 편집을 먼저 만드세요") }

    /// 저장할 편집이 있다(곡·재생 목록·재생 기록)
    @MainActor private static func hasSavable(_ store: LibraryStore) -> Bool {
        store.pendingLibraryCount > 0 || store.playlists.hasPlaylistDrafts || store.history.hasHistoryDrafts
    }

    /// 줄마다 ⌘S가 켜지는 때. 쓰지 않고 이유를 보이는 줄(1~3)은 눌러도 아무 일이 없으면 안 되니 켜 둔다.
    /// 4번 줄은 입력 중인 칸이 있을 때만 켜진다(R19). 쓰는 중(5번 줄)은 대기열 맨 앞에 넣으므로 켜 두되 이미 수동 저장이 도는 중이면 끈다
    @MainActor private static func reflectEnabled(_ row: ReflectionStatusRow, in window: LibraryWindowModel) -> Bool {
        let store = window.store
        switch row.saveCommand {
        case .restoreOnly, .refuseWithReason: return true
        case .commitFieldThenFollow: return window.isEditingInput
        case .queueFront: return store.writeTask == nil
        case .saveNow, .saveAndResume, .saveAllLeftovers, .saveNowIfAllowed:
            // 막힌 초안 비교 창이 열려 있으면 눌러서 이유를 본다(`perform`이 알린다)
            if store.writesBlockedBySheet { return true }
            return !store.libraryBusy && (hasSavable(store) || window.isEditingInput)
        }
    }

    /// ⌘S: 입력 중인 칸을 확정한 뒤(R19) 줄이 정한 일을 한다. 저장하는 줄은 `ReflectionCoordinator.startWrite`가 확인 창·관문까지 간다
    @MainActor private static func performReflect(_ row: ReflectionStatusRow, in window: LibraryWindowModel, reflection: ReflectionCoordinator?) {
        let store = window.store
        guard reflectEnabled(row, in: window) else {
            store.showToast(.notice(text: noEditsReason, kind: .warning))
            return
        }
        guard let conditions = window.autoFeed?.conditions else { return }
        let typing = window.isEditingInput
        if typing { window.fieldEditing.commit() }
        func follow() {
            switch row.saveCommand {
            case .restoreOnly:
                store.showToast(.notice(text: String(ui: "이 라이브러리에 끝나지 않은 저장 기록이 남아 있어 저장하지 않았습니다. DJCrate 상태 줄에서 기록으로 복원하거나 이대로 두세요"),
                                        kind: .warning))
            case .refuseWithReason:
                refuse(row, conditions, in: window)
            case .commitFieldThenFollow, .queueFront, .saveNow, .saveAndResume, .saveAllLeftovers, .saveNowIfAllowed:
                // 입력 확정이 만든 편집까지 본다: 저장할 것이 없으면 쓰기를 시작하지 않고 이유를 보인다(막힌 초안 창·쓰는 중은 입구가 알린다)
                guard row == .writing || store.writesBlockedBySheet || hasSavable(store) else {
                    store.showToast(.notice(text: noEditsReason, kind: .warning))
                    return
                }
                reflection?.startWrite(rows: store.reflectionPreviewRows)
            }
        }
        // 포커스를 잃은 뒤에 값을 넣는 칸(SwiftUI 입력 칸)은 다음 갱신에서 확정한다: 입력을 확정한 경우 저장할 편집이 보일 때까지 잠깐 기다린 뒤 이어 간다.
        // AppKit 칸(곡 목록·태그 시트)은 확정이 바로 끝나 기다리지 않는다
        guard typing, row != .interrupted, row != .unwritable, row != .busy else { return follow() }
        Task { @MainActor in
            for _ in 0..<20 where !hasSavable(store) { try? await Task.sleep(for: .milliseconds(10)) }
            follow()
        }
    }

    /// 쓰지 않고 이유를 보인다(R3 2·3번 줄): 종료 중·쓸 수 없음·켜짐·시트·USB·정리 못 마침
    @MainActor private static func refuse(_ row: ReflectionStatusRow, _ conditions: ReflectionConditions, in window: LibraryWindowModel) {
        let store = window.store
        if let refusal = store.writeRefusal {
            store.showToast(.notice(refusal, nil))
        } else if row == .unwritable {
            let text = ReflectionStatusText.line(status: .saved, conditions: conditions, row: row, count: PendingWriteCount(items: 0, playlistEdits: 0),
                                                 showsWriting: false).help
            store.showToast(.notice(text: text ?? noEditsReason, kind: .warning))
        } else if ReflectionStatusText.topBusyHold(conditions) == .blockedDraftsOpen {
            store.announceWritesBlockedBySheet()
        } else if let refusal = ReflectionStatusText.refusal(conditions) {
            store.showToast(.notice(refusal.title, refusal.detail))
        }
    }

    @MainActor func disabledReason(in window: LibraryWindowModel) -> String? {
        guard !isEnabled(in: window) else { return nil }
        let store = window.store
        if isLocked(by: store) { return String(ui: "rekordbox 저장이 끝난 뒤 다시 시도하세요") }
        if writesLibrary, store.writesBlockedBySheet { return LibraryStore.writesBlockedBySheetReason }
        switch self {
        case .snapshot:
            if store.isLoading || store.isSynchronizingLibrary { return String(ui: "라이브러리 읽기가 끝난 뒤 다시 동기화하세요") }
            return String(ui: "덱의 큐 입력을 확정하고 끌기를 마친 뒤 동기화하세요")
        case .removeTracks:
            if store.isITunesSelection { return String(ui: "iTunes 동기화 목록에서는 곡을 뺄 수 없으니 rekordbox 컬렉션에서 곡을 고르세요") }
            return String(ui: "rekordbox 컬렉션에서 뺄 로컬 곡을 목록에서 고르세요")
        case .reflect: return Self.noEditsReason
        case .exportXML: return String(ui: "XML로 넘길 추가한 곡이나 큐·그리드 편집을 먼저 만드세요")
        case .exportLibraryXML:
            return store.staging.hasXMLExportJob ? String(ui: "라이브러리 XML 내보내기가 끝난 뒤 다시 시도하세요") : String(ui: "라이브러리를 먼저 불러온 뒤 내보내세요")
        case .importRekordboxXML:
            return window.xmlImport.isBusy
                ? String(ui: "지금 가져오는 XML이 끝난 뒤 다시 시도하세요") : String(ui: "라이브러리를 먼저 불러온 뒤 가져오세요")
        case .restore: return String(ui: "저장 전 백업이 없으니 활동 기록을 확인하세요")
        case .addFiles, .importAppleMusic: return String(ui: "라이브러리를 먼저 불러온 뒤 곡을 추가하세요")
        case .find:
            guard case .loaded = store.phase else { return String(ui: "라이브러리를 먼저 불러온 뒤 검색하세요") }
            return String(ui: "USB 쓰기 대기에는 검색할 곡이 없으니 곡 목록을 고르세요")
        case .pending, .activityLog, .pointSnapshots, .integrationGuide: return nil
        }
    }
}
