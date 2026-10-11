import CoreGraphics
import DJCDomain
import Foundation
import ImageIO

/// rekordbox 7.2.x가 곡을 분석할 때 음원 내장 아트워크로 만드는 파일 셋(자동 분석을 끄고 넣을 때는 만들지 않는다).
///
/// 2026-09-26 실험(시험 곡 "DJC 실험 아트", 1200×900 JPEG): 800×600·240×240·80×80, 머리 같음, `djc lab artwork-check` 화소 차이 0.1·2.5·4.9.
/// 2026-09-26 라이브러리 조사(스냅샷 사본과 share 읽기 전용, 아트워크 있는 곡 전부·파일 19,914개):
/// - 폴더는 곡 UUID로 정한다(`/PIONEER/Artwork/<앞 3자>/<나머지>/`, 분석 폴더와 같은 규칙). `ImagePath`는 그 안의 `artwork.jpg`.
/// - `artwork.jpg`: 원본 크기 그대로, 긴 변이 800을 넘으면 800으로 줄인다(비율 유지, 짧은 변은 반올림). 원본이 JPEG여도 다시 인코딩한다(PNG도 JPEG로).
/// - `artwork_m.jpg` 240×240, `artwork_s.jpg` 80×80: 정사각에 맞게 키우거나 줄이고 남는 곳은 검은 여백(가운데 맞춤).
/// - 셋 다 기준선 JPEG · JFIF 1.01 · libjpeg 품질 85 표 · 4:2:0 · 허프만 최적화(`ArtworkJPEG`). 축소 방식·DCT가 달라 바이트는 rekordbox와 다르다.
/// 확인하지 않은 것: 투명한 PNG(검은 바탕에 그린다), EXIF 회전(무시), 그림이 여럿일 때 고르는 그림(AVFoundation이 주는 첫 그림).
public enum TrackArtwork {
    public struct Files: Sendable, Equatable {
        public var full: Data
        public var medium: Data
        public var small: Data
    }

    static let fullLimit = 800
    static let mediumSide = 240
    static let smallSide = 80
    static let quality = 85
    /// 크기별 파일 이름(파일 행은 `artwork.jpg`에만 있다)
    static let fileNames = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]

    /// 곡 UUID로 정하는 아트워크 폴더(`/PIONEER/Artwork/<앞 3자>/<나머지>`)
    public static func folder(uuid: String) -> String { "/PIONEER/Artwork/\(uuid.prefix(3))/\(uuid.dropFirst(3))" }

    /// `djmdContent.ImagePath`
    public static func imagePath(uuid: String) -> String { folder(uuid: uuid) + "/artwork.jpg" }

    /// `artwork.jpg` 크기: 긴 변이 800을 넘을 때만 800으로 줄인다.
    static func fullSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > fullLimit else { return (width, height) }
        let scale = Double(fullLimit) / Double(longest)
        return (max(Int((Double(width) * scale).rounded()), 1), max(Int((Double(height) * scale).rounded()), 1))
    }

    /// 곡 정보에서 고른 그림(#66)을 rekordbox처럼 넣을 수 없으면 그 이유(할 일까지). 넣을 수 있으면 nil.
    /// rekordbox 7.2.18 실험은 JPEG(묶음 2 S1 1500×1500)·불투명 PNG(S2 1200×675)만 했다. 그 밖의 형식, 투명한 화소가 있는 그림(rekordbox의
    /// 바탕색 미확인), EXIF 방향이 있는 그림(rekordbox가 돌리는지 미확인)은 막는다.
    public static func unsupportedReason(_ image: Data) -> String? {
        let bytes = [UInt8](image.prefix(8))
        let isJPEG = bytes.starts(with: [0xFF, 0xD8, 0xFF]), isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard isJPEG || isPNG else { return String(ui: "JPEG·PNG가 아닌 앨범아트는 rekordbox에서 확인하지 않았으니 JPEG나 PNG 앨범아트를 고르세요") }
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width > 0, decoded.height > 0 else {
            return String(ui: "앨범아트를 읽지 못했으니 다른 JPEG·PNG 앨범아트를 고르세요")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            return String(ui: "회전 정보가 있는 앨범아트는 rekordbox 규칙을 확인하지 않았으니 회전을 적용해 저장한 앨범아트를 고르세요")
        }
        if hasTransparency(decoded) {
            return String(ui: "투명한 부분이 있는 앨범아트는 rekordbox 규칙을 확인하지 않았으니 투명한 곳이 없는 앨범아트를 고르세요")
        }
        return nil
    }

    /// 알파 칸이 있고 실제로 255보다 작은 화소가 있는지(알파 칸만 있고 모두 불투명한 PNG는 통과)
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        return stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 255 }
    }

    /// 내장 그림(JPEG·PNG 등 ImageIO가 푸는 것)으로 파일 셋을 만든다. 풀지 못하면 nil.
    public static func make(_ image: Data) -> Files? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width > 0, decoded.height > 0 else { return nil }
        let full = fullSize(width: decoded.width, height: decoded.height)
        guard let fullPixels = render(decoded, width: full.width, height: full.height,
                                      rect: CGRect(x: 0, y: 0, width: full.width, height: full.height)) else { return nil }
        var squares: [Data] = []
        for side in [mediumSide, smallSide] {
            // 정사각 안에 들어가게 늘이거나 줄여 가운데에 둔다
            let scale = min(Double(side) / Double(decoded.width), Double(side) / Double(decoded.height))
            let w = Double(decoded.width) * scale, h = Double(decoded.height) * scale
            let rect = CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h)
            guard let pixels = render(decoded, width: side, height: side, rect: rect) else { return nil }
            squares.append(ArtworkJPEG.encode(rgb: pixels, width: side, height: side, quality: quality))
        }
        return Files(full: ArtworkJPEG.encode(rgb: fullPixels, width: full.width, height: full.height, quality: quality),
                     medium: squares[0], small: squares[1])
    }

    /// 검은 sRGB 바탕에 `rect`로 그린 RGB 화소(위 행부터)
    static func render(_ image: CGImage, width: Int, height: Int, rect: CGRect) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<width * height {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }
}
