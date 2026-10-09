import Foundation

/// Device Library 읽기 보고서. 이름·경로 같은 글자 값은 넣지 않는다.
public struct PdbReadReport: Sendable {
    public var exportHeader: PdbFileHeader
    public var extHeader: PdbFileHeader?
    /// 표 이름("tracks", "exportExt.tags" 등) → 산 행/자리
    public var tableCounts: [String: (live: Int, slots: Int)]
    public var unknownRows: [UsbUnknownRows]
    /// 멈추지 않고 모은 구조 문제(`issueDetails`의 글자 모양)
    public var issues: [String]
    /// 문자열 모양별 개수(산 행만)
    public var stringKinds: [String: Int]
    public var issueDetails: [PdbIssue]
    /// 표 이름 → 사슬 쪽 수(인덱스 쪽 포함)
    public var pageCounts: [String: Int]
    /// 가장 긴 짧은 ASCII 글자 수
    public var longestShortASCII: Int
    /// 행 시작 기준 4바이트 경계에 있지 않은 UTF-16 문자열 수
    public var misalignedUTF16: Int
    /// 표 이름 → 먼 오프셋 모양(0x0064·0x0084·0x0684)으로 읽은 산 행 수. 왕복 검사가 다시 쓴 파일의 수와 비교한다
    public var farShapeRows: [String: Int]

    package init(exportHeader: PdbFileHeader, extHeader: PdbFileHeader?, tableCounts: [String: (live: Int, slots: Int)],
                 unknownRows: [UsbUnknownRows], issues: [String], stringKinds: [String: Int], issueDetails: [PdbIssue],
                 pageCounts: [String: Int], longestShortASCII: Int, misalignedUTF16: Int, farShapeRows: [String: Int]) {
        self.exportHeader = exportHeader
        self.extHeader = extHeader
        self.tableCounts = tableCounts
        self.unknownRows = unknownRows
        self.issues = issues
        self.stringKinds = stringKinds
        self.issueDetails = issueDetails
        self.pageCounts = pageCounts
        self.longestShortASCII = longestShortASCII
        self.misalignedUTF16 = misalignedUTF16
        self.farShapeRows = farShapeRows
    }
}

/// 파일 머리(쪽 0)
public struct PdbFileHeader: Sendable, Hashable {
    public var pageSize: UInt32
    public var numTables: UInt32
    /// 할당된 가장 큰 쪽 번호 + 1(파일 끝 너머 후보 포함)
    public var nextUnusedPage: UInt32
    /// 0x10. rekordbox가 정상으로 닫으면 5
    public var flag10: UInt32
    /// 다음 쪽 순번(모든 쪽 순번보다 큼)
    public var sequence: UInt32
    public var gap: UInt32
    public var tables: [PdbTablePointer]

    package init(pageSize: UInt32, numTables: UInt32, nextUnusedPage: UInt32, flag10: UInt32, sequence: UInt32, gap: UInt32,
                 tables: [PdbTablePointer]) {
        self.pageSize = pageSize
        self.numTables = numTables
        self.nextUnusedPage = nextUnusedPage
        self.flag10 = flag10
        self.sequence = sequence
        self.gap = gap
        self.tables = tables
    }
}

/// 표 포인터 `{type, empty_candidate, first_page, last_page}`
public struct PdbTablePointer: Sendable, Hashable {
    public var type: UInt32
    /// 사슬 마지막 쪽의 다음 쪽. 0으로 채운 쪽이거나 파일 끝 너머
    public var emptyCandidate: UInt32
    /// 인덱스 쪽
    public var firstPage: UInt32
    /// 사슬 마지막 쪽(데이터가 없으면 인덱스 쪽)
    public var lastPage: UInt32

    package init(type: UInt32, emptyCandidate: UInt32, firstPage: UInt32, lastPage: UInt32) {
        self.type = type
        self.emptyCandidate = emptyCandidate
        self.firstPage = firstPage
        self.lastPage = lastPage
    }
}

/// 멈추지 않고 모은 구조 문제. 값(이름·경로)은 넣지 않고 종류·표·쪽·자리만 둔다.
public struct PdbIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// 쪽 머리의 쪽 번호가 파일 안 위치와 다름
        case pageIndexMismatch
        /// 사슬이 파일 밖 쪽을 가리킴
        case pageOutsideFile
        /// 사슬이 이미 지난 쪽으로 돌아옴
        case cycle
        /// 사슬의 쪽이 다른 표의 쪽
        case pageTypeMismatch
        /// 사슬이 표 포인터의 last_page에서 끝나지 않음
        case lastPageMismatch
        /// 쪽 머리·행 인덱스를 읽을 수 없음
        case pageUnreadable
        /// 표 포인터가 type 0부터 오름차순이 아님
        case tableOrder
        /// 행 오프셋이 힙 밖
        case rowOutsideHeap
        /// 산 행끼리 같은 자리를 가리킴
        case rowOverlap
        /// 쪽 머리 산 행 수 ≠ presence 비트 수
        case liveCountMismatch
        /// 산 행을 해석할 수 없음(짧은 행·모르는 문자열 등)
        case rowUnreadable
        /// 같은 id 산 행이 둘 이상
        case duplicateID
        /// 한 행이어야 할 표에 산 행이 여럿
        case multipleRows
        /// 확인 안 된 행 모양(먼 오프셋 My Tag 행). 쓰기·편집이 막히도록 문제로 남긴다
        case unconfirmedRowShape
        /// 목록 항목이 없는 목록을 가리킴
        case orphanEntry
    }

    public var kind: Kind
    public var table: String
    public var page: Int?
    public var slot: Int?

    public init(kind: Kind, table: String, page: Int? = nil, slot: Int? = nil) {
        self.kind = kind
        self.table = table
        self.page = page
        self.slot = slot
    }

    public var description: String {
        "\(kind.rawValue) \(table)" + (page.map { " page \($0)" } ?? "") + (slot.map { " slot \($0)" } ?? "")
    }
}
