import AppKit
import DJCApplication
import Foundation

/// rekordbox에 그림을 쓰거나 되돌린 곡(ContentID)마다 올리는 번호(#66). 그림 바꾸기는 `ImagePath`가 그대로라 ContentID만 열쇠로 쓰면
/// 목록 썸네일 캐시가 옛 그림(그림이 없던 곡이면 "없음")을 계속 보인다. 열쇠에 번호를 붙여 새로 읽게 한다.
@MainActor
enum ArtworkRevisions {
    private(set) static var values: [String: Int] = [:]

    static func bump(_ contentIDs: some Sequence<String>) {
        for id in contentIDs { values[id, default: 0] += 1 }
    }

    /// 썸네일 캐시·셀 재사용 열쇠
    static func key(_ contentID: String) -> String { values[contentID].map { "\(contentID)#\($0)" } ?? contentID }
}

/// 목록 썸네일: 메인 스레드 밖에서 작게 디코딩해 캐시한다. 스크롤로 지나친 요청은 건너뛴다.
/// rekordbox가 만들어 둔 그림(`share/PIONEER/Artwork`)은 유스케이스(`EditArtwork`)로 읽는다. 덱의 그림(파일 내장 그림 포함)은 `TrackAssetReader`가 읽는다.
actor Thumbnails {
    private let artwork: EditArtwork

    init(artwork: EditArtwork) { self.artwork = artwork }

    struct Box: @unchecked Sendable { let image: CGImage }
    private final class Entry { let box: Box?; init(_ box: Box?) { self.box = box } }
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 3000
        return cache
    }()

    /// - Parameter root: rekordbox share 뿌리(라이브러리 저장소의 `shareRoot`)
    func image(imagePath: String?, root: URL?, key: String) -> Box? {
        if let hit = cache.object(forKey: key as NSString) { return hit.box }
        guard !Task.isCancelled else { return nil }
        let box = artwork.listThumbnail(imagePath: imagePath, shareRoot: root).map(Box.init)
        // 아트워크가 없는 곡도 기억해 파일을 다시 열지 않는다.
        cache.setObject(Entry(box), forKey: key as NSString)
        return box
    }
}

extension Thumbnails {
    /// 인스펙터 커버: 전체 크기 JPEG를 그대로 쓰지 않고 긴 변 `maxPixels` 이하로 작게 디코딩한다(메모리·메인 스레드 절약).
    /// `shareRoot`가 nil이면 기본 rekordbox 폴더. 캐시하지 않고 메인 밖에서 부른다
    nonisolated static func downsampled(_ artwork: EditArtwork, imagePath: String?, shareRoot: URL? = nil, maxPixels: Int) -> Box? {
        artwork.thumbnail(imagePath: imagePath, shareRoot: shareRoot, maxPixels: maxPixels).map(Box.init)
    }
}
