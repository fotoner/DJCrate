import DJCApplication
import DJCDomain
import Foundation

@MainActor
extension LibraryStore {
    /// USB를 읽고 로컬 큐·그리드 초안만 만든다(`UsbCueGridImport`). rekordbox와 USB에 쓰는 것은 별도의 반영 동작이다.
    func importUsbCueGrid(volumeKey: String) async -> UsbCueGridImportSummary {
        var summary = UsbCueGridImportSummary()
        guard !isLoading, !isWritingRekordbox, !isSynchronizingLibrary, allowsLibrarySync?() != false,
              let snapshot = snapshotURL, let usb, let volume = usb.volume(volumeKey),
              let library = usb.libraries[volumeKey], !usb.ejecting.contains(volumeKey) else {
            summary.details = [String(ui: "로컬 라이브러리와 USB를 다 읽고 편집을 마친 뒤 다시 가져오세요.")]
            summary.skippedCount = 1
            return summary
        }
        guard let _ = usb.beginWrite(volume, title: String(ui: "USB의 큐와 그리드 읽는 중"), cancellable: false) else {
            summary.details = [String(ui: "USB 작업이 진행 중이니 끝난 뒤 다시 가져오세요.")]
            summary.skippedCount = library.tracks.count
            return summary
        }
        defer { usb.endWrite(volumeKey) }
        let revision = previewRevision
        let rows = rowsByID
        let tracks = rows.mapValues { UsbCueGridImportTrack(track: $0.track, cues: $0.cues) }
        let share = shareRoot
        let scratch = useCases.usbCueGrid.scratchFolder(in: draftFolder)
        let service = usb.writeService
        do {
            let plan = try await LoadLibrary.background {
                try service.planCueGridImport(volume: volume, snapshot: snapshot, share: share, scratch: scratch, rows: tracks)
            }
            guard !Task.isCancelled, snapshotURL == snapshot, previewRevision == revision,
                  !isLoading, !isWritingRekordbox, !isSynchronizingLibrary,
                  allowsLibrarySync?() != false, usb.volume(volumeKey) == volume,
                  plan.rows.allSatisfy({ rowsByID[$0.row.track.id] == rows[$0.row.track.id] }) else {
                summary.details = [String(ui: "읽는 동안 라이브러리나 편집 상태가 바뀌었으니 편집을 마친 뒤 다시 가져오세요.")]
                summary.skippedCount = library.tracks.count
                return summary
            }
            // 가져온 초안은 이 초안 폴더에 곡별 파일로 바로 쓴다(유스케이스 `ImportUsbCueGridDrafts`). 저장 대기 입력·초안 파일·이 화면의
            // 메모리 입력이 있는 곡은 덮지 않는다.
            let importer = useCases.usbCueGrid
            let saved = importer.save(plan) { uuid, part in
                switch part {
                case .cue: hasDraft(.cue, trackUUID: uuid) || recoveryMemoryInput?(uuid, .cues)?.hasChanges == true
                case .grid: hasDraft(.grid, trackUUID: uuid) || recoveryMemoryInput?(uuid, .grid)?.hasChanges == true
                }
            }
            for draft in saved.cues {
                cueDraftChanged(draft)
                draftChanged(trackUUID: draft.trackUUID, kind: .cue, exists: true)
            }
            for uuid in saved.gridUUIDs {
                draftChanged(trackUUID: uuid, kind: .grid, exists: true)
                onGridDraftSaved?(uuid)
            }
            // 덱의 다른 곡 초안을 nil로 다시 읽어 버리지 않게 지금 덱 곡을 포함한 전체 초안을 넘긴다.
            if !saved.cues.isEmpty {
                onCueDraftsReloaded?(importer.cueDrafts(pendingUUIDs.filter { hasDraft(.cue, trackUUID: $0) }))
            }
            refreshUnlinkedDrafts()
            if case .pending = sidebar { refreshBase() }
            return saved.summary
        } catch {
            summary.skippedCount = library.tracks.count
            summary.details = [(error as? UsbCueGridReadFailure)?.message
                ?? String(ui: "USB 정보를 읽지 못했으니 기기 사용을 마치고 USB를 다시 연결한 뒤 가져오세요.")]
            return summary
        }
    }
}
