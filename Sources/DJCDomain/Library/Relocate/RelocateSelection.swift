import Foundation

/// 사람이 고른 결과(곡 ↔ 후보 파일, #62). 확실한 곡은 기본으로 그 후보를 고른 것으로 두고, 애매한 곡은 사람이 후보 중에서 고른다.
/// 아직 어디에도 저장하지 않는다(초안은 경로 바꾸기 쓰기 규칙을 rekordbox 실험으로 확인한 뒤에 만든다).
public struct RelocateSelection: Sendable, Equatable {
    public let report: RelocateReport
    /// 곡 ID → 고른 파일 경로. 고르지 않은 곡은 없다.
    private var picks: [String: String] = [:]

    public init(report: RelocateReport) {
        self.report = report
        for result in report.results {
            if case let .confident(candidate) = result.outcome { picks[result.id] = candidate.file.path }
        }
    }

    /// 후보 중 `path`를 고른다. `nil`이면 고르지 않는다. 그 곡의 후보가 아닌 경로는 무시한다.
    public mutating func choose(_ path: String?, for trackID: String) {
        guard let path else {
            picks[trackID] = nil
            return
        }
        guard let result = report.results.first(where: { $0.id == trackID }),
              result.candidates.contains(where: { $0.file.path == path }) else { return }
        picks[trackID] = path
    }

    public func chosen(for trackID: String) -> RelocateCandidate? {
        guard let path = picks[trackID], let result = report.results.first(where: { $0.id == trackID }) else { return nil }
        return result.candidates.first { $0.file.path == path }
    }

    /// 곡 ID → 고른 후보. 목록 전체를 그릴 때 곡마다 `chosen(for:)`로 보고서를 다시 훑지 않게 한 번에 구한다.
    public var chosenCandidates: [String: RelocateCandidate] {
        var chosen: [String: RelocateCandidate] = [:]
        for result in report.results {
            if let path = picks[result.id], let candidate = result.candidates.first(where: { $0.file.path == path }) {
                chosen[result.id] = candidate
            }
        }
        return chosen
    }

    public var chosenCount: Int { picks.count }

    /// 같은 파일을 둘 이상의 곡에 고른 경우: 파일 경로 → 곡 ID(보고서 순서). 한 파일은 한 곡에만 연결할 수 있다.
    public var conflicts: [String: [String]] {
        var byPath: [String: [String]] = [:]
        for result in report.results {
            if let path = picks[result.id] { byPath[path, default: []].append(result.id) }
        }
        return byPath.filter { $0.value.count > 1 }
    }
}
