import DJCDomain
import Foundation

/// rekordbox XML 내보내기(유스케이스): 라이브러리 전체 XML(앱 "라이브러리 XML 내보내기…"·CLI `xml-export`), 추가한 곡 XML,
/// 이미 있는 곡의 큐·그리드 초안을 넘기는 반영 XML과 가져온 뒤 확인(XML 연동). 고른 파일 하나에만 쓰고 rekordbox 라이브러리에는 쓰지 않는다.
public struct ExportXML: Sendable {
    let files: XMLFiles
    let source: LibrarySource
    let drafts: DraftStore
    /// 반영 묶음 저장(XML을 만들 때 남기고 가져온 뒤 확인할 때 읽는다)
    let batches: ReflectionBatchStore
    let now: @Sendable () -> Date

    public init(files: XMLFiles, source: LibrarySource, drafts: DraftStore, batches: ReflectionBatchStore, now: @escaping @Sendable () -> Date) {
        self.files = files
        self.source = source
        self.drafts = drafts
        self.batches = batches
        self.now = now
    }

    // MARK: - 라이브러리 XML

    /// 분석 파일 뿌리(CLI 규칙): `--share`를 주지 않으면 사본 DB 옆 `share`. 없는 폴더를 그대로 쓰면 모든 곡의 TEMPO가 조용히 빠지므로
    /// 폴더가 없으면 막고, 분석 없이 내보내는 것은 `noAnalysis`로 명시할 때만 한다(nil).
    public func analysisRoot(share: URL?, noAnalysis: Bool, snapshot: URL) throws -> URL? {
        if noAnalysis { return nil }
        let share = share ?? snapshot.deletingLastPathComponent().appending(path: "share")
        guard files.item(share) == .directory else {
            throw ReadFailure("missing_share", String(ui: "분석 파일 폴더가 없습니다: \(share.path). --share <rekordbox 폴더>/share를 주거나, 그리드 없이 내보내려면 --no-analysis를 주세요"))
        }
        return share
    }

    /// 출력 자리를 먼저 확인한다(DB를 열기 전). 덮어쓰기를 주지 않았으면 이미 있는 파일을 바꾸지 않는다(미리 보기는 쓰지 않으니 보지 않는다)
    public func checkOutput(_ out: URL, overwrite: Bool, dryRun: Bool) throws {
        try files.checkOutput(out)
        if !dryRun, !overwrite, files.item(out) != .none {
            throw LibraryXMLOutputError(reason: String(ui: "같은 이름의 파일이 이미 있습니다. 덮어쓰려면 --overwrite를 주거나 다른 이름을 고르세요"))
        }
    }

    /// 사본 라이브러리 전체를 `out` 한 파일에 쓴다(미리 보기면 읽기만). 쓰지 않은 초안은 넣지 않는다(rekordbox에 있는 그대로). 메인 밖에서 부른다
    public func exportLibrary(snapshot: URL, share: URL?, to out: URL, dryRun: Bool = false,
                              progress: (@Sendable (LibraryXMLProgress) -> Void)? = nil) throws -> LibraryXMLSummary {
        if !dryRun { try files.checkOutput(out) }
        return try files.exportLibrary(snapshot, share, dryRun ? nil : out, progress)
    }

    // MARK: - 추가한 곡 XML

    /// 키 초안이 있는 추가한 곡을 XML에서 뺄 때 알리는 이유. rekordbox XML의 키(`Tonality`)를 가져오는 규칙은 확인하지 않아 키 초안을
    /// 담지 않는다. 고른 키가 조용히 사라지지 않게 그 곡만 빼고 이유를 알린다. ‘rekordbox에 넣기’는 키를 함께 쓴다(#5).
    public static func stagedKeyDraftBlock(title: String) -> String {
        String(ui: "\(title): XML로 키를 넘기는 방법은 확인하지 않았으니 ‘rekordbox에 넣기’로 키까지 넣거나 태그 초안(키)을 버린 뒤 내보내세요")
    }

    /// 추가한 곡 XML 결과: 내보낸 곡 수, 그리드가 없는 곡 수, 뺀 곡의 이유
    public struct StagedExport: Sendable, Equatable {
        public var count: Int
        public var withoutGrid: Int
        public var skipped: [String]
    }

    /// 추가한 곡을 rekordbox XML로 쓴다. 태그 초안(시트·인스펙터에서 고친 값)과 그리드·큐 초안을 넣는다.
    /// 키 초안이 있는 곡은 XML에 담지 않고 이유를 돌려준다. 담을 곡이 하나도 없고 뺀 곡이 있으면 파일을 쓰지 않는다.
    /// 저장에 실패한 큐·그리드 초안이 있으면 디스크의 옛 초안을 XML로 내보내지 않는다(#170).
    public func exportStaged(_ candidates: [StagedTrack], tagDrafts: [String: TagDraft], to out: URL) throws -> StagedExport {
        try drafts.requireSaved(Set(candidates.map(\.uuid)))
        var skipped: [String] = []
        let tracks = candidates.filter { track in
            guard AddedTrackDrafts.confirmedKey(tagDrafts[track.uuid]) != nil else { return true }
            skipped.append(Self.stagedKeyDraftBlock(title: track.title))
            return false
        }
        if tracks.isEmpty, !skipped.isEmpty { return StagedExport(count: 0, withoutGrid: 0, skipped: skipped) }
        var withoutGrid = 0
        let entries = tracks.map { original -> StagedXMLEntry in
            var track = original
            if let fields = tagDrafts[original.uuid]?.fields {
                track.title = fields.title.isEmpty ? original.title : fields.title
                track.artist = fields.artist
                track.album = fields.album
                track.genre = fields.genre
                track.composer = fields.composer
                track.year = Int(fields.year)
                track.trackNumber = Int(fields.trackNumber)
                track.comment = fields.comment
            }
            let tempos = drafts.gridDraft(original.uuid)?.segments ?? []
            if tempos.isEmpty { withoutGrid += 1 }
            return StagedXMLEntry(track: track, tempos: tempos, cues: drafts.cueDraft(original.uuid)?.cues ?? [])
        }
        try files.writeStaged(entries, "DJCrate 추가", out)
        return StagedExport(count: entries.count, withoutGrid: withoutGrid, skipped: skipped)
    }

    // MARK: - 반영 XML(이미 있는 곡의 큐·그리드 초안)

    /// 곡마다 반영 계획. 요청한 곡마다 계획을 남겨 대상에서 빠진 이유도 미리 보기에 보인다.
    /// - Parameters:
    ///   - pending: 초안이 있는 곡(UUID, 쓰기 대기 표시)
    ///   - cueMarks: 큐 초안 표시가 있는 곡, `gridMarks`: 그리드 초안 표시가 있는 곡(화면이 든 표시)
    ///   - exclusions: 곡의 초안이 쓰기·XML에서 빠지는 이유(앞에 `• 제목: `가 붙은 줄, `DraftExclusions`)
    public func reflectionPlans(for rows: [TrackRow], pending: Set<String>, cueMarks: Set<String>, gridMarks: Set<String>,
                                exclusions: (TrackRow) -> [String]) -> [ReflectionXMLPlan] {
        rows.map { row in
            let uuid = row.track.uuid
            let cue = drafts.cueDraft(uuid), grid = drafts.gridDraft(uuid)
            let eligibleSource = !row.isStaged && !row.isUsb && pending.contains(uuid)
            var plan = files.reflectionPlan(row.track, row.cues, eligibleSource && cue?.trackUUID == uuid ? cue : nil,
                                            eligibleSource && grid?.trackUUID == uuid ? grid : nil)
            let reasons = exclusions(row)
            if !plan.isEligible {
                plan.blockers += reasons.map { String($0.dropFirst("• \(row.title): ".count)) }
                if plan.blockers.isEmpty { plan.blockers.append(String(ui: "큐·그리드 초안에 변경이 없으니 변경할 초안을 확인하세요")) }
            } else if cueMarks.contains(uuid) && cue?.trackUUID != uuid || gridMarks.contains(uuid) && grid?.trackUUID != uuid {
                plan.blockers += reasons.map { String($0.dropFirst("• \(row.title): ".count)) }
            }
            return plan
        }
    }

    /// 반영 XML을 쓰고 반영 묶음을 남긴다. 막힌 곡은 빼고 이유를 돌려준다. 저장에 실패한 초안이 있으면 쓰지 않는다(#170).
    public func exportReflection(_ plans: [ReflectionXMLPlan], uuids: Set<String>, to out: URL) throws
        -> (exported: [ReflectionXMLPlan], blocked: [ReflectionXMLPlan], batch: ReflectionXMLBatch?) {
        try drafts.requireSaved(uuids)
        let eligible = plans.filter(\.isEligible)
        let blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else { return ([], blocked, nil) }
        let stamp = now().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        // 재생 목록 이름은 늘 같게(rekordbox에서 찾기 쉽게). 만든 시각은 반영 묶음에 남긴다.
        try files.writeReflection(eligible, "DJCrate 반영", out)
        let batch = ReflectionXMLBatch(createdAt: stamp, xmlPath: out.path, plans: eligible, checks: [:])
        try batches.save(batch)
        return (eligible, blocked, batch)
    }

    // MARK: - 반영 XML 시험(CLI `reflection-dry-run`)

    /// 반영 XML 시험의 곡 하나: 반영 계획과 큐 초안의 변경 수(초안 파일 그대로, 자동 큐를 채우지 않고 센다)
    public struct DryRunPlan: Sendable {
        public var plan: ReflectionXMLPlan
        public var cueChanges: Int
    }

    /// 최신 스냅샷(`snapshotDirectory`)의 곡 가운데 큐·그리드 초안 파일이 있는 곡의 반영 계획(라이브러리 순서).
    /// 아무것도 쓰지 않고 반영 묶음도 남기지 않는다(rekordbox·연동 XML은 그대로)
    public func dryRunPlans(snapshotDirectory: URL) throws -> [DryRunPlan] {
        let library = try source.library(try source.latestSnapshot(snapshotDirectory))
        let uuids = drafts.cueDraftUUIDs().union(drafts.gridDraftUUIDs())
        return library.tracks.filter { uuids.contains($0.uuid) }.map { track in
            let cue = drafts.cueDraft(track.uuid)
            let plan = files.reflectionPlan(track, library.cues(for: track), cue, drafts.gridDraft(track.uuid))
            return DryRunPlan(plan: plan, cueChanges: cue?.changes.count ?? 0)
        }
    }

    /// 반영할 수 있는 계획만 `out` 한 파일에 쓴다(재생 목록 이름 "DJCrate 반영 시험", 반영 묶음은 남기지 않는다)
    public func writeDryRun(_ plans: [ReflectionXMLPlan], to out: URL) throws {
        try files.writeReflection(plans.filter(\.isEligible), "DJCrate 반영 시험", out)
    }

    /// 반영 묶음을 새 사본으로 확인한 결과
    public struct Verification: Sendable {
        public var batch: ReflectionXMLBatch
        /// 일치해 초안을 지운 곡(UUID)
        public var cleared: Set<String>
        public var matched = 0
        public var notYet = 0
        public var mismatched: [String] = []
        public var unverified: [String] = []
        /// 모두 확인됐다(묶음을 비웠다)
        public var finished: Bool { notYet == 0 && mismatched.isEmpty && unverified.isEmpty }
        /// 묶음 기록을 저장하지 못한 이유(있으면)
        public var storeError: (any Error)?
        public var storeFailed: Bool { storeError != nil }
        /// 초안을 지우지 못한 경고(있으면)
        public var cleanupWarning: String?

        /// 알림 한 줄
        public var message: String {
            var parts = [String(ui: "rekordbox XML 가져오기 확인(\(batch.createdAt) 묶음): 일치 \(matched)")]
            if notYet > 0 { parts.append(String(ui: "아직 가져오지 않음 \(notYet)")) }
            if !mismatched.isEmpty { parts.append(String(ui: "불일치 \(mismatched.count) — \(mismatched.prefix(2).joined(separator: " · "))")) }
            if !unverified.isEmpty {
                parts.append(String(ui: "확인하지 못함 \(unverified.count) — 라이브러리에 없는 곡: \(unverified.prefix(2).joined(separator: " · "))"))
            }
            if let cleanupWarning { parts.append(cleanupWarning) }
            if storeFailed {
                parts.append(String(ui: "반영 확인 기록을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 rekordbox와 동기화하세요."))
            }
            return parts.joined(separator: " · ")
        }

        /// 모두 확인됐고 경고가 없다
        public var isClean: Bool { finished && cleanupWarning == nil && !storeFailed }
    }

    /// `verifyReflection(_:rows:shareRoot:)`과 같다. 화면이 든 반영 묶음이 없으면 남겨 둔 묶음(`batches`)을 읽어 확인한다. 확인할 묶음이 없으면 nil
    public func verifyReflection(orSaved batch: ReflectionXMLBatch?, rows: [String: TrackRow], shareRoot: URL) -> Verification? {
        guard let batch = batch ?? batches.load() else { return nil }
        return verifyReflection(batch, rows: rows, shareRoot: shareRoot)
    }

    /// 새 사본을 읽은 뒤: 반영 묶음의 곡마다 rekordbox에 의도대로 들어갔는지 확인한다. 일치한 곡의 큐·그리드 초안은 지운다(이제 rekordbox 값이 원본이다).
    /// 어긋난 곡은 초안을 그대로 두고, 새 사본에 없는 곡은 확인하지 못한 것으로 남긴다(묶음을 다 확인한 것으로 비우지 않는다, #175).
    /// - Parameter rows: 새 사본의 곡(ContentID별)
    public func verifyReflection(_ batch: ReflectionXMLBatch, rows: [String: TrackRow], shareRoot: URL) -> Verification {
        var batch = batch
        var result = Verification(batch: batch, cleared: [])
        for plan in batch.plans {
            guard let row = rows[plan.trackID] else {
                result.unverified.append(plan.title)
                continue
            }
            let check = files.verifyReflection(plan, row.track, row.cues, source.grid(row.track.analysisDataPath, shareRoot))
            batch.checks[plan.trackID] = check
            switch check.result {
            case .matched:
                result.matched += 1
                // 저장 실패로 저장 큐에 남은 기록까지 같이 비우려고 파일을 직접 지우지 않는다(#172).
                drafts.removeCue(plan.uuid)
                drafts.removeGrid(plan.uuid)
                result.cleared.insert(plan.uuid)
            case .notYet:
                result.notYet += 1
            case .mismatched:
                result.mismatched.append("\(plan.title): \(check.problems.joined(separator: " / "))")
            }
        }
        result.batch = batch
        do {
            // 모두 확인됐으면 다음 묶음을 위해 비운다.
            try batches.save(result.finished ? nil : batch)
        } catch {
            result.storeError = error
        }
        // 초안을 지우지 못했으면 알린다(반영은 확인됐지만 덱·쓰기 전 확인이 옛 초안을 계속 볼 수 있다).
        result.cleanupWarning = result.cleared.isEmpty ? nil : drafts.saveWarning(for: result.cleared, restoring: false)
        return result
    }
}
