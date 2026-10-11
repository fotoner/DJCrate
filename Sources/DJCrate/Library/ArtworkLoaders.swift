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
