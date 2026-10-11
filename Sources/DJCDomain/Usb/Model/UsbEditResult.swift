import Foundation

/// USB 편집 하나의 결과
public enum UsbOutcome: Codable, Sendable, Hashable {
    case written
    /// 바꿀 것이 없었다(이미 같음·기기에서 고친 곡이라 건너뜀)
    case unchanged
    /// 이 편집만 빼고 나머지를 썼다
    case blocked(UsbBlock)
    /// 라이브러리는 고쳤지만 파일 지우기를 미뤘다(이유)
    case deferred(String)

    /// CLI·보고용 영어 고정 이름
    public var name: String {
        switch self {
        case .written: "written"
        case .unchanged: "unchanged"
        case .blocked: "blocked"
        case .deferred: "deferred"
        }
    }
}

/// USB 수정 계획 결과. `changes`가 있으면 `UsbWriter.write`로 쓴다
public struct UsbEditResult: Sendable {
    /// nil = 쓸 것 없음(모두 막혔거나 바뀐 것이 없음)
    public var changes: UsbChangeSet?
    /// 편집 번호(1부터, 적힌 순서) → 결과
    public var outcomes: [(edit: Int, outcome: UsbOutcome)]
    public var formatsWritten: Set<UsbFormat>
    /// 그 형식만 고치지 않는다(다른 형식은 쓴다)
    public var formatsBlocked: [UsbFormat: UsbBlock]
    public var mismatches: [UsbFormatMismatch]
    /// "형식 사이 목록 불일치 N", "남은 -wal을 사본에서 합쳤습니다" 등
    public var notes: [String]
    /// 쓰기를 멈추는 막힘(USB 전체·볼륨). 하나라도 있으면 `changes`는 nil
    public var blocks: [UsbBlock]
    /// 곡 단위로 빼고 쓴 막힘(곡 더하기에서 막힌 곡 등)
    public var trackBlocks: [UsbBlock]
    /// 막지 않는 알림(분석 파일 변환 경고 등)
    public var warnings: [UsbBlock]
    /// 편집을 적용한 두 형식 모델(OneLibrary 검증 기대값)
    public var applied: UsbLibrary?
    /// 이번 묶음에서 만들고 적용 결과에 남은 목록(key → USB ID). 남은 초안의 new 참조를 이어 받을 때 쓴다
    public var createdPlaylistIDs: [String: Int] = [:]
    /// Device Library 작성기가 쓴 모델(pdb 검증 기대값). Device Library를 쓰지 않으면 nil
    public var pdbWritten: UsbLibrary?
    /// 로컬 사본을 뜬 시각과 그 출처(곡 더하기·갱신이 있을 때만)
    public var snapshotTakenAt: Date?
    public var snapshotSource: UsbSnapshotTimeSource?
    /// 쓰기 전 USB에 이미 있던 불변식 문제(계획 때 USB DB 사본과 USB 파일로 본다). 검증은 이것을 빼고 새로 생긴 문제만 센다
    public var preexistingProblems: Set<String> = []
    /// 더한 곡 중 파일 크기 칸(로컬 FileSize)이 복사한 음원과 다른 곡(USB content id). 불변식 검증이 크기 비교를 뺀다
    public var audioSizeFromDatabase: Set<Int> = []

    public init(changes: UsbChangeSet? = nil, outcomes: [(edit: Int, outcome: UsbOutcome)] = [], formatsWritten: Set<UsbFormat> = [],
                formatsBlocked: [UsbFormat: UsbBlock] = [:], mismatches: [UsbFormatMismatch] = [], notes: [String] = [],
                blocks: [UsbBlock] = [], trackBlocks: [UsbBlock] = [], warnings: [UsbBlock] = [], applied: UsbLibrary? = nil,
                pdbWritten: UsbLibrary? = nil) {
        self.changes = changes
        self.outcomes = outcomes
        self.formatsWritten = formatsWritten
        self.formatsBlocked = formatsBlocked
        self.mismatches = mismatches
        self.notes = notes
        self.blocks = blocks
        self.trackBlocks = trackBlocks
        self.warnings = warnings
        self.applied = applied
        self.pdbWritten = pdbWritten
    }

    /// 편집 번호(1부터)의 결과
    public func outcome(_ edit: Int) -> UsbOutcome? {
        outcomes.first { $0.edit == edit }?.outcome
    }
}
