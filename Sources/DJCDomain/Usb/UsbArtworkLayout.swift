import Foundation

/// USB 아트워크 파일 자리(`PIONEER/Artwork/%05d/`). 한 폴더 안 파일 합이 한계를 넘게 되면 다음 폴더로 간다.
/// 나누는 기준은 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)에서 추정한 것이다(`artworkFolderSplit`).
public struct UsbArtworkLayout: Sendable {
    public static let folderByteLimit = 1_000_000

    /// 폴더 번호 → a·b·_m 파일 바이트 합
    private var folderUsage: [Int: Int]
    private var currentFolder: Int
    public private(set) var foldersUsed: Set<Int> = []

    /// 수정할 때: 기존 폴더별 a·b·_m 바이트 합과 마지막 폴더
    public init(folderUsage: [Int: Int] = [:], currentFolder: Int = 1) {
        self.folderUsage = folderUsage
        self.currentFolder = currentFolder
    }

    /// 지금 채우는 폴더
    public var folder: Int { currentFolder }

    /// bytes = a + b + a_m + b_m(= 2 × (small + medium)). 현재 폴더가 비어 있지 않고 합이 한계를 넘게 되면 다음 폴더.
    public mutating func place(bytes: Int) -> Int {
        let used = folderUsage[currentFolder] ?? 0
        if used > 0 && used + bytes > Self.folderByteLimit { currentFolder += 1 }
        folderUsage[currentFolder, default: 0] += bytes
        foldersUsed.insert(currentFolder)
        return currentFolder
    }

    /// USB 루트 기준 상대 경로: "PIONEER/Artwork/%05d/a%d.jpg", "…/a%d_m.jpg", "…/b%d.jpg", "…/b%d_m.jpg"
    public static func paths(imageID: Int, folder: Int) -> (a: String, aMedium: String, b: String, bMedium: String) {
        let base = directory(folder)
        return (base + "/a\(imageID).jpg", base + "/a\(imageID)_m.jpg", base + "/b\(imageID).jpg", base + "/b\(imageID)_m.jpg")
    }

    /// Device Library(pdb)가 가리키는 경로
    public static func pdbPath(imageID: Int, folder: Int) -> String {
        "/" + paths(imageID: imageID, folder: folder).a
    }

    /// OneLibrary가 가리키는 경로
    public static func oneLibraryPath(imageID: Int, folder: Int) -> String {
        "/" + paths(imageID: imageID, folder: folder).b
    }

    static func directory(_ folder: Int) -> String {
        UsbLayout.artworkRoot + "/" + String(format: "%05d", folder)
    }
}
