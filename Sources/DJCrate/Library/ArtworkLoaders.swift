import AppKit
import DJCApplication
import DJCDomain
import Observation

/// 중복 후보 줄의 앨범아트 칸이 읽은 썸네일. 곡 목록의 앨범아트 칸(`ThumbnailCell`)과 같은 디코딩·같은 캐시 키(ContentID)를 쓴다.
@MainActor @Observable
final class ArtworkThumbnailLoader {
    private(set) var box: Thumbnails.Box?

    /// `.task(id:)`가 부른다. 스크롤로 지나친 줄은 작업이 취소되어 디코딩하지 않고(`Thumbnails`) 그림도 바꾸지 않는다.
    func load(_ imagePath: String?, root: URL, key: String, from thumbnails: Thumbnails) async {
        let box = await thumbnails.image(imagePath: imagePath, root: root, key: key)
        if !Task.isCancelled { self.box = box }
    }
}

/// 태그 인스펙터 그림 칸이 읽은 그림: 초안 그림이 있으면 그것을, 없으면 rekordbox 그림을 읽는다(지우기 초안이면 빈 칸).
@MainActor @Observable
final class ArtworkWellLoader {
    private(set) var image: NSImage?

    /// `.task(id:)`가 부른다. 그사이 고른 곡이나 초안이 바뀌면(작업 취소) 옛 그림을 넣지 않는다.
    func load(_ row: TrackRow?, store: LibraryStore) async {
        guard let row else { image = nil; return }
        if let draft = store.artworkDrafts[row.track.uuid] {
            let data = draft.change == .set ? store.artworkDraftImage(trackUUID: row.track.uuid) : nil
            image = data.flatMap(NSImage.init(data:))
            return
        }
        let path = row.track.imagePath, artwork = store.useCases.artwork
        let box = await BlockingWork.run { Thumbnails.downsampled(artwork, imagePath: path, maxPixels: 240) }
        guard !Task.isCancelled else { return }
        image = box.map { NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height)) }
    }
}
