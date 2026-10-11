import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 주 창(`ContentView`)의 화면 모델(#254): 주 창이 띄우는 시트(쓰기 결과·연결되지 않은 초안·rekordbox XML 가져오기)와
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
    /// 마지막 쓰기 결과 시트(알림의 '자세히'·메뉴·사이드바 줄이 띄운다)
    var showingWriteResult = false
    /// 연결되지 않은 초안 시트의 화면 모델(띄울 때마다 새로 만든다)
    var unlinkedDrafts: UnlinkedDraftsModel?

    init(store: LibraryStore) {
        self.store = store
        xmlImport = XMLImportModel(store: store)
    }

    // MARK: - 시트

    func showWriteResult() { showingWriteResult = true }

    func openUnlinkedDrafts() { unlinkedDrafts = UnlinkedDraftsModel(store: store) }

    // MARK: - 입구

    @discardableResult
    func startLoadInitial() -> Task<Void, Never> { Task { [store] in await store.loadInitial() } }

    @discardableResult
    func startTakeSnapshot(force: Bool = false) -> Task<Void, Never> { Task { [store] in await store.takeSnapshot(force: force) } }

    @discardableResult
    func startSynchronizeLibrary() -> Task<Void, Never> { Task { [store] in await store.synchronizeLibrary() } }

    @discardableResult
    func startRefreshIfRekordboxChanged() -> Task<Void, Never> { Task { [store] in await store.refreshIfRekordboxChanged() } }

    /// 알림의 단추(USB 꺼내기 등)
    @discardableResult
    func performToastAction(_ action: AppToast.Action) -> Task<Void, Never> { Task { [store] in await store.usbCoordinator?.perform(action) } }

    // MARK: - 파일 끌어 놓기

    /// 창에 음원 파일을 놓을 수 있는지. 쓰는 중이거나 읽기 전용 목록(iTunes·USB)을 보는 중이면 받지 않는다
    var acceptsFileDrop: Bool {
        store.writeLockPolicy.allowsLibraryInteraction && !store.isITunesSelection && !store.isUsbSelection
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
            guard !urls.isEmpty, store.writeLockPolicy.allowsLibraryInteraction else { return }
            await store.staging.addFiles(urls)
        }
    }
}
