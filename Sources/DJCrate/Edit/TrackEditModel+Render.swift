import DJCApplication
import DJCDomain
import Foundation

/// 곡 편집 창의 렌더 → 추가한 곡
extension TrackEditModel {
    /// 백그라운드에서 렌더하고(진행·취소) 추가한 곡에 넣는다. 파일 이름 고르기·렌더·넣기는 `RenderEdit`가 메인 밖에서 한다.
    func render() {
        guard canRender, let edit, let carry else { return }
        pause()
        message = nil
        let request = EditOutputRequest(job: EditRenderJob(plan: .bars(edit), source: source, sourceOffset: timelineOffset),
                                        title: title, grid: [edit.outputGrid], cues: carry.placed, sourceTrack: row.track)
        let writer = writer
        let task = Task { [self] in
            defer { finishRendering() }
            do {
                let staged = try await writer.write(request) { [weak self] value in
                    Task { @MainActor in self?.updateRenderProgress(value) }
                }
                markStaged(staged)
                message = AppMessage(kind: .success, text: String(ui: "편집본을 추가한 곡에 넣었습니다: \(request.title) · \(edit.duration.clockText) · 큐 \(carry.placed.count)개"))
                onStaged?(staged)
            } catch is CancellationError {
                message = AppMessage(kind: .warning, text: String(ui: "렌더를 취소했습니다. 만들던 파일은 지웠습니다."))
            } catch {
                message = AppMessage(kind: .failure, text: String(ui: "렌더하지 못했습니다. \(Self.reason(error))"))
            }
        }
        markRendering(task)
    }
}
