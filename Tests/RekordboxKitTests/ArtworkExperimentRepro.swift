import DJCTestKit
import Foundation
@testable import RekordboxKit
import Testing

/// 곡 정보 그림 편집(#66)에서 rekordbox가 만든 그림 셋과 DJCrate가 같은 원본으로 만든 셋을 화소로 대조한다. 그림은 저장소에 넣지 않는다.
/// `DJC_ARTWORK_EXPERIMENT=<폴더>`: `jpeg.jpg`(묶음 2 S1 원본 1500×1500 JPEG)·`png.png`(S2 원본 1200×675 PNG)와 rekordbox 7.2.18이 만든
/// `jpeg/`·`png/` 아래 `artwork.jpg`·`artwork_m.jpg`·`artwork_s.jpg`(2026-10-04 묶음 2 S1 "DJC 시험 08"·S2 "DJC 시험 07"의 후 사본).
/// rekordbox 인코더는 결정적이다(#173 S5 W2a·W3b, 같은 원본 → 같은 MD5). DJCrate는 인코더가 달라 바이트는 다르고 크기·여백·머리가 같다.
/// 2026-10-04 잰 화소 차이(0~255, RGB 평균): JPEG 0.07·2.28·4.69, PNG 0.06·0.65·2.19(최대 13·50·60, 8·54·64). `_m`·`_s`는 축소 필터 차이다.
struct ArtworkExperimentRepro {
    static let names = ["artwork.jpg", "artwork_m.jpg", "artwork_s.jpg"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_ARTWORK_EXPERIMENT"] != nil))
    func rekordbox가_만든_그림_셋과_크기가_같고_화소가_거의_같다() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_ARTWORK_EXPERIMENT"] else { return }
        let root = URL(filePath: path)
        for (source, folder, sizes) in [("jpeg.jpg", "jpeg", ["800x800", "240x240", "80x80"]), ("png.png", "png", ["800x450", "240x240", "80x80"])] {
            let made = try #require(TrackArtwork.make(try Data(contentsOf: root.appending(path: source))))
            for (index, (name, ours)) in zip(Self.names, [made.full, made.medium, made.small]).enumerated() {
                let theirs = try Data(contentsOf: root.appending(path: "\(folder)/\(name)"))
                let a = try #require(ImageFixture.pixels(ours)), b = try #require(ImageFixture.pixels(theirs))
                #expect("\(a.width)x\(a.height)" == sizes[index] && "\(b.width)x\(b.height)" == sizes[index], "\(folder)/\(name)")
                let mean = Double(zip(a.rgb, b.rgb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.rgb.count)
                #expect(mean <= [0.15, 3.0, 6.0][index], "\(folder)/\(name) 화소 차이 \(mean)")
                // 머리 모양(JFIF 1.01·DQT 둘·SOF0 4:2:0)이 같다. 허프만 표(DHT)는 그림마다 다르다.
                let header = { (data: Data) in ImageFixture.jpegSegments(data).filter { $0.marker != 0xC4 }.map { "\($0.marker):\($0.body.count)" } }
                #expect(header(ours) == header(theirs), "\(folder)/\(name) JPEG 머리")
            }
        }
    }
}
