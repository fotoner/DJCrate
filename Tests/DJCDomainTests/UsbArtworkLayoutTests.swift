import DJCDomain
import Foundation
import Testing

@Suite("USB 아트워크 폴더 나누기")
struct UsbArtworkLayoutTests {
    @Test("폴더 합이 1,000,000을 넘게 되면 다음 폴더, 딱 맞으면 그대로")
    func splitsWhenExceeding1000000() {
        var layout = UsbArtworkLayout()
        #expect([500_000, 400_000, 200_000].map { layout.place(bytes: $0) } == [1, 1, 2])
        #expect(layout.foldersUsed == [1, 2])

        var exact = UsbArtworkLayout()
        #expect([600_000, 400_000].map { exact.place(bytes: $0) } == [1, 1])
        #expect(exact.place(bytes: 1) == 2)
    }

    @Test("빈 폴더에는 크기가 넘어도 넣는다")
    func firstImageNeverSplit() {
        var layout = UsbArtworkLayout()
        #expect(layout.place(bytes: 1_200_000) == 1)
        #expect(layout.place(bytes: 10) == 2)
        #expect(layout.foldersUsed == [1, 2])
    }

    @Test("기존 폴더 사용량에서 이어 간다")
    func continuesFromExistingUsage() {
        var layout = UsbArtworkLayout(folderUsage: [1: 999_000, 3: 900_000], currentFolder: 3)
        #expect(layout.place(bytes: 50_000) == 3)
        #expect(layout.place(bytes: 60_000) == 4)
        #expect(layout.foldersUsed == [3, 4])
    }

    @Test("폴더는 10진 5자리")
    func pathsFiveDigitFolder() {
        let paths = UsbArtworkLayout.paths(imageID: 20, folder: 2)
        #expect(paths.a == "PIONEER/Artwork/00002/a20.jpg")
        #expect(paths.aMedium == "PIONEER/Artwork/00002/a20_m.jpg")
        #expect(paths.b == "PIONEER/Artwork/00002/b20.jpg")
        #expect(paths.bMedium == "PIONEER/Artwork/00002/b20_m.jpg")
        #expect(UsbArtworkLayout.pdbPath(imageID: 7, folder: 1) == "/PIONEER/Artwork/00001/a7.jpg")
        #expect(UsbArtworkLayout.oneLibraryPath(imageID: 7, folder: 1) == "/PIONEER/Artwork/00001/b7.jpg")
    }

    @Test("a·b 파일은 같은 폴더")
    func aAndBSameFolder() {
        let paths = UsbArtworkLayout.paths(imageID: 123, folder: 12)
        let folders = Set([paths.a, paths.aMedium, paths.b, paths.bMedium].map { ($0 as NSString).deletingLastPathComponent })
        #expect(folders == ["PIONEER/Artwork/00012"])
    }
}
