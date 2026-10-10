import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    struct ITunesSyncCatalogCache {
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let contents: ITunesLibrarySnapshot
    }
    struct ITunesSyncCapture {
        let id: UUID
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let task: Task<ITunesLibrarySnapshot, Never>
    }

    /// 선택 창을 처음 열 때의 선택(동기화 원문에서 맨 위를 골랐는지 유스케이스가 본다)
    func iTunesInitialSelection(of source: ITunesLibrarySnapshot) -> ITunesSyncSelection {
        useCases.load.initialSelection(of: source)
    }

    func presentITunesSync() {
        iTunesSync = ITunesSyncModel()
        showingITunesSync = true
    }

    /// 사본 실행에서는 Music에 접근하지 않고 함께 캡처한 전체 목록만 쓴다.
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func iTunesSyncSource(forceRefresh: Bool = false,
                          captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async -> ITunesLibrarySnapshot {
        if location.opensExplicitCopy || !location.mayCaptureMusic {
            return iTunesSnapshot
        }
        guard let snapshot = snapshotURL else { return ITunesLibrarySnapshot(status: .unavailable) }
        let revision = previewRevision
        let epoch = iTunesSyncCatalogEpoch
        let sourceDirectory = snapshot.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory)
            ? location.rekordboxDirectory : snapshot.deletingLastPathComponent()
        let loader = useCases.load

        if !forceRefresh {
            if let cached = iTunesSyncCatalogCache, cached.snapshot == snapshot, cached.revision == revision,
               cached.epoch == epoch,
               cached.sourceDirectory == sourceDirectory,
               loader.isCurrentCatalog(cached.contents, directory: sourceDirectory) {
                return cached.contents
            }
            if loader.isCurrentCatalog(iTunesSnapshot, directory: sourceDirectory) {
                return iTunesSnapshot
            }
        }

        // 뒤에서 도는 최신화가 같은 DB의 Music 전체 목록을 이미 읽는 중이면 그 결과를 함께 쓴다.
        if let refresh = currentITunesRefresh(snapshot: snapshot, revision: revision) {
            await refresh.value
            guard snapshotURL == snapshot, previewRevision == revision else {
                return ITunesLibrarySnapshot(status: .unavailable)
            }
            return iTunesSnapshot
        }

        // 쓸 수 있는 캐시가 없을 때만 진행 중인 Music 읽기를 함께 기다린다.
        if let pending = iTunesSyncCapture, pending.snapshot == snapshot, pending.revision == revision,
           pending.epoch == epoch, pending.sourceDirectory == sourceDirectory {
            let captured = await pending.task.value
            return currentITunesCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                                     epoch: epoch, directory: sourceDirectory) ?? captured
        }

        let id = UUID()
        let task = Task(priority: .userInitiated) {
            (try? await LoadLibrary.background { loader.captureCatalog(captureITunes) }) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        iTunesSyncCapture = .init(id: id, snapshot: snapshot, revision: revision, epoch: epoch,
                                  sourceDirectory: sourceDirectory, task: task)
        let captured = await task.value
        if iTunesSyncCapture?.id == id { iTunesSyncCapture = nil }
        if let current = currentITunesCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                                          epoch: epoch, directory: sourceDirectory) {
            return current
        }
        if snapshotURL == snapshot, previewRevision == revision, iTunesSyncCatalogEpoch == epoch,
           loader.isCurrentCatalog(captured, directory: sourceDirectory) {
            iTunesSyncCatalogCache = .init(snapshot: snapshot, revision: revision, epoch: epoch,
                                            sourceDirectory: sourceDirectory, contents: captured)
        }
        return captured
    }

    private func currentITunesCatalogIfSuperseded(snapshot: URL, revision: Int, epoch: UInt64,
                                                   directory: URL) -> ITunesLibrarySnapshot? {
        guard snapshotURL != snapshot || previewRevision != revision || iTunesSyncCatalogEpoch != epoch else { return nil }
        guard snapshotURL == snapshot, previewRevision == revision,
              useCases.load.isCurrentCatalog(iTunesSnapshot, directory: directory) else {
            return ITunesLibrarySnapshot(status: .unavailable)
        }
        return iTunesSnapshot
    }

    func syncITunesPlaylists(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL) async throws {
        guard !isLoading, !isWritingRekordbox, snapshotURL == database, source.status == .ready else {
            throw DJCError.writeRefused(String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요."))
        }
        // 최신화가 끝나기 전의 목록으로 쓰면 폴더 계층이 낡을 수 있다.
        guard currentITunesRefresh(snapshot: database, revision: previewRevision) == nil else {
            throw DJCError.writeRefused(ITunesSyncModel.waitingForMusicMessage)
        }
        guard let base = source.syncData else {
            throw DJCError.writeRefused(String(ui: "rekordbox 동기화 파일 사본이 없습니다. rekordbox에서 한 번 동기화한 뒤 새로고침하세요."))
        }
        // 다른 폴더의 `--db` 사본은 새로고침해도 쓰기 대상과 원문이 맞춰지지 않는다. 쓰기 관문의 "새로고침" 안내 대신 다시 여는 길을 알린다
        if useCases.load.syncDiffersFromTarget(base, opened: database, location: location) {
            throw DJCError.writeRefused(String(ui: "지금 연 사본(--db)의 동기화 선택이 rekordbox와 다르니 --db 없이 다시 열어 동기화하세요."))
        }
        guard let syncITunesWrite else { throw DJCError.writeRefused(String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요.")) }
        invalidatePendingLoads()
        defer { invalidatePendingLoads() }
        // 쓰기는 반영 세션이 한다: 반영·복원과 같은 쓰기 대상에(명시한 사본 `--db`는 읽기 출처만 바꾼다), 덱은 잠그지 않는다.
        let written = try await syncITunesWrite(ITunesSyncWrite(base: base, source: source.selectionNodes, selection: selection))
        // 쓴 선택을 목록에 적용하고 동기화 창을 연 사본·지금 보는 사본 옆에 목록 사본을 남긴다(규칙은 유스케이스).
        let synced = try useCases.load.publishSync(source: source, syncData: written.syncData, database: database, target: written.target,
                                                   active: snapshotURL, location: location)
        let selected = synced.selected, sameSource = synced.sameSource
        if synced.saveFailed {
            reportLibraryError(String(ui: "rekordbox 동기화는 완료했지만 사본을 저장하지 못했습니다. 저장 폴더를 확인한 뒤 새로고침하세요."))
        }
        // 개발 실행에서 `--db`로 쓰기 대상과 다른 폴더의 사본을 열었으면 그 사본에는 쓴 선택이 보이지 않는다. 화면은 그대로 두고 알린다.
        guard synced.visible else {
            toast = .notice(String(ui: "iTunes 동기화를 rekordbox에 썼습니다"),
                            String(ui: "지금 연 사본(--db)에는 보이지 않으니 --db 없이 다시 열어 확인하세요."))
            return
        }
        guard snapshotURL == database || sameSource else { return }
        iTunesSnapshot = selected
        iTunesLibrary = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
        if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
        refreshBase()
        self.selection.formIntersection(Set(displayRows.map(\.id)))
    }
}
