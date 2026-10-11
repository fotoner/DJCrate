import DJCDomain
import Foundation

/// 쪽 하나에 행을 담은 모양(쪽 머리 0x20·0x22와 행 인덱스 tx 비트)
enum PdbPageShape: Sendable, Hashable {
    /// 한 번에 씀: 0x20 = 자리 수, 0x22 = 0, tx 비트 = presence 비트
    case bulk
    /// 한 행씩 덧붙임: 0x20 = 1, 0x22 = 마지막 자리, tx 비트는 마지막 자리만
    case append
}

/// rekordbox가 새로 내보낸 파일의 쪽 배치(쪽 번호·사슬·순번)와 쪽 바이트.
/// 표마다 인덱스 쪽(2t+1)과 빈 후보(2t+2)를 먼저 잡고, 정해진 순서로 표를 넣으며 후보를 데이터 쪽으로 쓰는 순간 새 후보를 잡는다.
/// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
struct PdbLayout {
    struct DataPage: Sendable {
        var number: Int
        var rows: [PdbEncodedRow] = []
        /// 힙 바이트 합(행 할당 크기의 합)
        var used = 0
    }

    let kind: PdbFileKind
    /// 표 번호 → 인덱스 쪽
    let indexPages: [Int]
    /// 표 번호 → 빈 후보(사슬 마지막 쪽의 next)
    private(set) var candidates: [Int]
    /// 표 번호 → 데이터 쪽(사슬 순서). 빈 표는 없다
    private(set) var dataPages: [Int: [DataPage]] = [:]
    /// 할당한 가장 큰 쪽 번호 + 1(파일 끝 너머 후보 포함)
    private(set) var nextUnused: Int

    /// 표를 넣는 순서(여기 없는 표는 늘 비어 있다)
    static func insertOrder(_ kind: PdbFileKind) -> [Int] {
        switch kind {
        case .export: [19, 6, 16, 17, 18, 7, 2, 1, 3, 4, 5, 0, 13, 8, 11, 12]
        case .exportExt: [7, 3, 4]
        }
    }

    /// 한 번에 쓰는 표(나머지는 한 행씩 덧붙인 모양)
    static func bulkTables(_ kind: PdbFileKind) -> Set<Int> {
        switch kind {
        case .export: [6, 16, 17, 18]
        case .exportExt: [7, 3]
        }
    }

    /// 데이터 쪽에 순번을 주는 표 순서와 첫 순번(인덱스 쪽은 모두 1).
    /// export는 한 번에 쓰는 표 다음 나머지를 쪽을 닫는 순서대로, 표 19는 마지막(곡 수를 끝에 고친다).
    static func sequenceOrder(_ kind: PdbFileKind) -> (first: UInt32, tables: [Int]) {
        switch kind {
        case .export:
            let bulk = [6, 16, 17, 18]
            return (2, bulk + insertOrder(kind).filter { $0 != 19 && !bulk.contains($0) } + [19])
        case .exportExt:
            return (1, [7, 3, 4])
        }
    }

    static func shape(_ kind: PdbFileKind, _ type: Int) -> PdbPageShape {
        bulkTables(kind).contains(type) ? .bulk : .append
    }

    /// 쪽 머리 0x20·0x22: 한 번에 씀은 (자리 수, 0), 덧붙임은 (1, 마지막 자리). 행 하나인 쪽은 둘 다 (1, 0)
    static func transactionFields(_ shape: PdbPageShape, slots: Int) -> (count: UInt16, index: UInt16) {
        switch shape {
        case .bulk: (UInt16(slots), 0)
        case .append: (1, UInt16(max(slots - 1, 0)))
        }
    }

    /// 쪽에 행 하나가 더 들어가는지: used + L + 행 인덱스(nro + 1) ≤ 4056
    static func fits(_ page: DataPage, _ row: PdbEncodedRow) -> Bool {
        page.used + row.bytes.count + PdbPage.indexSize(slots: page.rows.count + 1) <= PdbRowSize.pageCapacity
    }

    /// 행이 모두 빈 쪽 하나에 들어가는지: 행 크기 합 + 행 인덱스 ≤ 4056(`dataPage`를 부르기 전에 확인한다)
    static func fitsOnePage(_ rows: [PdbEncodedRow]) -> Bool {
        rows.reduce(0) { $0 + $1.bytes.count } + PdbPage.indexSize(slots: rows.count) <= PdbRowSize.pageCapacity
    }

    /// `rows`: 표 번호 → 행(쪽 안 자리 순서). 행은 모두 빈 쪽 하나에 들어가야 한다.
    init(kind: PdbFileKind, rows: [Int: [PdbEncodedRow]]) {
        precondition(rows.allSatisfy { $0.value.isEmpty || Self.insertOrder(kind).contains($0.key) }, "넣는 순서에 없는 표")
        self.kind = kind
        var next = 1
        var index: [Int] = [], candidates: [Int] = []
        for _ in 0..<kind.tableCount {
            index.append(next)
            candidates.append(next + 1)
            next += 2
        }
        for type in Self.insertOrder(kind) {
            guard let tableRows = rows[type], !tableRows.isEmpty else { continue }
            // 후보를 데이터 쪽으로 쓰는 순간 새 후보를 잡는다
            var current = DataPage(number: candidates[type])
            candidates[type] = next
            next += 1
            var pages: [DataPage] = []
            for row in tableRows {
                precondition(PdbRowSize.fitsEmptyPage(rowSize: row.bytes.count), "빈 쪽에도 들어가지 않는 행")
                if !current.rows.isEmpty, !Self.fits(current, row) {
                    pages.append(current)
                    current = DataPage(number: candidates[type])
                    candidates[type] = next
                    next += 1
                }
                current.rows.append(row)
                current.used += row.bytes.count
            }
            pages.append(current)
            dataPages[type] = pages
        }
        indexPages = index
        self.candidates = candidates
        nextUnused = next
    }

    /// 파일 쪽 수: 후보가 아닌 쪽 중 가장 큰 번호 + 1. 그보다 큰 후보는 파일 끝 너머라 쓰지 않는다
    var pageCount: Int {
        let data = dataPages.values.flatMap { $0.map(\.number) }
        return ((indexPages + data).max() ?? 0) + 1
    }

    /// 쪽 번호 → 상대 순번(인덱스 쪽 1, 데이터 쪽은 `sequenceOrder`)
    func relativeSequences() -> [Int: UInt32] {
        var result: [Int: UInt32] = [:]
        for page in indexPages { result[page] = 1 }
        let (first, order) = Self.sequenceOrder(kind)
        var next = first
        for type in order {
            for page in dataPages[type] ?? [] {
                result[page.number] = next
                next += 1
            }
        }
        return result
    }

    /// 머리 순번(`base` + 가장 큰 상대 순번 + 1)이 u32에 들어가는지. 옛 머리 순번은 USB 파일에서 읽은 값이라 끝에 가까울 수 있다
    func sequenceFits(base: UInt32) -> Bool {
        UInt64(base) + UInt64(relativeSequences().values.max() ?? 0) + 1 <= UInt64(UInt32.max)
    }

    /// 파일 바이트. 모든 쪽 순번 = `sequenceBase` + 상대 순번, 머리 순번 = 가장 큰 쪽 순번 + 1.
    /// 부르는 쪽이 `sequenceFits`로 먼저 확인한다
    func data(sequenceBase: UInt32) -> Data {
        precondition(sequenceFits(base: sequenceBase), "쪽 순번이 u32를 넘는다")
        let relative = relativeSequences()
        var file = Data(count: pageCount * PdbPage.size)
        func place(_ page: Data, _ number: Int) {
            file.replaceSubrange((number * PdbPage.size)..<((number + 1) * PdbPage.size), with: page)
        }
        var pointers: [PdbTablePointer] = []
        for type in 0..<kind.tableCount {
            let pages = dataPages[type] ?? []
            let index = indexPages[type], candidate = candidates[type]
            place(Self.indexPage(number: UInt32(index), type: UInt32(type), next: UInt32(pages.first?.number ?? candidate),
                                 firstData: pages.first.map { UInt32($0.number) }, sequence: sequenceBase + relative[index, default: 1]),
                  index)
            for (position, page) in pages.enumerated() {
                let next = position + 1 < pages.count ? pages[position + 1].number : candidate
                place(Self.dataPage(number: UInt32(page.number), type: UInt32(type), next: UInt32(next),
                                    sequence: sequenceBase + relative[page.number, default: 1], rows: page.rows, shape: Self.shape(kind, type)),
                      page.number)
            }
            pointers.append(PdbTablePointer(type: UInt32(type), emptyCandidate: UInt32(candidate), firstPage: UInt32(index),
                                            lastPage: UInt32(pages.last?.number ?? index)))
        }
        let sequence = sequenceBase + (relative.values.max() ?? 0) + 1
        place(Self.headerPage(nextUnused: UInt32(nextUnused), sequence: sequence, pointers: pointers), 0)
        return file
    }

    // MARK: - 쪽 바이트

    /// 첫 인덱스 쪽 본문 뒤를 채우는 빈 항목 수
    static let indexEntryCount = 1004
    static let noPage: UInt32 = 0x03FF_FFFF
    static let emptyIndexEntry: UInt32 = 0x1FFF_FFF8

    /// 파일 머리(쪽 0): 0, 4096, 표 수, next_unused, 5, 머리 순번, 0, 표 포인터
    static func headerPage(nextUnused: UInt32, sequence: UInt32, pointers: [PdbTablePointer]) -> Data {
        var page = PdbPageBytes()
        page.u32(UInt32(PdbPage.size), at: 0x04)
        page.u32(UInt32(pointers.count), at: 0x08)
        page.u32(nextUnused, at: 0x0C)
        // rekordbox가 정상으로 닫은 파일과 같게
        page.u32(5, at: 0x10)
        page.u32(sequence, at: 0x14)
        for (position, pointer) in pointers.enumerated() {
            let at = 0x1C + 16 * position
            page.u32(pointer.type, at: at)
            page.u32(pointer.emptyCandidate, at: at + 4)
            page.u32(pointer.firstPage, at: at + 8)
            page.u32(pointer.lastPage, at: at + 12)
        }
        return page.data
    }

    /// 인덱스 쪽: flags 0x64, 0x20·0x22 = 0x1FFF, 0x24 = 0x03EC. 본문은 지운 행이 있는 쪽이 없는 모양
    static func indexPage(number: UInt32, type: UInt32, next: UInt32, firstData: UInt32?, sequence: UInt32) -> Data {
        var page = PdbPageBytes()
        page.u32(number, at: 0x04)
        page.u32(type, at: 0x08)
        page.u32(next, at: 0x0C)
        page.u32(sequence, at: 0x10)
        page.u8(0x64, at: 0x1B)
        page.u16(0x1FFF, at: 0x20)
        page.u16(0x1FFF, at: 0x22)
        page.u16(0x03EC, at: 0x24)
        page.u32(number, at: 0x28)
        page.u32(firstData ?? noPage, at: 0x2C)
        page.u32(noPage, at: 0x30)
        page.u16(0x1FFF, at: 0x3A)
        for entry in 0..<indexEntryCount { page.u32(emptyIndexEntry, at: 0x3C + 4 * entry) }
        return page.data
    }

    /// 데이터 쪽: flags 0x24, 행 수 묶음 nro + (nr << 13), free·used, 모양대로 0x20·0x22, 힙과 쪽 끝의 행 인덱스.
    /// 행은 한 쪽에 들어가야 한다(`fitsOnePage`)
    static func dataPage(number: UInt32, type: UInt32, next: UInt32, sequence: UInt32, rows: [PdbEncodedRow], shape: PdbPageShape) -> Data {
        precondition(fitsOnePage(rows), "한 쪽에 들어가지 않는 행")
        var page = PdbPageBytes()
        let count = rows.count, used = rows.reduce(0) { $0 + $1.bytes.count }
        page.u32(number, at: 0x04)
        page.u32(type, at: 0x08)
        page.u32(next, at: 0x0C)
        page.u32(sequence, at: 0x10)
        page.data.replaceSubrange(0x18..<0x1B, with: PdbPage.packRowCounts(slots: count, live: count))
        page.u8(0x24, at: 0x1B)
        page.u16(UInt16(PdbPage.freeSize(used: used, slots: count)), at: 0x1C)
        page.u16(UInt16(used), at: 0x1E)
        let transaction = transactionFields(shape, slots: count)
        page.u16(transaction.count, at: 0x20)
        page.u16(transaction.index, at: 0x22)
        var offsets: [Int] = [], heap = 0
        for (slot, row) in rows.enumerated() {
            var bytes = row.bytes
            if row.hasIndexShift {
                let shift = UInt16(truncatingIfNeeded: slot * 0x20)
                bytes[bytes.startIndex + 2] = UInt8(shift & 0xFF)
                bytes[bytes.startIndex + 3] = UInt8(shift >> 8)
            }
            offsets.append(heap)
            page.data.replaceSubrange((PdbPage.heapStart + heap)..<(PdbPage.heapStart + heap + bytes.count), with: bytes)
            heap += bytes.count
        }
        for group in 0..<((count + 15) / 16) {
            let base = PdbPage.size - group * 0x24
            var presence: UInt16 = 0, transaction: UInt16 = 0
            for bit in 0..<16 {
                let slot = group * 16 + bit
                guard slot < count else { break }
                page.u16(UInt16(offsets[slot]), at: base - 6 - 2 * bit)
                presence |= 1 << bit
                if shape == .bulk || slot == count - 1 { transaction |= 1 << bit }
            }
            page.u16(transaction, at: base - 2)
            page.u16(presence, at: base - 4)
        }
        return page.data
    }
}

/// 4096바이트 쪽 하나(0으로 시작, little-endian 칸 쓰기)
struct PdbPageBytes {
    var data = Data(count: PdbPage.size)

    mutating func u8(_ value: UInt8, at offset: Int) {
        data[offset] = value
    }

    mutating func u16(_ value: UInt16, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }

    mutating func u32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}
