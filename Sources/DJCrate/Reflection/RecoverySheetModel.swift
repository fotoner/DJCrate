import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 복구 시트(#232)의 한 줄이 가리키는 것: 곡의 한 종류, 또는 재생 목록 하나.
enum RecoveryRequest: Sendable {
    case draft(TrackRow, DraftRecoveryKind)
    case playlist(String)

    var id: String {
        switch self {
        case let .draft(row, kind): "\(row.track.uuid)/\(kind)"
        case let .playlist(id): "playlist/\(id)"
        }
    }
}

/// 줄마다 고르는 것. 나중에는 초안을 그대로 둔다.
enum RecoveryChoice: Hashable, Sendable { case keep, useCurrent, later }

/// 시트를 어느 창에 붙일지(곡 편집 창에서 연 시트는 그 창에 붙는다)
enum RecoverySheetAnchor: Sendable { case library, editWindow }

/// 큐 대상을 다시 지정하는 줄의 고르기 상태: 내가 고친 큐 ↔ 지금 rekordbox의 큐
struct RecoveryCueMapping {
    /// 내가 고쳤지만 지금 rekordbox에 같은 ID가 없는 큐
    var missing: [EditableCue]
    /// 이을 수 있는 현재 큐
    var candidates: [EditableCue]
    /// 내 큐의 sourceID → 현재 큐의 sourceID
    var selection: [String: String] = [:]

    var isComplete: Bool { missing.allSatisfy { $0.sourceID.map { selection[$0] != nil } ?? false } }

    /// 다른 줄이 이미 고른 현재 큐는 빼고 보여 준다
    func candidates(for oldSource: String) -> [EditableCue] {
        let others = Set(selection.filter { $0.key != oldSource }.map(\.value))
        return candidates.filter { $0.sourceID.map { !others.contains($0) } ?? false }
    }
}

/// 시트의 줄 하나. 고르기 상태와 보여 줄 글을 들고 있고, 판정·저장은 `RecoverySheetModel`이 기존 규칙으로 한다.
@MainActor @Observable
final class RecoveryLine: Identifiable {
    enum Phase: Equatable {
        case loading, ready
        /// 비교·저장하지 못했다(이유 한 문장). 초안은 그대로다.
        case failed(String)
        case saved
    }

    let id: String
    let request: RecoveryRequest
    var title: String
    let kindLabel: String
    var phase: Phase = .loading
    var choice: RecoveryChoice = .later
    /// 무엇이 rekordbox에서 바뀌었는지 한 줄
    var summary = ""
    var notes: [String] = []
    /// 접어 둔 자세히 보기(기준·현재·내 편집)
    var details: [String] = []
    var canKeep = false
    /// 초안의 기준이 지금 rekordbox와 달라졌는지. 같으면 rekordbox가 바뀌어서가 아니라 다른 이유로 쓰지 못하는 초안이다(#232 리뷰).
    var isStale = true
    /// 내 편집 유지를 고를 수 없는 이유
    var keepBlockedReason: String?
    var cueMapping: RecoveryCueMapping?
    /// 이어 준 큐 대응으로는 내 편집을 다시 적용할 수 없을 때의 이유
    var mappingFailure: String?
    /// 저장하며 알릴 것(앞 줄을 저장하면서 이미 해결된 목록 등)
    var resultNote: String?
    /// 줄 안에서 펼친 것(화면 상태. 큐 대상 지정은 필요한 줄이 처음부터 펼쳐져 있다)
    var detailsExpanded = false
    var mappingExpanded = true
    fileprivate var draftReview: DraftRecoveryReview?
    fileprivate var playlistReview: PlaylistRecoveryReview?

    init(request: RecoveryRequest) {
        self.request = request
        id = request.id
        switch request {
        case let .draft(row, kind): title = row.title; kindLabel = kind.label
        case .playlist:
            title = ""
            kindLabel = String(localized: "recovery.kind.playlist", defaultValue: "재생 목록", bundle: UIStrings.bundle)
        }
    }

    var isPlaylist: Bool { if case .playlist = request { true } else { false } }

    /// 고를 수 있는 것. 합칠 수 없는 줄은 내 편집 유지를 뺀다.
    var options: [RecoveryChoice] {
        guard phase == .ready else { return [] }
        return canKeep ? [.keep, .useCurrent, .later] : [.useCurrent, .later]
    }

    func label(for choice: RecoveryChoice) -> String {
        switch choice {
        case .keep: isPlaylist ? String(ui: "다시 적용") : String(ui: "내 편집 유지·다시 적용")
        case .useCurrent: isPlaylist ? String(ui: "초안 버리기") : String(ui: "현재값 사용")
        case .later: String(ui: "나중에")
        }
    }

    /// 고른 것이 무엇을 하는지(저장하기 전에 읽는 글)
    var consequence: String? {
        guard phase == .ready else { return nil }
        switch (choice, isPlaylist) {
        case (.keep, false): return String(ui: "내 편집을 현재값 위에 다시 쌓습니다.")
        case (.keep, true): return String(ui: "다시 적용할 수 있는 편집을 현재 목록 위에 초안으로 쌓습니다.")
        case (.useCurrent, false): return String(ui: "이 곡의 \(kindLabel) 편집을 버리고 현재값을 씁니다. 다른 곡과 다른 종류의 초안은 그대로입니다.")
        case (.useCurrent, true): return String(ui: "이 목록의 막힌 편집을 되돌릴 수 없게 버립니다.")
        case (.later, _): return String(ui: "초안을 그대로 둡니다.")
        }
    }

    /// 내 편집을 버리는 선택인지(저장 전에 눈에 띄게 알린다)
    var discardsEdits: Bool { phase == .ready && choice == .useCurrent }
}

/// 막힌 초안 복구 시트의 모델(#232). 곡·종류별, 재생 목록별 줄을 한 시트에 모아 줄마다 "내 편집 유지·다시 적용 / 현재값 사용 / 나중에"를
/// 고른 뒤 한 번에 저장한다. 비교·적용은 `LibraryStore`의 기존 규칙(`prepareDraftRecovery`·`applyDraftRecovery`·`preparePlaylistRecovery`·
/// `applyPlaylistRecovery`)을 줄마다 그대로 부르므로, 같은 선택은 예전 연속 창 흐름과 같은 초안 상태를 만든다.
@MainActor @Observable
final class RecoverySheetModel: Identifiable {
    struct Dependencies {
        var readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)?
        var save: ((RecoveryDraft) throws -> Void)?
    }

    /// 비교·적용 규칙과 시트를 띄울 자리를 가진 라이브러리 화면 모델. 시트가 닫히면 `close()`가 `host.recoverySheet`를 비워 이 참조의 순환이 풀린다.
    @ObservationIgnored let host: LibraryStore
    @ObservationIgnored let anchor: RecoverySheetAnchor
    @ObservationIgnored private let dependencies: Dependencies
    private(set) var lines: [RecoveryLine]
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isClosed = false
    /// 이 시트에서 저장한 줄이 하나라도 있는지(닫기 단추 이름을 정한다)
    private(set) var hasSaved = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var loadStarted = false
    /// 저장 단추가 시작한 일. 시트가 내려가도 끝까지 간다. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(host: LibraryStore, requests: [RecoveryRequest], anchor: RecoverySheetAnchor = .library, dependencies: Dependencies = Dependencies()) {
        self.host = host
        self.anchor = anchor
        self.dependencies = dependencies
        // 같은 곡·종류가 두 번 들어와도 줄은 하나다(저장이 같은 초안을 두 번 적용하지 않게).
        var seen = Set<String>()
        lines = requests.filter { seen.insert($0.id).inserted }.map(RecoveryLine.init)
        // 비교를 마치기 전에도 재생 목록 줄에 이름이 보이게(비교 뒤에는 rekordbox의 현재 이름으로 바뀐다)
        for line in lines { if case let .playlist(id) = line.request { line.title = host.playlistItem(id)?.name ?? "" } }
    }

    var canSave: Bool {
        !isClosed && !isSaving && !isLoading && lines.contains { $0.phase == .ready && $0.choice != .later }
    }

    /// "현재값 사용"·"초안 버리기"를 고른 줄 수(저장하면 내 편집을 버린다)
    var discardCount: Int { lines.filter(\.discardsEdits).count }

    // MARK: - 읽기

    /// 줄마다 지금 rekordbox와 비교한다. 곡 줄 전체의 현재값은 사본 하나로, 재생 목록 줄 전체의 현재값은 사본 하나로 읽고 줄끼리 나눠 쓴다
    /// (줄마다 사본을 뜨고 라이브러리 전체를 읽으면 줄이 늘수록 느려진다). 비교는 한 줄씩 차례로 한다.
    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        isLoading = true
        defer { isLoading = false }
        let prefetches = await prefetchDrafts()
        let playlistCurrent = await prefetchPlaylists()
        for line in lines {
            if isClosed || Task.isCancelled { return }
            switch line.request {
            case let .draft(row, kind): await loadDraft(line, row: row, kind: kind, prefetch: prefetches[line.id])
            case .playlist(let id): await loadPlaylist(line, id: id, current: playlistCurrent)
            }
        }
    }

    /// 곡 줄의 현재값을 사본 하나로 읽는다. 읽지 못한 줄은 그 이유를 결과로 든다.
    private func prefetchDrafts() async -> [String: Result<RecoveryPrefetch, any Error>] {
        let inputs: [(id: String, original: RecoveryDraft)] = lines.compactMap { line in
            guard case let .draft(row, kind) = line.request,
                  let original = host.recoveryInput(uuid: row.track.uuid, kind: kind) else { return nil }
            return (line.id, original)
        }
        guard !inputs.isEmpty else { return [:] }
        do {
            let results = try await host.readRecoveryPrefetches(inputs.map(\.original), readCurrent: dependencies.readCurrent)
            return Dictionary(uniqueKeysWithValues: zip(inputs.map(\.id), results))
        } catch {
            return Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, Result<RecoveryPrefetch, any Error>.failure(error)) })
        }
    }

    private func prefetchPlaylists() async -> Result<PlaylistRecoveryCurrent, any Error>? {
        guard lines.contains(where: \.isPlaylist) else { return nil }
        do { return .success(try await host.readPlaylistRecoveryPrefetch()) } catch { return .failure(error) }
    }

    private func loadDraft(_ line: RecoveryLine, row: TrackRow, kind: DraftRecoveryKind,
                           prefetch: Result<RecoveryPrefetch, any Error>?) async {
        do {
            let prefetched = try prefetch?.get()
            let review = try await host.prepareDraftRecovery(row: row, kind: kind, readCurrent: dependencies.readCurrent,
                                                              prefetched: prefetched)
            line.title = review.title
            line.draftReview = review
            line.isStale = RecoverySummary.isStale(review)
            let missing = RecoverySummary.missingCueMappings(review)
            let keepable = line.isStale && review.keepRefusal == nil
                && (try? review.original.resolved(onto: review.current, choice: .keepEditing)) != nil
            line.canKeep = keepable
            if !line.isStale {
                // rekordbox가 바뀐 것이 아니면 다시 적용할 것이 없다. 쓰지 못한 이유는 쓰기 결과에 있다.
                line.keepBlockedReason = String(ui: "이 초안은 rekordbox가 바뀌어서 막힌 것이 아니니 ‘마지막 쓰기 결과…’에서 쓰지 못한 이유를 확인하세요.")
            } else if !keepable {
                if missing.isEmpty {
                    line.keepBlockedReason = review.keepRefusal
                        ?? String(ui: "큐 ID나 그리드 구간의 대응이 모호해 자동으로 다시 적용할 수 없으니 현재값을 사용하거나 ‘나중에’로 두고 편집 대상을 다시 지정하세요.")
                } else {
                    line.keepBlockedReason = String(ui: "내 큐가 rekordbox에서 다시 만들어졌으니 아래에서 이어 줄 현재 큐를 모두 고르면 내 편집을 유지할 수 있습니다.")
                    line.cueMapping = RecoveryCueMapping(missing: missing, candidates: RecoverySummary.cueMappingCandidates(review))
                }
            }
            refreshText(line)
            line.choice = keepable ? .keep : .later
            line.phase = .ready
        } catch {
            line.phase = .failed(Self.message(for: error))
        }
    }

    private func loadPlaylist(_ line: RecoveryLine, id: String, current: Result<PlaylistRecoveryCurrent, any Error>?) async {
        do {
            let review = try await host.preparePlaylistRecovery(playlist: id, prefetched: try current?.get())
            line.title = RecoverySummary.playlistTitle(review)
            line.playlistReview = review
            line.canKeep = !review.recovery.reapplied.isEmpty
            if !line.canKeep {
                line.keepBlockedReason = String(ui: "다시 적용할 수 있는 편집이 없으니 초안을 버리거나 ‘나중에’로 두고 목록을 다시 편집하세요.")
            }
            line.summary = RecoverySummary.playlistSummary(review)
            line.notes = RecoverySummary.playlistNotes(review)
            line.details = RecoverySummary.playlistDetails(review)
            line.choice = line.canKeep ? .keep : .later
            line.phase = .ready
        } catch {
            line.phase = .failed(Self.message(for: error))
        }
    }

    /// 쓰기 결과에서 열 때: rekordbox가 바뀌어 막힌 줄만 남긴다. 다른 이유로 막힌 곡의 이유는 쓰기 결과(토스트·결과 보기)에 있다.
    func keepOnlyStale() {
        lines.removeAll { $0.phase == .ready && !$0.isPlaylist && !$0.isStale }
    }

    /// 비교 내용(요약·경고·자세히 보기)을 지금 검토 상태(이어 준 큐 대응 포함)로 다시 만든다.
    private func refreshText(_ line: RecoveryLine) {
        guard let review = line.draftReview else { return }
        line.summary = RecoverySummary.summary(review)
        line.notes = RecoverySummary.notes(review)
        line.details = RecoverySummary.details(review)
    }

    // MARK: - 고르기

    func choose(_ choice: RecoveryChoice, for line: RecoveryLine) {
        guard !isClosed, !isSaving, line.options.contains(choice) else { return }
        line.choice = choice
    }

    /// 내 큐(`oldSource`)에 이을 현재 큐를 고른다(nil이면 이은 것을 푼다). 모두 이어 규칙이 받아들이면 내 편집 유지를 고를 수 있다.
    func mapCue(_ oldSource: String, to currentSource: String?, in line: RecoveryLine) {
        guard !isClosed, !isSaving, var mapping = line.cueMapping, var review = line.draftReview,
              mapping.missing.contains(where: { $0.sourceID == oldSource }) else { return }
        if let currentSource {
            guard mapping.candidates(for: oldSource).contains(where: { $0.sourceID == currentSource }) else { return }
            mapping.selection[oldSource] = currentSource
        } else {
            mapping.selection[oldSource] = nil
        }
        line.mappingFailure = nil
        review.cueSourceMappings = mapping.isComplete ? mapping.selection : [:]
        var keepable = false
        if mapping.isComplete {
            do {
                let resolved = try review.original.resolved(onto: review.current, choice: .keepEditing, sourceMappings: mapping.selection)
                keepable = DraftRecoveryReview.gridKeepRefusal(original: review.original, resolved: resolved, currentGrid: review.currentGrid,
                                                              lengthSeconds: review.currentRow?.track.lengthSeconds) == nil
                if !keepable { line.mappingFailure = review.keepRefusal }
            } catch {
                line.mappingFailure = String(ui: "이 대응으로는 내 편집을 다시 적용할 수 없으니 다른 큐를 고르거나 현재값을 사용하세요.")
            }
        }
        line.cueMapping = mapping
        line.draftReview = review
        let couldKeep = line.canKeep
        line.canKeep = keepable
        refreshText(line)
        // 아직 고르지 않은(나중에) 줄만 내 편집 유지로 바꾼다. 사람이 고른 현재값 사용은 그대로 둔다.
        if keepable, !couldKeep, line.choice == .later { line.choice = .keep } else if !keepable, line.choice == .keep { line.choice = .later }
    }

    // MARK: - 저장

    /// 고른 줄을 차례로 저장한다. 줄마다 기존 규칙이 지금 상태를 다시 확인하므로, 실패한 줄은 초안을 그대로 두고 이유를 줄에 남기며
    /// 다른 줄은 그대로 저장한다. 실패한 줄이 남지 않았으면 시트를 닫는다. 저장 직전의 현재값은 곡 줄 전체에 사본 하나, 재생 목록 줄 전체에 사본 하나로 읽는다.
    /// - Returns: 고른 줄이 모두 저장됐는지(저장할 줄이 없으면 false)
    func startSave() { task = Task { await save() } }

    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        let chosen = lines.filter { $0.phase == .ready && $0.choice != .later }
        let latest = await prefetchLatest(chosen)
        var saved = 0, failed = 0
        for line in chosen {
            line.resultNote = nil
            do {
                switch line.request {
                case .draft: try await saveDraft(line, latest: latest.drafts[line.id])
                case .playlist(let id): try await savePlaylist(line, id: id, current: latest.playlists)
                }
                line.phase = .saved
                saved += 1
            } catch {
                line.choice = .later
                line.phase = .failed(Self.message(for: error))
                failed += 1
            }
        }
        if saved > 0 {
            hasSaved = true
            host.toast = failed == 0
                ? AppToast(kind: .success, title: String(ui: "초안을 저장했습니다"),
                           detail: String(ui: "쓰기 미리 보기에서 지원 제한과 최신 상태를 다시 확인하세요."))
                : AppToast(kind: .warning, title: String(ui: "초안 일부만 저장했습니다"),
                           detail: String(ui: "저장하지 못한 줄은 비교 창에서 이유를 확인하세요."))
        }
        // 앞서 저장에 실패한 줄이 남아 있으면 이유를 볼 수 있게 시트를 열어 둔다.
        if !lines.contains(where: { if case .failed = $0.phase { true } else { false } }) { close() }
        return failed == 0
    }

    /// 저장 직전의 현재값(곡 줄 전체 사본 하나, 재생 목록 줄 전체 사본 하나). 읽지 못하면 그 이유가 줄마다의 저장 실패가 된다.
    private func prefetchLatest(_ chosen: [RecoveryLine])
        async -> (drafts: [String: Result<RecoveryPrefetch, any Error>], playlists: Result<PlaylistRecoveryCurrent, any Error>?) {
        let inputs: [(id: String, original: RecoveryDraft)] = chosen.compactMap { line in
            line.draftReview.map { (line.id, $0.original) }
        }
        var drafts: [String: Result<RecoveryPrefetch, any Error>] = [:]
        if !inputs.isEmpty {
            do {
                let results = try await host.readRecoveryPrefetches(inputs.map(\.original), readCurrent: dependencies.readCurrent)
                drafts = Dictionary(uniqueKeysWithValues: zip(inputs.map(\.id), results))
            } catch {
                drafts = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, Result<RecoveryPrefetch, any Error>.failure(error)) })
            }
        }
        var playlists: Result<PlaylistRecoveryCurrent, any Error>?
        if chosen.contains(where: \.isPlaylist) {
            do { playlists = .success(try await host.readPlaylistRecoveryPrefetch()) } catch { playlists = .failure(error) }
        }
        return (drafts, playlists)
    }

    private func saveDraft(_ line: RecoveryLine, latest: Result<RecoveryPrefetch, any Error>?) async throws {
        guard let review = line.draftReview else { throw DJCError.writeRefused(String(ui: "복구할 초안을 확인하지 못했으니 편집을 저장하고 곡을 다시 선택하세요.")) }
        try await host.applyDraftRecovery(review, choice: line.choice == .keep ? .keepEditing : .useCurrent,
                                           readCurrent: dependencies.readCurrent, save: dependencies.save, latest: try latest?.get())
    }

    /// 재생 목록은 앞 목록을 저장하면 초안 전체가 바뀌므로, 비교한 뒤 초안이 바뀌었으면(같은 저장의 앞 줄이든 이전 저장이든) 같은 기준으로
    /// 다시 비교해 고를 때 본 것과 같을 때만 적용한다.
    private func savePlaylist(_ line: RecoveryLine, id: String, current: Result<PlaylistRecoveryCurrent, any Error>?) async throws {
        guard var review = line.playlistReview else { throw DJCError.writeRefused(String(ui: "복구할 초안을 확인하지 못했으니 편집을 저장하고 곡을 다시 선택하세요.")) }
        let latest = try current?.get()
        if host.playlistDraft != review.original {
            guard host.blockedPlaylistRecoveryIDs.contains(id) else {
                // 이미 해결됐으니 줄은 저장한 것으로 보고 안내만 남긴다.
                line.resultNote = String(ui: "앞에서 저장하면서 이미 해결됐습니다.")
                return
            }
            let fresh = try await host.preparePlaylistRecovery(playlist: id, prefetched: latest)
            guard Self.sameComparison(fresh, review, shownDetails: line.details) else {
                throw DJCError.writeRefused(String(ui: "앞에서 저장하면서 이 목록의 비교 내용이 바뀌어 초안을 그대로 남겼으니 다시 열어 확인하세요."))
            }
            review = fresh
        }
        try await host.applyPlaylistRecovery(review, reapply: line.choice == .keep && line.canKeep, latest: latest)
    }

    /// 고를 때 본 비교와 같은지. 편집 번호는 앞 목록을 버리면 당겨지므로 번호가 아니라 편집 내용으로 견준다.
    private static func sameComparison(_ fresh: PlaylistRecoveryReview, _ shown: PlaylistRecoveryReview, shownDetails: [String]) -> Bool {
        func reapplied(_ review: PlaylistRecoveryReview) -> [PlaylistEdit] { review.recovery.reapplied.map { review.original.steps[$0].edit } }
        return RecoverySummary.playlistDetails(fresh) == shownDetails && reapplied(fresh) == reapplied(shown)
            && fresh.recovery.refused.values.sorted() == shown.recovery.refused.values.sorted()
    }

    /// 줄에 남기는 이유는 무엇을 하면 되는지까지 한 문장이다. 쓰기 거절은 이미 그렇게 쓴 문장이라 뒤에 일반 안내를 덧붙이지 않는다.
    static func message(for error: any Error) -> String {
        if error is CancellationError { return String(ui: "비교를 마치지 못했으니 이 창을 닫고 다시 여세요.") }
        if error is DraftRecoveryError {
            return String(ui: "큐 ID나 그리드 구간의 대응이 모호해 내 편집을 그대로 남겼으니 현재값을 사용하거나 편집 대상을 다시 지정하세요.")
        }
        if case let DJCError.writeRefused(reason) = error { return reason }
        return AppErrorMessage.message(for: error)
    }

    // MARK: - 닫기

    /// 시트를 띄운다: 메인 창(또는 곡 편집 창)이 `host.recoverySheet`를 보고 띄운다.
    func present() { host.recoverySheet = self }

    /// 아무것도 바꾸지 않고 닫는다(저장한 줄은 그대로 저장돼 있다).
    func cancel() { close() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if host.recoverySheet === self { host.recoverySheet = nil }
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    /// 시트가 닫힐 때까지 기다린다(쓰기 흐름은 시트가 닫혀야 끝난다).
    func waitUntilClosed() async {
        if isClosed { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
