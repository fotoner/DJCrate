import DJCDomain
import Foundation

extension DeckModel {
    var playbackUnavailableReason: String? {
        guard !canPlay else { return nil }
        guard let row else { return String(ui: "목록에서 곡을 골라 덱에 불러오세요") }
        if row.track.isStreaming { return String(ui: "스트리밍 곡은 재생할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요") }
        // 음원 파일이 있는지는 불러올 때 메인 밖에서 본 값(`audioSourceState`의 `.missing`)을 쓴다. 화면이 읽을 때마다 파일을 보지 않는다.
        return (audioSourceState == .ready ? AudioSourceState.preparing : audioSourceState).unavailableReason
    }

    var hotCueCreationUnavailableReason: String? {
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 편집하세요") }
        if draft == nil { return String(ui: "곡을 덱에 불러오고 초안 읽기가 끝난 뒤 편집하세요") }
        return canPlay || grid != nil || instantLoop != nil ? nil : playbackUnavailableReason
    }

    var gridUnavailableReason: String? {
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 편집하세요") }
        if row?.track.isStreaming == true { return String(ui: "스트리밍 곡은 그리드를 편집할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요") }
        if let gridEditBlockedReason { return gridEditBlockedReason }
        return gridDraft == nil ? gridSourceNotice ?? String(ui: "곡을 덱에 불러오고 그리드 읽기가 끝난 뒤 편집하세요") : nil
    }
}
