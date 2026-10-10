import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 가져오기 차이 미리 보기 시트의 내용
struct XMLImportPreview: Identifiable, Sendable {
    let id = UUID()
    var fileName: String
    var comparison: XMLImportComparison
    var snapshot: URL { comparison.snapshot }
    var shareRoot: URL? { comparison.share }
    var xml: XMLLibrary { comparison.xml }
    var library: XMLLibrary { comparison.library }
    var diff: XMLLibraryDiff.Result { comparison.diff }
}

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72) 화면 모델(#249). 다른 도구가 만든 rekordbox XML을 메인 스레드 밖에서 읽어 지금 라이브러리와 비교하고,
/// 미리 보기 시트에서 고른 차이를 초안으로만 만든다(유스케이스 `ImportXML`, CLI `xml-diff --draft`와 같은 규칙). rekordbox에는 쓰지 않는다.
/// 메뉴가 읽는 중인지 보므로 `LibraryStore`가 하나를 들고 있는다(`store.xmlImport`).
@MainActor @Observable
final class XMLImportModel {
    struct Ports {
        /// 비교할 사본 라이브러리(없으면 읽지 않는다)
        var snapshot: @MainActor () -> URL?
        /// 분석 파일 뿌리: 준 폴더(없으면 저장소의 share)가 있는 폴더면 그대로, 아니면 nil(그리드를 비교하지 않는다)
        var share: @MainActor (URL?) -> URL?
        /// XML과 사본을 메인 밖에서 읽어 비교한다
        var compare: @Sendable (_ xml: URL, _ snapshot: URL, _ share: URL?) async throws -> XMLImportComparison
        /// 고른 차이를 초안으로 만든다
        var makeDrafts: @MainActor (XMLImportComparison, XMLImportDrafts.Selection) async throws -> XMLImportDraftResult
        /// 초안 파일이 생긴 뒤 화면의 초안 표시를 다시 읽는다
        var draftsChanged: @MainActor () async -> Void
        var isWriting: @MainActor () -> Bool
        /// 읽지 못한 이유를 알린다
        var fail: @MainActor (String) -> Void
    }

    /// 미리 보기 탭
    enum Tab: Hashable, CaseIterable {
        case cue, grid, tag, playlist, unmatched

        var kind: XMLImportDrafts.Kind? {
            switch self {
            case .cue: .cue
            case .grid: .grid
            case .tag: .tag
            case .playlist: .playlist
            case .unmatched: nil
            }
        }
    }

    struct UnmatchedRow { var key: String; var title: String; var detail: String }

    /// XML·라이브러리를 읽는 중
    private(set) var isReading = false
    /// 차이 미리 보기(있으면 시트가 열린다). 바뀌면 결과를 지우고 처음 고를 차이를 정한다
    var preview: XMLImportPreview? {
        didSet {
            guard oldValue?.id != preview?.id else { return }
            result = nil
            chooseDefaults()
        }
    }
    /// 미리 보기에서 만든 초안 결과(시트가 결과 화면으로 바뀐다)
    private(set) var result: XMLImportDraftResult?
    private(set) var isMakingDrafts = false
    var tab: Tab = .cue
    /// 종류별로 고른 곡(라이브러리 키)
    private(set) var chosen: [XMLImportDrafts.Kind: Set<String>] = [:]
    private(set) var chosenLists: Set<[String]> = []
    /// 마지막 읽기(시험이 기다린다)
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// 마지막 초안 만들기(닫으면 취소할 수 있게 든다)
    @ObservationIgnored private(set) var draftTask: Task<Void, Never>?
    @ObservationIgnored private let ports: Ports

    init(ports: Ports) {
        self.ports = ports
    }

    convenience init(store: LibraryStore) {
        let importer = store.useCases.importXML
        self.init(ports: Ports(
            snapshot: { [weak store] in store?.snapshotURL },
            share: { [weak store] root in (root ?? store?.shareRoot).flatMap(importer.existingFolder) },
            compare: { xml, snapshot, share in try await importer.compareInBackground(xml: xml, snapshot: snapshot, share: share) },
            makeDrafts: { [weak store] comparison, selection in
                guard let store else { throw CancellationError() }
                return try await importer.makeDrafts(comparison, selection: selection, context: store.xmlImportContext())
            },
            draftsChanged: { [weak store] in await store?.refreshExternalDrafts() },
            isWriting: { [weak store] in store?.isWritingRekordbox ?? false },
            fail: { [weak store] in store?.staging.stagingMessage = AppMessage(kind: .failure, text: $0) }))
    }

    /// 읽는 중이거나 미리 보기가 열려 있다(메뉴가 새 가져오기를 막는다)
    var isBusy: Bool { isReading || preview != nil }

    // MARK: 읽기

    /// - Parameter shareRoot: 분석 파일 뿌리(읽기만, 없으면 저장소의 share). 시험은 합성 사본의 `share`를 준다. 없는 폴더면 그리드를 비교하지 않는다.
    func start(from url: URL, shareRoot: URL? = nil) {
        guard let snapshot = ports.snapshot() else { return }
        let share = ports.share(shareRoot)
        cancel()
        isReading = true
        let compare = ports.compare
        task = Task { [weak self] in
            let result = await Result { try await compare(url, snapshot, share) }
            guard let self, !Task.isCancelled else { return }
            isReading = false
            task = nil
            switch result {
            case let .success(comparison): preview = XMLImportPreview(fileName: url.lastPathComponent, comparison: comparison)
            case .failure(is CancellationError): break
            case let .failure(error): ports.fail(Self.failure(error))
            }
        }
    }

    /// 읽는 중인 가져오기와 계획 중인 초안 만들기를 멈춘다(시트를 닫거나 새로 가져올 때). 저장을 시작한 초안은 끝까지 쓴다.
    func cancel() {
        task?.cancel()
        draftTask?.cancel()
        isReading = false
    }

    static func failure(_ error: any Error) -> String {
        let reason = (error as? XMLReadError)?.reason ?? AppErrorMessage.message(for: error)
        return String(ui: "rekordbox XML을 가져오지 못했습니다: \(reason)")
    }

    // MARK: 초안 만들기

    var chosenCount: Int { chosen.values.reduce(0) { $0 + $1.count } + chosenLists.count }
    var canMakeDrafts: Bool { !isMakingDrafts && chosenCount > 0 && !ports.isWriting() }

    /// 미리 보기 시트의 "초안으로 만들기". 닫으면 취소할 수 있게 작업을 들고 있는다.
    func startDrafts() {
        guard let preview else { return }
        let selection = XMLImportDrafts.Selection(playlistPaths: chosenLists, tracksByKind: chosen)
        draftTask?.cancel()
        draftTask = Task { [weak self] in await self?.makeDrafts(preview, selection: selection) }
    }

    /// 고른 차이를 초안으로 만든다. 저장 전 입력(메모리 태그 초안·저장하지 못한 큐·그리드)과 기존 초안 파일은 덮지 않고,
    /// 재생 목록은 메모리 초안에 편집을 덧붙여 저장한다. 덱에 올린 곡의 그리드 초안은 덱이 받는다(유스케이스 `ImportXML.makeDrafts`).
    @discardableResult
    func makeDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection) async -> XMLImportDraftResult {
        isMakingDrafts = true
        defer { isMakingDrafts = false }
        var result: XMLImportDraftResult
        do {
            result = try await ports.makeDrafts(preview.comparison, selection)
            if result.cues + result.grids + result.tags > 0 { await ports.draftsChanged() }
        } catch let partial as ImportXML.PartialFailure {
            result = partial.result
            result.failure = String(ui: "초안을 만들지 못했습니다: \(AppErrorMessage.message(for: partial.error))")
        } catch {
            result = XMLImportDraftResult(failure: String(ui: "초안을 만들지 못했습니다: \(AppErrorMessage.message(for: error))"))
        }
        if self.preview?.id == preview.id { self.result = result }
        return result
    }

    // MARK: 고르기

    func isChosen(kind: XMLImportDrafts.Kind, key: String) -> Bool { chosen[kind]?.contains(key) == true }

    func setChosen(_ on: Bool, kind: XMLImportDrafts.Kind, key: String) {
        if on { chosen[kind, default: []].insert(key) } else { chosen[kind]?.remove(key) }
    }

    func isChosen(list path: [String]) -> Bool { chosenLists.contains(path) }

    func setChosen(_ on: Bool, list path: [String]) {
        if on { chosenLists.insert(path) } else { chosenLists.remove(path) }
    }

    /// 이 탭 모두 고르기·빼기
    func setAll(_ on: Bool) {
        guard let diff = preview?.diff else { return }
        switch tab {
        case .cue, .grid, .tag:
            let kind = tab.kind!
            chosen[kind] = on ? Set(tracks(for: kind).map(\.libraryKey)) : []
        case .playlist: chosenLists = on ? Set(diff.playlists.map(\.path)) : []
        case .unmatched: break
        }
    }

    func tracks(for kind: XMLImportDrafts.Kind) -> [XMLLibraryDiff.TrackDiff] {
        (preview?.diff.tracks ?? []).filter { track in
            switch kind {
            case .cue: track.cues != nil
            case .grid: track.grid != nil
            case .tag: !track.tags.isEmpty
            case .playlist: false
            }
        }
    }

    /// 못 맞춘 곡: 라이브러리에 없는 곡, 여러 곡에 맞는 곡
    var unmatched: [UnmatchedRow] {
        guard let preview else { return [] }
        let diff = preview.diff
        let byKey = Dictionary(preview.xml.tracks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func rows(_ keys: [String], _ reason: String) -> [UnmatchedRow] {
            keys.map { key in
                let track = byKey[key]
                return UnmatchedRow(key: key, title: track?.title.isEmpty == false ? track!.title : key,
                                    detail: "\(reason) · \(track?.path ?? String(ui: "파일이 아닌 위치"))")
            }
        }
        return rows(diff.matches.unmatched, String(ui: "라이브러리에 없음")) + rows(diff.matches.ambiguous, String(ui: "여러 곡에 맞음"))
    }

    func count(_ tab: Tab) -> Int {
        guard let diff = preview?.diff else { return 0 }
        switch tab {
        case .cue: return diff.counts.cueTracks
        case .grid: return diff.counts.gridTracks
        case .tag: return diff.counts.tagTracks
        case .playlist: return diff.playlists.count
        case .unmatched: return diff.matching.unmatched + diff.matching.ambiguous
        }
    }

    /// 새 미리 보기에서 처음 고를 차이와 처음 탭
    private func chooseDefaults() {
        guard let diff = preview?.diff else {
            chosen = [:]
            chosenLists = []
            return
        }
        // 빼기만 있는 큐는 처음에 고르지 않는다(큐를 내보내지 않은 도구일 수 있다)
        chosen = XMLImportDrafts.defaultChoice(diff)
        // 못 맞춘 곡이 든 "곡이 다른 목록"은 바꾸지 않으니 처음에 고르지 않는다
        chosenLists = Set(diff.playlists.filter { $0.kind == .missing || $0.unmatchedEntries == 0 }.map(\.path))
        tab = [Tab.cue, .grid, .tag, .playlist].first { count($0) > 0 } ?? .cue
    }
}
