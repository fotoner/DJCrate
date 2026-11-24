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

/// 재생 목록 초안 편집(유스케이스, #39·#40): 편집 요청 묶음 계획(`planning`, 앱 사이드바와 CLI `djc draft playlist`), 쓴 뒤 정리(새 목록 ID 잇기),
/// 복원 뒤 다시 쌓기, 컬렉션 등록 뒤 목록 연결, 최근 목록·넣기 전 나누기·재생 기록 원본 고르기(#251).
/// 초안은 앱의 재생 목록 조각(`PlaylistEditStore`)이 들고(되돌리기·표시), 초안 파일·연결 기록 저장은 여기서 포트로 한다.
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

    /// 재생 목록 초안을 저장하되 식별자가 없는 단계 가운데 주어진 자리는 그 출처를 잇는다(⌘Z가 되살린 단계, #295 E6).
    /// 그 저장을 모르는 포트면 보통 저장이다(되살린 단계는 이 포트의 출처를 받는다)
    @MainActor
    public func saveDraft(_ draft: PlaylistDraft, freshOrigins: [Int: Set<DraftOrigin>]) throws {
        guard !freshOrigins.isEmpty, let save = drafts.savePlaylistDraftOrigins else { return try saveDraft(draft) }
        try save(draft, freshOrigins)
    }

    /// 재생 목록 초안을 저장하되 식별자가 없는 단계마다 그 자리의 출처(`freshOrigins`, 없으면 이 포트의 출처)에 `carried`를 더한다(#295 리뷰 F10).
    /// `carried`는 화면이 저장에 실패한 동안 기억한 출처다: 저장에 실패한 뒤에는 출처를 줄이지 않는다(합집합). 단계 대응을 찾지 않고 식별자 없는 단계 모두에 더한다
    @MainActor
    public func saveDraft(_ draft: PlaylistDraft, freshOrigins: [Int: Set<DraftOrigin>] = [:], carrying carried: Set<DraftOrigin>) throws {
        try saveDraft(draft, freshOrigins: unidentifiedOrigins(draft, freshOrigins: freshOrigins, carrying: carried))
    }

    /// 식별자가 없는 단계마다 줄 출처(자리 → 출처). 이 포트의 출처 밖에 더할 출처가 없으면 `freshOrigins` 그대로다
    /// (이 포트의 출처만 더하면 제안인지가 바뀌지 않는다: 보통 저장으로 둔다)
    func unidentifiedOrigins(_ draft: PlaylistDraft, freshOrigins: [Int: Set<DraftOrigin>], carrying carried: Set<DraftOrigin>) -> [Int: Set<DraftOrigin>] {
        guard !carried.subtracting([drafts.origin]).isEmpty else { return freshOrigins }
        var origins = freshOrigins
        for index in draft.steps.indices where draft.steps[index].id == nil {
            origins[index] = (freshOrigins[index] ?? [drafts.origin]).union(carried)
        }
        return origins
    }

    /// 그 저장이 실패하면 화면이 기억할 출처: `carried`에 식별자 없는 단계가 받을 출처를 모두 더한다(`saveDraft(_:freshOrigins:carrying:)`)
    public func carriedAfterFailure(_ draft: PlaylistDraft, freshOrigins: [Int: Set<DraftOrigin>] = [:],
                                    carrying carried: Set<DraftOrigin>) -> Set<DraftOrigin> {
        draft.steps.indices.filter { draft.steps[$0].id == nil }.reduce(carried) { $0.union(freshOrigins[$1] ?? [drafts.origin]) }
    }

    /// 디스크 초안의 단계 출처(식별자 → 출처, #295 E6). ⌘Z 단계가 편집 전·뒤 단계의 출처를 기록한다. 읽지 못하면 빈 사전.
    /// 단계의 지금 내용 해시가 도장의 해시와 다르면(바깥에서 고쳤다) 모름을 더한다(`PlaylistStepStamping.save`의 바깥 변경 규칙과 같다)
    public func stepOrigins() -> [UUID: Set<DraftOrigin>] {
        guard let disk = try? drafts.readPlaylistDraft() else { return [:] }
        let stamps = drafts.playlistStamps()
        guard stamps.count == disk.steps.count else { return [:] }
        var origins: [UUID: Set<DraftOrigin>] = [:]
        for (step, stamp) in zip(disk.steps, stamps) {
            guard let id = step.id else { continue }
            let outside = (try? DraftContentHash(step: step, in: disk)) != stamp.contentHash
            origins[id] = outside ? stamp.origins.union([.unknown]) : stamp.origins
        }
        return origins
    }

    /// 디스크의 재생 목록 초안을 읽는다(없으면 빈 초안, 읽지 못하면 던진다). 앱은 편집 전에 바깥(CLI)에서 바뀌었는지 본다(#260)
    public func loadDraft() throws -> PlaylistDraft { try drafts.readPlaylistDraft() }

    /// 재생 목록 초안 파일 잠금을 잡는다(#260). 앱은 rekordbox에 쓰는 동안 들고 있어 CLI가 그 파일을 고치지 못하게 한다.
    /// 잡으면 푸는 함수, CLI가 `wait`초 넘게 들고 있으면 nil
    public func lockDraftFile(wait: TimeInterval = 0) -> (@Sendable () -> Void)? { drafts.lockPlaylistDraft(wait) }

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
    /// - Parameter carried: 화면이 저장에 실패한 동안 기억한 출처(식별자 없는 단계에 더한다, `saveDraft(_:freshOrigins:carrying:)`)
    /// - Returns: 기다리는 연결이 없거나 기록을 읽지 못했으면 nil
    @MainActor
    public func resolveImports(_ imports: PlaylistImports, draft: PlaylistDraft, rekordbox: PlaylistLayout,
                               contentIDsByPath: [String: String], loadFailed: Bool, carrying carried: Set<DraftOrigin> = []) -> ImportsResolution? {
        guard !loadFailed, imports.pendingCount > 0 else { return nil }
        var next = imports, nextDraft = draft
        var resolution = ImportsResolution()
        resolution.reasons = next.reconcile(contentIDsByPath: contentIDsByPath, draft: &nextDraft, rekordbox: rekordbox)
        if nextDraft != draft {
            do {
                try saveDraft(nextDraft, carrying: carried)
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
        /// 정리한 뒤 메모리가 이어 갈 초안(쓰는 동안 바뀌었거나 바깥에서 더한 편집을 담는다). 정리하지 못했으면 nil: 그대로 둔다
        public var draft: PlaylistDraft?
        /// 그 초안을 저장하지 못한 이유(메모리 초안은 디스크보다 최신이 된다, #174). 초안 파일을 읽지 못해 쓴 단계를 빼지 못한 이유이기도 하다
        public var draftError: (any Error)?
        /// 새로 만든 목록의 `new:키` → 받은 rekordbox ID. 만든 단계를 뺀 목록만이다(뺄 수 없었던 만들기는 아직 `new:키`다)
        public var ids: [String: String] = [:]
        /// 새 ID를 이은 연결 기록과 그 저장 결과(옮길 새 목록이 없으면 nil)
        public var imports: ImportsChange?
        /// 바깥에서 고친 내용의 사본을 남기고 뺀 단계(판 → 사본 파일). 부르는 쪽이 상태 줄에 경고한다(R22)
        public var copied: [DraftRevision: URL] = [:]
        /// 사본을 남기지 못해 남긴 단계. 있으면 정리가 끝나지 않았다
        public var copyFailed: Set<DraftRevision> = []
        /// 이번 쓰기가 rekordbox에 쓴 단계의 식별자(이미 그 모양이라 바꾸지 않은 단계 포함). 정리·사본에 실패해 초안에 남은 단계도 든다.
        /// 앱의 ⌘Z가 그 편집의 단계가 쓰였는지 본다(#295 E6)
        public var writtenSteps: Set<UUID> = []
        /// 이번 쓰기가 만든 목록의 `new:키` → 받은 rekordbox ID(정리하지 못해 아직 옮기지 않은 것 포함, #295 E6)
        public var writtenIDs: [String: String] = [:]

        /// 정리가 모두 끝났다(쓴 단계를 빼고, 남은 단계와 연결 기록의 연결 ID를 옮겨 저장했다).
        /// 끝나지 않았으면 부르는 쪽은 미정리 목록을 지우지 않고 그 대상의 다음 쓰기를 보류한 채 다음 정리 때 다시 한다(R22)
        public var isComplete: Bool { copyFailed.isEmpty && draftError == nil && (imports?.stored ?? true) }
    }

    /// 쓴 뒤: 쓴 단계를 판으로 찾아 초안에서 빼 저장하고(막힌 단계와 쓰는 동안 더한 단계는 남겨 다음 쓰기에서 다시 본다), 새로 만든 목록의
    /// `new:키`를 받은 rekordbox ID로 바꿔 남은 단계의 대상·목적지와 연결 기록에 옮겨 저장한다(R22).
    /// 판으로 찾는 쓴 단계는 해시가 달라도 빼고, 달랐던 단계는 바깥에서 고친 내용을 실제 목록 ID와 함께 `backups/backupFolder`에 사본으로 남긴
    /// 뒤에만 뺀다(`DraftStore.removeWrittenSteps`). 사본을 남기지 못한 단계는 그 만들기와 함께 `new:키`로 남기고 `isComplete`가 false다.
    /// 쓰는 동안 더한 편집은 메모리·디스크 모두 남는다. 기준은 정리한 디스크 초안이다. 다만 저장하지 못한 편집이 메모리에 있으면(`memoryUnsaved`)
    /// 메모리 초안이 정본이다: 쓰는 동안 앱은 초안 파일 잠금(#260)을 들어 바깥(CLI)이 초안을 고치지 못하고, 쓰기를 시작할 때 저장하지 못한 메모리가
    /// 있으면 쓰기가 막히므로(`ensurePlaylistDraftSaved`) 그때 메모리 = 디스크 + 저장하지 못한 편집이다. 그 메모리에서 이번에 쓴 단계(식별자로)만 빼고
    /// 연결 ID를 옮겨 저장한다. 바깥 수정·사본 실패는 재시작 정리(`resumeCleanup`, 메모리 없음)에서만 생긴다.
    /// 사본을 남기지 못한 단계가 하나라도 있으면 연결 ID를 옮기지 않는다(옮기는 저장이 남은 단계에 새 판을 주어 다시 할 때 찾지 못하게 된다).
    /// 메모리가 정본일 때 그런 단계가 있으면 메모리를 합치지도 저장하지도 않는다(`draft`가 nil: 앱 메모리와 저장하지 못한 표시는 그대로다).
    /// - Parameters:
    ///   - current: 지금 메모리 초안(`memoryUnsaved`일 때만 쓴다)
    ///   - memoryUnsaved: 메모리 초안에 저장하지 못한 편집이 있다(`PlaylistEditStore.playlistDraftUnsaved`)
    ///   - entries: 묶음에 읽어 넣은 단계의 판·해시(`written.steps`와 같은 차례, 쓰기 묶음의 `revisions.playlistSteps`).
    ///     비어 있으면 판을 모르는 묶음이라 지금 동작(쓰는 동안 바뀌지 않았을 때 자리로 뺀다)이다
    @MainActor
    public func finishWrite(_ written: PlaylistDraft, outcomes: [PlaylistOutcome], current: PlaylistDraft,
                            imports: PlaylistImports, importsLoadFailed: Bool,
                            entries: [DraftBatchEntry] = [], backups: URL? = nil, backupFolder: String = "",
                            memoryUnsaved: Bool = false) -> WriteCleanup {
        if let backups, !entries.isEmpty, entries.count == written.steps.count {
            let attempts = Self.attempts(written, outcomes: outcomes, entries: entries)
            let cleanup = PlaylistStepCleanup(
                written: attempts.filter { $0.outcome == .written }.map { WrittenPlaylistStep(revision: $0.revision, contentHash: $0.contentHash) },
                newPlaylistIDs: Self.newPlaylistIDs(written, outcomes: outcomes), backups: backups, backupFolder: backupFolder)
            // 이번에 쓴 단계의 식별자: 메모리 초안에서 이 단계만 뺀다
            let writtenIDs = Set(zip(written.steps, attempts).filter { $0.1.outcome == .written }.compactMap(\.0.id))
            var result = cleanUp(cleanup, memory: memoryUnsaved ? (current, writtenIDs) : nil, imports: imports, importsLoadFailed: importsLoadFailed)
            result.writtenSteps = writtenIDs
            result.writtenIDs = cleanup.newPlaylistIDs
            return result
        }
        var finished = Self.afterWrite(written, outcomes: outcomes, current: current)
        // 쓰는 동안(또는 1초 바깥 변경 확인 전에) CLI가 디스크 초안 뒤에 더한 편집은 남긴다(#260). 메모리 초안으로 저장하면 사라진다
        if finished.draft != nil, let disk = try? drafts.readPlaylistDraft(), disk != current,
           let kept = Self.keepingExternal(disk, written: written, outcomes: outcomes) {
            finished.draft = kept
        }
        var cleanup = WriteCleanup(draft: finished.draft, ids: finished.ids)
        cleanup.writtenSteps = Set(zip(written.steps, outcomes).filter { $0.1.status != .blocked }.compactMap(\.0.id))
        cleanup.writtenIDs = finished.ids
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

    /// 재시작 정리(R22): 정리 전에 멈춘 쓰기의 미정리 목록(재생 목록 몫)으로 같은 정리를 다시 한다. 앱은 첫 읽기 뒤 시작 저장보다 먼저 부른다.
    /// 목록의 판으로 쓴 단계만 빼고(이미 빠졌으면 그대로), 남은 단계와 연결 기록의 연결 ID를 옮긴다. 다시 해도 결과가 같다.
    /// 끝나지 않았으면(`isComplete`가 false) 목록을 지우지 않는다. 정리가 모두 끝나면 부르는 쪽이 목록을 지운다.
    /// - Parameters:
    ///   - backups: 백업 루트(목록의 `backupFolder`가 그 안의 폴더다. 바깥에서 고친 단계의 사본을 거기에 남긴다)
    ///   - imports: 지금 연결 기록(디스크에서 읽은 것)
    @MainActor
    public func resumeCleanup(_ list: DraftCleanupList, backups: URL, imports: PlaylistImports, importsLoadFailed: Bool) -> WriteCleanup {
        cleanUp(PlaylistStepCleanup(list: list, backups: backups), memory: nil, imports: imports, importsLoadFailed: importsLoadFailed)
    }

    /// 쓴 뒤 정리와 재시작 정리가 같이 쓰는 한 길: 판으로 쓴 단계를 빼고 → 연결 ID를 남은 단계에 옮겨 저장하고 → 연결 기록에 옮겨 저장한다.
    /// 저장 순서는 초안 → 연결 기록이다. 초안을 저장한 뒤 멈춰도 다시 하면 쓴 단계는 이미 없고(찾지 못함) 연결 ID는 다시 옮겨져 같은 결과다.
    /// - Parameter memory: 저장하지 못한 편집이 있는 메모리 초안과 이번에 쓴 단계의 식별자. 있으면 메모리가 정본이다(`finishWrite`)
    @MainActor
    private func cleanUp(_ cleanup: PlaylistStepCleanup, memory: (current: PlaylistDraft, writtenIDs: Set<UUID>)?, imports: PlaylistImports,
                         importsLoadFailed: Bool) -> WriteCleanup {
        var result = WriteCleanup()
        // 디스크 정리가 먼저다: 판으로 쓴 단계를 빼고(사본이 필요하면 남긴 뒤에) 사본을 남기지 못한 단계는 남긴다
        let removal: PlaylistStepRemoval
        do { removal = try drafts.removeWrittenSteps(cleanup) } catch {
            result.draftError = error
            return result
        }
        result.copied = removal.copied
        result.copyFailed = removal.copyFailed
        // 사본을 남기지 못한 단계가 있으면 연결 ID를 옮기지 않는다: 옮기는 저장은 남은 단계(사본을 남기지 못한 단계 포함)에 새 판을 주어
        // 다음 정리가 옛 판으로 그 단계를 찾지 못한다. 메모리가 정본이어도 같다: 메모리를 저장하면 그 단계에 새 판이 간다
        if memory != nil, !removal.copyFailed.isEmpty { return result }
        let disk: PlaylistDraft
        do { disk = try drafts.readPlaylistDraft() } catch {
            result.draftError = error
            return result
        }
        // 만든 단계가 남아 있는 키도 아직 `new:키`다(옮기면 목록을 다시 만든다)
        let creating = Set(disk.steps.compactMap { step -> String? in
            if case let .create(key, _, _, _) = step.edit { PlaylistRef.new(key).layoutID } else { nil }
        })
        let movable = removal.copyFailed.isEmpty ? cleanup.newPlaylistIDs.filter { !creating.contains($0.key) } : [:]
        result.ids = movable
        if let memory {
            // 메모리가 정본: 저장하지 못한 편집이 있는 메모리에서 이번에 쓴 단계만 식별자로 빼고 저장한다. 디스크에서 이미 없어진 쓴 단계도 같다
            var kept = memory.current
            kept.removeSteps(at: kept.steps.indices.filter { kept.steps[$0].id.map(memory.writtenIDs.contains) ?? false })
            kept = kept.remapped(movable)
            result.draft = kept
            do { try saveDraft(kept) } catch { result.draftError = error }
        } else {
            var next = disk.remapped(movable)
            if next != disk {
                do {
                    try saveDraft(next)
                    // 저장이 바뀐 단계에 새 판을 주므로 다시 읽어 식별자를 받는다
                    next = (try? drafts.readPlaylistDraft()) ?? next
                } catch { result.draftError = error }
            }
            result.draft = next
        }
        if !movable.isEmpty {
            var remapped = imports
            remapped.remapTargets(movable)
            result.imports = saveImports(remapped, over: imports, loadFailed: importsLoadFailed)
        }
        return result
    }

    /// 쓰기 묶음에서 시도한 재생 목록 단계(시도한 차례): 단계마다 판·읽어 넣은 해시·결과. 미정리 목록(`DraftCleanupList.playlistSteps`)에 적는다.
    /// 막힌 단계는 막힘(이유), 결과가 없는 단계(앞 단계가 막힌 단위 등)는 시도하지 않음이다. 이미 그 모양이라 바꾸지 않은 단계도 쓴 것으로 본다
    /// - Parameter entries: `written.steps`와 같은 차례(쓰기 묶음의 `revisions.playlistSteps`)
    public static func attempts(_ written: PlaylistDraft, outcomes: [PlaylistOutcome], entries: [DraftBatchEntry]) -> [DraftCleanupList.PlaylistStep] {
        entries.indices.map { index in
            let outcome: DraftCleanupList.StepOutcome = switch index < outcomes.count ? outcomes[index].status : nil {
            case .blocked?: .blocked(outcomes[index].reason ?? "")
            case .written?, .unchanged?: .written
            case nil: .notTried
            }
            return DraftCleanupList.PlaylistStep(revision: entries[index].revision, contentHash: entries[index].contentHash, outcome: outcome)
        }
    }

    /// 쓴 만들기 단계가 받은 새 목록 ID(`new:키` → rekordbox ID). 미정리 목록(`DraftCleanupList.newPlaylistIDs`)에 적는다
    public static func newPlaylistIDs(_ written: PlaylistDraft, outcomes: [PlaylistOutcome]) -> [String: String] {
        var ids: [String: String] = [:]
        for (step, outcome) in zip(written.steps, outcomes) {
            if case let .create(key, _, _, _) = step.edit, outcome.status == .written, let id = outcome.playlistID {
                ids[PlaylistRef.new(key).layoutID] = id
            }
        }
        return ids
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
    /// - Parameter carried: 화면이 저장에 실패한 동안 기억한 출처(`ReflectionLibraryState.playlistCarriedOrigins`)
    @MainActor
    public func resetImports(contentIDs: Set<String>, draft: PlaylistDraft, rekordbox: PlaylistLayout, imports: PlaylistImports,
                             importsLoadFailed: Bool, carrying carried: Set<DraftOrigin> = []) -> ImportsReset {
        var nextImports = imports, nextDraft = draft
        nextImports.reset(contentIDs: contentIDs)
        nextDraft.forgetContentIDs(contentIDs, rekordbox: rekordbox)
        var reset = ImportsReset(contentIDs: contentIDs)
        do {
            try saveDraft(nextDraft, carrying: carried)
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
    /// - Parameter carried: 화면이 저장에 실패한 동안 기억한 출처(다시 쌓은 단계는 모두 식별자가 없어 모두에 더한다)
    @MainActor
    public func restore(_ edits: [PlaylistEdit], onto current: PlaylistDraft, rekordbox: PlaylistLayout, imports: PlaylistImports,
                        importsLoadFailed: Bool, carrying carried: Set<DraftOrigin> = []) -> Restored {
        let rebuilt = Self.restoring(edits, onto: current, rekordbox: rekordbox)
        var draftError: (any Error)?
        do { try saveDraft(rebuilt.draft, carrying: carried) } catch { draftError = error }
        var restoredImports = imports
        restoredImports.restoreTargets(createdKeys: rebuilt.createdKeys)
        return Restored(draft: rebuilt.draft, draftError: draftError,
                        imports: saveImports(restoredImports, over: imports, loadFailed: importsLoadFailed), failed: rebuilt.failed)
    }

    /// 하나라도 막혀 편집을 더하지 않은 안내(화면에 그대로 보인다, `planning`의 `allOrNothing`)
    public static func refusedMessage(_ reason: String) -> String {
        String(ui: "재생 목록을 고치지 않았습니다: \(reason)")
    }

    // MARK: - 최근 목록·넣기 전 나누기·재생 기록 원본(#251)

    /// 최근에 곡을 넣은 목록을 몇 개까지 기억할지(오른쪽 클릭 메뉴 맨 위·'마지막에 쓴 목록에 넣기')
    public static let recentLimit = 5

    /// 곡을 넣은 목록을 최근 목록 맨 앞에 한 번만 둔다. `recentLimit`개를 넘으면 오래된 것을 버린다
    public static func touchingRecent(_ id: String, in recent: [String]) -> [String] {
        var recent = recent.filter { $0 != id }
        recent.insert(id, at: 0)
        return Array(recent.prefix(recentLimit))
    }

    /// 쓴 뒤: 새로 만든 목록의 임시 ID(`new:키`)를 받은 rekordbox ID로 바꾼다(`finishWrite`의 `ids`)
    public static func remappingRecent(_ recent: [String], ids: [String: String]) -> [String] {
        recent.map { ids[$0] ?? $0 }
    }

    /// 목록에 넣기 전에 곡을 나눈다: 새로 넣을 곡, 이미 든 곡, 넣지 않는 추가한 곡(아직 rekordbox 컬렉션에 없다)의 수
    /// - Parameter tracks: 곡마다 한 줄(재생 기록의 반복 행은 부르는 쪽이 먼저 줄인다)
    public static func addPlan(_ tracks: [TrackRow], to item: PlaylistLayout.Item) -> (new: [String], duplicates: [String], staged: Int) {
        let staged = tracks.filter(\.isStaged).count
        let split = item.split(adding: tracks.filter { !$0.isStaged }.map(\.track.id))
        return (split.new, split.duplicates, staged)
    }

    /// 새 목록에 넣을 곡. 추가한 곡은 아직 rekordbox 컬렉션에 없어 뺀다
    public static func creatableTrackIDs(_ tracks: [TrackRow]) -> [String] {
        tracks.filter { !$0.isStaged }.map(\.track.id)
    }

    /// 재생 기록으로 만들 재생 목록의 이름과 컬렉션 곡(튼 순서, 반복 재생 포함 — 넣을 때 처음 한 번만 남는다). 없는 기록이면 nil.
    /// rekordbox 기록(#70)을 먼저 본다. 이름은 기록 제목이다. USB에서 보존한 기록(#43)은 컬렉션 짝이 있는 곡만 고르고, 이름은 기록 이름이다.
    public static func historySource(_ id: String, histories: [String: RekordboxHistory], archived: [String: ArchivedHistory],
                                     rows: [TrackRow.ID: TrackRow]) -> (name: String, rows: [TrackRow])? {
        if let history = histories[id] {
            return (history.title, history.entries.sorted { $0.trackNumber < $1.trackNumber }.compactMap { rows[$0.contentID] })
        }
        guard let archived = archived[id] else { return nil }
        return (archived.name, archived.entries.sorted { $0.trackNumber < $1.trackNumber }.compactMap { $0.contentID.flatMap { rows[$0] } })
    }

    /// 목록에 곡을 넣은 결과 안내(넣은 곡·이미 든 곡·저장 실패·아직 컬렉션에 없는 곡). 알릴 것이 없으면 nil
    public static func addSummary(name: String, added: Int, duplicates: Int, saveFailed: Bool, staged: Int,
                                  saveFailureText: String) -> (text: String, warning: Bool)? {
        var lines: [String] = []
        var warning = false
        if added > 0 { lines.append(String(ui: "‘\(name)’에 \(added)곡을 넣었습니다(저장 대기).")) }
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

    /// 판을 모르는 묶음의 쓴 뒤: 쓴 편집을 자리로 초안에서 뺀다(막힌 편집은 남겨 다음 쓰기에서 다시 본다). 새로 만든 목록의 `new:키`가 받은
    /// rekordbox ID를 돌려주고, 남은 단계의 대상·목적지의 `new:키`도 그 ID로 옮긴다.
    /// - Parameter current: 지금 초안. 쓰는 동안 바뀌었으면 그대로 둔다(초안 nil)
    public static func afterWrite(_ written: PlaylistDraft, outcomes: [PlaylistOutcome], current: PlaylistDraft)
        -> (draft: PlaylistDraft?, ids: [String: String]) {
        let ids = newPlaylistIDs(written, outcomes: outcomes)
        guard current == written else { return (nil, ids) }
        var draft = written
        draft.removeSteps(at: outcomes.indices.filter { outcomes[$0].status != .blocked })
        return (draft.remapped(ids), ids)
    }

    /// 판을 모르는 묶음의 쓴 뒤: 디스크 초안이 쓴 초안으로 시작하면(그 뒤에 바깥에서 편집을 더함) 쓴 편집만 뺀 디스크 초안. 아니면 nil(메모리 초안으로 정리한다)
    public static func keepingExternal(_ disk: PlaylistDraft, written: PlaylistDraft, outcomes: [PlaylistOutcome]) -> PlaylistDraft? {
        guard disk.steps.count > written.steps.count, disk.steps.starts(with: written.steps) else { return nil }
        var draft = disk
        draft.removeSteps(at: outcomes.indices.filter { outcomes[$0].status != .blocked })
        return draft.remapped(newPlaylistIDs(written, outcomes: outcomes))
    }

    /// 복원한 뒤: 그때 쓴 편집을 되돌린 rekordbox 상태에 다시 쌓고 그 뒤 쌓은 초안을 이어 붙인다. 다시 쌓지 못한 편집 수와 다시 만들 목록 열쇠도 준다
    public static func restoring(_ edits: [PlaylistEdit], onto current: PlaylistDraft, rekordbox: PlaylistLayout)
        -> (draft: PlaylistDraft, failed: Int, createdKeys: Set<String>) {
        let rebuilt = PlaylistDraft.rebuilt(edits + current.edits, rekordbox: rekordbox)
        let keys = Set(edits.compactMap { edit in if case let .create(key, _, _, _) = edit { key } else { nil } })
        return (rebuilt.draft, rebuilt.failed.count, keys)
    }
}
