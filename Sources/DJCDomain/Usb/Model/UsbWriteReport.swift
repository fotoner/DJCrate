import Foundation

/// USB 쓰기·회복·되돌리기 결과. 끝난 쓰기는 백업 폴더에 `report.json`으로 남는다
public struct UsbWriteReport: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case dryRun, written, rolledBack, restoreFailed, restorePending, recovered, restored, needsReplan
    }

    public var outcome: Outcome
    public var session: String
    /// 백업 폴더(없으면 nil)
    public var backup: String?
    /// 상대 경로 → 결과 SHA-256. `usb-restore`가 지금 USB와 비교해 그 뒤 바뀌었는지 본다
    public var resultDatabases: [String: String]
    public var filesCreated: Int
    public var filesReused: Int
    public var filesOverwritten: Int
    public var filesRemoved: Int
    public var appleDoubleRemoved: Int
    public var blocks: [UsbBlock]
    public var notes: [String]

    public init(outcome: Outcome, session: String, backup: String? = nil, resultDatabases: [String: String] = [:], filesCreated: Int = 0,
                filesReused: Int = 0, filesOverwritten: Int = 0, filesRemoved: Int = 0, appleDoubleRemoved: Int = 0,
                blocks: [UsbBlock] = [], notes: [String] = []) {
        self.outcome = outcome
        self.session = session
        self.backup = backup
        self.resultDatabases = resultDatabases
        self.filesCreated = filesCreated
        self.filesReused = filesReused
        self.filesOverwritten = filesOverwritten
        self.filesRemoved = filesRemoved
        self.appleDoubleRemoved = appleDoubleRemoved
        self.blocks = blocks
        self.notes = notes
    }
}
