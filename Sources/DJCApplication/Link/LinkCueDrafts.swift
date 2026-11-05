import DJCDomain
import Foundation

/// LINK로 CDJ가 보낸 큐 저장·삭제(#280)를 곡의 큐 초안 파일에 하나씩 차례로 옮긴다(MEMORY를 잇달아 눌러도 섞이지 않게).
/// 앱이 맡은 초안 저장을 먼저 끝내 그 위에 얹는다(아직 쓰지 않은 앱 입력이 이 편집을 덮지 않게). 앱은 다시 읽기로 화면에 받는다.
/// rekordbox에는 쓰지 않는다(LNK-11·LNK-16)
public actor LinkCueDrafts {
    private let edits: EditDraftFiles
    private let flush: @Sendable () -> Void

    /// - Parameter flush: 앱이 맡은 초안 저장이 디스크에 닿을 때까지 기다린다
    public init(edits: EditDraftFiles, flush: @escaping @Sendable () -> Void) {
        self.edits = edits
        self.flush = flush
    }

    // 안에서 기다리지 않는다(액터가 편집 하나를 끝까지 한 뒤 다음 편집을 받게)
    public func apply(_ edit: LinkCueEdit, track: Track, rekordboxCues: [Cue]) throws -> LinkCueEditResult {
        flush()
        return try edits.applyLinkCue(edit, track: track, rekordboxCues: rekordboxCues)
    }
}
