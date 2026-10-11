import DJCApplication
import DJCDomain
import Foundation

/// 재생 목록 연결 기록(컬렉션에 들어간 뒤 만들 목록 연결). 읽기·저장·연결 맞추기의 순서(초안 → 연결 기록)는 유스케이스 `EditPlaylists`가 정하고,
/// 여기서는 돌려받은 초안·연결 기록을 메모리와 안내에 맞춘다.
extension PlaylistEditStore {
    /// 곡 넣기를 되돌린 뒤: 반영 세션이 그 곡의 연결 기록과 초안 편집을 잊어 저장한 결과를 맞춘다
    func applyPlaylistImportsReset(_ reset: EditPlaylists.ImportsReset) {
        if let error = reset.draftError {
            playlistMessage = AppMessage(kind: .warning,
                                         text: String(ui: "재생 목록 초안을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
            return
        }
        if let draft = reset.draft {
            playlistDraft = draft
            refreshPlaylists()
        }
        if let imports = reset.imports { applyImportsChange(imports) }
    }

    func loadPlaylistImports() {
        do { playlistImports = try library.useCases.playlists.loadImports() }
        catch {
            playlistImportsLoadFailed = true
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 연결을 읽지 못했습니다. DJCrate 데이터 폴더의 playlist-imports.json을 확인한 뒤 앱을 다시 여세요."))
        }
    }

    /// 연결 기록을 저장한다(바뀌었을 때만, 읽지 못했으면 저장하지 않는다). 저장했거나 바뀐 것이 없으면 true
    @discardableResult
    func savePlaylistImports(_ imports: PlaylistImports) -> Bool {
        applyImportsChange(library.useCases.playlists.saveImports(imports, over: playlistImports, loadFailed: playlistImportsLoadFailed))
    }

    /// 연결 기록 저장 결과를 메모리와 안내에 맞춘다. 디스크가 그 기록과 같으면 true
    @discardableResult
    func applyImportsChange(_ change: EditPlaylists.ImportsChange) -> Bool {
        switch change.result {
        case .saved:
            playlistImports = change.imports
        case .failed:
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 연결을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하고 다시 시도하세요."))
        case .unchanged, .blocked: break
        }
        return change.stored
    }

    /// 직접 추가·XML 가져오기 모두 새 스냅샷에서 컬렉션 등록을 확인한 뒤 연결한다(유스케이스 `EditPlaylists.resolveImports`).
    /// 초안 저장에 실패하면 연결은 남기며, 연결 저장만 실패하면 다음 읽기에서 중복 없이 다시 확인한다.
    func resolvePlaylistImports(contentIDsByPath: [String: String]? = nil) {
        guard !playlistImportsLoadFailed, playlistImports.pendingCount > 0 else { return }
        let ids = contentIDsByPath ?? Dictionary(library.rows.map { (PlaylistImports.pathKey($0.track.folderPath), $0.track.id) },
                                                 uniquingKeysWith: { first, _ in first })
        guard let resolution = library.useCases.playlists.resolveImports(playlistImports, draft: playlistDraft, rekordbox: rekordboxPlaylists,
                                                                 contentIDsByPath: ids, loadFailed: playlistImportsLoadFailed) else { return }
        if let error = resolution.draftError {
            playlistMessage = AppMessage(kind: .warning,
                                         text: String(ui: "재생 목록 초안을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요: \(error.localizedDescription)"))
            return
        }
        if let draft = resolution.draft {
            playlistDraft = draft
            refreshPlaylists()
        }
        guard let imports = resolution.imports, applyImportsChange(imports) else { return }
        if let reason = resolution.reasons.first { playlistMessage = AppMessage(kind: .warning, text: reason) }
    }
}
