import DJCDomain
import Foundation

/// rekordbox XML 가져오기(유스케이스, #72): 다른 도구가 만든 XML을 사본 라이브러리와 비교하고, 고른 차이를 DJCrate 초안으로만 만든다.
/// 앱의 "rekordbox XML 가져오기…"와 CLI `xml-diff --draft`가 같은 순서·규칙을 쓴다. rekordbox 라이브러리에는 쓰지 않는다.
/// 기존 초안은 덮지 않는다: 계획할 때 초안 파일이 있거나 저장 전 입력(`DraftStore.unsavedUUIDs`)·부르는 쪽이 준 초안(앱의 메모리 태그 초안,
/// 덱에서 고친 그리드)이 있으면 건너뛰고, 계획한 뒤 저장 직전에 생긴 초안도 곡 이름으로 알리고 건너뛴다.
public struct ImportXML: Sendable {
    let files: XMLFiles
    let source: LibrarySource
    let drafts: DraftStore
    let draftFiles: DraftFiles
    /// 새로 만드는 재생 목록 초안의 열쇠
    let newKey: @Sendable () -> String

    public init(files: XMLFiles, source: LibrarySource, drafts: DraftStore, draftFiles: DraftFiles,
                newKey: @escaping @Sendable () -> String) {
        self.files = files
        self.source = source
        self.drafts = drafts
        self.draftFiles = draftFiles
        self.newKey = newKey
    }

    // MARK: - 비교

    /// XML과 사본 라이브러리를 읽어 비교한다(메인 밖에서 부른다)
    /// - Parameter share: 분석 파일 뿌리(읽기만). nil이면 그리드를 읽지 않고 비교하지도 않는다
    public func compare(xml: URL, snapshot: URL, share: URL?) throws -> XMLImportComparison {
        let document = try files.read(xml)
        try Task.checkCancellation()
        let library = try files.library(snapshot, share, document)
        try Task.checkCancellation()
        return XMLImportComparison(snapshot: snapshot, share: share, xml: document, library: library,
                                   diff: XMLLibraryDiff.compute(xml: document, library: library))
    }

    /// 메인 밖에서 비교한다. 부른 작업을 취소하면 읽기도 멈춘다(`CancellationError`).
    /// XML 파싱과 분석 파일 읽기가 조각마다 작업 취소를 보므로 `BlockingWork`(GCD)가 아니라 이 작업 안에서 돈다.
    @concurrent
    public func compareInBackground(xml: URL, snapshot: URL, share: URL?) async throws -> XMLImportComparison {
        try compare(xml: xml, snapshot: snapshot, share: share)
    }

    /// 분석 파일 뿌리로 쓸 폴더: 있는 폴더면 그대로, 아니면 nil(없는 폴더면 그리드를 비교하지 않는다)
    public func existingFolder(_ url: URL) -> URL? { files.item(url) == .directory ? url : nil }

    /// 비교할 XML 파일이 있는지(CLI가 DB를 열기 전에 본다)
    public func requireXMLFile(_ xml: URL) throws {
        guard files.item(xml) == .file else {
            throw ReadFailure("missing_xml", String(ui: "XML 파일이 없습니다: \(xml.path). 파일 위치를 확인하세요"))
        }
    }

    // MARK: - 초안 만들기

    /// 재생 목록 초안을 고칠 곳: 지금 초안과 저장(앱은 화면이 든 메모리 초안, CLI는 초안 파일)
    public struct PlaylistTarget: Sendable {
        public var current: @MainActor () -> PlaylistDraft
        public var save: @MainActor (PlaylistDraft) throws -> Void

        public init(current: @escaping @MainActor () -> PlaylistDraft, save: @escaping @MainActor (PlaylistDraft) throws -> Void) {
            self.current = current
            self.save = save
        }
    }

    /// 덱에 올린 곡의 그리드 초안은 덱이 받아 자기 저장 경로로 쓴다(따로 쓰면 덱의 다음 편집·되돌리기가 그 파일을 덮거나 지운다, 앱만)
    public struct DeckGrid: Sendable {
        /// 지금 덱의 곡(UUID)과 그 그리드 초안을 덱에서 고쳤는지
        public var state: @MainActor () -> (uuid: String, hasChanges: Bool)?
        /// 덱이 받아 저장한다. 받지 못하면(덱에서 고쳤거나 다른 곡) 거짓
        public var adopt: @MainActor (GridDraft) -> Bool

        public init(state: @escaping @MainActor () -> (uuid: String, hasChanges: Bool)?, adopt: @escaping @MainActor (GridDraft) -> Bool) {
            self.state = state
            self.adopt = adopt
        }
    }

    /// 초안 만들기의 앞뒤 사정
    public struct Context: Sendable {
        /// 파일 말고도 이미 있는 것으로 볼 초안(곡 UUID). 앱은 메모리 태그 초안을 준다(저장 전 입력은 여기서 더한다)
        public var existing: [XMLImportDrafts.Kind: Set<String>]
        public var playlists: PlaylistTarget
        public var deck: DeckGrid?

        public init(existing: [XMLImportDrafts.Kind: Set<String>] = [:], playlists: PlaylistTarget, deck: DeckGrid? = nil) {
            self.existing = existing
            self.playlists = playlists
            self.deck = deck
        }
    }

    /// 고른 차이를 초안으로 만든다(앱). 계획과 파일 저장은 메인 밖에서 하고, 재생 목록·덱은 메인 액터에서 맞춘다.
    /// 계획하는 동안 취소되면 아무것도 쓰지 않고 빈 결과를 돌려준다. 곡별 초안 파일을 쓴 뒤 실패하면 그때까지 센 것과 함께 던진다(`PartialFailure`).
    /// CLI는 같은 단계를 그 자리에서 부른다(`makeDraftsNow`).
    @MainActor
    public func makeDrafts(_ comparison: XMLImportComparison, selection: XMLImportDrafts.Selection,
                           context: Context) async throws -> XMLImportDraftResult {
        // 덱에서 고친 그리드는 파일보다 덱이 최신일 수 있다.
        var extra = context.existing
        if let deck = context.deck?.state(), deck.hasChanges { extra[.grid, default: []].insert(deck.uuid) }
        let existing = settledExisting(extra)
        let playlistBase = context.playlists.current()
        let planned = try await LoadLibrary.background { [self] in
            try plan(comparison, selection: selection, playlistDraft: playlistBase, existing: existing)
        }
        guard !Task.isCancelled else { return XMLImportDraftResult() }
        var plan = planned
        let playlist = plan.playlistDraft
        plan.playlistDraft = nil
        // 덱에 올린 곡의 그리드는 아래에서 덱에 넘긴다.
        let deckUUID = context.deck?.state()?.uuid
        let deckGrid = plan.gridDrafts.first { $0.trackUUID == deckUUID }
        var files = plan
        files.gridDrafts.removeAll { $0.trackUUID == deckUUID }
        let saved = try await LoadLibrary.background { [self, files] in try save(files) }
        var result = Self.result(plan, saved: saved)
        do {
            if let deckGrid, let deck = context.deck {
                let subject = plan.titles[deckGrid.trackUUID] ?? deckGrid.trackUUID
                let skipped = XMLImportDrafts.Note(kind: .grid, libraryKey: nil, subject: subject, reason: XMLImportDrafts.existingReason(.grid))
                if let now = deck.state(), now.uuid == deckGrid.trackUUID {
                    // 저장하는 동안 덱에서 그리드를 고쳤으면 덱 초안을 남긴다.
                    if !now.hasChanges, deck.adopt(deckGrid) { result.grids += 1 } else { result.skipped.append(skipped) }
                } else {
                    // 그 사이 덱의 곡이 바뀌었으면 파일로 쓴다.
                    var rest = XMLImportDrafts.Plan()
                    rest.gridDrafts = [deckGrid]
                    rest.titles = plan.titles
                    let other = try save(rest)
                    result.grids += other.saved[.grid, default: 0]
                    result.skipped += other.raced
                }
            }
            switch Self.playlistStep(playlist, base: playlistBase, current: context.playlists.current()) {
            case .none: break
            case let .save(draft):
                try context.playlists.save(draft)
                result.playlists = plan.playlistLists
            case .raced: result.skipped.append(Self.playlistRaced)
            }
        } catch {
            // 곡별 초안 파일은 이미 썼다: 센 것을 함께 돌려준다
            throw PartialFailure(result: result, error: error)
        }
        return result
    }

    /// 고른 차이를 그 자리에서 초안으로 만든다(CLI `xml-diff --draft`). 앱과 같은 단계(저장 대기 입력·초안 파일은 덮지 않음 → 계획 →
    /// 계획한 뒤 생긴 파일은 건너뜀 → 재생 목록 초안이 그대로일 때만 저장)이고, 덱이 없고 재생 목록 초안은 파일(`draftFiles.playlist`)이다.
    /// 실패하면 던진다(앞서 쓴 초안은 남는다).
    public func makeDraftsNow(_ comparison: XMLImportComparison, selection: XMLImportDrafts.Selection) throws -> XMLImportDraftResult {
        let existing = settledExisting([:])
        let current = draftFiles.playlist, savePlaylist = draftFiles.savePlaylist
        let base = current()
        var plan = try plan(comparison, selection: selection, playlistDraft: base, existing: existing)
        let playlist = plan.playlistDraft
        plan.playlistDraft = nil
        var result = Self.result(plan, saved: try save(plan))
        switch Self.playlistStep(playlist, base: base, current: current()) {
        case .none: break
        case let .save(draft):
            try savePlaylist(draft)
            result.playlists = plan.playlistLists
        case .raced: result.skipped.append(Self.playlistRaced)
        }
        return result
    }

    /// 걸린 저장을 끝내고, 저장 대기 입력(큐·그리드)을 이미 있는 초안으로 더한다
    private func settledExisting(_ extra: [XMLImportDrafts.Kind: Set<String>]) -> [XMLImportDrafts.Kind: Set<String>] {
        drafts.flush()
        let unsaved = drafts.unsavedUUIDs()
        var existing = extra
        existing[.cue, default: []].formUnion(unsaved)
        existing[.grid, default: []].formUnion(unsaved)
        return existing
    }

    private static func result(_ plan: XMLImportDrafts.Plan, saved: SaveResult) -> XMLImportDraftResult {
        XMLImportDraftResult(cues: saved.saved[.cue, default: 0], grids: saved.saved[.grid, default: 0], tags: saved.saved[.tag, default: 0],
                             skipped: plan.skipped + saved.raced, losses: plan.losses)
    }

    /// 재생 목록 초안을 어떻게 할지: 계획을 세우는 동안 재생 목록 초안이 바뀌었으면 덮지 않는다
    private enum PlaylistStep { case none, save(PlaylistDraft), raced }

    private static func playlistStep(_ playlist: PlaylistDraft?, base: PlaylistDraft, current: PlaylistDraft) -> PlaylistStep {
        guard let playlist else { return .none }
        return current == base ? .save(playlist) : .raced
    }

    private static var playlistRaced: XMLImportDrafts.Note {
        XMLImportDrafts.Note(kind: .playlist, libraryKey: nil, subject: "", reason: XMLImportDrafts.existingReason(.playlist))
    }

    /// 사본·분석 파일·기존 초안을 읽어 계획을 세운다(쓰지 않는다, 메인 밖에서 부른다)
    /// - Parameter existing: 파일 말고도 이미 있는 것으로 볼 초안(곡 UUID)
    public func plan(_ comparison: XMLImportComparison, selection: XMLImportDrafts.Selection, playlistDraft: PlaylistDraft,
                     existing extra: [XMLImportDrafts.Kind: Set<String>] = [:]) throws -> XMLImportDrafts.Plan {
        let diff = comparison.diff
        let library = try source.library(comparison.snapshot)
        let wanted = Set(diff.tracks.map(\.libraryKey)).filter { key in
            XMLImportDrafts.Kind.allCases.contains { selection.includes($0, track: key) }
        }
        let listed = Set(library.playlists.filter { !$0.isFolder }.flatMap(\.trackIDs))
        var sources: [String: XMLImportDrafts.TrackSource] = [:]
        for track in library.tracks where wanted.contains(track.id) {
            let grid = selection.kinds.contains(.grid) && comparison.share != nil
                ? source.grid(track.analysisDataPath, comparison.share) : nil
            let existing = Set(XMLImportDrafts.Kind.allCases.filter {
                draftFiles.exists($0, track.uuid) || extra[$0]?.contains(track.uuid) == true
            })
            sources[track.id] = XMLImportDrafts.TrackSource(track: track, cues: library.cues(for: track), grid: grid,
                                                            inPlaylist: listed.contains(track.id), existing: existing)
        }
        return XMLImportDrafts.plan(diff: diff, selection: selection, sources: sources,
                                    layout: PlaylistLayout(rekordbox: library.playlists), playlistDraft: playlistDraft, newKey: newKey,
                                    newID: drafts.newCueID)
    }

    /// 계획의 큐·그리드·태그 초안 파일을 쓴다. 계획한 뒤 그 사이 생긴 곡별 초안 파일은 덮지 않고 `raced`로 돌려준다(메인 밖에서 부른다)
    public func save(_ plan: XMLImportDrafts.Plan) throws -> SaveResult {
        var result = SaveResult()
        func raced(_ kind: XMLImportDrafts.Kind, _ uuid: String) -> Bool {
            guard draftFiles.exists(kind, uuid) else { return false }
            result.raced.append(XMLImportDrafts.Note(kind: kind, libraryKey: nil, subject: plan.titles[uuid] ?? uuid,
                                                     reason: XMLImportDrafts.existingReason(kind)))
            return true
        }
        for draft in plan.cueDrafts where !raced(.cue, draft.trackUUID) {
            try draftFiles.saveCue(draft)
            result.saved[.cue, default: 0] += 1
        }
        for draft in plan.gridDrafts where !raced(.grid, draft.trackUUID) {
            try draftFiles.saveGrid(draft)
            result.saved[.grid, default: 0] += 1
        }
        for draft in plan.tagDrafts where !raced(.tag, draft.trackUUID) {
            try draftFiles.saveTag(draft)
            result.saved[.tag, default: 0] += 1
        }
        return result
    }

    /// 곡별 초안 파일을 쓴 뒤(덱 그리드·재생 목록 초안에서) 실패했다. 그때까지 만든 초안 수를 함께 든다
    public struct PartialFailure: Error {
        public var result: XMLImportDraftResult
        public var error: any Error
    }

    /// 초안 파일 저장 결과
    public struct SaveResult: Sendable, Equatable {
        /// 계획을 세운 뒤 저장하기 전에 생긴 초안이 있어 건너뛴 것(곡 이름으로)
        public var raced: [XMLImportDrafts.Note] = []
        /// 종류별로 저장한 초안 수
        public var saved: [XMLImportDrafts.Kind: Int] = [:]

        public init() {}
    }
}

/// XML과 사본 라이브러리의 비교(가져오기 미리 보기·CLI 보고서)
public struct XMLImportComparison: Sendable {
    public var snapshot: URL
    /// 그리드를 읽은 분석 파일 뿌리(nil이면 그리드를 비교하지 않았다)
    public var share: URL?
    public var xml: XMLLibrary
    public var library: XMLLibrary
    public var diff: XMLLibraryDiff.Result

    public init(snapshot: URL, share: URL?, xml: XMLLibrary, library: XMLLibrary, diff: XMLLibraryDiff.Result) {
        self.snapshot = snapshot
        self.share = share
        self.xml = xml
        self.library = library
        self.diff = diff
    }
}

/// 초안 만들기 결과(앱 시트·CLI 줄이 보인다)
public struct XMLImportDraftResult: Equatable, Sendable {
    public var cues = 0
    public var grids = 0
    public var tags = 0
    /// 편집한 재생 목록 수(재생 목록 초안을 저장했을 때)
    public var playlists = 0
    /// 기존 초안이 있어 건너뛴 것(계획 때·저장 직전·덱·재생 목록)
    public var skipped: [XMLImportDrafts.Note] = []
    /// 초안에 담지 못한 차이
    public var losses: [XMLImportDrafts.Note] = []
    /// 화면이 보일 실패 이유(앱이 채운다)
    public var failure: String?

    public init(cues: Int = 0, grids: Int = 0, tags: Int = 0, playlists: Int = 0, skipped: [XMLImportDrafts.Note] = [],
                losses: [XMLImportDrafts.Note] = [], failure: String? = nil) {
        self.cues = cues
        self.grids = grids
        self.tags = tags
        self.playlists = playlists
        self.skipped = skipped
        self.losses = losses
        self.failure = failure
    }
}
