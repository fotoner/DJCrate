import DJCApplication
import DJCDomain
import Foundation

/// 이미 rekordbox에 있는 곡에 DJCrate 초안(큐·그리드)을 반영: 계획 → XML → (사용자가 rekordbox에서 가져옴) → 검증.
extension LibraryStore {
    /// 툴바 버튼의 대상: 선택한 곡 중 초안이 있는 곡, 없으면 반영 대기 곡 전체.
    var reflectionTargets: [TrackRow] {
        let pending = pendingUUIDs
        let selected = selectedRows.filter { !$0.isStaged && pending.contains($0.track.uuid) }
        if !selected.isEmpty { return selected }
        return rows.filter { pending.contains($0.track.uuid) }
    }

    /// 요청한 곡마다 계획을 남겨 대상에서 빠진 이유도 미리 보기에 표시한다.
    func reflectionPlans(for rows: [TrackRow]) -> [ReflectionXMLPlan] {
        useCases.exportXML.reflectionPlans(for: rows, pending: pendingUUIDs, cueMarks: cueDraftUUIDs, gridMarks: gridDraftUUIDs) {
            draftExclusionReasons(for: [$0], xml: true)
        }
    }

    /// 반영 XML을 쓴다. 막힌 곡은 빼고 이유를 돌려준다.
    func exportReflection(rows: [TrackRow], to url: URL) throws -> (exported: [ReflectionXMLPlan], blocked: [ReflectionXMLPlan]) {
        let exported = try useCases.exportXML.exportReflection(reflectionPlans(for: rows), uuids: Set(rows.map(\.track.uuid)), to: url)
        if let batch = exported.batch { reflectionBatch = batch }
        return (exported.exported, exported.blocked)
    }

    /// 새 스냅샷을 읽은 뒤: 반영 묶음의 곡마다 rekordbox에 의도대로 들어갔는지 확인한다(유스케이스 `ExportXML.verifyReflection`).
    /// 일치한 곡의 초안은 지운다(이제 rekordbox 값이 원본이다). 어긋난 곡은 초안을 그대로 두고 알린다.
    func verifyReflection() {
        guard let verified = useCases.exportXML.verifyReflection(orSaved: reflectionBatch, rows: rowsByID, shareRoot: shareRoot) else { return }
        for uuid in verified.cleared {
            draftCueCounts[uuid] = nil
            draftChanged(trackUUID: uuid, kind: .cue, exists: false)
            draftChanged(trackUUID: uuid, kind: .grid, exists: false)
        }
        if let error = verified.storeError { AppErrorMessage.log(error) }
        reflectionBatch = verified.finished ? nil : verified.batch
        reflectionMessage = AppMessage(kind: verified.isClean ? .success : .warning, text: verified.message)
        useCases.log("[반영 검증] \(reflectionMessage?.text ?? "")")
    }
}
