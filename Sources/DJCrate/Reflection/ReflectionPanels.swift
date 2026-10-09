import DJCDomain
import AppKit
import SwiftUI

/// 기존 곡의 큐·그리드 초안을 연동 XML 파일에 쓴다. 연동 파일만 바꾸므로 묻지 않고, 넣지 않은 것은 결과 줄에 알린다(#212).
@MainActor
enum ReflectionPanels {
    static func export(store: LibraryStore, rows: [TrackRow]) {
        let plans = store.reflectionPlans(for: rows)
        let eligible = plans.filter(\.isEligible), blocked = plans.filter { !$0.blockers.isEmpty }
        guard !eligible.isEmpty else {
            // 연동 파일을 쓰지 않았다. 창 대신 XML 결과 줄 자리에 남긴다(#230).
            store.reflectionMessage = blockedMessage(blocked)
            return
        }
        // 결과 줄에는 초안이 있는 곡의 막힘만 남긴다(고르기만 한 곡은 알리지 않는다, #211).
        let exclusions = store.draftExclusionReasons(for: rows, xml: true, blockedOnly: true)
        let pending = store.pendingUUIDs
        do {
            let url = try RekordboxLink.prepare(store.linkedXMLFile)
            _ = try store.exportReflection(rows: rows, to: url)
        } catch {
            store.reflectionMessage = AppMessage(kind: .failure, text: String(ui: "XML을 만들지 못했습니다. 저장 위치와 권한을 확인하세요: \(error.localizedDescription)"))
            return
        }
        store.reflectionMessage = resultMessage(written: eligible.count, blocked: blocked.filter { pending.contains($0.uuid) }, exclusions: exclusions)
        RekordboxLink.showSetupIfNeeded(store.linkedXMLFile)
    }

    /// XML을 만든 뒤의 목록 위 알림: 쓴 곡 수와 가져오는 순서, 막혀서 뺀 곡·XML에 넣지 않은 초안(앞 둘과 수)
    static func resultMessage(written: Int, blocked: [ReflectionXMLPlan], exclusions: [String]) -> AppMessage {
        // 재생 목록 이름 "DJCrate 반영"은 XML에 쓰는 이름 그대로다(번역하지 않음).
        var text = String(ui: "\(written)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"DJCrate 반영\" › 곡 모두 선택 › Import To Collection → DJCrate rekordbox와 동기화(⟳)")
        if !blocked.isEmpty {
            let names = blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", ")
            text += " · " + String(ui: "막혀서 뺀 곡 \(blocked.count): \(names)")
        }
        // 막힌 곡의 이유와 겹치는 줄은 한 번만 센다.
        let blockedLines = Set(blocked.flatMap { plan in plan.blockers.map { "• \(plan.title): \($0)" } })
        let omitted = exclusions.filter { !blockedLines.contains($0) }
        if !omitted.isEmpty {
            let lines = omitted.prefix(2).map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }.joined(separator: ", ")
            text += " · " + String(ui: "XML에 넣지 않은 초안 \(omitted.count): \(lines)")
        }
        return AppMessage(kind: blocked.isEmpty && omitted.isEmpty ? .success : .warning, text: text)
    }

    /// XML로 만들 곡이 없을 때의 목록 위 알림: 막힌 곡은 결과 줄처럼 앞 둘과 수
    static func blockedMessage(_ blocked: [ReflectionXMLPlan]) -> AppMessage {
        let reason = blocked.isEmpty ? String(ui: "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
            : String(ui: "막혀서 뺀 곡 \(blocked.count): \(blocked.prefix(2).map { "\($0.title)(\($0.blockers.first ?? ""))" }.joined(separator: ", "))")
        return AppMessage(kind: .warning, text: String(ui: "XML로 만들 곡이 없습니다") + " · " + reason)
    }
}
