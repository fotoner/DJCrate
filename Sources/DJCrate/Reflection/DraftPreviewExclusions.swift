import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    /// 고른 곡 가운데 쓰기·XML에서 빠지는 초안의 줄(규칙은 DJCApplication `DraftExclusions`, 반영 세션과 같다)
    /// - Parameter blockedOnly: 쓰기 확인 목록용. 초안을 읽지 못해 막힌 줄만 남긴다(#211)
    func draftExclusionReasons(for rows: [TrackRow], xml: Bool = false, blockedOnly: Bool = false) -> [String] {
        useCases.watch.exclusionReasons(for: rows, state: reflectionState(), xml: xml, blockedOnly: blockedOnly)
    }

    /// 실제 쓰기 대상은 유지하고, 같은 선택에서 빠진 곡을 미리 보기에 함께 넘긴다.
    /// 쓰기 확인 목록은 이 가운데 막힌 초안만 보인다(`blockedOnly`, #211).
    var reflectionPreviewRows: [TrackRow] {
        let targets = reflectionTargets
        var ids = Set(targets.map(\.id))
        return targets + selectedRows.filter { ids.insert($0.id).inserted }
    }
}
