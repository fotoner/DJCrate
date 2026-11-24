import DJCApplication
import DJCDomain
import Foundation

/// 재생 목록 연결 기록(컬렉션에 들어간 뒤 만들 목록 연결). 읽기·저장·연결 맞추기의 순서(초안 → 연결 기록)는 유스케이스 `EditPlaylists`가 정하고,
/// 여기서는 돌려받은 초안·연결 기록을 메모리와 안내에 맞춘다. 안내는 읽기·쓰기 뒤에 저절로 하는 일이라 떠 있는 경고를 덮지 않는다(`notify`).
extension PlaylistEditStore {
    static var importsSaveFailureText: String {
        String(ui: "재생 목록 연결을 보관하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요.")
    }
    static var importsLoadFailureText: String {
        String(ui: "재생 목록 연결을 읽지 못했습니다. DJCrate 데이터 폴더의 playlist-imports.json을 확인한 뒤 앱을 다시 여세요.")
    }

    /// 곡 넣기를 되돌린 뒤: 반영 세션이 그 곡의 연결 기록과 초안 편집을 잊어 저장한 결과를 맞춘다
    func applyPlaylistImportsReset(_ reset: EditPlaylists.ImportsReset) {
        if let error = reset.draftError {
            // 세션은 저장에 실패한 동안 기억한 출처를 더해 저장했다(`ReflectionLibraryState.playlistCarriedOrigins`): 메모리 초안의 식별자 없는 단계 출처를 계속 기억한다
            unsavedStepOrigins = library.useCases.playlists.carriedAfterFailure(playlistDraft, carrying: unsavedStepOrigins)
            library.notify(.notice(text: String(ui: "재생 목록 편집을 보관하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"), kind: .warning))
            return
        }
        if let draft = reset.draft {
            unsavedStepOrigins = []
            playlistDraft = draft
            adoptSavedIdentifiers()
            refreshPlaylists()
        }
        if let imports = reset.imports { applyImportsChange(imports) }
    }

    func loadPlaylistImports() {
        do { playlistImports = try library.useCases.playlists.loadImports() }
        catch {
            playlistImportsLoadFailed = true
            library.notify(.notice(text: Self.importsLoadFailureText, kind: .warning))
        }
    }

    /// 연결 기록을 저장한다(바뀌었을 때만, 읽지 못했으면 저장하지 않는다). 저장했거나 바뀐 것이 없으면 true
    @discardableResult
    func savePlaylistImports(_ imports: PlaylistImports) -> Bool {
        applyImportsChange(library.useCases.playlists.saveImports(imports, over: playlistImports, loadFailed: playlistImportsLoadFailed))
    }

    /// 연결 기록 저장 결과를 메모리와 안내에 맞춘다. 디스크가 그 기록과 같으면 true
    /// - Parameter notifying: 저장하지 못했을 때 알릴지(곡 추가는 결과 알림에 실패를 담아 직접 알린다)
    @discardableResult
    func applyImportsChange(_ change: EditPlaylists.ImportsChange, notifying: Bool = true) -> Bool {
        switch change.result {
        case .saved:
            playlistImports = change.imports
        case .failed:
            if notifying { library.notify(.notice(text: Self.importsSaveFailureText, kind: .warning)) }
        case .unchanged, .blocked: break
        }
        return change.stored
    }

    /// 직접 추가·XML 가져오기 모두 새 스냅샷에서 컬렉션 등록을 확인한 뒤 연결한다(유스케이스 `EditPlaylists.resolveImports`).
    /// 초안 저장에 실패하면 연결은 남기며, 연결 저장만 실패하면 다음 읽기에서 중복 없이 다시 확인한다.
    func resolvePlaylistImports(contentIDsByPath: [String: String]? = nil) {
        guard !playlistImportsLoadFailed, playlistImports.pendingCount > 0 else { return }
        // 바깥(CLI)에서 바뀐 초안이 있으면 먼저 받는다(메모리 초안으로 저장해 덮지 않게, #260).
        // 디스크 초안을 읽지 못했으면 곡 연결과 연결 기록 저장을 미룬다(옛 메모리에 곡을 더해 저장하지 않게). 연결은 소비하지 않고 기다린다
        _ = syncExternal()
        guard !playlistDraftNeedsSync else { return }
        let ids = contentIDsByPath ?? Dictionary(library.rows.map { (PlaylistImports.pathKey($0.track.folderPath), $0.track.id) },
                                                 uniquingKeysWith: { first, _ in first })
        let edits = library.useCases.playlists, carrying = unsavedStepOrigins
        guard let resolution = edits.resolveImports(playlistImports, draft: playlistDraft, rekordbox: rekordboxPlaylists, contentIDsByPath: ids,
                                                    loadFailed: playlistImportsLoadFailed, carrying: carrying) else { return }
        if let error = resolution.draftError {
            // 기억한 출처를 더해 저장하려다 실패했다: 메모리 초안의 식별자 없는 단계 출처를 계속 기억한다(#295 리뷰 F10)
            unsavedStepOrigins = edits.carriedAfterFailure(playlistDraft, carrying: carrying)
            library.notify(.notice(text: String(ui: "재생 목록 편집을 보관하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"), kind: .warning))
            return
        }
        if let draft = resolution.draft {
            unsavedStepOrigins = []
            playlistDraft = draft
            adoptSavedIdentifiers()
            refreshPlaylists()
        }
        guard let imports = resolution.imports, applyImportsChange(imports) else { return }
        if let reason = resolution.reasons.first { library.notify(.notice(text: reason, kind: .warning)) }
    }
}
