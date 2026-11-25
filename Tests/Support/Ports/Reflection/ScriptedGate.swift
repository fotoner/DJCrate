import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 반영 세션 시험의 쓰기 관문 가짜: 정해 둔 결과(`GateScript`)를 돌려주고 받은 것을 남긴다(`GateCalls`).
/// 실제 관문(`RekordboxWriteGate.live`)과 같은 계약을 지키는지는 DJCAdaptersTests의 계약 시험이 같은 시험 함수로 본다.
public struct GateScript: Sendable {
    public var preview = RekordboxWriteReport(outcomes: [], backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
    public var previewError: (any Error)?
    /// nil이면 미리 본 보고서를 쓴 결과로 돌려준다(백업은 대상의 백업 폴더 안)
    public var write: RekordboxWriteReport?
    public var writeError: (any Error)?
    /// 묶음에 따라 쓰기에서 던질 오류(⌘S가 나눠 쓴 쓰기 가운데 하나만 실패시키는 시험)
    public var writeErrorFor: (@Sendable (DraftWriteBatch) -> (any Error)?)?
    public var addPreview = RekordboxTrackWriteReport(dryRun: true)
    public var add: RekordboxTrackWriteReport?
    public var addError: (any Error)?
    public var deletePreview = RekordboxTrackWriteReport(dryRun: true)
    public var delete: RekordboxTrackWriteReport?
    public var deleteError: (any Error)?
    public var restoreError: (any Error)?
    public var pointError: (any Error)?
    public var syncData = Data("sync".utf8)
    /// 쓰기 기록 판정(R11)의 처음 값. 기본은 지금 동작과 같은 "기록 없음". 중단 기록이면 그 기록의 요청과 같은 요청만
    /// 복원·"이대로 둔다"가 받아들이고(다르면 `.changed`), "이대로 둔다"가 끝나면 기록이 사라진다(가짜 관문이 상태를 든다)
    public var journal = RekordboxJournalVerdict.none
    /// 받아들인 복원의 결과(복원은 기록을 지우지 않는다: 이 가짜는 기록으로 복원의 끝 상태를 흉내 내지 않는다)
    public var journalRestore = RekordboxJournalRestore.restored(backup: nil)
    public var journalError: (any Error)?
    /// 미정리 목록(R22)
    public var cleanupLists: [DraftCleanupList] = []
    /// 미정리 목록을 읽을 때 던질 오류(목록을 읽지 못함)
    public var cleanupListsError: (any Error)?
    /// 미리 보기·쓰기 결과를 넘긴 묶음에 든 것만 남긴다(실제 관문처럼). 자동 저장이 묶음을 나눠 쓰는 시험이 켠다
    public var reportsBatchOnly = false
    /// 실제로 넣는 동안(dryRun 아님) 부른다: 넣는 동안 바깥(CLI)이 초안을 저장하는 경우를 흉내 낸다
    public var duringAdd: (@Sendable () -> Void)?
    /// 미정리 목록을 읽을 때 부른다(그때 쓰기 잠금을 쥐었는지 시험이 본다)
    public var onCleanupLists: (@Sendable () -> Void)?
    /// 실제로 쓰는 동안(dryRun 아님, 라이브러리 변경을 마치기 전) 부른다: 오래 걸리는 쓰기(`WriteHold`)나 자기 쓰기가 바꾼 파일을 흉내 낸다
    public var duringWrite: (@Sendable () -> Void)?
    /// 실제 관문처럼 라이브러리 변경을 마친 자리(미정리 목록을 만드는 자리, 잠금 해제 전)에서 작업의 `afterChanges`를 부른다(#295 E4).
    /// 실제 관문은 모두 막힌 쓰기도 그 자리를 지난다. 끄면 그 자리에 닿지 않고 돌아온 쓰기를 흉내 낸다
    public var callsAfterChanges = true
    /// `afterChanges` 뒤(쓰기 잠금을 푼 뒤에 해당) 부른다: 잠금이 풀린 틈의 바깥 변화를 흉내 낸다
    public var afterWriteUnlocked: (@Sendable () -> Void)?

    public init() {}
}

/// 관문의 쓰기를 붙잡아 두는 곳(오래 걸리는 쓰기, #295 E4). `hold`가 켜져 있으면 `wait`이 `release()`까지 막는다(관문은 협력 풀 밖에서 불린다)
public final class WriteHold: Sendable {
    private let state = Mutex<(on: Bool, waiting: Bool)>((false, false))
    public init() {}
    public func hold() { state.withLock { $0.on = true } }
    public var isWaiting: Bool { state.withLock { $0.waiting } }
    public func release() { state.withLock { $0.on = false } }
    /// 붙잡혀 있으면 풀릴 때까지 기다린다(60초 안전망)
    public func wait() {
        guard state.withLock({ state -> Bool in
            guard state.on else { return false }
            state.waiting = true
            return true
        }) else { return }
        for _ in 0..<60_000 where state.withLock({ $0.on }) { usleep(1_000) }
        state.withLock { $0.waiting = false }
    }
}

/// 관문이 받은 것(메인 밖에서 부르므로 잠금으로 모은다)
public final class GateCalls: Sendable {
    public struct Calls: Sendable {
        public var previews: [DraftWriteBatch] = []
        public var previewSources: [RekordboxWriteTarget] = []
        public var writes: [DraftWriteBatch] = []
        public var writeInputs: [[String: RekordboxAnalysisInput]] = []
        public var writeTargets: [RekordboxWriteTarget] = []
        public var dryRuns: [Bool] = []
        public var restores: [URL] = []
        public var restoreTargets: [RekordboxWriteTarget] = []
        public var adds: [TrackAddBatch] = []
        public var addTargets: [RekordboxWriteTarget] = []
        public var deletes: [[String]] = []
        public var deleteTargets: [RekordboxWriteTarget] = []
        public var points: [URL] = []
        public var playlistWrites: [[PlaylistEdit]] = []
        public var iTunesTargets: [RekordboxWriteTarget] = []
        /// 기록 판정에 넘긴 잠금의 키(관문이 잡게 했으면 nil)
        public var journalHolds: [RekordboxWriteLockKey?] = []
        /// 기록으로 복원·"이대로 둔다"에 넘긴 요청
        public var journalRequests: [RekordboxJournalRequest] = []
        /// "이대로 둔다"로 지운 기록의 작업 ID(`apply`가 끝난 뒤에만 지운다)
        public var keptJournals: [String] = []
        /// 지운 미정리 목록의 작업 ID
        public var removedCleanupLists: [String] = []
        /// 관문을 부른 차례("preview"·"write"·"restore"·"add preview"·"add"·"delete preview"·"delete"·"point"·
        /// "journal"·"restore journal"·"keep journal"·"cleanup lists"·"remove cleanup list")
        public var order: [String] = []
    }
    private let calls = Mutex(Calls())
    public init() {}
    public var value: Calls { calls.withLock { $0 } }
    func record(_ change: (inout Calls) -> Void) { calls.withLock { change(&$0) } }
}

/// 관문의 미리 보기를 멈춰 두는 곳(취소 시험). `hold`가 켜져 있으면 미리 보기가 `release()`까지 기다린다.
public final class PreviewHold: Sendable {
    private let state = Mutex<(on: Bool, waiting: CheckedContinuation<Void, Never>?)>((false, nil))
    public init() {}
    public func hold() { state.withLock { $0.on = true } }
    public var isWaiting: Bool { state.withLock { $0.waiting != nil } }
    func wait() async {
        guard state.withLock({ $0.on }) else { return }
        await withCheckedContinuation { continuation in state.withLock { $0.waiting = continuation } }
    }
    public func release() { state.withLock { $0.on = false; $0.waiting?.resume(); $0.waiting = nil } }
}

extension RekordboxWriteGate {
    /// 정해 둔 결과를 돌려주는 관문. 계약(실제 관문과 같다): 미리 보기는 사본을 만든 뒤 `copied`를 한 번 부르고 시험 결과(dryRun)를 돌려준다,
    /// 쓰기·넣기·빼기·재생 목록 쓰기는 `dryRun`을 결과에 그대로 적는다, 쓰면(dryRun 아님) 대상의 백업 폴더에 백업을 남긴다,
    /// 복원은 되돌리기 직전 상태를 대상의 백업 폴더에 남긴 백업을 돌려준다.
    /// 동기 입구(쓰기·복원·넣기·빼기·시점 복원·재생 목록·동기화)는 협력 풀 밖에서 불려야 한다(`expectBlockingOffPool`, 세션은 `BlockingWork`).
    /// - Parameter journal: 가짜 관문이 드는 쓰기 기록 상태(시험이 기록이 남았는지 직접 본다). 주지 않으면 `script.journal`로 새로 만든다
    public static func scripted(_ script: GateScript, calls: GateCalls = GateCalls(), hold: PreviewHold = PreviewHold(),
                                journal: ScriptedJournal? = nil) -> Self {
        // 미정리 목록은 가짜 관문이 상태로 든다: 처음 값은 `script.cleanupLists`, 앱 쓰기(작업이 실린 묶음)는 쓴 뒤 목록을 남기고 지우기가 뺀다
        let lists = Mutex(script.cleanupLists)
        var gate = RekordboxWriteGate(
            write: { batch, inputs, target, dryRun in
                expectBlockingOffPool()
                calls.record {
                    $0.writes.append(batch); $0.writeInputs.append(inputs); $0.writeTargets.append(target); $0.dryRuns.append(dryRun)
                    $0.order.append("write")
                }
                if let error = script.writeError ?? script.writeErrorFor?(batch) { throw error }
                if !dryRun { script.duringWrite?() }
                var report = script.write ?? script.preview
                if script.reportsBatchOnly { report = report.restricted(to: batch) }
                report.dryRun = dryRun
                if script.write == nil { report.backup = dryRun ? nil : target.backups.appending(path: "write-1").path }
                if !dryRun, let operation = batch.operation {
                    let steps = batch.revisions.playlistSteps.map { DraftCleanupList.PlaylistStep(revision: $0.revision, contentHash: $0.contentHash,
                                                                                                outcome: .written) }
                    let list = DraftCleanupList(operationID: operation.id, target: RekordboxWriteLockKey(device: 0, inode: 0),
                                                draftHome: operation.draftHome.path, backupFolder: "write-1",
                                                written: batch.revisions.written(batch.revisions.tracks.keys), playlistSteps: steps)
                    lists.withLock { $0.append(list) }
                }
                if !dryRun {
                    if script.callsAfterChanges { batch.operation?.afterChanges?.run() }
                    script.afterWriteUnlocked?()
                }
                return report
            },
            preview: { batch, _, source, copied in
                await copied()
                await hold.wait()
                calls.record { $0.previews.append(batch); $0.previewSources.append(source); $0.order.append("preview") }
                if let error = script.previewError { throw error }
                var report = script.preview
                if script.reportsBatchOnly { report = report.restricted(to: batch) }
                report.dryRun = true
                return report
            },
            restore: { backup, target in
                expectBlockingOffPool()
                calls.record { $0.restores.append(backup); $0.restoreTargets.append(target); $0.order.append("restore") }
                if let error = script.restoreError { throw error }
                return target.backups.appending(path: "before-restore")
            },
            addTracks: { batch, target, dryRun in
                expectBlockingOffPool()
                calls.record { $0.adds.append(batch); $0.addTargets.append(target); $0.dryRuns.append(dryRun); $0.order.append(dryRun ? "add preview" : "add") }
                if !dryRun, let error = script.addError { throw error }
                if !dryRun { script.duringAdd?() }
                var report = dryRun ? script.addPreview : script.add ?? script.addPreview
                report.dryRun = dryRun
                // 앱 곡 넣기(작업이 실린 묶음)는 실제 관문처럼 곡 넣기 몫의 미정리 목록을 남긴다(옛·새 UUID, 쓴 초안의 판, 쓴 값, 막힌 칸)
                if !dryRun, let operation = batch.operation {
                    lists.withLock { $0.append(DraftCleanupList(operationID: operation.id, target: RekordboxWriteLockKey(device: 0, inode: 0),
                                                                draftHome: operation.draftHome.path, backupFolder: "add-1",
                                                                trackAdds: Self.trackAdds(report, batch: batch))) }
                }
                return report
            },
            deleteTracks: { ids, target, dryRun in
                expectBlockingOffPool()
                calls.record {
                    $0.deletes.append(ids); $0.deleteTargets.append(target); $0.dryRuns.append(dryRun)
                    $0.order.append(dryRun ? "delete preview" : "delete")
                }
                if !dryRun, let error = script.deleteError { throw error }
                var report = dryRun ? script.deletePreview : script.delete ?? script.deletePreview
                report.dryRun = dryRun
                return report
            },
            restorePointSnapshot: { entry, _, _, _, _ in
                expectBlockingOffPool()
                calls.record { $0.points.append(entry); $0.order.append("point") }
                if let error = script.pointError { throw error }
                return RekordboxPointRestoreReport(restored: pointEntry(entry), beforeRestore: pointEntry(URL(filePath: "/tmp/before")))
            },
            writePlaylists: { edits, _, dryRun in
                expectBlockingOffPool()
                calls.record { $0.playlistWrites.append(edits); $0.dryRuns.append(dryRun) }
                return RekordboxWriteReport(outcomes: [], backup: nil, dryRun: dryRun, createdAt: "", finalUpdateCount: nil)
            },
            syncITunes: { _, target in
                expectBlockingOffPool()
                calls.record { $0.iTunesTargets.append(target) }
                return script.syncData
            })
        // 중단 기록은 가짜 관문이 상태로 든다: "이대로 둔다"가 끝나면 사라진다
        let journal = journal ?? ScriptedJournal(script.journal)
        gate.journal = { _, hold in
            expectBlockingOffPool()
            calls.record { $0.journalHolds.append(hold?.key); $0.order.append("journal") }
            if let error = script.journalError { throw error }
            return journal.verdict
        }
        gate.restoreJournal = { _, request in
            expectBlockingOffPool()
            calls.record { $0.journalRequests.append(request); $0.order.append("restore journal") }
            if let error = script.journalError { throw error }
            switch journal.refusal(for: request) {
            case .nothing: return .nothing
            case .changed: return .changed
            default: return script.journalRestore
            }
        }
        gate.keepJournal = { _, request, apply in
            expectBlockingOffPool()
            // 들어온 차례는 잠금 앞에서 적는다(겹친 호출이 잠금을 기다리는 것을 시험이 본다)
            calls.record { $0.journalRequests.append(request); $0.order.append("keep journal") }
            if let error = script.journalError { throw error }
            // 실제 관문의 쓰기 잠금처럼 재확인·넘긴 일·기록 삭제를 한 잠금 안에서 차례로 한다
            return try journal.serialized {
                if let refused = journal.refusal(for: request) { return refused }
                do {
                    try apply()
                } catch {
                    calls.record { $0.order.append("keep journal: apply failed") }
                    throw error
                }
                journal.clear()
                calls.record { $0.keptJournals.append(request.operationID); $0.order.append("remove journal") }
                return .kept
            }
        }
        gate.cleanupLists = { _, _ in
            expectBlockingOffPool()
            script.onCleanupLists?()
            calls.record { $0.order.append("cleanup lists") }
            if let error = script.cleanupListsError { throw error }
            return lists.withLock { $0 }
        }
        gate.removeCleanupList = { list, _ in
            expectBlockingOffPool()
            lists.withLock { $0.removeAll { $0.operationID == list.operationID } }
            calls.record { $0.removedCleanupLists.append(list.operationID); $0.order.append("remove cleanup list") }
        }
        return gate
    }
}

extension RekordboxWriteGate {
    /// 곡 넣기 몫의 미정리 목록(실제 관문 `TrackAddBatch.draftRecord`와 같은 규칙. 태그 값은 넣은 곡의 키 기준값 위에 쓴 키를 얹는다)
    static func trackAdds(_ report: RekordboxTrackWriteReport, batch: TrackAddBatch) -> [DraftCleanupList.TrackAdd] {
        report.added.filter(\.written).compactMap { outcome -> DraftCleanupList.TrackAdd? in
            guard let old = batch.stagedUUIDs[outcome.path], let new = outcome.uuid else { return nil }
            var keys: [DraftKey] = [], blocked: [String] = []
            var values = DraftCleanupList.TrackAddValues()
            if outcome.cuesWritten != nil {
                keys.append(DraftKey(.cue, old))
                values.cues = batch.cues[outcome.path]
            } else if outcome.cueReason != nil {
                blocked.append("cues")
            }
            if let analysis = batch.analyses[outcome.path] {
                keys.append(DraftKey(.grid, old))
                values.grid = analysis.segments
            }
            if batch.revisions.tracks[DraftKey(.tag, old)] != nil || outcome.keyWritten != nil {
                keys.append(DraftKey(.tag, old))
                var tags = outcome.keyBase ?? TagFields()
                tags.musicalKey = outcome.keyWritten ?? ""
                values.tags = tags
            }
            if let key = outcome.keyWritten {
                values.musicalKey = key
            } else if outcome.keyReason != nil {
                blocked.append(TagFields.Key.musicalKey.rawValue)
            }
            return DraftCleanupList.TrackAdd(stagedUUID: old, trackUUID: new, written: batch.revisions.written(keys), values: values, blockedFields: blocked)
        }
    }
}

/// 가짜 관문이 든 쓰기 기록 상태. 상태 읽기(`verdict`·`exists`)는 작업 잠금(`serialized`)과 따로 잠가,
/// "이대로 둔다"의 넘긴 일 안에서도 기록이 남았는지 볼 수 있다(실제 관문은 기록 파일을 직접 본다)
public final class ScriptedJournal: Sendable {
    private let state: Mutex<RekordboxJournalVerdict>
    /// 실제 관문의 쓰기 잠금을 흉내 낸다(기록을 다루는 일을 차례로 세운다)
    private let operation = NSLock()

    public init(_ verdict: RekordboxJournalVerdict) { state = Mutex(verdict) }

    public var verdict: RekordboxJournalVerdict { state.withLock { $0 } }
    /// 중단 기록이 남아 있는지
    public var exists: Bool {
        if case .interrupted = verdict { return true }
        return false
    }
    func clear() { state.withLock { $0 = .none } }
    /// 바깥(다른 프로세스)이 기록을 남기거나 지웠다
    public func set(_ verdict: RekordboxJournalVerdict) { state.withLock { $0 = verdict } }

    /// 작업 잠금을 기다린 적이 있는 호출 수(겹친 호출이 잠금 경합에 닿았는지 시험이 본다)
    public var contended: Int { waits.withLock { $0 } }
    private let waits = Mutex(0)

    func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if !operation.try() {
            waits.withLock { $0 += 1 }
            operation.lock()
        }
        defer { operation.unlock() }
        return try body()
    }

    /// 요청을 받아들일 수 없으면 그 결과(기록 없음·달라짐), 받아들이면 nil
    func refusal(for request: RekordboxJournalRequest) -> RekordboxJournalKeep? {
        guard case let .interrupted(finding) = verdict else { return .nothing }
        return finding.request == request ? nil : .changed
    }
}

/// 시점 스냅샷 항목(메타데이터는 저장 모양 그대로 읽는다)
public func pointEntry(_ url: URL) -> RekordboxPointSnapshotEntry {
    let json = #"{"version":1,"name":"","kind":"manual","createdAt":0,"pinned":false,"items":[]}"#
    let metadata = try! JSONDecoder().decode(RekordboxPointSnapshotMetadata.self, from: Data(json.utf8))
    return RekordboxPointSnapshotEntry(url: url, metadata: metadata)
}

extension RekordboxWriteReport {
    /// 묶음에 든 초안의 결과만 남긴 보고서(재생 목록 결과는 묶음의 단계 수만큼 앞에서부터)
    public func restricted(to batch: DraftWriteBatch) -> Self {
        var report = self
        let cues = Set(batch.drafts.map(\.trackUUID)), grids = Set(batch.grids.map(\.trackUUID)), gains = Set(batch.gains.keys)
        let tags = Set(batch.tags.map(\.trackUUID)), artworks = Set(batch.artworks.map(\.trackUUID)), merges = Set(batch.merges.map(\.id))
        report.outcomes = outcomes.filter { cues.contains($0.trackUUID) }
        report.gridOutcomes = gridOutcomes?.filter { grids.contains($0.trackUUID) }
        report.analysisOutcomes = analysisOutcomes?.filter { grids.contains($0.trackUUID) }
        report.gainOutcomes = gainOutcomes?.filter { gains.contains($0.trackUUID) }
        report.tagOutcomes = tagOutcomes?.filter { tags.contains($0.trackUUID) }
        report.artworkOutcomes = artworkOutcomes?.filter { artworks.contains($0.trackUUID) }
        report.mergeOutcomes = mergeOutcomes?.filter { merges.contains($0.trackUUID) }
        report.playlistOutcomes = batch.playlists.map { Array((playlistOutcomes ?? []).prefix($0.steps.count)) }
        let histories = Set(batch.histories.map(\.id))
        report.historyOutcomes = historyOutcomes?.filter { histories.contains($0.id) }
        return report
    }
}
