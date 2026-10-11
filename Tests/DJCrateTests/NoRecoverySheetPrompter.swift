@testable import DJCrate
import Testing

/// 복구 시트가 열릴 일이 없는 시험용 프롬프터의 표지(#232). 시트가 열리는 흐름에 닿으면 기다리지 않고 시험을 실패시키며 시트를 닫는다.
/// `ReflectionPrompter.review`는 기본 구현이 없다: 실제 프롬프터(`AlertPrompter`)는 시트가 닫히기를 기다리므로, 시험용이 그대로 따르면 끝없이 기다린다.
@MainActor
protocol NoRecoverySheetPrompter: ReflectionPrompter {}

extension NoRecoverySheetPrompter {
    func review(_ model: RecoverySheetModel) async {
        Issue.record("이 시험에서는 막힌 초안 복구 시트가 열리면 안 됩니다")
        model.cancel()
    }
}
