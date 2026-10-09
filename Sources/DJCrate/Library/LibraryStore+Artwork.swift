import DJCApplication
import DJCDomain
import Foundation

/// 곡 그림 초안(#66): 그림 넣기·바꾸기·지우기를 초안으로 쌓고 반영 때 rekordbox 라이브러리에 쓴다(음원 파일의 그림은 그대로).
/// 그림을 고르면 그 사본을 초안 폴더에 바로 둔다(원본 파일을 옮겨도 초안이 남게). 저장은 그 자리에서 끝나 실패하면 바로 알린다.
extension LibraryStore {
    /// 그림을 고칠 수 있는 곡(이 라이브러리의 로컬 곡). 추가한 곡·USB 곡·스트리밍 곡은 뺀다.
    func canEditArtwork(_ row: TrackRow) -> Bool { EditArtwork.canEdit(row) }

    /// 초안 base: 스냅샷의 곡 행 `ImagePath`와 살아 있는 그림 파일 행
    func artworkBase(for row: TrackRow) -> ArtworkBase {
        ArtworkBase(imagePath: row.track.imagePath ?? "", files: artworkFileRows[row.track.id] ?? [])
    }

    /// 고른 그림 파일로 넣기·바꾸기 초안을 만든다. 읽지 못하거나 확인하지 않은 그림이면 초안을 만들지 않고 알린다.
    func setArtwork(fileAt url: URL, rows: [TrackRow]) {
        do {
            setArtwork(try useCases.artwork.image(at: url), name: url.lastPathComponent, rows: rows)
        } catch {
            artworkMessage = AppMessage(kind: .warning, text: String(ui: "앨범아트 파일을 읽지 못했으니 파일 위치와 접근 권한을 확인한 뒤 다시 고르세요"))
        }
    }

    func setArtwork(_ image: Data, name: String?, rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        let edits: [ArtworkEdit]
        do {
            edits = try useCases.artwork.setEdits(image: image, name: name,
                                                  targets: rows.filter(canEditArtwork).map { ($0.track.uuid, artworkBase(for: $0)) })
        } catch {
            artworkMessage = AppMessage(kind: .warning, text: (error as? EditArtwork.Refused)?.message ?? DJCError.reason(of: error))
            return
        }
        finishArtworkChange(failed: saveArtworkDrafts(edits))
    }

    /// 그림 지우기 초안. 그림이 없는 곡은 남은 넣기 초안만 버린다. 실패는 한 번에 센다(뒤 단계가 앞 단계의 실패 안내를 지우지 않게).
    func deleteArtwork(rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        let targets = rows.filter(canEditArtwork)
        let withArtwork = targets.filter { artworkBase(for: $0).hasArtwork }
        let saved = saveArtworkDrafts(withArtwork.map {
            ArtworkEdit(draft: ArtworkDraft(trackUUID: $0.track.uuid, change: .delete, base: artworkBase(for: $0)), image: nil)
        })
        let removed = removeArtworkDrafts(targets.filter { !artworkBase(for: $0).hasArtwork })
        finishArtworkChange(failed: saved + removed)
    }

    /// 초안 버리기(그림)
    func discardArtworkDrafts(rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        finishArtworkChange(failed: removeArtworkDrafts(rows))
    }

    /// 초안과 사본을 지운다. 지우지 못한 곡 수를 돌려준다.
    private func removeArtworkDrafts(_ rows: [TrackRow]) -> Int {
        let result = useCases.artwork.remove(rows.map(\.track.uuid), inMemory: Set(artworkDrafts.keys))
        for uuid in result.removed {
            artworkDrafts[uuid] = nil
            artworkChangeCount += 1
            updateEdited(uuid)
        }
        return result.failed
    }

    /// 초안을 저장한다. 저장하지 못한 곡 수를 돌려준다.
    private func saveArtworkDrafts(_ edits: [ArtworkEdit]) -> Int {
        let result = useCases.artwork.save(edits)
        for edit in result.saved {
            artworkDrafts[edit.trackUUID] = edit.draft
            artworkChangeCount += 1
            updateEdited(edit.trackUUID)
        }
        return result.failed
    }

    /// 한 동작을 마친 뒤 한 번만 부른다. 실패가 있으면 안내를 남기고, 모두 되면 지난 안내를 지운다.
    private func finishArtworkChange(failed: Int) {
        artworkMessage = EditArtwork.failureText(failed).map { AppMessage(kind: .warning, text: $0) }
        if location.movesDamagedDrafts { applyMovedDrafts(useCases.watch.takeMovedFiles()) }
        if case .pending = sidebar { refreshBase() }
    }

    /// 초안의 그림 사본(넣기·바꾸기 초안만). 인스펙터가 보여 준다.
    func artworkDraftImage(trackUUID: String) -> Data? {
        guard artworkDrafts[trackUUID]?.change == .set else { return nil }
        return useCases.artwork.draftImage(trackUUID)
    }

    /// 쓰기 뒤: 쓴 곡의 그림 초안(파일은 반영 세션이 지웠다, 백업에 남아 있다)을 메모리에서 지우고 목록·덱이 그 곡의 그림을 새로 읽게 한다.
    func clearWrittenArtwork(_ written: [String], failed: Int) {
        guard !written.isEmpty else { return }
        for uuid in written {
            artworkDrafts[uuid] = nil
            artworkChangeCount += 1
            updateEdited(uuid)
        }
        ArtworkRevisions.bump(written.compactMap { rowsByUUID[$0]?.track.id })
        if failed > 0 {
            writeFollowUp.append(String(ui: "rekordbox에는 썼지만 앨범아트 초안 \(failed)곡을 정리하지 못했으니 쓰기 대기 목록에서 앨범아트 초안 버리기로 버리세요."))
        }
    }

    /// 복원 뒤: 되살린 그림 초안(파일은 반영 세션이 저장했다)을 메모리에 넣고, 그 곡과 그 백업이 그림을 쓴 곡(`touched`)의 그림을 새로 읽게 한다.
    func showRestoredArtwork(_ restored: [String: ArtworkDraft], touched: [String]) {
        for (uuid, draft) in restored {
            artworkDrafts[uuid] = draft
            artworkChangeCount += 1
            updateEdited(uuid)
        }
        ArtworkRevisions.bump(touched.compactMap { rowsByUUID[$0]?.track.id })
    }
}
