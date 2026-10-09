import Foundation

/// 시험 하나가 쓰는 임시 폴더. 값이 사라질 때 폴더째 지운다.
/// 합성 음원·캐시처럼 rekordbox DB가 필요 없는 시험이 `RekordboxFixture`를 임시 폴더로만 쓰지 않게 한다.
public final class TemporaryFolder {
    public let url: URL

    public init(prefix: String = "djc-test") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
