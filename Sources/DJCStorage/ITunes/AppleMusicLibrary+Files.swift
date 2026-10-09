import DJCDomain
import Foundation

extension AppleMusicLibrary {
    /// 이 Mac에서 읽을 수 있는 보통 파일인지
    public static func isReadableFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// 이 Mac의 파일로 확인하며 XML을 읽는다
    public static func parse(_ data: Data) throws -> Self { try parse(data, isReadableFile: isReadableFile) }
}
