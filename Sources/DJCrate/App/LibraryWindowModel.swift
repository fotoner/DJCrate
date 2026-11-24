import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 주 창(`ContentView`)의 화면 모델(#254): 주 창이 띄우는 시트(활동 기록·연결되지 않은 초안·rekordbox XML 가져오기)와
/// 주 창의 단추·알림·끌어 놓기·메뉴가 부르는 입구(MVVM-4). 입구는 핵심의 비동기 일을 시작만 하고 기다리지 않는다.
/// 단추의 `Task {}`처럼 화면이 사라져도 취소하지 않는다. 돌려주는 손잡이는 시험이 기다린다.
/// 상태는 공유 핵심(`LibraryStore`)에 있다. 이 모델은 주 창만 쓰는 시트 상태만 든다. 다른 화면 모델·기능 조각이 여는 시트
/// (재생 목록 고르기·USB·막힌 초안 복구)는 그 주인이 든다. 조립 지점(`AppComposition.libraryWindow`)이 한 번 만든다.
@MainActor
@Observable
final class LibraryWindowModel {
    /// 공유 핵심. 입구는 핵심의 일을 시작한다
    @ObservationIgnored let store: LibraryStore
    /// rekordbox XML 가져오기(읽는 중·미리 보기 시트·결과). 메뉴가 읽는 중인지 보므로 시트를 닫아도 남는다
    @ObservationIgnored let xmlImport: XMLImportModel
    /// 활동 기록 시트의 화면 모델(알림의 결과 보기·메뉴·사이드바 줄이 띄운다. 띄울 때마다 새로 만든다)
    var activityLog: ActivityLogModel? { didSet { activityLogSeen() } }
    /// 활동 기록 시트를 열고 닫을 때 부른다. 시트가 모든 알림을 보이므로 상태 줄이 그때까지의 알림을 읽음으로 본다(조립 지점이 잇는다)
    @ObservationIgnored var activityLogSeen: () -> Void = {}
    /// 연결되지 않은 초안 시트의 화면 모델(띄울 때마다 새로 만든다)
    var unlinkedDrafts: UnlinkedDraftsModel?
    /// 켤 때 알림의 "모두 갱신"이 부르는 AI 에이전트 설치 모델(조립 지점이 붙인다. 시험은 nil)
    @ObservationIgnored var agentTools: AgentToolsSettingsModel?
    /// 자동 저장 엔진이 알린 상태(엔진이 있는 조립만 붙인다). nil이면 ⌘S·상태 줄이 지금 동작 그대로다(저장 대기가 있으면 저장, #404)
    @ObservationIgnored var autoFeed: AutoReflectionFeed?
    /// 입력 중인 칸(Return 전)과 그 확정(R19). 조립 지점이 실제 것을 붙인다(화면 시험은 바꿔 끼운다)
    @ObservationIgnored var fieldEditing = FieldEditingState()

    init(store: LibraryStore) {
        self.store = store
        xmlImport = XMLImportModel(store: store)
    }

    // MARK: - 저장(R3 표)

    /// 앱이 지금 아는 저장 막힘 사유(가져오기 시트·막힌 초안 비교 창·USB 쓰기). 엔진이 알린 조건은 다음 발행까지 낡을 수 있어 저장 입구가 다시 본다
    @ObservationIgnored var liveHolds: @MainActor () -> Set<ReflectionHold> = { [] }

    /// 저장 단추·⌘S·상태 줄이 보는 조건: 엔진이 알린 조건에 앱이 지금 아는 막힘 사유를 더한다(S3). 엔진이 없는 조립은 nil이다
    var saveConditions: ReflectionConditions? {
        guard let feed = autoFeed else { return nil }
        var conditions = feed.conditions
        conditions.holds.formUnion(liveHolds())
        return conditions
    }

    /// R3 표에서 지금 드는 줄. 엔진이 없는 조립은 nil이다
    var saveRow: ReflectionStatusRow? { saveConditions.map { ReflectionStatusRow.first($0) } }

    /// 저장 단추가 보이는 줄인가(R3 표). 엔진이 없는 조립은 지금처럼 늘 보인다
    var showsSaveButton: Bool { saveRow?.showsSaveButton ?? true }

    /// 입력 중인 칸이 있다(R19): 칸에 글자를 치는 중이거나 엔진이 편집 중으로 알렸다
    var isEditingInput: Bool { fieldEditing.isEditing || autoFeed?.conditions.editingField == true }

    // MARK: - 시트

    /// 활동 기록을 연다. 알림의 결과 보기는 그 알림의 항목을 고른다(없으면 맨 위 항목)
    func showActivityLog(selecting entry: ActivityEntry.ID? = nil) {
        activityLog = ActivityLogModel(log: store.activityLog, selection: entry)
    }

    func openUnlinkedDrafts() { unlinkedDrafts = UnlinkedDraftsModel(store: store) }

    // MARK: - 검색칸

    /// 편집 › 찾기(⌘F)가 올리는 검색칸 포커스 요청 번호. 머리 줄 검색칸(잎 뷰)만 읽고, 번호가 바뀌면 칸으로 포커스를 옮긴다.
    /// 칸이 없는 화면에서는 메뉴가 꺼져 있어 요청이 오지 않는다(`LibraryMenuAction.find`)
    private(set) var searchFocusRequest = 0

    func focusSearch() { searchFocusRequest += 1 }

    // MARK: - 입구

    @discardableResult
    func startLoadInitial() -> Task<Void, Never> { Task { [store] in await store.loadInitial() } }

    /// 읽기 실패 화면의 [다시 시도]
    @discardableResult
    func startRetryLoad() -> Task<Void, Never> { Task { [store] in await store.retryLoad() } }

    @discardableResult
    func startSynchronizeLibrary() -> Task<Void, Never> { Task { [store] in await store.synchronizeLibrary() } }

    @discardableResult
    func startRefreshIfRekordboxChanged() -> Task<Void, Never> { Task { [store] in await store.refreshIfRekordboxChanged() } }

    /// 알림의 단추(USB 꺼내기 등)
    @discardableResult
    func performToastAction(_ action: AppToast.Action) -> Task<Void, Never> {
        switch action {
        case .updateAgentTools:
            Task { [store, agentTools] in
                if let toast = store.toast, toast.action == action { store.dismissToast(toast.id) }
                guard let agentTools else { return }
                store.showToast(await agentTools.updateAllFromNotice())
            }
        case .ejectUsb:
            Task { [store] in await store.usbCoordinator?.perform(action) }
        case let .openIntegrationGuide(topic):
            Task { [store] in store.showIntegrationGuide?(topic) }
        }
    }

    // MARK: - 파일 끌어 놓기

    /// 창에 음원 파일을 놓을 수 있는지. 쓰는 중이거나 읽기 전용 목록(iTunes·USB)을 보는 중이면 받지 않는다
    var acceptsFileDrop: Bool {
        !store.libraryBusy && !store.isITunesSelection && !store.isUsbSelection
    }

    /// 창에 끌어다 놓은 파일을 읽어 추가한 곡에 넣는다. 읽는 사이 rekordbox 쓰기가 시작되면 넣지 않는다.
    @discardableResult
    func addDroppedFiles(_ providers: [NSItemProvider]) -> Task<Void, Never> {
        Task { [store] in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard !urls.isEmpty, !store.libraryBusy else { return }
            await store.staging.addFiles(urls)
        }
    }
}
