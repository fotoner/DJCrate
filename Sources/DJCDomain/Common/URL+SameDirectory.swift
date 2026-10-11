import Foundation

extension URL {
    /// URL의 디렉터리 힌트(`/`)가 달라도 같은 파일시스템 폴더면 같은 출처다(파일 시스템은 보지 않는다).
    public func isSameDirectory(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}
