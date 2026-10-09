import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    /// 렌더해 넣은 편집본(곡 편집·Flip)을 추가한 곡 목록에서 고르고 덱에 올린다(덱의 곡을 편집한 결과라 이어서 확인한다).
    /// 초안은 편집 창이 파일로 써 두었다.
    /// - Parameter hasGrid: 그리드 초안을 함께 넣었는지(원곡 그리드를 옮기지 못한 Flip은 없다)
    func showStagedEdit(_ track: StagedTrack, hasGrid: Bool = true) {
        loadStaged()
        // 넣기가 손상된 추가 목록을 옮겼으면(옛 목록은 보관만 된다) 알린다. 새로 읽은 목록은 비어 있지 않아 저장 알림 규칙을 쓰지 않는다.
        applyMovedDrafts(useCases.watch.takeMovedFiles())
        if hasGrid { draftChanged(trackUUID: track.uuid, kind: .grid, exists: true) }
        // 편집 창이 쓴 초안 파일(큐·그리드)을 메인 밖에서 다시 읽는다
        Task { await refreshExternalDrafts() }
        search = ""
        sidebar = .staged
        selection = [track.id]
        loadToDeck(rowsByID[track.id])
        stagingMessage = AppMessage(kind: .success, text: String(ui: "편집본 ‘\(track.title)’을 추가한 곡에 넣었습니다. rekordbox에 바로 넣기나 XML로 넘기세요"))
    }
}
