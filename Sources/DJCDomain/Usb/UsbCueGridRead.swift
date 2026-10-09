import Foundation

/// USB 분석 파일 한 곡에서 읽은, 로컬 초안으로 옮길 수 있는 큐·박(`UsbCueGridReader.read`). 큐 실패와 그리드 실패는 서로 막지 않는다
public struct UsbCueGridRead: Sendable, Equatable {
    public var cues: [EditableCue]?
    public var grid: BeatGrid?
    public var usesLegacyCues: Bool
    public var cueIssue: String?
    public var gridIssue: String?

    public init(cues: [EditableCue]?, grid: BeatGrid?, usesLegacyCues: Bool, cueIssue: String?, gridIssue: String?) {
        self.cues = cues
        self.grid = grid
        self.usesLegacyCues = usesLegacyCues
        self.cueIssue = cueIssue
        self.gridIssue = gridIssue
    }
}

/// 큐·그리드 가져오기를 그 곡에서 멈춘 이유(무엇을 하면 되는지까지 적은 한 문장)
public struct UsbCueGridReadFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}
