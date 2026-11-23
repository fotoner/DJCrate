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

    public init() {}
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
    public static func scripted(_ script: GateScript, calls: GateCalls = GateCalls(), hold: PreviewHold = PreviewHold()) -> Self {
        var gate = RekordboxWriteGate(
            write: { batch, inputs, target, dryRun in
                expectBlockingOffPool()
                calls.record {
                    $0.writes.append(batch); $0.writeInputs.append(inputs); $0.writeTargets.append(target); $0.dryRuns.append(dryRun)
                    $0.order.append("write")
                }
                if let error = script.writeError { throw error }
                var report = script.write ?? script.preview
                report.dryRun = dryRun
                if script.write == nil { report.backup = dryRun ? nil : target.backups.appending(path: "write-1").path }
                return report
            },
            preview: { batch, _, source, copied in
                await copied()
                await hold.wait()
                calls.record { $0.previews.append(batch); $0.previewSources.append(source); $0.order.append("preview") }
                if let error = script.previewError { throw error }
                var report = script.preview
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
                var report = dryRun ? script.addPreview : script.add ?? script.addPreview
                report.dryRun = dryRun
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
        let journal = ScriptedJournal(script.journal)
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
            calls.record { $0.journalRequests.append(request); $0.order.append("keep journal") }
            if let error = script.journalError { throw error }
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
        gate.cleanupLists = { _, _ in
            expectBlockingOffPool()
            calls.record { $0.order.append("cleanup lists") }
            return script.cleanupLists
        }
        gate.removeCleanupList = { list, _ in
            expectBlockingOffPool()
            calls.record { $0.removedCleanupLists.append(list.operationID); $0.order.append("remove cleanup list") }
        }
        return gate
    }
}

/// 가짜 관문이 든 쓰기 기록 상태
private final class ScriptedJournal: Sendable {
    private let state: Mutex<RekordboxJournalVerdict>

    init(_ verdict: RekordboxJournalVerdict) { state = Mutex(verdict) }

    var verdict: RekordboxJournalVerdict { state.withLock { $0 } }
    func clear() { state.withLock { $0 = .none } }

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
