import DJCApplication
import DJCDomain
import Foundation

/// 곡 그림 초안(#66)의 공유 색인: 그림 넣기·바꾸기·지우기 초안을 쌓고 반영 때 rekordbox 라이브러리에 쓴다(음원 파일의 그림은 그대로).
/// 초안을 만드는 동작은 인스펙터 그림 칸 화면 모델(`ArtworkInspectorModel`)에 있다. 색인은 목록 ✎ 칸·반영이 함께 보므로 여기에 둔다.
extension LibraryStore {
    /// 초안 base: 스냅샷의 곡 행 `ImagePath`와 살아 있는 그림 파일 행
    func artworkBase(for row: TrackRow) -> ArtworkBase {
        ArtworkBase(imagePath: row.track.imagePath ?? "", files: artworkFileRows[row.track.id] ?? [])
    }

    /// 곡 하나의 그림 초안을 색인에 넣거나(nil이면) 뺀다. 백그라운드 읽기가 그 사이 바뀐 것을 알도록 고친 횟수도 센다.
    func showArtworkDraft(_ draft: ArtworkDraft?, for uuid: String) {
        artworkDrafts[uuid] = draft
        artworkChangeCount += 1
        updateEdited(uuid)
    }

    /// 그림 초안을 고친 동작 하나를 마친 뒤: 옮긴 손상 초안을 받고, 쓰기 대기 목록을 보고 있으면 다시 거른다.
    func finishArtworkDraftChange() {
        if location.movesDamagedDrafts { applyMovedDrafts(useCases.watch.takeMovedFiles()) }
        if case .pending = sidebar { refreshBase() }
    }

    /// 쓰기 뒤: 쓴 곡의 그림 초안(파일은 반영 세션이 지웠다, 백업에 남아 있다)을 메모리에서 지우고 목록·덱이 그 곡의 그림을 새로 읽게 한다.
    func clearWrittenArtwork(_ written: [String], failed: Int) {
        guard !written.isEmpty else { return }
        for uuid in written { showArtworkDraft(nil, for: uuid) }
        ArtworkRevisions.bump(written.compactMap { rowsByUUID[$0]?.track.id })
        if failed > 0 {
            writeFollowUp.append(String(ui: "rekordbox에는 썼지만 앨범아트 초안 \(failed)곡을 정리하지 못했으니 쓰기 대기 목록에서 앨범아트 초안 버리기로 버리세요."))
        }
    }

    /// 복원 뒤: 되살린 그림 초안(파일은 반영 세션이 저장했다)을 메모리에 넣고, 그 곡과 그 백업이 그림을 쓴 곡(`touched`)의 그림을 새로 읽게 한다.
    func showRestoredArtwork(_ restored: [String: ArtworkDraft], touched: [String]) {
        for (uuid, draft) in restored { showArtworkDraft(draft, for: uuid) }
        ArtworkRevisions.bump(touched.compactMap { rowsByUUID[$0]?.track.id })
    }
}
