import DJCDomain
import Foundation

extension LibraryReport {
    /// - Parameter checkFiles: 스트리밍이 아닌 곡의 음원 파일이 있는지 이 Mac에서 확인한다(CLI `report --files`)
    public init(library: RekordboxLibrary, checkFiles: Bool, commentRule: (any CommentRule)? = nil) {
        self.init(library: library, fileExists: checkFiles ? { FileManager.default.fileExists(atPath: $0) } : nil, commentRule: commentRule)
    }
}
