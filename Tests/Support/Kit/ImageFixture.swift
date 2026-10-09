import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 합성 그림(그러데이션)과 음원 내장 아트워크. 아트워크 시험용(실데이터 없음).
public enum ImageFixture {
    /// 가장자리까지 밝은 그러데이션 그림. 레터박스(검은 여백)와 구별된다. `blue`를 바꾸면 곡마다 다른 그림이 된다.
    public static func image(width: Int, height: Int, type: UTType = .jpeg, blue: UInt8 = 153) -> Data {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = UInt8(77 + 178 * x / width)
                rgba[i + 1] = UInt8(77 + 178 * y / height)
                rgba[i + 2] = blue
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// 그림을 풀어 RGB 화소(위 행부터)로 돌려준다.
    public static func pixels(_ data: Data) -> (width: Int, height: Int, rgb: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgb += rgba[i..<i + 3] }
        return (width, height, rgb)
    }

    /// 한 행의 RGB 평균 밝기(0~255)
    public static func rowBrightness(_ pixels: (width: Int, height: Int, rgb: [UInt8]), row: Int) -> Double {
        let start = row * pixels.width * 3
        return Double(pixels.rgb[start..<start + pixels.width * 3].reduce(0) { $0 + Int($1) }) / Double(pixels.width * 3)
    }

    /// JPEG 표식(0xFFxx)과 그 내용을 SOS까지 차례로
    public static func jpegSegments(_ data: Data) -> [(marker: UInt8, body: Data)] {
        let bytes = [UInt8](data)
        var segments: [(UInt8, Data)] = []
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            segments.append((marker, Data(bytes[i + 4..<min(i + 2 + length, bytes.count)])))
            if marker == 0xDA { break }
            i += 2 + length
        }
        return segments
    }
}

public extension AudioFixture {
    /// 음원 앞에 ID3v2.3 태그(APIC 앞표지 하나)를 붙인 사본. 원본에 ID3 태그가 없어야 한다.
    static func mp3(_ source: URL, artwork image: Data, mime: String = "image/jpeg", in directory: URL, name: String = "artwork.mp3") throws -> URL {
        func bigEndian(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }) }
        func syncsafe(_ value: Int) -> Data { Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) }) }
        // 글자 인코딩 0(ISO-8859-1) · MIME · 그림 종류 3(앞표지) · 빈 설명 · 그림
        let body = Data([0]) + Data(mime.utf8) + Data([0, 3, 0]) + image
        let frame = Data("APIC".utf8) + bigEndian(body.count) + Data([0, 0]) + body
        let tag = Data("ID3".utf8) + Data([3, 0, 0]) + syncsafe(frame.count) + frame
        let url = directory.appending(path: name)
        try (tag + Data(contentsOf: source)).write(to: url)
        return url
    }
}
