import CoreGraphics
import Foundation
import ImageIO

extension RekordboxShare {
    /// rekordbox가 만들어 둔 그림(`share/PIONEER/Artwork`)을 긴 변이 `maxPixels` 이하가 되게 작게 디코딩한다(큰 그림 → 중간 그림 순).
    /// 전체 크기 JPEG를 그대로 쓰지 않는다(메모리 절약). `root`가 nil이면 기본 rekordbox 폴더.
    public static func artworkThumbnail(_ imagePath: String?, root: URL? = nil, maxPixels: Int) -> CGImage? {
        for size in [ArtworkSize.full, .medium] {
            guard let url = artworkURL(imagePath, size: size, root: root),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  ] as CFDictionary)
            else { continue }
            return image
        }
        return nil
    }
}
