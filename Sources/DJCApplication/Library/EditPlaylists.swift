import DJCDomain
import Foundation

/// 재생 목록 연결 기록(`playlist-imports.json`, 포트): 컬렉션에 들어간 뒤 만들 목록 연결과 끝낸 출처. 실제 구현은 DJCAdapters(`live(url:)`).
public struct PlaylistImportsStore: Sendable {
    /// 기록을 읽는다(파일이 없으면 빈 기록, 읽지 못하면 던진다)
    public var load: @Sendable () throws -> PlaylistImports
    public var save: @Sendable (PlaylistImports) throws -> Void

    public init(load: @escaping @Sendable () throws -> PlaylistImports, save: @escaping @Sendable (PlaylistImports) throws -> Void) {
        self.load = load
        self.save = save
    }

    /// 기록하지 않는다(시험·캡처)
    public static let none = PlaylistImportsStore(load: { PlaylistImports() }, save: { _ in })
}

/// 재생 목록 초안 편집(유스케이스, #39·#40): 편집 더하기(하나라도 막히면 아무것도 더하지 않는다), 쓴 뒤 정리(새 목록 ID 잇기),
/// 복원 뒤 다시 쌓기, 컬렉션 등록 뒤 목록 연결. 초안은 화면 모델이 들고(되돌리기·표시), 초안 파일·연결 기록 저장은 여기서 포트로 한다.
/// 저장 순서는 초안 → 연결 기록이다: 초안을 저장하지 못하면 연결 기록은 그대로 두어 다음 읽기에서 다시 확인한다.
/// 반영 세션도 쓴 뒤·복원 뒤 저장에 이것을 쓴다(`finishWrite`·`resetImports`).
public struct EditPlaylists: Sendable {
    let imports: PlaylistImportsStore
    let drafts: DraftStore

    public init(imports: PlaylistImportsStore, drafts: DraftStore) {
        self.imports = imports
        self.drafts = drafts
    }

    // MARK: - 저장

    /// 재생 목록 초안을 저장한다(실패하면 던진다: 화면은 메모리 초안을 그대로 두고 쓰기 전에 다시 저장한다, #174)
    @MainActor
    public func saveDraft(_ draft: PlaylistDraft) throws { try drafts.savePlaylistDraft(draft) }

    /// 연결 기록을 읽는다(파일이 없으면 빈 기록, 읽지 못하면 던진다)
    public func loadImports() throws -> PlaylistImports { try imports.load() }

    /// 연결 기록 저장 결과
    public enum ImportsSaveResult: Sendable {
        /// 바뀐 것이 없어 저장하지 않았다
        case unchanged
        case saved
        case failed(any Error)
        /// 기록을 읽지 못해 저장하지 않았다(읽지 못한 파일을 빈 기록으로 덮지 않게)
        case blocked
    }

    /// 저장하려던 연결 기록과 그 결과
    public struct ImportsChange: Sendable {
        public var imports: PlaylistImports
        public var result: ImportsSaveResult
        /// 디스크가 `imports`와 같다(저장했거나 바뀐 것이 없다)
        public var stored: Bool {
            switch result {
            case .unchanged, .saved: true
            case .failed, .blocked: false
            }
        }
    }

    /// 바뀌었을 때만 연결 기록을 저장한다. 기록을 읽지 못했으면(`loadFailed`) 저장하지 않는다
    public func saveImports(_ imports: PlaylistImports, over current: PlaylistImports, loadFailed: Bool) -> ImportsChange {
        guard !loadFailed else { return ImportsChange(imports: imports, result: .blocked) }
        guard imports != current else { return ImportsChange(imports: imports, result: .unchanged) }
        do {
            try self.imports.save(imports)
            return ImportsChange(imports: imports, result: .saved)
        } catch {
            return ImportsChange(imports: imports, result: .failed(error))
        }
    }

    // MARK: - 컬렉션 등록 뒤 목록 연결

    /// 연결 맞춘 결과
    public struct ImportsResolution: Sendable {
        /// 곡을 넣어 저장한 새 초안(바뀐 것이 없거나 저장하지 못했으면 nil)
        public var draft: PlaylistDraft?
        /// 초안을 저장하지 못한 이유(그러면 연결 기록은 저장하지 않았다)
        public var draftError: (any Error)?
        /// 초안을 저장했거나 바꿀 것이 없었으면 연결 기록 저장 결과
        public var imports: ImportsChange?
        /// 연결하지 못한 목록의 이유
        public var reasons: [String] = []
    }

    /// 직접 추가·XML 가져오기 모두 새 스냅샷에서 컬렉션 등록을 확인한 뒤 연결한다: 등록된 곡을 초안에 넣어 저장하고, 그다음 연결 기록을 저장한다.
    /// 초안 저장에 실패하면 연결은 남기며, 연결 저장만 실패하면 다음 읽기에서 중복 없이 다시 확인한다.
    /// - Returns: 기다리는 연결이 없거나 기록을 읽지 못했으면 nil
    @MainActor
    public func resolveImports(_ imports: PlaylistImports, draft: PlaylistDraft, rekordbox: PlaylistLayout,
                               contentIDsByPath: [String: String], loadFailed: Bool) -> ImportsResolution? {
        guard !loadFailed, imports.pendingCount > 0 else { return nil }
        var next = imports, nextDraft = draft
        var resolution = ImportsResolution()
        resolution.reasons = next.reconcile(contentIDsByPath: contentIDsByPath, draft: &nextDraft, rekordbox: rekordbox)
        if nextDraft != draft {
            do {
                try saveDraft(nextDraft)
                resolution.draft = nextDraft
            } catch {
                resolution.draftError = error
                return resolution
            }
        }
        resolution.imports = saveImports(next, over: imports, loadFailed: loadFailed)
        return resolution
    }

    // MARK: - 쓴 뒤·복원 뒤(반영 세션)

    /// 쓴 뒤 정리한 결과
    public struct WriteCleanup: Sendable {
        /// 쓴 편집을 뺀 초안(쓰는 동안 초안이 바뀌었으면 nil: 그대로 둔다)
        public var draft: PlaylistDraft?
        /// 그 초안을 저장하지 못한 이유(메모리 초안은 디스크보다 최신이 된다, #174)
        public var draftError: (any Error)?
        /// 새로 만든 목록의 `new:키` → 받은 rekordbox ID
        public var ids: [String: String] = [:]
        /// 새 ID를 이은 연결 기록과 그 저장 결과(새로 만든 목록이 없으면 nil)
        public var imports: ImportsChange?
    }

    /// 쓴 뒤: 쓴 편집을 초안에서 빼 저장하고(막힌 편집은 남겨 다음 쓰기에서 다시 본다), 새로 만든 목록의 `new:키`를 받은 rekordbox ID로 바꿔
    /// 연결 기록에 이어 저장한다.
    /// - Parameter current: 지금 초안. 쓰는 동안 바뀌었으면 그대로 둔다
    @MainActor
    public func finishWrite(_ written: PlaylistDraft, outcomes: [PlaylistOutcome], current: PlaylistDraft,
                            imports: PlaylistImports, importsLoadFailed: Bool) -> WriteCleanup {
        let finished = Self.afterWrite(written, outcomes: outcomes, current: current)
        var cleanup = WriteCleanup(draft: finished.draft, ids: finished.ids)
        if let draft = finished.draft {
            do { try saveDraft(draft) } catch { cleanup.draftError = error }
        }
        if !finished.ids.isEmpty {
            var remapped = imports
            remapped.remapTargets(finished.ids)
            cleanup.imports = saveImports(remapped, over: imports, loadFailed: importsLoadFailed)
        }
        return cleanup
    }

    /// 되돌린 곡의 연결을 잊은 결과
    public struct ImportsReset: Sendable {
        /// 되돌린 곡(ContentID)
        public var contentIDs: Set<String>
        /// 그 곡 편집을 잊어 저장한 초안(저장하지 못했으면 nil)
        public var draft: PlaylistDraft?
        /// 초안을 저장하지 못한 이유(그러면 연결 기록은 저장하지 않았다)
        public var draftError: (any Error)?
        /// 초안을 저장했으면 연결 기록 저장 결과
        public var imports: ImportsChange?
    }

    /// 곡 추가를 되돌린 뒤: 되돌린 곡(ContentID)의 연결 기록을 다시 기다리는 연결로 돌리고, 초안에서 그 곡 편집을 잊어 저장한 다음 연결 기록을 저장한다
    @MainActor
    public func resetImports(contentIDs: Set<String>, draft: PlaylistDraft, rekordbox: PlaylistLayout, imports: PlaylistImports,
                             importsLoadFailed: Bool) -> ImportsReset {
        var nextImports = imports, nextDraft = draft
        nextImports.reset(contentIDs: contentIDs)
        nextDraft.forgetContentIDs(contentIDs, rekordbox: rekordbox)
        var reset = ImportsReset(contentIDs: contentIDs)
        do {
            try saveDraft(nextDraft)
            reset.draft = nextDraft
        } catch {
            reset.draftError = error
            return reset
        }
        reset.imports = saveImports(nextImports, over: imports, loadFailed: importsLoadFailed)
        return reset
    }

    /// 복원 뒤 다시 쌓은 결과
    public struct Restored: Sendable {
        /// 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓고 그 뒤 초안을 이어 붙인 초안(저장하지 못했어도 화면은 이것을 든다)
        public var draft: PlaylistDraft
        public var draftError: (any Error)?
        /// 다시 만들 목록의 연결을 `new:키`로 되돌린 연결 기록과 그 저장 결과
        public var imports: ImportsChange
        /// 다시 쌓지 못한 편집 수
        public var failed: Int
    }

    /// 복원한 뒤 새 스냅샷을 읽고 나서: 그때 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓아 저장하고, 다시 만들 목록의 연결을 되돌려 저장한다
    @MainActor
    public func restore(_ edits: [PlaylistEdit], onto current: PlaylistDraft, rekordbox: PlaylistLayout, imports: PlaylistImports,
                        importsLoadFailed: Bool) -> Restored {
        let rebuilt = Self.restoring(edits, onto: current, rekordbox: rekordbox)
        var draftError: (any Error)?
        do { try saveDraft(rebuilt.draft) } catch { draftError = error }
        var restoredImports = imports
        restoredImports.restoreTargets(createdKeys: rebuilt.createdKeys)
        return Restored(draft: rebuilt.draft, draftError: draftError,
                        imports: saveImports(restoredImports, over: imports, loadFailed: importsLoadFailed), failed: rebuilt.failed)
    }

    /// 편집을 더하지 않은 이유(화면에 그대로 보인다)
    public struct Refused: Error, Sendable {
        public var message: String
    }

    /// 편집을 차례로 초안에 더한다. 하나라도 쓸 수 없으면 아무것도 더하지 않고 이유(`Refused`)를 던진다
    public static func appending(_ edits: [PlaylistEdit], to draft: PlaylistDraft, rekordbox: PlaylistLayout) throws -> PlaylistDraft {
        var draft = draft
        do {
            for edit in edits { try draft.append(edit, rekordbox: rekordbox) }
        } catch {
            let reason = (error as? PlaylistLayout.Blocked)?.reason ?? DJCError.reason(of: error)
            throw Refused(message: String(ui: "재생 목록을 고치지 않았습니다: \(reason)"))
        }
        return draft
    }

    /// 목록에 곡을 넣은 결과 안내(넣은 곡·이미 든 곡·저장 실패·아직 컬렉션에 없는 곡). 알릴 것이 없으면 nil
    public static func addSummary(name: String, added: Int, duplicates: Int, saveFailed: Bool, staged: Int,
                                  saveFailureText: String) -> (text: String, warning: Bool)? {
        var lines: [String] = []
        var warning = false
        if added > 0 { lines.append(String(ui: "‘\(name)’에 \(added)곡을 넣었습니다(쓰기 대기).")) }
        if duplicates > 0 {
            warning = true
            lines.append(String(ui: "이미 들어 있는 \(duplicates)곡은 넣지 않았습니다."))
        }
        // 넣은 결과 안내가 저장 실패 경고를 덮지 않게 한다(#174).
        if saveFailed {
            warning = true
            lines.append(saveFailureText)
        }
        if staged > 0 {
            warning = true
            lines.append(String(ui: "추가한 곡 \(staged)곡은 rekordbox 컬렉션에 넣은 뒤 목록에 넣을 수 있습니다."))
        }
        return lines.isEmpty ? nil : (lines.joined(separator: " "), warning)
    }

    /// 쓴 뒤: 쓴 편집을 초안에서 뺀다(막힌 편집은 남겨 다음 쓰기에서 다시 본다). 새로 만든 목록의 `new:키`가 받은 rekordbox ID를 돌려준다.
    /// - Parameter current: 지금 초안. 쓰는 동안 바뀌었으면 그대로 둔다(초안 nil)
    public static func afterWrite(_ written: PlaylistDraft, outcomes: [PlaylistOutcome], current: PlaylistDraft)
        -> (draft: PlaylistDraft?, ids: [String: String]) {
        var ids: [String: String] = [:]
        for (step, outcome) in zip(written.steps, outcomes) {
            if case let .create(key, _, _, _) = step.edit, outcome.status == .written, let id = outcome.playlistID {
                ids[PlaylistRef.new(key).layoutID] = id
            }
        }
        guard current == written else { return (nil, ids) }
        var draft = written
        draft.removeSteps(at: outcomes.indices.filter { outcomes[$0].status != .blocked })
        return (draft, ids)
    }

    /// 복원한 뒤: 그때 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓고 그 뒤 쌓은 초안을 이어 붙인다. 다시 쌓지 못한 편집 수와 다시 만들 목록 열쇠도 준다
    public static func restoring(_ edits: [PlaylistEdit], onto current: PlaylistDraft, rekordbox: PlaylistLayout)
        -> (draft: PlaylistDraft, failed: Int, createdKeys: Set<String>) {
        let rebuilt = PlaylistDraft.rebuilt(edits + current.edits, rekordbox: rekordbox)
        let keys = Set(edits.compactMap { edit in if case let .create(key, _, _, _) = edit { key } else { nil } })
        return (rebuilt.draft, rebuilt.failed.count, keys)
    }
}
