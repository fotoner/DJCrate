import DJCDomain
import Foundation

/// 수정 미리 보기·쓰기 요약(확인 창·쓰기 대기 목록이 보인다). 곡 제목·경로는 담지 않는다
public struct UsbEditSummary: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case written, unchanged
        case blocked(String)
        /// 라이브러리는 고치고 파일 지우기를 미뤘다(이유)
        case deferred(String)
    }

    /// 형식 하나의 결과
    public struct FormatResult: Equatable, Sendable {
        public var format: UsbFormat
        public var written: Bool
        /// 그 형식을 고치지 않는 이유
        public var blocked: String?

        public init(format: UsbFormat, written: Bool, blocked: String? = nil) {
            self.format = format
            self.written = written
            self.blocked = blocked
        }
    }

    /// 같은 이유로 빼고 쓰는 곡 수(같은 곡은 한 번)
    public struct Count: Equatable, Sendable {
        public var message: String
        public var count: Int

        public init(message: String, count: Int) {
            self.message = message
            self.count = count
        }
    }

    /// 초안 편집 수
    public var editCount: Int
    /// 편집 번호(1부터) → 결과
    public var outcomes: [Int: Outcome]
    /// 쓰기를 멈추는 막힘(USB 전체·볼륨)의 문구
    public var stopping: [String]
    public var skipped: [Count]
    public var formats: [FormatResult]
    /// USB에서 지울 파일 수
    public var removals: Int
    /// 파일 지우기를 미룬 이유
    public var deferred: [String]
    public var notes: [String]
    public var warnings: [String]
    /// CDJ에서 확인하지 않은 항목(`UsbProvisionalRule.needsDeviceCheck`, 이름 순). 쓰기를 막지 않고 알리기만 한다
    public var rules: [UsbProvisionalRule]
    /// 준비한 변경 묶음이 있는지
    public var hasChanges: Bool
    public var isTestVolume: Bool
    /// 한 형식이 막힌 채 곡을 더하거나 빼 두 형식의 곡이 달라진다(다음부터 이 USB 편집이 막힌다)
    public var formatDrift: Bool
    /// 이 요약이 계획한 초안 편집(적힌 순서). 쓰기 직전 초안이 이것과 다르면 확인 창에 없던 편집을 쓰지 않게 다시 미리 본다
    public var edits: [UsbLibraryEdit]

    public init(editCount: Int, outcomes: [Int: Outcome], stopping: [String], skipped: [Count], formats: [FormatResult], removals: Int,
         deferred: [String], notes: [String], warnings: [String], rules: [UsbProvisionalRule], hasChanges: Bool, isTestVolume: Bool,
         formatDrift: Bool, edits: [UsbLibraryEdit] = []) {
        self.editCount = editCount
        self.outcomes = outcomes
        self.stopping = stopping
        self.skipped = skipped
        self.formats = formats
        self.removals = removals
        self.deferred = deferred
        self.notes = notes
        self.warnings = warnings
        self.rules = rules
        self.hasChanges = hasChanges
        self.isTestVolume = isTestVolume
        self.formatDrift = formatDrift
        self.edits = edits
    }

    public init(result: UsbEditResult, edits: [UsbLibraryEdit], volume: UsbVolumeInfo) {
        var outcomes: [Int: Outcome] = [:]
        var deferred: [String] = []
        for (edit, outcome) in result.outcomes {
            switch outcome {
            case .written: outcomes[edit] = .written
            case .unchanged: outcomes[edit] = .unchanged
            case let .blocked(block): outcomes[edit] = .blocked(block.message)
            case let .deferred(reason):
                outcomes[edit] = .deferred(reason)
                if !deferred.contains(reason) { deferred.append(reason) }
            }
        }
        var order: [String] = [], tracks: [String: Set<UsbBlock.Scope>] = [:]
        for block in result.trackBlocks {
            if tracks[block.message] == nil { order.append(block.message) }
            tracks[block.message, default: []].insert(block.scope)
        }
        let tracksChanged = result.outcomes.contains { entry in
            guard edits.indices.contains(entry.edit - 1) else { return false }
            switch entry.outcome {
            case .written, .deferred: break
            case .unchanged, .blocked: return false
            }
            switch edits[entry.edit - 1] {
            case .addTracks, .removeTracks: return true
            case .refreshTracks, .playlist, .syncPlaylist, .syncSelection: return false
            }
        }
        self.init(editCount: edits.count, outcomes: outcomes, stopping: Self.unique(result.blocks.map(\.message)),
                  skipped: order.map { Count(message: $0, count: tracks[$0]?.count ?? 0) },
                  formats: UsbFormat.allCases.compactMap { format in
                      if let block = result.formatsBlocked[format] { return FormatResult(format: format, written: false, blocked: block.message) }
                      return result.formatsWritten.contains(format) ? FormatResult(format: format, written: true, blocked: nil) : nil
                  },
                  removals: result.changes?.removals.count ?? 0, deferred: deferred, notes: Self.grouped(result.notes),
                  warnings: Self.unique(result.warnings.map(\.message)),
                  rules: UsbProvisionalRule.deviceCheckRules(result.changes?.requiredRules ?? []), hasChanges: result.changes != nil,
                  isTestVolume: volume.isDiskImage, formatDrift: !result.formatsBlocked.isEmpty && tracksChanged, edits: edits)
    }

    /// 이 USB에 초안이 없다
    public static func noDraft(isTestVolume: Bool) -> UsbEditSummary {
        UsbEditSummary(editCount: 0, outcomes: [:], stopping: [String(ui: "이 USB에 쌓인 초안이 없습니다. 편집을 먼저 더하세요")], skipped: [],
                       formats: [], removals: 0, deferred: [], notes: [], warnings: [], rules: [], hasChanges: false,
                       isTestVolume: isTestVolume, formatDrift: false)
    }

    /// 쓸 편집(파일 지우기를 미룬 것 포함)
    public var writtenCount: Int {
        outcomes.values.filter { if case .written = $0 { true } else if case .deferred = $0 { true } else { false } }.count
    }
    public var blockedCount: Int { outcomes.values.filter { if case .blocked = $0 { true } else { false } }.count }
    public var unchangedCount: Int { outcomes.values.filter { $0 == .unchanged }.count }
    public var skippedTrackCount: Int { skipped.reduce(0) { $0 + $1.count } }
    public var canWrite: Bool { stopping.isEmpty && hasChanges }

    public static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// 끝에 USB 상대 경로가 붙은 알림은 같은 이유끼리 수로만 적는다(`djc usb-edit` 요약과 같다)
    public static func grouped(_ notes: [String]) -> [String] {
        var lines: [String] = [], counts: [(head: String, count: Int)] = []
        for note in unique(notes) {
            guard let range = note.range(of: ": "),
                  ["contents/", "pioneer/"].contains(where: { note[range.upperBound...].lowercased().hasPrefix($0) }) else {
                lines.append(note)
                continue
            }
            let head = String(note[..<range.lowerBound])
            if let index = counts.firstIndex(where: { $0.head == head }) { counts[index].count += 1 } else { counts.append((head, 1)) }
        }
        return lines + counts.map { String(ui: "\($0.head) (\($0.count)개)") }
    }
}

/// 수정 쓰기 결과: 요약과 쓰기 보고서(쓸 것이 없었으면 nil)
public struct UsbEditWritten: Sendable {
    public var summary: UsbEditSummary
    public var report: UsbWriteReport?

    public init(summary: UsbEditSummary, report: UsbWriteReport?) {
        self.summary = summary
        self.report = report
    }
}
