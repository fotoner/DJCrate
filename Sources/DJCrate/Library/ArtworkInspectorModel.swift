import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 인스펙터 그림 칸 화면 모델(#66·#250): 그림 넣기·바꾸기·지우기 초안을 만들고(유스케이스 `EditArtwork`) 안내와 보일 그림을 든다.
/// 그림을 고르면 그 사본을 초안 폴더에 바로 둔다(원본 파일을 옮겨도 초안이 남게). 저장은 그 자리에서 끝나 실패하면 바로 알린다.
/// 초안 색인(`LibraryStore.artworkDrafts`)은 목록 ✎ 칸·반영과 같은 색인이라 공유 핵심에 둔다. 반영하면 rekordbox 라이브러리의 그림만 바뀐다.
@MainActor
@Observable
final class ArtworkInspectorModel {
    /// 그림 초안 안내(읽지 못한 그림·쓸 수 없는 곡). 한 동작이 모두 되면 지운다.
    private(set) var message: AppMessage?
    /// 그림 칸이 읽은 그림: 초안 그림이 있으면 그것, 없으면 rekordbox 그림(지우기 초안이면 빈 칸)
    private(set) var image: NSImage?
    @ObservationIgnored private let library: LibraryStore
    private var artwork: EditArtwork { library.useCases.artwork }

    init(store: LibraryStore) {
        library = store
    }

    // MARK: - 보이기

    /// 그림을 고칠 수 있는 곡(이 라이브러리의 로컬 곡). 추가한 곡·USB 곡·스트리밍 곡은 뺀다.
    func editable(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(EditArtwork.canEdit) }

    func draft(for row: TrackRow) -> ArtworkDraft? { library.artworkDrafts[row.track.uuid] }

    /// 고칠 수 있는 곡의 그림 초안
    func drafts(_ rows: [TrackRow]) -> [ArtworkDraft] { editable(rows).compactMap(draft(for:)) }

    /// rekordbox에 그림이 있는 곡인지(초안 전)
    func hasArtwork(_ row: TrackRow) -> Bool { library.artworkBase(for: row).hasArtwork }

    /// rekordbox에 쓰는 동안(단추를 막는다)
    var isLocked: Bool { library.isWritingRekordbox }

    // MARK: - 초안 만들기

    /// 고른 그림 파일로 넣기·바꾸기 초안을 만든다. 읽지 못하거나 확인하지 않은 그림이면 초안을 만들지 않고 알린다.
    func setArtwork(fileAt url: URL, rows: [TrackRow]) {
        do {
            setArtwork(try artwork.image(at: url), name: url.lastPathComponent, rows: rows)
        } catch {
            message = AppMessage(kind: .warning, text: String(ui: "앨범아트 파일을 읽지 못했으니 파일 위치와 접근 권한을 확인한 뒤 다시 고르세요"))
        }
    }

    func setArtwork(_ image: Data, name: String?, rows: [TrackRow]) {
        guard !library.isWritingRekordbox else { return }
        let edits: [ArtworkEdit]
        do {
            edits = try artwork.setEdits(image: image, name: name,
                                         targets: editable(rows).map { ($0.track.uuid, library.artworkBase(for: $0)) })
        } catch {
            message = AppMessage(kind: .warning, text: (error as? EditArtwork.Refused)?.message ?? DJCError.reason(of: error))
            return
        }
        finish(failed: save(edits))
    }

    /// 그림 지우기 초안. 그림이 없는 곡은 남은 넣기 초안만 버린다. 실패는 한 번에 센다(뒤 단계가 앞 단계의 실패 안내를 지우지 않게).
    func deleteArtwork(rows: [TrackRow]) {
        guard !library.isWritingRekordbox else { return }
        let targets = editable(rows)
        let withArtwork = targets.filter(hasArtwork)
        let saved = save(withArtwork.map {
            ArtworkEdit(draft: ArtworkDraft(trackUUID: $0.track.uuid, change: .delete, base: library.artworkBase(for: $0)), image: nil)
        })
        let removed = remove(targets.filter { !hasArtwork($0) })
        finish(failed: saved + removed)
    }

    /// 초안 버리기(그림)
    func discardDrafts(rows: [TrackRow]) {
        guard !library.isWritingRekordbox else { return }
        finish(failed: remove(rows))
    }

    /// 초안과 사본을 지운다. 지우지 못한 곡 수를 돌려준다.
    private func remove(_ rows: [TrackRow]) -> Int {
        let result = artwork.remove(rows.map(\.track.uuid), inMemory: Set(library.artworkDrafts.keys))
        for uuid in result.removed { library.showArtworkDraft(nil, for: uuid) }
        return result.failed
    }

    /// 초안을 저장한다. 저장하지 못한 곡 수를 돌려준다.
    private func save(_ edits: [ArtworkEdit]) -> Int {
        let result = artwork.save(edits)
        for edit in result.saved { library.showArtworkDraft(edit.draft, for: edit.trackUUID) }
        return result.failed
    }

    /// 한 동작을 마친 뒤 한 번만 부른다. 실패가 있으면 안내를 남기고, 모두 되면 지난 안내를 지운다.
    private func finish(failed: Int) {
        message = EditArtwork.failureText(failed).map { AppMessage(kind: .warning, text: $0) }
        library.finishArtworkDraftChange()
    }

    // MARK: - 그림 칸

    /// 초안의 그림 사본(넣기·바꾸기 초안만)
    func draftImage(trackUUID: String) -> Data? {
        guard library.artworkDrafts[trackUUID]?.change == .set else { return nil }
        return artwork.draftImage(trackUUID)
    }

    /// 그림 칸을 다시 읽을 열쇠: 초안(그림 사본의 해시)과 rekordbox 그림이 바뀔 때만 바뀐다.
    func imageKey(for row: TrackRow?) -> String {
        guard let row else { return "" }
        let pending = draft(for: row).map { "\($0.change.rawValue)-\($0.imageSHA256 ?? "")" } ?? "-"
        return "\(row.track.id)|\(ArtworkRevisions.key(row.track.id))|\(row.track.imagePath ?? "")|\(pending)"
    }

    /// `.task(id:)`가 부른다. 그사이 고른 곡이나 초안이 바뀌면(작업 취소) 옛 그림을 넣지 않는다.
    func loadImage(_ row: TrackRow?) async {
        guard let row else { image = nil; return }
        if let draft = draft(for: row) {
            let data = draft.change == .set ? draftImage(trackUUID: row.track.uuid) : nil
            image = data.flatMap(NSImage.init(data:))
            return
        }
        let path = row.track.imagePath, artwork = artwork
        let box = await BlockingWork.run { Thumbnails.downsampled(artwork, imagePath: path, maxPixels: 240) }
        guard !Task.isCancelled else { return }
        image = box.map { NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height)) }
    }

    /// 그림 칸이 사라질 때(인스펙터를 닫거나 고른 곡이 없을 때). 이 모델은 조립 지점에 남으므로, 다시 나타난 칸이 다른 곡의 옛 그림 대신 빈 칸에서 시작하게 한다.
    func forgetImage() { image = nil }
}
