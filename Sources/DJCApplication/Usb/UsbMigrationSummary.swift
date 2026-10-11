import DJCDomain
import Foundation

/// 옮기기 미리 보기·쓰기 요약. 세션의 계획에서 수·막힘·규칙만 받아 곡 제목이나 경로는 담지 않는다.
public struct UsbMigrationSummary: Equatable, Sendable {
    public var trackCount: Int
    public var playlistCount: Int
    public var artworkFiles: Int
    public var blocks: [UsbBlock]
    /// CDJ에서 확인하지 않은 항목(이름 순). 쓰기를 막지 않고 알리기만 한다
    public var rules: [UsbProvisionalRule]
    public var notes: [String]
    public var hasChanges: Bool
    public var isTestVolume: Bool

    public init(trackCount: Int, playlistCount: Int, artworkFiles: Int, blocks: [UsbBlock], rules: [UsbProvisionalRule], notes: [String],
                hasChanges: Bool, isTestVolume: Bool) {
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        self.artworkFiles = artworkFiles
        self.blocks = blocks
        self.rules = rules
        self.notes = notes
        self.hasChanges = hasChanges
        self.isTestVolume = isTestVolume
    }

    public var canWrite: Bool { blocks.isEmpty && hasChanges && trackCount > 0 }
    public var stopping: String {
        var seen: Set<String> = []
        return blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

extension UsbMigrationSummary {
    public init(result: UsbMigrationResult, volume: UsbVolumeInfo) {
        self.init(trackCount: result.trackCount, playlistCount: result.playlistCount, artworkFiles: result.artworkFiles,
                  blocks: result.blocks, rules: UsbProvisionalRule.deviceCheckRules(result.changes?.requiredRules ?? []),
                  notes: result.notes, hasChanges: result.changes != nil, isTestVolume: volume.isDiskImage)
    }
}

public struct UsbMigrationWritten: Sendable {
    public var summary: UsbMigrationSummary
    public var report: UsbWriteReport?

    public init(summary: UsbMigrationSummary, report: UsbWriteReport?) {
        self.summary = summary
        self.report = report
    }
}
