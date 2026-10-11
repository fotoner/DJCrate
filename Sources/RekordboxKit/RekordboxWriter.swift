import DJCDomain
import Foundation

/// DJCrate 큐 초안을 rekordbox `master.db`에 직접 쓴다.
///
/// rekordbox 7.2.18이 직접 큐를 고쳤을 때 DB가 바뀐 모양을 비교해 그대로 따른다(2026-09-26 확인):
/// - `djmdCue`: 지운 큐는 행을 지우고, 새 큐는 새 행(ID는 32비트 난수, UUID 새로)으로 넣는다.
/// - `contentCue.Cues`(JSON): 남은 큐는 원문 그대로 두고, 지운 큐를 빼고, 새 큐를 끝에 붙인다. `rb_cue_count`는 큐 수.
/// - `contentCue`·`djmdContent`: 동기화 상태 256 → 257, `rb_local_usn`은 전역 카운터(`agentRegistry.localUpdateCount`)를
///   하나씩 올려 받는다. `djmdContent.CueUpdated`는 고친 횟수만큼 늘린다.
/// 옮긴 큐는 지우고 새로 넣는다. FLAC은 rekordbox처럼 프레임 탐색 위치(SeekInfo)를 계산해 적는다.
/// VBR MP3(MPEG 탐색 위치 규칙 미확인)는 막는다.
///
/// 안전장치: rekordbox(에이전트 포함)가 켜져 있거나 확인하지 않은 버전·DB 구조면 쓰지 않는다(`RekordboxCompatibility`). 쓰기 전에 DB를 통째로 백업하고, 한
/// 트랜잭션 안에서 쓰고 다시 읽어 검증한 뒤에만 커밋한다. 커밋 뒤 무결성 검사·재검증이 실패하면 백업으로 되돌린다
/// (`writeRolledBack`). 되돌리지도 못하면 상태를 알 수 없으니 `restoreFailed`로 따로 알린다.
/// 초안을 시작한 뒤 rekordbox에서 그 곡의 큐가 바뀌었으면 그 곡은 쓰지 않는다.
/// 그리드·오토게인·분석 붙이기·재생 목록·재생 기록은 역할별 확장(`+Grid`·`+Gain`·`+Analysis`·`+Playlist`·`+History`)에 있다.
public enum RekordboxWriter {
    // 결과 값은 DJCDomain에 있다(#167). 옛 이름을 남긴다.
    public typealias Outcome = RekordboxWriteOutcome
    public typealias Report = RekordboxWriteReport

    public static var liveDatabase: URL { LibrarySnapshot.rekordboxDirectory.appending(path: "master.db") }


    /// 백업은 한 개에 150MB 안팎이다. 최근 이만큼만 남긴다.
    /// 확인 창 없이 바로 쓰게 하면서(#210) 되돌릴 수 있는 쓰기 수를 5에서 20으로 늘렸다(사용자 결정 2026-10-07, #209).
    static let backupsToKeep = 20

    static func isLive(_ database: URL, liveDatabase: URL = liveDatabase) -> Bool {
        RekordboxWriteGuard.sameFile(database, liveDatabase)
    }

    // MARK: - 쓰기

    /// 초안들을 쓴다. `dryRun`이면 같은 과정을 모두 거친 뒤 되돌린다(스냅샷 사본으로 미리 보기).
    /// - Parameters:
    ///   - grids: 그리드 초안. 분석 파일(`shareRoot` 아래)을 고친다.
    ///   - shareRoot: 분석 파일 뿌리. 라이브 DB면 rekordbox share 폴더, 사본 DB면 명시해야 그리드를 쓴다(실제 파일을 건드리지 않게).
    ///   - writeGuard: 라이브 DB 판단과 실행·버전 확인(시험에서 바꾼다). DB 구조는 사본이어도 늘 확인한다.
    ///   - tags: 태그 초안. rekordbox 곡 정보(`djmdContent` 등)만 고치고 음원 파일 태그는 그대로 둔다(`writableTagKeys` 칸만).
    ///   - analysisInputs: 분석 전 곡(분석 파일 없음)의 음원 길이·음량·내장 그림(곡 UUID별). 그 곡의 그리드 초안으로 분석 파일을 만들어 붙이고,
    ///     그림이 있으면 아트워크도 넣는다(`RekordboxTrackWriter.writesArtwork`).
    ///   - playlists: 재생 목록 편집(적힌 순서대로). DB 옆 `masterPlaylists6.xml`도 rekordbox처럼 고친다.
    ///   - playlistDraft: 앱의 재생 목록 초안. `playlists` 대신 준다. 초안을 만든 뒤 rekordbox에서 바뀐 목록(base와 다름)의 편집은 쓰지 않는다.
    ///   - artworks: 곡 정보 그림 초안(넣기·바꾸기·지우기, #66). 그림 파일 셋은 `shareRoot` 아래에 쓴다. 음원 파일의 그림은 그대로 둔다.
    ///   - histories: USB에서 가져온 기기 재생 기록(#43, 넘긴 순서대로). `writesHistories`가 닫혀 있으면 모두 막고 DB·백업을 건드리지 않는다.
    public static func write(drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:], tags: [TagDraft] = [],
                             artworks: [ArtworkEdit] = [],
                             analysisInputs: [String: AnalysisInput] = [:], playlists: [PlaylistEdit] = [],
                             playlistDraft: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = [], histories: [HistoryImport] = [],
                             iTunesSync: RekordboxITunesSyncChange? = nil,
                             to database: URL, dryRun: Bool,
                             now: Date = .now, backups: URL, shareRoot: URL? = nil,
                             guard writeGuard: RekordboxWriteGuard = .system) throws -> Report {
        if let iTunesSync {
            guard drafts.isEmpty, grids.isEmpty, gains.isEmpty, tags.isEmpty, artworks.isEmpty, analysisInputs.isEmpty,
                  playlists.isEmpty, playlistDraft == nil, merges.isEmpty, histories.isEmpty else { throw RekordboxITunesSyncChange.invalidSource }
            return try writeITunesSync(iTunesSync, to: database, dryRun: dryRun, now: now, backups: backups, guard: writeGuard)
        }
        return try write(drafts: drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, analysisInputs: analysisInputs, playlists: playlists,
                  playlistDraft: playlistDraft, merges: merges, histories: histories, to: database,
                  dryRun: dryRun, now: now, backups: backups, shareRoot: shareRoot, guard: writeGuard, attachesAnalysis: attachesAnalysis,
                  writesArtwork: RekordboxTrackWriter.writesArtwork)
    }

    /// - Parameters:
    ///   - attachesAnalysis: 분석 붙이기를 여는지. 앱은 `attachesAnalysis`를 따르고, 시험과 사본 실험(`djc lab analysis-attach-test`)만 바꾼다.
    ///   - writesArtwork: 분석을 붙이는 곡에 아트워크도 넣는지. 앱은 `RekordboxTrackWriter.writesArtwork`를 따르고, 시험만 바꾼다.
    ///   - tagKeys: 태그 쓰기를 연 칸. 앱은 `writableTagKeys`를 따르고, 시험과 사본 실험(`djc lab tag-write-test`)만 바꾼다.
    ///   - tagScopes: 칸별로 확인한 범위(평점·곡 색의 곡 상태·재생 목록). 앱은 `TagWriteScope.byKey`, 사본 실험만 비운다.
    ///   - writesHistories: 재생 기록 쓰기를 여는지. 앱은 `writesHistories`를 따르고, 시험과 사본 재현(`djc lab history-repro`)만 연다.
    ///   - historyEnvironment: 기록 ID·UUID 난수와 로컬 시간대(시험만 정한다)
    package static func write(drafts: [CueDraft], grids: [GridDraft], gains: [String: Double], tags: [TagDraft] = [],
                              artworks: [ArtworkEdit] = [],
                              analysisInputs: [String: AnalysisInput],
                              playlists: [PlaylistEdit] = [], playlistDraft: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = [],
                              histories: [HistoryImport] = [], to database: URL, dryRun: Bool, now: Date,
                              backups: URL, shareRoot: URL?,
                              guard writeGuard: RekordboxWriteGuard = .system, attachesAnalysis: Bool,
                              writesArtwork: Bool = RekordboxTrackWriter.writesArtwork,
                              tagKeys: Set<TagFields.Key> = writableTagKeys,
                              tagScopes: [TagFields.Key: TagWriteScope] = TagWriteScope.byKey,
                              writesHistories: Bool = RekordboxWriter.writesHistories,
                              historyEnvironment: HistoryEnvironment = .system) throws -> Report {
        let stamp = CueJSON.timestamps(now)
        let grids = grids.filter(\.hasChanges)
        var tags = tags.filter(\.hasChanges)
        let playlistSteps = playlistDraft?.steps ?? playlists.map { PlaylistDraft.Step(edit: $0) }
        // 재생 기록 결과(넘긴 순서 → 결과). 쓰기를 열기 전에는 모두 막고, 그러면 쓸 기록이 없는 것으로 본다(다른 초안은 평소처럼).
        var historyResults: [Int: HistoryOutcome] = [:]
        var histories = Array(histories.enumerated())
        if !writesHistories {
            for (index, history) in histories { historyResults[index] = .blocked(history, closedHistoryReason) }
            histories = []
        }
        func historyReport() -> [HistoryOutcome]? {
            historyResults.isEmpty ? nil : historyResults.keys.sorted().compactMap { historyResults[$0] }
        }
        guard drafts.contains(where: \.hasChanges) || !grids.isEmpty || !gains.isEmpty || !tags.isEmpty || !artworks.isEmpty || !playlistSteps.isEmpty
                || !merges.isEmpty || !histories.isEmpty else {
            // 쓸 것이 없으면 DB를 열지도, 백업을 만들지도 않는다.
            var report = Report(outcomes: drafts.map { Outcome(trackUUID: $0.trackUUID, title: $0.trackUUID, status: .unchanged,
                                                               reason: nil, removed: 0, added: 0) },
                                backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
            report.historyOutcomes = historyReport()
            return report
        }
        let live = writeGuard.isLive(database)
        let gridRoot = try writeGuard.checkTargets(database, shareRoot: shareRoot, dryRun: dryRun)
        do {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            try RekordboxCompatibility.checkSchema(reader)
            // 백업(약 150MB)을 뜨기 전에 막힐 조건을 먼저 본다.
            let counters = try RekordboxCompatibility.updateCounters(reader)
            if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        }
        // 태그: 막힐 초안(닫힌 칸·잘못된 값·곡 없음·base 불일치)은 백업 전에 거른다. 트랜잭션 안에서 한 번 더 본다.
        var tagOutcomes: [Outcome] = []
        var xmlTags: [String: String] = [:]
        if !tags.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            let checked = try checkTagDrafts(tags, db: reader, writable: tagKeys, mergesPending: !merges.isEmpty,
                                             playlistSteps: playlistSteps, scopes: tagScopes)
            tags = checked.passed
            tagOutcomes = checked.blocked
            xmlTags = checked.touchesXML
        }
        // 그림: 막힐 초안(곡·상태·경로·파일 행·base·그림)은 백업 전에 거르고 새 그림 셋을 만든다. 트랜잭션 안에서 한 번 더 본다.
        var artworkPlans: [ArtworkPlan] = []
        var artworkOutcomes: [Outcome] = []
        if !artworks.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            (artworkPlans, artworkOutcomes) = try checkArtworkDrafts(artworks, db: reader, share: gridRoot)
        }
        // 재생 목록 편집과 곡 정보 쓰기는 DB 옆 masterPlaylists6.xml도 고친다(곡 정보는 그 곡이 든 목록의 Timestamp, #173).
        // 쓰는 DB 옆 파일만 대상이고 없으면 DB만 쓴다. 곡 정보는 그 곡이 든 살아 있는 목록이 있을 때만 읽는다. 사본 옆 파일이 라이브 XML의
        // 링크이거나 읽지 못하면 그 곡정보 초안만 막는다(큐·그리드 등은 쓴다). 재생 목록·합치기는 예전처럼 쓰기째 막는다.
        let playlistXMLURL = playlistXMLURL(for: database)
        var playlistXML: MasterPlaylistsXML?
        let editsPlaylists = !playlistSteps.isEmpty || !merges.isEmpty
        if editsPlaylists || !xmlTags.isEmpty {
            if editsPlaylists { try writeGuard.checkAdjacentFile(playlistXMLURL, database: database) }
            // XML을 고칠 곡정보 초안만 이유와 함께 막는다(곡 이름은 다른 막힘처럼 DB `Title`).
            func blockXMLTags(_ reason: String) {
                for draft in tags {
                    guard let title = xmlTags[draft.trackUUID] else { continue }
                    tagOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: title, status: .blocked, reason: reason, removed: 0, added: 0))
                }
                tags.removeAll { xmlTags[$0.trackUUID] != nil }
            }
            if !editsPlaylists, writeGuard.adjacentFileIsLive(playlistXMLURL, database: database) {
                blockXMLTags(String(ui: "사본 폴더의 masterPlaylists6.xml이 라이브 동기화 파일에 이어져 있어 재생 목록 시각을 고칠 수 없으니 그 파일을 실제 사본으로 복사한 뒤 다시 쓰세요"))
            } else if FileManager.default.fileExists(atPath: playlistXMLURL.path) {
                if let xml = try? MasterPlaylistsXML(contentsOf: playlistXMLURL), xml.text.contains("</PLAYLISTS>") {
                    playlistXML = xml
                } else if editsPlaylists {
                    throw DJCError.writeRefused(String(ui: "masterPlaylists6.xml을 읽지 못했습니다. rekordbox를 한 번 켰다가 종료한 뒤 다시 시도하세요"))
                } else {
                    blockXMLTags(String(ui: "masterPlaylists6.xml을 읽지 못해 재생 목록 시각을 고칠 수 없으니 rekordbox를 한 번 켰다가 종료한 뒤 다시 쓰세요"))
                }
            }
        }
        // 태그·그림 초안이 모두 막혔고 다른 쓸 것도 없으면 백업을 뜨지 않는다.
        if tags.isEmpty, artworkPlans.isEmpty, !tagOutcomes.isEmpty || !artworkOutcomes.isEmpty, !drafts.contains(where: \.hasChanges), grids.isEmpty,
           gains.isEmpty, playlistSteps.isEmpty, merges.isEmpty, histories.isEmpty {
            let unchanged = drafts.map { Outcome(trackUUID: $0.trackUUID, title: $0.trackUUID, status: .unchanged,
                                                   reason: nil, removed: 0, added: 0) }
            var report = Report(outcomes: unchanged, backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
            report.tagOutcomes = tagOutcomes.isEmpty ? nil : tagOutcomes
            report.artworkOutcomes = artworkOutcomes.isEmpty ? nil : artworkOutcomes
            report.historyOutcomes = historyReport()
            return report
        }
        var mergeOutcomes: [Outcome] = []
        var mergePlans: [DuplicateMergeDraft] = []
        if !merges.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            let edited = Set(drafts.filter(\.hasChanges).map(\.trackUUID) + grids.map(\.trackUUID)
                + Array(gains.keys) + tags.map(\.trackUUID) + artworkPlans.map(\.uuid))
            var reserved = Set<String>()
            for draft in merges {
                do {
                    let ids = Set(draft.members.map(\.trackUUID))
                    guard ids.isDisjoint(with: edited), ids.isDisjoint(with: reserved), playlistSteps.isEmpty else {
                        throw DuplicateMerge.Blocked(String(ui: "같은 곡의 다른 초안이나 재생 목록 초안이 있습니다. 먼저 쓰거나 버린 뒤 합치세요"))
                    }
                    _ = try checkMerge(draft, db: reader)
                    mergePlans.append(draft); reserved.formUnion(ids)
                } catch let error as DuplicateMerge.Blocked {
                    mergeOutcomes.append(Outcome(trackUUID: draft.id, title: draft.keeping.title, status: .blocked,
                                                  reason: error.reason, removed: 0, added: 0))
                }
            }
        }
        if !merges.isEmpty, mergePlans.isEmpty, !drafts.contains(where: \.hasChanges), grids.isEmpty, gains.isEmpty,
           tags.isEmpty, artworkPlans.isEmpty, playlistSteps.isEmpty, histories.isEmpty {
            var report = Report(outcomes: [], backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
            report.mergeOutcomes = mergeOutcomes
            report.tagOutcomes = tagOutcomes.isEmpty ? nil : tagOutcomes
            report.artworkOutcomes = artworkOutcomes.isEmpty ? nil : artworkOutcomes
            report.historyOutcomes = historyReport()
            return report
        }
        // 재생 기록: 막힐 기록(빈 이름·날짜·폴더 자리·곡·같은 곡의 다른 초안)은 백업 전에 거른다. 트랜잭션 안에서 한 번 더 본다.
        // 같은 곡 행을 두 번 고치는 조합(태그·그림·합치기)은 확인하지 않아 그 기록을 막는다. 큐·그리드·분석은 같은 곡이어도 함께 쓴다.
        let historyConflicts = HistoryConflicts(edited: Set(tags.map(\.trackUUID) + artworkPlans.map(\.uuid)),
                                                merged: Set(mergePlans.flatMap { $0.members.map(\.trackUUID) }))
        var historyPlans: [(index: Int, history: HistoryImport)] = []
        if !histories.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            var seen = Set<String>()
            var historyTrackCounts: [String: Int] = [:]
            var historyTrackIDs: [Int: Set<String>] = [:]
            for (index, history) in histories {
                do {
                    guard seen.insert(history.id).inserted else {
                        throw HistoryBlocked(reason: String(ui: "같은 기록이 한 번에 두 번 들어 있어 앞의 것만 쓰니 쓴 뒤 기록을 확인하세요"))
                    }
                    guard !live || (history.expectedLibraryID != nil && !history.trackIdentities.isEmpty) else {
                        throw HistoryBlocked(reason: String(ui: "기록의 원본 곡 식별이 없어 라이브러리에 쓰지 않으니 DJCrate에서 USB 기록을 다시 가져온 뒤 쓰세요"))
                    }
                    let checked = try checkHistory(history, db: reader, conflicts: historyConflicts, environment: historyEnvironment)
                    let ids = Set(checked.tracks.map(\.contentID))
                    historyTrackIDs[index] = ids
                    for id in ids { historyTrackCounts[id, default: 0] += 1 }
                    historyPlans.append((index, history))
                } catch let present as HistoryPresent {
                    historyResults[index] = present.outcome
                } catch let blocked as HistoryBlocked {
                    historyResults[index] = .blocked(history, blocked.reason)
                }
            }
            // 여러 기록의 같은 곡 재생 횟수 규칙은 아직 실험하지 않았다. 해당 기록 모두를 백업 전에 막는다.
            let repeated = Set(historyTrackCounts.filter { $0.value > 1 }.map(\.key))
            historyPlans.removeAll { plan in
                guard !(historyTrackIDs[plan.index] ?? []).isDisjoint(with: repeated) else { return false }
                historyResults[plan.index] = .blocked(plan.history, String(ui: "같은 곡이 여러 기록에 든 묶음은 재생 횟수 규칙을 확인하지 않아 쓰지 않으니 기록을 하나씩 쓰거나 rekordbox에서 직접 가져오세요"))
                return true
            }
            // 기록이 모두 막혔고 다른 쓸 것도 없으면 백업을 뜨지 않는다.
            if historyPlans.isEmpty, !drafts.contains(where: \.hasChanges), grids.isEmpty, gains.isEmpty, tags.isEmpty, artworkPlans.isEmpty,
               playlistSteps.isEmpty, mergePlans.isEmpty {
                let unchanged = drafts.map { Outcome(trackUUID: $0.trackUUID, title: $0.trackUUID, status: .unchanged,
                                                       reason: nil, removed: 0, added: 0) }
                var report = Report(outcomes: unchanged, backup: nil, dryRun: dryRun, createdAt: stamp.json, finalUpdateCount: nil)
                report.tagOutcomes = tagOutcomes.isEmpty ? nil : tagOutcomes
                report.artworkOutcomes = artworkOutcomes.isEmpty ? nil : artworkOutcomes
                report.mergeOutcomes = mergeOutcomes.isEmpty ? nil : mergeOutcomes
                report.historyOutcomes = historyReport()
                return report
            }
        }
        // 그리드 계획(파일을 읽기만 한다)
        var gridPlans: [RekordboxGridWriter.Plan] = []
        var gridOutcomes: [Outcome] = []
        // 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일을 만들어 붙인다(파형·오토게인까지).
        var attachPlans: [AttachPlan] = []
        var analysisOutcomes: [Outcome] = []
        if !grids.isEmpty {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            for draft in grids {
                var info: (title: String, anlz: String?, bpm: Int, path: String, id: String, fileName: String)?
                try reader.query("""
                    SELECT Title, AnalysisDataPath, BPM, FolderPath, ID, FileNameL FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0
                    """, [.text(draft.trackUUID)]) { r in
                    info = (r.string(0) ?? "", r.string(1), r.int(2) ?? 0, r.string(3) ?? "", r.string(4) ?? "", r.string(5) ?? "")
                }
                guard let info else {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: draft.trackUUID, status: .blocked,
                                                reason: String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요"), removed: 0, added: 0))
                    continue
                }
                guard let gridRoot else {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .blocked,
                                                reason: String(ui: "사본 DB에는 분석 파일 경로를 따로 주어야 그리드를 씁니다"), removed: 0, added: 0))
                    continue
                }
                if needsAnalysis(info.anlz) {
                    let fileName = info.fileName.isEmpty ? URL(filePath: info.path).lastPathComponent : info.fileName
                    do {
                        let plan = try attachPlan(draft: draft, content: (info.id, info.title, info.path, fileName),
                                                  input: analysisInputs[draft.trackUUID], share: gridRoot, reader: reader, enabled: attachesAnalysis,
                                                  writesArtwork: writesArtwork)
                        attachPlans.append(plan)
                        analysisOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .written, reason: nil,
                                                        removed: 0, added: plan.ready.beats))
                    } catch let blocked as Blocked {
                        analysisOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                                        reason: blocked.reason, removed: 0, added: 0))
                    }
                    continue
                }
                do {
                    let plan = try RekordboxGridWriter.plan(draft: draft, title: info.title, analysisDataPath: info.anlz,
                                                            rekordboxBPM100: info.bpm, audioPath: info.path, shareRoot: gridRoot)
                    gridPlans.append(plan)
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: info.title, status: .written, reason: nil,
                                                removed: 0, added: plan.beats.count))
                } catch let blocked as RekordboxGridWriter.Blocked {
                    gridOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                                reason: blocked.reason, removed: 0, added: 0))
                }
            }
        }

        let backup = dryRun ? nil : try makeBackup(of: database, in: backups, now: now, label: "write")
        // 분석 파일도 원본을 백업에 둔다(되돌리기용).
        if let backup, let gridRoot, !gridPlans.isEmpty { try backupAnalysis(gridPlans, in: backup, shareRoot: gridRoot) }
        // 바꾸거나 지울 그림 파일도 둔다(그리드 백업이 manifest를 새로 쓰므로 그 뒤에 더한다).
        if let backup, let gridRoot, !artworkPlans.isEmpty { try backupArtworkFiles(artworkPlans, in: backup, shareRoot: gridRoot) }

        var outcomes: [Outcome] = []
        var gainOutcomes: [Outcome] = []
        var written: [(contentID: String, expectation: Expectation)] = []
        var gained: [GainExpectation] = []
        var regridded: [GridExpectation] = []
        var tagged: [TagExpectation] = []
        var drawn: [ArtworkExpectation] = []
        var attached: [AttachPlan] = []
        var playlistOutcomes: [PlaylistOutcome] = []
        var playlistWork: PlaylistWork?
        var updatedXML: MasterPlaylistsXML?
        /// XML에 할 일(재생 목록 → 합치기 → 곡 정보 순). 트랜잭션 끝에서 한 번에 계산하고 커밋 뒤에 적는다.
        var xmlChanges: [PlaylistXMLChange] = []
        /// 곡 정보로 Timestamp를 고칠 목록(한 번씩)
        var touchedPlaylists: Set<String> = []
        var merged: [MergeExpectation] = []
        var mergeRenumbered = RekordboxTrackWriter.Renumbered()
        var mergeFiles: [URL] = []
        var historyExpectations: [HistoryExpectation] = []
        /// 기록을 쓴 곡 행(ContentID → 쓴 뒤 칸)
        var historyPlays: [String: HistoryPlay] = [:]
        var finalUpdateCount: Int?
        var committed = false
        do {
            let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive(), writable: true)
            try db.execute("BEGIN IMMEDIATE")
            var finished = false
            defer { if !finished { try? db.execute("ROLLBACK") } }

            var usn = try localUpdateCount(db)
            let startUSN = usn
            // 여러 묶음이 같은 목록을 고칠 수 있어, 처음 상태 검사는 어떤 편집보다 먼저 한꺼번에 한다.
            var checkedMerges: [(draft: DuplicateMergeDraft, cues: CueDraft)] = []
            for draft in mergePlans {
                do { checkedMerges.append((draft, try checkMerge(draft, db: db))) }
                catch let blocked as DuplicateMerge.Blocked {
                    mergeOutcomes.append(Outcome(trackUUID: draft.id, title: draft.keeping.title, status: .blocked,
                                                  reason: blocked.reason, removed: 0, added: 0))
                }
            }
            // 분석 붙이기가 먼저: 같은 곡의 큐·게인은 분석한 곡에 쓰는 것과 같게 뒤에 쓴다.
            for var plan in attachPlans {
                try db.execute("SAVEPOINT djc_analysis")
                do {
                    try applyAttach(&plan, db: db, usn: &usn, stamp: stamp)
                    try db.execute("RELEASE djc_analysis")
                    attached.append(plan)
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_analysis")
                    try db.execute("RELEASE djc_analysis")
                    if let i = analysisOutcomes.firstIndex(where: { $0.trackUUID == plan.trackUUID }) {
                        analysisOutcomes[i] = Outcome(trackUUID: plan.trackUUID, title: blocked.title, status: .blocked,
                                                      reason: blocked.reason, removed: 0, added: 0)
                    }
                }
            }
            for draft in drafts {
                try db.execute("SAVEPOINT djc_track")
                do {
                    let result = try apply(draft, db: db, usn: &usn, stamp: stamp)
                    outcomes.append(result.outcome)
                    if let expectation = result.expectation {
                        try verify(db: db, contentID: result.contentID, expectation)
                        written.append((result.contentID, expectation))
                    }
                    try db.execute("RELEASE djc_track")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_track")
                    try db.execute("RELEASE djc_track")
                    outcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked,
                                            reason: blocked.reason, removed: 0, added: 0))
                }
            }
            // 오토게인: rekordbox가 직접 고쳤을 때처럼 djmdMixerParam 한 행(삭제 안 된 것)의 게인 두 칸·상태·변경 번호만 바꾼다.
            for (uuid, gainDB) in gains.sorted(by: { $0.key < $1.key }) {
                try db.execute("SAVEPOINT djc_gain")
                do {
                    let result = try applyGain(uuid: uuid, gainDB: gainDB, db: db, usn: &usn, stamp: stamp)
                    gainOutcomes.append(result.outcome)
                    gained.append(result.expectation)
                    try db.execute("RELEASE djc_gain")
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_gain")
                    try db.execute("RELEASE djc_gain")
                    gainOutcomes.append(Outcome(trackUUID: uuid, title: blocked.title, status: .blocked, reason: blocked.reason, removed: 0, added: 0))
                }
            }
            // 재생 목록: 적힌 순서대로. 막힌 편집은 그 편집만 되돌리고(번호도) 뒤 편집을 이어 쓴다.
            if !playlistSteps.isEmpty {
                let tree = try PlaylistTree.read(db)
                // 초안의 base는 쓰기 전 rekordbox 상태와 비교한다(이 묶음에서 앞 편집이 바꾼 상태가 아니라).
                let rekordbox = playlistDraft.map { _ in tree.layout }
                var work = PlaylistWork(tree: tree, xmlIDs: Set(playlistXML?.nodes.map(\.id) ?? []))
                for step in playlistSteps {
                    let edit = step.edit
                    if let playlistDraft, let rekordbox,
                       let reason = playlistDraft.staleReason(for: step, rekordbox: rekordbox) {
                        let name = work.tree.nodes[edit.playlist.layoutID]?.name ?? edit.playlist.description
                        playlistOutcomes.append(PlaylistOutcome(edit: edit, playlistID: nil, name: name, status: .blocked, reason: reason))
                        continue
                    }
                    try db.execute("SAVEPOINT djc_playlist")
                    let saved = (work, usn)
                    do {
                        playlistOutcomes.append(try applyPlaylist(edit, work: &work, db: db, usn: &usn, stamp: stamp))
                        try db.execute("RELEASE djc_playlist")
                    } catch let blocked as PlaylistBlocked {
                        try db.execute("ROLLBACK TO djc_playlist")
                        try db.execute("RELEASE djc_playlist")
                        (work, usn) = saved
                        playlistOutcomes.append(PlaylistOutcome(edit: edit, playlistID: nil, name: blocked.name, status: .blocked,
                                                                reason: blocked.reason))
                    }
                }
                if playlistOutcomes.contains(where: { $0.status == .written }) {
                    try verifyPlaylists(work, db: db)
                    xmlChanges += work.xml
                    playlistWork = work
                }
            }

            if !checkedMerges.isEmpty {
                var work = PlaylistWork(tree: try PlaylistTree.read(db), xmlIDs: Set(playlistXML?.nodes.map(\.id) ?? []))
                for plan in checkedMerges {
                    try db.execute("SAVEPOINT djc_merge")
                    let saved = (work, usn, mergeRenumbered)
                    do {
                        let cues = plan.cues
                        let result = try applyMerge(plan.draft, cue: cues, work: &work, db: db, usn: &usn, stamp: stamp, share: gridRoot,
                                                    renumbered: &mergeRenumbered)
                        try backupDeletionFiles(result.files, in: backup, shareRoot: gridRoot)
                        try verifyPlaylists(work, db: db)
                        try db.execute("RELEASE djc_merge")
                        merged.append(result.expectation); mergeFiles += result.files
                        mergeOutcomes.append(Outcome(trackUUID: plan.draft.id, title: plan.draft.keeping.title, status: .written,
                                                      reason: result.expectation.fileWarning, removed: plan.draft.removing.count, added: cues.cues.count - cues.base.count))
                    } catch {
                        let reason: String
                        switch error {
                        case let blocked as DuplicateMerge.Blocked: reason = blocked.reason
                        case let blocked as Blocked: reason = blocked.reason
                        case let blocked as PlaylistBlocked: reason = blocked.reason
                        case let blocked as RekordboxTrackWriter.Blocked: reason = blocked.reason
                        default: throw error
                        }
                        try db.execute("ROLLBACK TO djc_merge")
                        try db.execute("RELEASE djc_merge")
                        (work, usn, mergeRenumbered) = saved
                        mergeOutcomes.append(Outcome(trackUUID: plan.draft.id, title: plan.draft.keeping.title, status: .blocked,
                                                      reason: reason, removed: 0, added: 0))
                    }
                }
                if !merged.isEmpty {
                    playlistWork = work
                    xmlChanges += work.xml
                }
            }

            // BPM이 바뀌는 그리드: .DAT 파일 기록과 곡 BPM을 rekordbox처럼 고친다(파일은 커밋 뒤에 쓴다).
            for plan in gridPlans where plan.newBPM100 != nil {
                if let expectation = try applyGridDatabase(plan, db: db, usn: &usn, stamp: stamp) { regridded.append(expectation) }
                // 같은 곡에 큐도 썼으면 곡의 변경 번호는 이제 그리드 쪽 번호다.
                for i in written.indices where written[i].expectation.contentUUID == plan.trackUUID {
                    written[i].expectation.contentUSN = usn
                }
            }
            // 그림: 태그 앞에 쓴다(같은 곡의 태그가 곡 행에 마지막 번호를 준다, #173 S2 U03은 그림 저장 → 아티스트 저장 순서였다).
            for plan in artworkPlans {
                try db.execute("SAVEPOINT djc_artwork")
                let savedUSN = usn
                do {
                    guard !attached.contains(where: { $0.trackUUID == plan.uuid }) else {
                        throw Blocked(title: plan.title, reason: String(ui: "같은 곡에 분석 붙이기와 앨범아트 쓰기를 함께 하지 않으니 그리드를 먼저 쓴 뒤 앨범아트를 쓰세요"))
                    }
                    let expectation = try applyArtwork(plan, db: db, share: gridRoot, usn: &usn, stamp: stamp)
                    artworkOutcomes.append(Outcome(trackUUID: plan.uuid, title: expectation.plan.title, status: .written, reason: nil,
                                                   removed: 0, added: 0, artwork: expectation.plan.kind))
                    // 넣기·지우기는 곡 행 번호를 바꾼다. 같은 곡의 큐·BPM 검증은 그 번호를 본다.
                    if case let .int(trackUSN)? = expectation.track["rb_local_usn"] {
                        for i in written.indices where written[i].contentID == expectation.plan.contentID { written[i].expectation.contentUSN = trackUSN }
                        for i in regridded.indices where regridded[i].contentID == expectation.plan.contentID {
                            regridded[i].content["rb_local_usn"] = .int(trackUSN)
                        }
                    }
                    drawn.append(expectation)
                    try db.execute("RELEASE djc_artwork")
                    // 그림 저장은 재생 목록 XML을 고치지 않는다(#173 S1 X2·S3 V04·S5 W1·W2b·W3a).
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_artwork")
                    try db.execute("RELEASE djc_artwork")
                    usn = savedUSN
                    artworkOutcomes.append(Outcome(trackUUID: plan.uuid, title: blocked.title, status: .blocked, reason: blocked.reason,
                                                   removed: 0, added: 0, artwork: plan.kind))
                }
            }
            // 태그는 마지막: 곡 행을 한 번 더 고쳐 가장 큰 변경 번호를 받는다(큐·그리드·분석·그림을 쓴 곡이면 그 뒤 편집처럼).
            for draft in tags {
                try db.execute("SAVEPOINT djc_tags")
                let savedUSN = usn
                do {
                    let result = try applyTags(draft, db: db, usn: &usn, stamp: stamp, writable: tagKeys, scopes: tagScopes)
                    tagOutcomes.append(result.outcome)
                    // 여러 곡이 같은 앨범을 저장하거나 마지막 참조를 놓으면(지움·258) 뒤 편집이 그 행 검증을 맡는다.
                    let replacedAlbums = Set(result.expectation.touchedAlbums.keys).union(result.expectation.releasedAlbums)
                    for i in tagged.indices {
                        for id in replacedAlbums { tagged[i].touchedAlbums.removeValue(forKey: id) }
                    }
                    tagged.append(result.expectation)
                    for i in written.indices where written[i].contentID == result.expectation.contentID {
                        written[i].expectation.contentUSN = usn
                    }
                    // 그림을 넣거나 지운 곡도 곡 행 번호의 마지막 값은 태그 쪽이다.
                    for i in drawn.indices where drawn[i].plan.contentID == result.expectation.contentID && drawn[i].track["rb_local_usn"] != nil {
                        drawn[i].track["rb_local_usn"] = .int(usn)
                    }
                    // BPM을 고친 곡이면 곡 정보 변경 횟수·변경 번호의 마지막 값은 태그 쪽이다.
                    for i in regridded.indices where regridded[i].contentID == result.expectation.contentID {
                        regridded[i].content["TrackInfoUpdated"] = .text(result.expectation.trackInfoUpdated)
                        regridded[i].content["rb_local_usn"] = .int(usn)
                    }
                    try db.execute("RELEASE djc_tags")
                    // 곡 정보를 썼으면 그 곡이 든 살아 있는 목록마다 XML Timestamp를 쓴 시각으로. 정보 패널 아홉 칸과 키가 모두 같다
                    // (부모 폴더는 그대로, #173 S1 X1·S2 U11·U12·S3 V07·S4 A1~A6·B2, S5 K1). 어느 칸이 고치는지는 `playlistXMLTagKeys` 한 곳이다.
                    if playlistXML != nil, touchesPlaylistXML(draft) {
                        for id in try tagPlaylists(db, contentID: result.expectation.contentID) where touchedPlaylists.insert(id).inserted {
                            xmlChanges.append(.touch(id))
                        }
                    }
                } catch let blocked as Blocked {
                    try db.execute("ROLLBACK TO djc_tags")
                    try db.execute("RELEASE djc_tags")
                    usn = savedUSN
                    tagOutcomes.append(Outcome(trackUUID: draft.trackUUID, title: blocked.title, status: .blocked, reason: blocked.reason,
                                               removed: 0, added: 0))
                }
            }
            // 재생 기록은 그 뒤(#43): 곡 행 재생 횟수를 고쳐 그 곡의 가장 큰 변경 번호를 받는다. 같은 곡의 큐·그리드·분석 검증은 그 번호·횟수를 본다.
            // 막힌 기록은 그 기록만 되돌린다(번호도).
            for (index, history) in historyPlans {
                try db.execute("SAVEPOINT djc_history")
                let saved = (usn, historyPlays)
                do {
                    let result = try applyHistory(history, db: db, usn: &usn, stamp: stamp, conflicts: historyConflicts,
                                                  environment: historyEnvironment, plays: &historyPlays)
                    try db.execute("RELEASE djc_history")
                    historyExpectations.append(result.expectation)
                    historyResults[index] = HistoryOutcome(id: history.id, name: result.checked.name,
                                                           historyID: dryRun ? nil : result.expectation.historyID, status: .written,
                                                           reason: nil, entries: result.checked.tracks.count, skipped: result.checked.skipped)
                    for track in result.checked.tracks {
                        guard let play = historyPlays[track.contentID] else { continue }
                        for i in written.indices where written[i].contentID == track.contentID { written[i].expectation.contentUSN = play.usn }
                        for i in regridded.indices where regridded[i].contentID == track.contentID {
                            regridded[i].content["TrackInfoUpdated"] = .text(play.trackInfoUpdated)
                            regridded[i].content["rb_local_usn"] = .int(play.usn)
                        }
                    }
                } catch let present as HistoryPresent {
                    try db.execute("ROLLBACK TO djc_history")
                    try db.execute("RELEASE djc_history")
                    (usn, historyPlays) = saved
                    historyResults[index] = present.outcome
                } catch let blocked as HistoryBlocked {
                    try db.execute("ROLLBACK TO djc_history")
                    try db.execute("RELEASE djc_history")
                    (usn, historyPlays) = saved
                    historyResults[index] = .blocked(history, blocked.reason)
                }
            }
            // XML은 커밋 뒤에 적지만, 적을 수 있는지는 커밋 전에 본다.
            if !xmlChanges.isEmpty { updatedXML = try playlistXML.map { try applyPlaylistXML(xmlChanges, to: $0, now: now) } }
            if let backup, !merged.isEmpty {
                try JSONEncoder().encode(merged.map(\.draft)).write(to: backup.appending(path: "merge-drafts.json"), options: .atomic)
            }
            if usn != startUSN {
                let changed = try db.run("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(usn)])
                guard changed == 1 else { throw DJCError.writeVerificationFailed(String(ui: "변경 카운터를 올리지 못했습니다")) }
            }
            guard try localUpdateCount(db) == usn else { throw DJCError.writeVerificationFailed(String(ui: "변경 카운터가 맞지 않습니다")) }
            finalUpdateCount = usn

            let databaseChanged = !written.isEmpty || !regridded.isEmpty || !gained.isEmpty || !attached.isEmpty || !tagged.isEmpty
                || !drawn.isEmpty || playlistWork != nil || !merged.isEmpty || !historyExpectations.isEmpty
            if dryRun || !databaseChanged {
                try db.execute("ROLLBACK")
            } else {
                try db.execute("COMMIT")
                committed = true
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            finished = true
            db.close()
        } catch {
            // 커밋 전 실패는 ROLLBACK으로 끝난다. 백업은 남겨 두지만 쓸 일은 없다.
            throw error
        }

        // 커밋한 쓰기는 모두 무결성 검사와 다시 읽기를 거친다(백업은 시험 실행이 아닐 때만 있다).
        if let backup, committed {
            do {
                try checkIntegrity(of: database)
                let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
                defer { db.close() }
                for item in written { try verify(db: db, contentID: item.contentID, item.expectation) }
                // 분석을 붙인 뒤 태그·재생 기록도 쓴 곡은 곡 정보 변경 횟수를 그쪽에서 본다.
                let taggedIDs = Set(tagged.map(\.contentID)).union(historyPlays.keys)
                for plan in attached { try verifyAttach(plan, db: db, skipsTrackInfo: taggedIDs.contains(plan.contentID)) }
                for expectation in tagged { try verifyTags(db: db, expectation) }
                for expectation in drawn { try verifyArtwork(db: db, expectation) }
                for expectation in regridded { try verifyGrid(db: db, expectation) }
                for expectation in gained { try verifyGain(db: db, expectation) }
                if let playlistWork { try verifyPlaylists(playlistWork, db: db) }
                for expectation in merged { try verifyMerge(expectation, db: db) }
                try RekordboxTrackWriter.verifyRenumbered(mergeRenumbered, db: db)
                for expectation in historyExpectations { try verifyHistory(db: db, expectation) }
                try verifyHistoryPlays(db: db, historyPlays)
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live)
            }
        }
        // masterPlaylists6.xml: DB를 확인한 뒤 적는다. 고칠 줄이 없으면(곡이 든 목록의 NODE가 없음 등) 같은 내용을 다시 쓰지 않는다.
        if let backup, let updatedXML, let original = playlistXML, updatedXML != original {
            try writePlaylistXML(updatedXML, original: original, to: playlistXMLURL, database: database, backup: backup, live: live)
        }

        // 분석 파일(붙이기는 새로 만들고, 그리드는 고친다): DB가 끝난 뒤 쓴다. 하나라도 검증에 실패하면 DB·파일 모두 쓰기 전으로
        // 되돌린다(만든 파일은 지운다). 큐 없이 BPM·게인만 커밋했어도 DB를 되돌린다.
        var created: [URL] = []
        if let backup, !gridPlans.isEmpty || !attached.isEmpty {
            do {
                for plan in attached { try writeAnalysisFiles(plan, created: &created) }
                for plan in gridPlans { try RekordboxGridWriter.apply(plan) }
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live, restoreDatabase: committed) {
                    try removeAnalysisFiles(created)
                    try restoreGridFiles(gridPlans)
                }
            }
        }

        // 그림 파일: 분석 파일 다음에 쓴다. 실패하면 만든 파일을 지우고 바꾸거나 지운 옛 그림을 백업에서 되살린 뒤 DB를 되돌린다.
        if let backup, !drawn.isEmpty {
            do {
                for expectation in drawn { try writeArtworkFiles(expectation, created: &created) }
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live) {
                    try removeAnalysisFiles(created)
                    try restoreGridFiles(gridPlans)
                    try restoreArtworkFiles(drawn)
                }
            }
        }

        if let backup, !mergeFiles.isEmpty {
            do {
                try removeOwnedFiles(mergeFiles)
            } catch {
                throw recover(from: error, database: database, backup: backup, live: live) {
                    try restoreAnalysis(from: backup,
                                        shareRoot: gridRoot ?? database.deletingLastPathComponent().appending(path: "share"))
                    try removeAnalysisFiles(created)
                }
            }
        }

        var report = Report(outcomes: outcomes, backup: backup?.path, dryRun: dryRun, createdAt: stamp.json,
                            finalUpdateCount: finalUpdateCount)
        report.gridOutcomes = gridOutcomes.isEmpty ? nil : gridOutcomes
        report.gainOutcomes = gainOutcomes.isEmpty ? nil : gainOutcomes
        report.analysisOutcomes = analysisOutcomes.isEmpty ? nil : analysisOutcomes
        report.createdFiles = created.isEmpty ? nil : created.map(\.path)
        report.playlistOutcomes = playlistOutcomes.isEmpty ? nil : playlistOutcomes
        let artworkAdded = attached.filter { $0.artwork != nil }.map(\.trackUUID)
        report.artworkAdded = artworkAdded.isEmpty ? nil : artworkAdded
        report.tagOutcomes = tagOutcomes.isEmpty ? nil : tagOutcomes
        report.mergeOutcomes = mergeOutcomes.isEmpty ? nil : mergeOutcomes
        report.artworkOutcomes = artworkOutcomes.isEmpty ? nil : artworkOutcomes
        report.historyOutcomes = historyReport()
        if let backup {
            if let warning = saveReport(report, in: backup, shareRoot: gridRoot) { report.warnings = [warning] }
            // 되돌리면 DJCrate 초안도 살릴 수 있게 쓴 초안을 백업 옆에 둔다.
            let written = Set(report.written.map(\.trackUUID))
            let folder = backup.appending(path: "cue-drafts")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for draft in drafts where written.contains(draft.trackUUID) {
                try? JSONEncoder().encode(draft).write(to: folder.appending(path: "\(draft.trackUUID).json"), options: .atomic)
            }
            let gainWritten = Set(report.gainWritten.map(\.trackUUID))
            if !gainWritten.isEmpty {
                let written = gains.filter { gainWritten.contains($0.key) }
                try? JSONEncoder().encode(written).write(to: backup.appending(path: "gain-drafts.json"), options: .atomic)
            }
            // 분석을 붙인 곡도 그리드 초안으로 쓴 것이라 함께 둔다(되돌리면 그리드 초안을 살린다).
            let gridWritten = Set((report.gridWritten + report.analysisWritten).map(\.trackUUID))
            if !gridWritten.isEmpty {
                let gridFolder = backup.appending(path: "grid-drafts")
                try? FileManager.default.createDirectory(at: gridFolder, withIntermediateDirectories: true)
                for draft in grids where gridWritten.contains(draft.trackUUID) {
                    try? JSONEncoder().encode(draft).write(to: gridFolder.appending(path: "\(draft.trackUUID).json"), options: .atomic)
                }
            }
            // 태그 초안도 둔다(되돌리면 DJCrate에 다시 살린다).
            let tagWritten = Set(report.tagWritten.map(\.trackUUID))
            if !tagWritten.isEmpty {
                let tagFolder = backup.appending(path: "tag-drafts")
                try? FileManager.default.createDirectory(at: tagFolder, withIntermediateDirectories: true)
                for draft in tags where tagWritten.contains(draft.trackUUID) {
                    try? JSONEncoder().encode(draft).write(to: tagFolder.appending(path: "\(draft.trackUUID).json"), options: .atomic)
                }
            }
            // 그림 초안과 그림 사본도 둔다(되돌리면 DJCrate에 다시 살린다).
            let artworkWritten = Set(report.artworkWritten.map(\.trackUUID))
            if !artworkWritten.isEmpty {
                let artworkFolder = backup.appending(path: "artwork-drafts")
                try? FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
                for edit in artworks where artworkWritten.contains(edit.trackUUID) {
                    try? JSONEncoder().encode(edit.draft).write(to: artworkFolder.appending(path: "\(edit.trackUUID).json"), options: .atomic)
                    if let image = edit.image { try? image.write(to: artworkFolder.appending(path: "\(edit.trackUUID).image"), options: .atomic) }
                }
            }
            let playlistWritten = report.playlistWritten.map(\.edit)
            if !playlistWritten.isEmpty {
                try? JSONEncoder().encode(playlistWritten).write(to: backup.appending(path: "playlist-edits.json"), options: .atomic)
            }
            prune(backups)
        }
        return report
    }

    // MARK: - 커밋 뒤 실패

    /// masterPlaylists6.xml을 적고 다시 읽어 확인한다(DB를 커밋하고 확인한 뒤). 적거나 다시 읽다 실패하면 DB를 되돌리기 전에 원본 XML부터
    /// 다시 쓰고(재생 목록 쓰기 #38과 같은 순서라 DB 복원이 실패해도 XML은 원본) DB를 백업으로 되돌린다.
    /// - Parameter read: 다시 읽기(시험만 바꾼다)
    static func writePlaylistXML(_ updated: MasterPlaylistsXML, original: MasterPlaylistsXML, to url: URL, database: URL, backup: URL, live: Bool,
                                 read: (URL) throws -> MasterPlaylistsXML = { try MasterPlaylistsXML(contentsOf: $0) }) throws {
        do {
            try updated.data.write(to: url, options: .atomic)
            guard try read(url) == updated else {
                throw DJCError.writeVerificationFailed(String(ui: "masterPlaylists6.xml을 다시 읽으니 적은 것과 다릅니다"))
            }
        } catch {
            throw recover(from: error, database: database, backup: backup, live: live, filesLabel: "masterPlaylists6.xml") {
                // 원자적 쓰기가 실패했으면 원본 그대로다. 같은 내용을 다시 쓰다 같은 이유로 실패해 복원 실패로 알리지 않는다.
                guard (try? Data(contentsOf: url)) != original.data else { return }
                try original.data.write(to: url, options: .atomic)
            }
        }
    }

    /// 커밋 뒤 확인·분석 파일 쓰기가 실패했을 때 쓰기 전으로 되돌리고 던질 오류를 고른다.
    /// 모두 되돌렸으면 `writeRolledBack`, 하나라도 못 했거나 되돌린 DB가 무결성 검사를 통과하지 못하면 `restoreFailed`.
    /// - Parameters:
    ///   - restoreDatabase: DB를 커밋했으면 true(백업의 master.db로 바꾼다)
    ///   - files: 분석 파일 되돌리기(바꾼 파일은 원본으로, 만든 파일은 지우기)
    static func recover(from failure: any Error, database: URL, backup: URL, live: Bool, restoreDatabase: Bool = true,
                        filesLabel: String? = nil, files: () throws -> Void = {}) -> DJCError {
        var problems: [String] = []
        // files는 분석 파일·아트워크(그리드·분석 붙이기·합치기)나 원본 XML(filesLabel)을 되돌린다. DB와 XML은 restoreFiles가 백업에서 살린다.
        do { try files() } catch {
            let reason = DJCError.reason(of: error)
            problems.append(filesLabel.map { "\($0): \(reason)" } ?? String(ui: "분석·앨범아트 파일: \(reason)"))
        }
        if restoreDatabase {
            // restoreFiles는 DB를 되살린 뒤에만 XML을 되살리고, 실패에 꼬리표("master.db:"·"masterPlaylists6.xml:")를 붙여 던진다.
            do { try restoreFiles(from: backup, to: database) } catch { problems.append(DJCError.reason(of: error)) }
            do { try checkIntegrity(of: database) } catch { problems.append("master.db: \(DJCError.reason(of: error))") }
        }
        let reason = DJCError.reason(of: failure)
        guard problems.isEmpty else {
            return .restoreFailed(reason: reason, restoreError: problems.joined(separator: " / "), backup: backup.path,
                                  database: live ? nil : database.path)
        }
        return .writeRolledBack(reason)
    }

    /// 그리드를 쓴 분석 파일을 원본 바이트로 되돌린다. 원본 그대로인 파일(쓰기 전에 실패한 곡)은 건드리지 않는다.
    static func restoreGridFiles(_ plans: [RekordboxGridWriter.Plan]) throws {
        var files: [(URL, Data)] = []
        for plan in plans {
            files.append((plan.datURL, plan.originalDat))
            if let extURL = plan.extURL, let originalExt = plan.originalExt { files.append((extURL, originalExt)) }
        }
        try each(files.filter { (try? Data(contentsOf: $0.0)) != $0.1 }) { url, original in
            try original.write(to: url, options: .atomic)
        }
    }

    /// 하나가 실패해도 나머지를 모두 해 보고, 처음 실패를 던진다(되돌리기를 중간에 멈추지 않게).
    static func each<S: Sequence>(_ items: S, _ body: (S.Element) throws -> Void) throws {
        var first: (any Error)?
        for item in items {
            do { try body(item) } catch { first = first ?? error }
        }
        if let first { throw first }
    }
}
