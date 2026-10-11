import Foundation

/// 계획이 필요로 하는 확인 안 된 규칙과 볼륨을 보고 쓰기 전 막힘을 낸다.
public enum UsbRuleCheck {
    /// 실물이면 관문 결과(`UsbPhysicalWriteGate`)를 내고, 확인 안 된 규칙은 늘 막는 규칙(`alwaysBlocks`)만 막는다.
    /// 그 밖의 확인 안 된 규칙은 막지 않는다 — 곡 내용 규칙은 미리 보기·확인 창이 "CDJ에서 확인하지 않은 항목"으로 알린다(`needsDeviceCheck`)
    public static func blocks(required: Set<UsbProvisionalRule>, volume: UsbVolumeInfo, gate: UsbPhysicalWriteGate,
                              confirmName: String?) -> [UsbBlock] {
        var result = gate.blocks(volume, confirmName: confirmName)
        for rule in UsbProvisionalRule.allCases where required.contains(rule) && rule.alwaysBlocks && !rule.isConfirmed {
            result.append(UsbBlock(code: "provisional", scope: .volume,
                                   message: String(ui: "확인하지 않은 규칙(\(rule.summary))이 필요해 이 USB에 쓸 수 없습니다"),
                                   rule: rule))
        }
        return result
    }
}
