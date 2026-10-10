import Foundation

/// 뷰의 단추·메뉴·알림·끌어 놓기가 부르는 동기 입구(MVVM-4, #244). 저장소의 비동기 일을 시작만 하고 기다리지 않는다.
/// 단추의 `Task {}`와 같이 화면이 사라져도 취소하지 않는다. 돌려주는 손잡이는 시험이 기다린다.
extension LibraryStore {
    @discardableResult
    func startLoadInitial() -> Task<Void, Never> { Task { await loadInitial() } }

    @discardableResult
    func startTakeSnapshot(force: Bool = false) -> Task<Void, Never> { Task { await takeSnapshot(force: force) } }

    @discardableResult
    func startSynchronizeLibrary() -> Task<Void, Never> { Task { await synchronizeLibrary() } }

    @discardableResult
    func startRefreshIfRekordboxChanged() -> Task<Void, Never> { Task { await refreshIfRekordboxChanged() } }

    @discardableResult
    func startRefreshITunesPlaylists() -> Task<Void, Never> { Task { await refreshITunesPlaylists() } }

    @discardableResult
    func startAddingFiles(_ urls: [URL], toPlaylist playlistID: String) -> Task<Void, Never> {
        Task { await addFiles(urls, toPlaylist: playlistID) }
    }

    /// 창에 끌어다 놓은 파일을 읽어 추가한 곡에 넣는다. 읽는 사이 rekordbox 쓰기가 시작되면 넣지 않는다.
    @discardableResult
    func addDroppedFiles(_ providers: [NSItemProvider]) -> Task<Void, Never> {
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard !urls.isEmpty, writeLockPolicy.allowsLibraryInteraction else { return }
            await addFiles(urls)
        }
    }

    /// 알림의 단추(USB 꺼내기 등)
    @discardableResult
    func performToastAction(_ action: AppToast.Action) -> Task<Void, Never> { Task { await usbCoordinator?.perform(action) } }

    /// 사이드바 USB 줄의 '로컬 변경을 USB에 반영'
    @discardableResult
    func startRefreshUsbLocalChanges(volumeKey: String) -> Task<Void, Never> {
        Task { await usbEdits?.refreshLocalChanges(volumeKey: volumeKey) }
    }
}
