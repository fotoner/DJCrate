import DJCApplication
import DJCDomain
import Foundation

extension UsbProgress.Phase {
    /// 진행 덮개에 보일 단계 이름
    var displayName: String {
        switch self {
        case .planning: String(ui: "계획")
        case .staging: String(ui: "준비(분석 파일·앨범아트·DB)")
        case .backup: String(ui: "백업")
        case .files: String(ui: "파일 쓰기")
        case .commit: String(ui: "DB 교체")
        case .cleanup: String(ui: "정리")
        case .verify: String(ui: "검증")
        case .restore: String(ui: "되돌리기")
        case .recover: String(ui: "회복")
        }
    }
}

/// 쓰는 동안 덮개에 보일 것(순수)
struct UsbWriteProgressModel: Equatable {
    var title: String
    var volumeName: String
    var phase: String?
    /// "3/12"
    var items: String?
    var bytes: String?
    var fraction: Double?
    /// DB 교체가 시작되면(`cancellable == false`) 숨긴다
    var showsCancel: Bool

    init(_ write: UsbActiveWrite) {
        title = write.title
        volumeName = write.volumeName
        guard let progress = write.progress else {
            phase = nil
            items = nil
            bytes = nil
            fraction = nil
            showsCancel = write.cancellable
            return
        }
        phase = progress.phase.displayName
        items = progress.totalItems > 0 ? "\(progress.completedItems)/\(progress.totalItems)" : nil
        if progress.totalBytes > 0 {
            let format = ByteCountFormatStyle(style: .file)
            bytes = "\(progress.completedBytes.formatted(format)) / \(progress.totalBytes.formatted(format))"
            fraction = min(1, Double(progress.completedBytes) / Double(progress.totalBytes))
        } else {
            bytes = nil
            fraction = progress.totalItems > 0 ? min(1, Double(progress.completedItems) / Double(progress.totalItems)) : nil
        }
        showsCancel = write.cancellable && progress.cancellable
    }
}
