import DJCApplication
import DJCDomain
import Foundation
import Observation

/// '폴더에서 찾기…'(#62): 파일 없는 곡의 새 위치 후보를 폴더에서 맞춰 미리 보는 화면의 상태.
/// 읽기만 한다. rekordbox·음원에는 쓰지 않고, 고른 결과도 어디에 저장하지 않는다(경로 바꾸기 쓰기 규칙은 아직 막혀 있다).
/// 찾기(파일 크기·훑기·볼륨)는 유스케이스 `RelocateTracks`가 한다.
@MainActor
@Observable
final class RelocateModel: Identifiable {
    enum Phase: Equatable {
        case scanning(RelocateProgress)
        case reviewing
        case failed(String)
    }

    /// 목록에서 보여 줄 분류
    enum Filter: CaseIterable, Hashable {
        case all, confident, ambiguous, noCandidate
    }

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// 경로 바꾸기 쓰기를 막아 둔 이유(버튼 옆에 그대로 보인다).
    static var writeBlockedReason: String {
        String(ui: "경로 바꾸기 쓰기 규칙을 rekordbox 실험으로 아직 확인하지 않아 막아 두었으니, 지금은 rekordbox의 Relocate로 직접 연결하세요.")
    }

    let tracks: [Track]
    let snapshot: URL?
    private let relocate: RelocateTracks
    private(set) var folder: URL
    private(set) var phase: Phase = .scanning(RelocateProgress(phase: .listing, audioFiles: 0, filesToRead: 0, filesRead: 0))
    private(set) var selection = RelocateSelection(report: RelocateReport(results: []))
    private(set) var summary: RelocateSummary?
    /// 곡마다 왜 없는지(외장 디스크가 연결되지 않았는지). 대상에서 빼지 않고 표시만 한다.
    private(set) var absences: [String: RelocateAbsence] = [:]
    var filter: Filter = .all

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(tracks: [Track], snapshot: URL?, folder: URL, relocate: RelocateTracks) {
        self.tracks = tracks
        self.snapshot = snapshot
        self.folder = folder
        self.relocate = relocate
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var report: RelocateReport { selection.report }

    /// 지금 고른 폴더를 훑는다. 이미 훑는 중이면 그것을 취소하고 새로 시작한다.
    func start() {
        task?.cancel()
        generation += 1
        let generation = generation
        let tracks = tracks, snapshot = snapshot, folder = folder, relocate = relocate
        phase = .scanning(RelocateProgress(phase: .listing, audioFiles: 0, filesToRead: 0, filesRead: 0))
        selection = RelocateSelection(report: RelocateReport(results: []))
        summary = nil
        absences = [:]
        // 훑는 동안만 모델을 붙들고(끝나면 놓인다), 창을 닫으면 `cancel()`이 멈춘다.
        task = Task {
            do {
                let found = try await relocate.find(tracks, snapshot: snapshot, folder: folder) { progress in
                    Task { @MainActor [weak self] in self?.apply(progress: progress, generation: generation) }
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                self.absences = found.absences
                self.selection = RelocateSelection(report: found.output.report)
                self.summary = found.output.summary
                self.phase = .reviewing
            } catch is CancellationError {
                // 취소·다시 시작: 새 훑기가 상태를 이어받는다. 취소만 했으면 `cancel()`이 상태를 정한다.
            } catch {
                guard generation == self.generation else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 다른 폴더로 다시 찾는다.
    func rescan(in folder: URL) {
        self.folder = folder
        start()
    }

    /// 훑기를 멈춘다(창을 닫을 때·취소 단추). 읽은 것은 버린다.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if isScanning { phase = .failed(String(ui: "찾기를 취소했습니다. 폴더를 다시 고르세요.")) }
    }

    func choose(_ path: String?, for trackID: String) {
        selection.choose(path, for: trackID)
    }

    var visibleResults: [RelocateResult] {
        switch filter {
        case .all: report.results
        case .confident: report.results.filter { $0.outcome.kind == .confident }
        case .ambiguous: report.results.filter { $0.outcome.kind == .ambiguous }
        case .noCandidate: report.results.filter { $0.outcome.kind == .none }
        }
    }

    func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: report.results.count
        case .confident: report.confidentCount
        case .ambiguous: report.ambiguousCount
        case .noCandidate: report.noneCount
        }
    }

    func absence(for trackID: String) -> RelocateAbsence? { absences[trackID] }

    /// 외장 디스크가 연결되지 않아 없는 곡 수
    var unmountedVolumeCount: Int { absences.values.lazy.filter { $0.unmountedVolumeName != nil }.count }

    /// 화면에 보일 후보 경로: 훑은 폴더 기준 상대 경로(폴더 밖이면 그대로). 링크를 푼 폴더 경로로 훑었을 수도 있어 둘 다 본다.
    func displayPath(_ path: String) -> String {
        for root in [folder.resolvingSymlinksInPath().path, folder.path] {
            if let relative = RelocateScanPolicy.relativePath(of: path, in: root) { return relative }
        }
        return path
    }

    private func apply(progress: RelocateProgress, generation: Int) {
        guard generation == self.generation, isScanning else { return }
        phase = .scanning(progress)
    }
}
