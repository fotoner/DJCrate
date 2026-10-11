import DJCDomain
import Foundation

/// 백그라운드 그리드 추정 한 건.
public struct GridJobItem: Sendable, Hashable {
    public var uuid: String
    public var path: String
    /// 추가한 곡이면 추정 BPM을 목록에도 적어 두고, 키도 찾는다.
    public var staged: Bool
    /// 그리드도 추정할지(추가한 곡의 키만 남았으면 false)
    public var grid = true

    public init(uuid: String, path: String, staged: Bool, grid: Bool = true) {
        self.uuid = uuid
        self.path = path
        self.staged = staged
        self.grid = grid
    }
}

/// 추가한 곡(아직 rekordbox에 없는 곡, 유스케이스): 파일·폴더 넣기, 넣기 결과 저장·재생 목록 연결, rekordbox로 가져온 뒤 그리드 확인,
/// 그리드·키 추정. 추가 목록 파일은 `StagingStore` 한 길로 쓴다(지금 목록에 결과를 얹어 저장한다: 넣는 동안 다른 곳이 고친 줄을 덮지 않게, adv2 N8).
/// 화면 모델은 지금 목록(`staged`)을 들고 이 유스케이스가 돌려준 목록·결과를 적용한다.
public struct StageTracks: Sendable {
    let files: TrackFiles
    let analysis: StagingAnalysis
    let drafts: DraftStore
    let source: LibrarySource
    /// 오늘 날짜(`yyyy-MM-dd`, 추가한 날·가져오기 확인 날)
    let today: @Sendable () -> String
    /// 추가 목록 파일(`staged.json`)
    let staging: StagingStore
    /// 재생 목록 연결 기록(곡을 재생 목록에 놓거나 Music 목록으로 만들 때)
    let imports: PlaylistImportsStore
    /// 새 열쇠(새로 만들 목록의 초안 키·출처를 모르는 보관함 ID)
    let newKey: @Sendable () -> String

    public init(files: TrackFiles, analysis: StagingAnalysis, drafts: DraftStore, source: LibrarySource, today: @escaping @Sendable () -> String,
                staging: StagingStore, imports: PlaylistImportsStore, newKey: @escaping @Sendable () -> String) {
        self.files = files
        self.analysis = analysis
        self.drafts = drafts
        self.source = source
        self.today = today
        self.staging = staging
        self.imports = imports
        self.newKey = newKey
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    // MARK: - 넣기

    /// 넣기 결과. 화면 모델이 지금 추가 목록에 얹는다(`apply`)
    public struct Addition: Sendable, Equatable {
        /// 새로 넣을 곡
        public var added: [StagedTrack] = []
        /// 이미 rekordbox 컬렉션에 있어 넣지 않고 고른 곡(XML로 다시 가져오면 rekordbox의 기존 큐·그리드를 덮을 수 있다)
        public var libraryRows: [TrackRow] = []
        /// 이미 추가 목록에 있던 곡(ID)
        public var stagedIDs: [String] = []
        /// 태그를 읽지 못한 파일 수
        public var failed = 0
        /// 이미 추가한 곡에 덧붙일 Apple Music 출처(곡 ID별)
        public var origins: [String: [AppleMusicOrigin]] = [:]

        public init(added: [StagedTrack] = [], libraryRows: [TrackRow] = [], stagedIDs: [String] = [], failed: Int = 0,
                    origins: [String: [AppleMusicOrigin]] = [:]) {
            self.added = added
            self.libraryRows = libraryRows
            self.stagedIDs = stagedIDs
            self.failed = failed
            self.origins = origins
        }

        /// 추가 목록을 고쳐야 하는지
        public var changesList: Bool { !added.isEmpty || !origins.isEmpty }

        /// 지금 목록에 얹는다(넣는 동안 바뀐 줄은 그대로 두고 출처만 덧붙인다)
        public func apply(to list: inout [StagedTrack]) {
            for (id, origins) in origins {
                guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
                list[index].rememberAppleMusicOrigins(origins)
            }
            list += added
        }

        /// 재생 목록에 이을 음원 경로(넣은 곡·이미 추가한 곡·이미 컬렉션에 있는 곡)
        public func playlistPaths(in list: [StagedTrack]) -> [String] {
            added.map(\.path) + list.filter { stagedIDs.contains($0.id) }.map(\.path) + libraryRows.map(\.track.folderPath)
        }

        /// 결과 안내(문장, 읽지 못한 파일이 있으면 경고)
        public func summary(linksPlaylists: Bool) -> (text: String, warning: Bool) {
            var parts: [String] = []
            if !added.isEmpty { parts.append(String(ui: "\(added.count)곡 추가")) }
            if !libraryRows.isEmpty { parts.append(String(ui: "rekordbox에 이미 있는 \(libraryRows.count)곡을 골랐습니다")) }
            if !stagedIDs.isEmpty { parts.append(String(ui: "이미 추가한 \(stagedIDs.count)곡을 골랐습니다")) }
            if failed > 0 { parts.append(String(ui: "\(failed)곡은 읽지 못함")) }
            if linksPlaylists {
                parts.append(String(ui: "컬렉션에 들어간 곡은 재생 목록 초안에 연결합니다. 목록은 ‘rekordbox에 쓰기’로 만듭니다."))
            }
            return (parts.joined(separator: " · "), failed > 0)
        }
    }

    /// 넣을 수 있는 음원(파일·폴더 안). 없으면 빈 배열
    public func audioFiles(in urls: [URL]) -> [URL] { files.audioFiles(urls) }

    /// 고른 음원을 나눈다: rekordbox 컬렉션에 이미 있는 곡은 그 곡을 고르고, 이미 추가한 곡은 출처만 덧붙이고, 새 곡은 태그를 읽어 넣는다.
    /// - Parameters:
    ///   - current: 지금 추가 목록(나누기 기준)
    ///   - rows: rekordbox 컬렉션의 곡
    ///   - origins: 음원 경로(NFC)별 Apple Music 출처
    public func add(_ audioFiles: [URL], current: [StagedTrack], library rows: [TrackRow],
                    origins: [String: [AppleMusicOrigin]] = [:]) async -> Addition {
        let inLibrary = Dictionary(rows.map { (Self.key($0.track.folderPath), $0) }, uniquingKeysWith: { first, _ in first })
        let stagedByPath = Dictionary(current.map { (Self.key($0.path), $0.id) }, uniquingKeysWith: { first, _ in first })
        var known = Set(stagedByPath.keys)
        let addedOn = today()
        var addition = Addition()
        for url in audioFiles {
            let path = Self.key(url.path)
            // 이미 rekordbox에 있는 곡은 추가하지 않고 그 곡을 바로 연다(XML로 다시 가져오면 기존 큐를 덮을 수 있다).
            if let row = inLibrary[path] { addition.libraryRows.append(row); continue }
            if let id = stagedByPath[path] {
                addition.stagedIDs.append(id)
                if let found = origins[path] { addition.origins[id, default: []] += found }
                continue
            }
            if known.contains(path) { continue }
            do {
                var track = try await files.stagedTrack(url, addedOn)
                track.rememberAppleMusicOrigins(origins[path] ?? [])
                addition.added.append(track)
                known.insert(path)
            } catch {
                addition.failed += 1
            }
        }
        return addition
    }

    // MARK: - 추가 목록 저장

    /// 지금 추가 목록 파일
    @MainActor
    public func list() -> [StagedTrack] { staging.tracks() }

    /// 추가 목록 전체를 저장한다. 저장하지 못하면 던진다(화면의 목록은 그대로).
    /// - Parameter takingMovedFiles: 저장이 손상된 옛 파일을 옮겼는지 가져온다(데이터 폴더를 정한 저장소만)
    /// - Returns: 저장이 옮긴 손상 파일
    @MainActor
    public func saveList(_ list: [StagedTrack], takingMovedFiles: Bool) throws -> [DamagedDraftFile] {
        try staging.save(list)
        return takingMovedFiles ? drafts.takeMovedFiles() : []
    }

    /// 재생 목록에 잇기: 곡을 목록에 놓았거나(`playlistID`) Music 목록으로 만든다(`createPlaylists`, 출처는 `origins`)
    public struct PlaylistLink: Sendable {
        public var createPlaylists: Bool
        public var playlistID: String?
        /// 음원 경로(NFC)별 Apple Music 출처
        public var origins: [String: [AppleMusicOrigin]]

        public init(createPlaylists: Bool = false, playlistID: String? = nil, origins: [String: [AppleMusicOrigin]] = [:]) {
            self.createPlaylists = createPlaylists
            self.playlistID = playlistID
            self.origins = origins
        }
    }

    /// 넣기 결과를 저장한 결과
    public struct Commit: Sendable {
        /// 결과를 얹은 추가 목록(바꿀 것이 없었으면 nil). 저장하지 못했어도 화면은 이 목록을 든다
        public var list: [StagedTrack]?
        public var listSaveError: (any Error)?
        /// 저장이 손상된 옛 목록 파일을 옮겼으면 그 파일
        public var moved: [DamagedDraftFile] = []
        /// 재생 목록에 이었으면 더한 연결 기록과 그 저장 결과
        public var link: EditPlaylists.ImportsChange?
    }

    /// 넣기 결과를 지금 목록에 얹어 저장하고(넣는 동안 다른 곳이 고친 줄은 그대로 두고 출처만 덧붙인다), 재생 목록에 잇게 했으면
    /// 넣은 곡·이미 추가한 곡·이미 컬렉션에 있는 곡의 경로를 연결 기록에 더해 저장한다(목록은 컬렉션에 들어간 뒤 초안에 잇는다).
    /// - Parameters:
    ///   - list: 지금 추가 목록(넣는 동안 바뀌었을 수 있어 넣기 뒤의 목록을 준다)
    ///   - imports: 지금 연결 기록. 읽지 못했으면(`importsLoadFailed`) 저장하지 않는다
    @MainActor
    public func commit(_ addition: Addition, onto list: [StagedTrack], link: PlaylistLink?, imports current: PlaylistImports,
                       importsLoadFailed: Bool, takingMovedFiles: Bool) -> Commit {
        var commit = Commit()
        var list = list
        if addition.changesList {
            addition.apply(to: &list)
            commit.list = list
            do { commit.moved = try saveList(list, takingMovedFiles: takingMovedFiles) } catch { commit.listSaveError = error }
        }
        guard let link, link.createPlaylists || link.playlistID != nil else { return commit }
        let paths = addition.playlistPaths(in: list)
        var imports = current
        if link.createPlaylists {
            let accepted = Set(paths.map { $0.precomposedStringWithCanonicalMapping })
            imports.addAppleMusic(link.origins.filter { accepted.contains($0.key) }, unidentifiedLibraryID: newKey(),
                                  newKey: { newKey().lowercased() })
        }
        if let playlistID = link.playlistID { imports.addFiles(paths, to: PlaylistRef(playlistID)) }
        commit.link = EditPlaylists(imports: self.imports, drafts: drafts).saveImports(imports, over: current, loadFailed: importsLoadFailed)
        return commit
    }

    /// 다시 읽은 추가 목록
    public struct Reload: Sendable {
        public var list: [StagedTrack]
        /// 가져온 뒤 확인 결과 문장(확인한 곡이 없으면 nil)
        public var summary: (text: String, allMatched: Bool)?
        /// 확인 결과를 적은 목록을 저장하지 못한 이유
        public var saveError: (any Error)?
        /// 저장이 손상된 옛 목록 파일을 옮겼으면 그 파일
        public var moved: [DamagedDraftFile] = []
    }

    /// 라이브러리를 다시 읽은 뒤: 추가 목록을 읽고, 새 스냅샷에 같은 경로의 곡이 생긴 곡(= rekordbox로 가져옴)의 그리드를 비교해 적어 저장한다
    @MainActor
    public func reloadList(rows: [TrackRow], shareRoot: URL, takingMovedFiles: Bool) -> Reload {
        let current = staging.tracks()
        let verified = verifyImports(current, rows: rows, shareRoot: shareRoot)
        var reload = Reload(list: verified.list ?? current, summary: verified.summary)
        if let list = verified.list {
            do { reload.moved = try saveList(list, takingMovedFiles: takingMovedFiles) } catch { reload.saveError = error }
        }
        return reload
    }

    // MARK: - 가져오기 뒤 확인

    /// 새 사본에 추가한 곡과 같은 경로의 곡이 있으면(= rekordbox로 가져옴) 넘긴 그리드 초안과 rekordbox가 분석한 그리드를 비교해 적는다.
    /// 둘 다 rekordbox 시간축이라 그대로 비교한다. 어긋나면 인코더 지연 규칙이 그 파일에서 틀린 것이다.
    /// - Returns: 확인 결과를 적은 목록(바뀐 줄이 없으면 nil)과 알릴 문장(확인한 곡이 없으면 nil)
    public func verifyImports(_ current: [StagedTrack], rows: [TrackRow], shareRoot: URL)
        -> (list: [StagedTrack]?, summary: (text: String, allMatched: Bool)?) {
        let byPath = Dictionary(rows.map { (Self.key($0.track.folderPath), $0) }, uniquingKeysWith: { first, _ in first })
        let checkedOn = today()
        var list = current
        var changed = false
        for index in list.indices {
            guard let row = byPath[Self.key(list[index].path)] else { continue }
            // 추가한 곡의 그리드 초안은 그리드 추정이 이 초안 폴더에 쓴다
            let check = compareImported(list[index], with: row.track, today: checkedOn, shareRoot: shareRoot,
                                        gridDraft: drafts.gridDraft(list[index].uuid))
            if list[index].importCheck != check {
                list[index].importCheck = check
                changed = true
            }
        }
        let checked = list.compactMap(\.importCheck)
        guard !checked.isEmpty else { return (changed ? list : nil, nil) }
        let counts = Dictionary(grouping: checked, by: \.result).mapValues(\.count)
        var parts = [String(ui: "rekordbox 가져오기 확인 \(checked.count)곡")]
        if let n = counts[.matched] { parts.append(String(ui: "그리드 일치 \(n)")) }
        if let n = counts[.shifted] { parts.append(String(ui: "박 어긋남 \(n)")) }
        if let n = counts[.reanalyzed] { parts.append(String(ui: "rekordbox가 재분석 \(n)")) }
        if let n = counts[.pending] { parts.append(String(ui: "분석 대기 \(n)")) }
        if let n = counts[.noGrid] { parts.append(String(ui: "그리드 없이 보냄 \(n)")) }
        return (changed ? list : nil, (parts.joined(separator: " · "), checked.allSatisfy { $0.result == .matched }))
    }

    /// 넘긴 그리드 초안과 rekordbox가 가져와 분석한 그리드(`shareRoot`의 분석 파일)를 비교한다.
    public func compareImported(_ staged: StagedTrack, with track: Track, today: String, shareRoot: URL?,
                                gridDraft: GridDraft?) -> StagedTrack.ImportCheck {
        .compare(sent: gridDraft?.segments ?? [], imported: source.grid(track.analysisDataPath, shareRoot),
                 duration: Double(track.lengthSeconds), checkedOn: today)
    }

    // MARK: - 그리드·키 추정

    /// 추가한 곡의 그리드 초안(그리드 추정이 이 초안 폴더에 쓴다). 없으면 nil
    public func gridDraft(_ uuid: String) -> GridDraft? { drafts.gridDraft(uuid) }

    /// 그리드 추정 결과
    public enum GridEstimation: Sendable, Equatable {
        /// 덱에서 이미 적용했거나 편집한 곡(목록 BPM만 맞춘다)
        case existing(bpm: Double?)
        /// 파일이 없거나 추정하지 못했거나, 추정하는 동안 덱에서 초안을 만들었다
        case skipped
        /// 그리드 초안을 저장했다(저장에 실패했으면 그 실패, 입력은 저장 큐에 남는다)
        case saved(bpm: Double, confident: Bool, failure: DraftSaveFailure?)
    }

    /// 초안이 없는 곡의 그리드를 추정해 그리드 초안(rekordbox 시간축)으로 저장한다. 추정은 메인 밖에서 하고,
    /// 덱에서 이미 만든 초안(저장 대기 입력 포함)을 덮지 않게 확인과 저장은 메인 액터에서 붙여 한다(덱도 메인 액터에서 초안을 저장한다).
    @MainActor
    public func estimateGrid(_ item: GridJobItem) async -> GridEstimation {
        if let existing = drafts.currentGrid(item.uuid) { return .existing(bpm: existing.segments.first?.bpm) }
        let url = URL(filePath: item.path)
        guard files.exists(item.path), let estimate = try? await analysis.estimateGrid(url, item.uuid) else { return .skipped }
        // 추정하는 동안 덱에서 초안을 만들었으면 덮지 않는다.
        guard drafts.currentGrid(item.uuid) == nil else { return .skipped }
        let draft = GridDraft(trackUUID: item.uuid, base: [], segments: estimate.segments).shifted(by: analysis.timelineOffset(url))
        // 바로 뒤 키 찾기·덱이 디스크의 초안을 읽으니 저장을 끝낸다. 실패해도 입력은 저장 큐에 남는다.
        drafts.saveGrid(draft)
        drafts.flush()
        let failure = drafts.failures().first { $0.kind == .grid && $0.trackUUID == item.uuid }
        return .saved(bpm: estimate.bpm, confident: estimate.isConfident, failure: failure)
    }

    /// 태그에 키가 없던 추가한 곡의 조성을 찾는다(다음 실행 때 다시 계산하지 않게 목록에 적는다). 파일이 없거나 읽지 못하면 nil
    @MainActor
    public func findKey(_ track: StagedTrack) async -> (key: String?, source: StagedTrack.KeySource)? {
        guard track.needsKey, files.exists(track.path) else { return nil }
        let url = URL(filePath: track.path)
        let grid = drafts.gridDraft(track.uuid)?.grid(duration: track.duration)
        return await key(fileAt: url, grid: grid, offset: analysis.timelineOffset(url), duration: track.duration, cacheKey: track.uuid)
    }

    /// 태그의 키, 없으면 곡 전체의 주 조성 추정(덱과 같은 크로마·마디 창). 파일을 읽지 못하면 nil(다음에 다시 본다).
    /// `grid`는 rekordbox 시간축이라 `offset`만큼 당겨 크로마(음원 시간축)에 맞춘다.
    public func key(fileAt url: URL, grid: BeatGrid?, offset: Double, duration: Double,
                    cacheKey: String?) async -> (key: String?, source: StagedTrack.KeySource)? {
        if let tag = await files.tagKey(url) { return (tag, .tag) }
        // 소리가 없어 조성을 못 찾아도 추정한 것으로 적어 두어 되풀이하지 않는다.
        guard let found = await analysis.mainKey(url, grid, offset, duration, cacheKey) else { return nil }
        return (found, .estimate)
    }
}
