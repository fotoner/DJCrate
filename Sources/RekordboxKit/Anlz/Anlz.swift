import DJCDomain
import Foundation

public extension BeatGrid {
    static func load(anlz url: URL) throws -> BeatGrid {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= data.count else { return 0 }
            return data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= data.count else { return 0 }
            return Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
        }
        func tag(_ offset: Int) -> String {
            String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4], as: UTF8.self)
        }

        guard data.count > 12, tag(0) == "PMAI" else { throw DJCError.invalidAnalysisFile(url.path) }
        var offset = u32(4)
        while offset + 12 <= data.count {
            let headerLength = u32(offset + 4), tagLength = u32(offset + 8)
            guard tagLength > 0 else { break }
            if tag(offset) == "PQTZ" {
                // 개수는 파일에서 읽은 값이라 믿지 않는다. 태그·파일 범위로 상한을 둔다
                // (rekordbox가 분석 중인 반쯤 쓰인 파일이면 40억 번 반복할 수 있다).
                guard headerLength >= 24, tagLength >= headerLength else { break }
                let start = offset + headerLength
                let end = min(offset + tagLength, data.count)
                let count = min(u32(offset + 20), max(0, (end - start) / 8))
                let beats = (0..<count).compactMap { i -> Beat? in
                    let entry = start + i * 8
                    guard entry + 8 <= end else { return nil }
                    return Beat(number: u16(entry), bpm: Double(u16(entry + 2)) / 100, time: Double(u32(entry + 4)) / 1000)
                }
                return BeatGrid(beats: beats)
            }
            offset += tagLength
        }
        return BeatGrid(beats: [])
    }
}

/// `~/Library/Pioneer/rekordbox/share` 아래 rekordbox 부속 파일(아트워크·ANLZ) 경로.
public enum RekordboxShare {
    public static var directory: URL {
        LibrarySnapshot.rekordboxDirectory.appending(path: "share")
    }

    public enum ArtworkSize: String, Sendable {
        case small = "_s", medium = "_m", full = ""
    }

    /// `ImagePath`는 `/PIONEER/Artwork/…/artwork.jpg` 형태. 크기별로 `_s`·`_m` 파일이 옆에 있다.
    public static func artworkURL(_ imagePath: String?, size: ArtworkSize, root: URL? = nil) -> URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        let base = (root ?? directory).appending(path: String(imagePath.drop(while: { $0 == "/" })))
        guard size != .full else { return base }
        let sized = base.deletingPathExtension().path + size.rawValue + "." + base.pathExtension
        return URL(filePath: sized)
    }

    /// rekordbox 파형 분석 파일(.EXT)이 있는지. 없으면 rekordbox에서 트랙 분석이 끝나지 않은 곡이다.
    /// `root`는 share 뿌리(nil이면 기본 rekordbox 폴더)
    public static func hasWaveformAnalysis(_ analysisDataPath: String?, root: URL? = nil) -> Bool {
        guard let dat = analysisURL(analysisDataPath, root: root) else { return false }
        return FileManager.default.fileExists(atPath: dat.deletingPathExtension().appendingPathExtension("EXT").path)
    }

    public static func analysisURL(_ analysisDataPath: String?, root: URL? = nil) -> URL? {
        guard let path = analysisDataPath, !path.isEmpty else { return nil }
        return (root ?? directory).appending(path: String(path.drop(while: { $0 == "/" })))
    }
}
