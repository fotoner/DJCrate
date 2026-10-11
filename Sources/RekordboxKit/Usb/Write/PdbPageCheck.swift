import DJCDomain
import Foundation

/// 있는 Device Library 파일의 쪽을 칸 값만으로 다시 만들어 바이트를 비교한다(작성기 규칙 확인용, `djc lab pdb-verify`).
/// 쪽 번호·next·순번·행 자리 순서는 원본 값을 쓰고, 파일 머리·쪽 머리·행·행 인덱스는 작성기 규칙으로 만든다.
/// 제자리 수정 이력이 있는 쪽(지운 행이 있는 데이터 쪽, 0x20·0x22가 한 번에 씀·덧붙임 모양이 아닌 데이터 쪽,
/// 지운 쪽 목록이 있는 인덱스 쪽)은 대상에서 뺀다. 행을 해석하지 못하거나 다시 만든 행이 한 쪽에 들어가지 않는 데이터 쪽은
/// 쪽을 만들지 않고 이유와 함께 다른 쪽으로 남긴다.
public enum PdbPageCheck {
    public enum Category: String, Sendable, CaseIterable {
        case header, index, zero, data
    }

    /// 데이터 쪽을 다시 만들지 못한 이유
    public enum RebuildFailure: String, Sendable, Hashable {
        /// 원본 행을 표 규칙으로 해석하지 못함
        case rowUnreadable
        /// 다시 만든 행이 원본보다 커서 한 쪽에 들어가지 않음(긴 ASCII 0x40 → UTF-16 등)
        case rowsDoNotFit
    }

    public struct Page: Sendable, Hashable {
        public var number: Int
        public var category: Category
        /// 표 이름(파일 머리·빈 쪽은 "")
        public var table: String
        /// 처음 다른 바이트 자리(쪽 시작 기준). nil = 같음, -1 = 쪽을 다시 만들지 못함(이유는 `rebuildFailure`)
        public var firstDifference: Int?
        /// 데이터 쪽이 다를 때 다른 행: 자리, 원본 할당 크기, 다시 만든 크기, 행 안 처음 다른 자리
        public var rows: [RowDifference] = []
        public var rebuildFailure: RebuildFailure?

        public var isSame: Bool { firstDifference == nil }

        public init(number: Int, category: Category, table: String, firstDifference: Int?, rows: [RowDifference] = [],
                    rebuildFailure: RebuildFailure? = nil) {
            self.number = number
            self.category = category
            self.table = table
            self.firstDifference = firstDifference
            self.rows = rows
            self.rebuildFailure = rebuildFailure
        }
    }

    public struct RowDifference: Sendable, Hashable {
        public var slot: Int
        public var originalSize: Int
        public var rebuiltSize: Int
        public var firstDifference: Int

        public init(slot: Int, originalSize: Int, rebuiltSize: Int, firstDifference: Int) {
            self.slot = slot
            self.originalSize = originalSize
            self.rebuiltSize = rebuiltSize
            self.firstDifference = firstDifference
        }
    }

    public struct Excluded: Sendable, Hashable {
        public var number: Int
        public var table: String
        /// "deadRows"(지운 행이 있는 데이터 쪽), "inPlaceShape"(0x20·0x22가 그 표의 쓰기 모양과 다른 데이터 쪽)
        /// "indexEntries"(지운 쪽 목록이 있는 인덱스 쪽) 또는 "nfcStrings"(작성기가 NFC로 바꿔 쓰는 문자열이 든 데이터 쪽, #233)
        public var reason: String

        public init(number: Int, table: String, reason: String) {
            self.number = number
            self.table = table
            self.reason = reason
        }
    }

    public struct Report: Sendable {
        public var kind: PdbFileKind
        public var pageCount: Int
        public var compared: [Page]
        public var excluded: [Excluded]

        public init(kind: PdbFileKind, pageCount: Int, compared: [Page], excluded: [Excluded]) {
            self.kind = kind
            self.pageCount = pageCount
            self.compared = compared
            self.excluded = excluded
        }

        public func count(_ category: Category) -> (same: Int, total: Int) {
            let pages = compared.filter { $0.category == category }
            return (pages.filter(\.isSame).count, pages.count)
        }
    }

    public static func check(_ data: Data) throws -> Report {
        let file = try PdbFile(data: data)
        var owner: [Int: PdbTablePointer] = [:]
        for pointer in file.header.tables {
            for page in file.walk(pointer).pages { owner[Int(page.header.pageIndex)] = pointer }
        }
        var compared: [Page] = [], excluded: [Excluded] = []
        func original(_ number: Int) -> Data {
            Data(data[(number * PdbPage.size)..<((number + 1) * PdbPage.size)])
        }
        func compare(_ number: Int, _ category: Category, _ table: String, _ rebuilt: Data) {
            compared.append(Page(number: number, category: category, table: table, firstDifference: firstDifference(original(number), rebuilt)))
        }

        let header = file.header
        compare(0, .header, "", PdbLayout.headerPage(nextUnused: header.nextUnusedPage, sequence: header.sequence, pointers: header.tables))
        for number in 1..<file.pageCount {
            guard let pointer = owner[number] else {
                compare(number, .zero, "", Data(count: PdbPage.size))
                continue
            }
            let table = file.kind.tableName(pointer.type)
            let page = try file.page(UInt32(number))
            let h = page.header
            if h.isIndex {
                guard h.u7 == 0 else {
                    excluded.append(Excluded(number: number, table: table, reason: "indexEntries"))
                    continue
                }
                let firstData = pointer.lastPage == pointer.firstPage ? nil : h.nextPage
                compare(number, .index, table, PdbLayout.indexPage(number: h.pageIndex, type: h.type, next: h.nextPage, firstData: firstData,
                                                                   sequence: h.sequence))
                continue
            }
            guard h.liveRows == h.rowSlots, page.slots.allSatisfy(\.isLive) else {
                excluded.append(Excluded(number: number, table: table, reason: "deadRows"))
                continue
            }
            // rekordbox가 제자리에서 고친 쪽은 행 할당이 새로 쓴 모양과 달라 비교 대상이 아니다
            let shape = PdbLayout.shape(file.kind, Int(h.type))
            let expected = PdbLayout.transactionFields(shape, slots: h.rowSlots)
            guard h.txRowCount == expected.count, h.txRowIndex == expected.index else {
                excluded.append(Excluded(number: number, table: table, reason: "inPlaceShape"))
                continue
            }
            guard let rows = try? page.slots.map({ try reencode(file.kind, Int(h.type), page.row($0)) }) else {
                compared.append(Page(number: number, category: .data, table: table, firstDifference: -1, rebuildFailure: .rowUnreadable))
                continue
            }
            // 작성기는 사람이 읽는 문자열을 NFC로 쓴다(#233). 원본 철자가 NFC가 아닌 행이 든 쪽은 rekordbox와 일부러 달라 비교하지 않는다
            if rows.contains(where: { $0.rules.contains(.pdbStringNFC) }) {
                excluded.append(Excluded(number: number, table: table, reason: "nfcStrings"))
                continue
            }
            // 다시 만든 행이 원본보다 크면 한 쪽에 들어가지 않을 수 있다. 쪽은 만들지 않고 행마다 크기만 남긴다
            guard PdbLayout.fitsOnePage(rows) else {
                compared.append(Page(number: number, category: .data, table: table, firstDifference: -1, rows: rowDifferences(page, rows),
                                     rebuildFailure: .rowsDoNotFit))
                continue
            }
            compare(number, .data, table,
                    PdbLayout.dataPage(number: h.pageIndex, type: h.type, next: h.nextPage, sequence: h.sequence, rows: rows, shape: shape))
            if !compared[compared.count - 1].isSame {
                compared[compared.count - 1].rows = rowDifferences(page, rows)
            }
        }
        return Report(kind: file.kind, pageCount: file.pageCount, compared: compared, excluded: excluded)
    }

    /// 행마다 원본(다음 행 오프셋까지)과 다시 만든 행(index_shift를 넣은 것)을 비교한다
    static func rowDifferences(_ page: PdbPage, _ rows: [PdbEncodedRow]) -> [RowDifference] {
        zip(page.slots, rows).compactMap { slot, row in
            let original = page.row(slot)
            var rebuilt = row.bytes
            if row.hasIndexShift, rebuilt.count >= 4 {
                let shift = UInt16(truncatingIfNeeded: slot.index * 0x20)
                rebuilt[rebuilt.startIndex + 2] = UInt8(shift & 0xFF)
                rebuilt[rebuilt.startIndex + 3] = UInt8(shift >> 8)
            }
            guard let difference = firstDifference(original, rebuilt) else { return nil }
            return RowDifference(slot: slot.index, originalSize: original.count, rebuiltSize: rebuilt.count, firstDifference: difference)
        }
    }

    static func firstDifference(_ a: Data, _ b: Data) -> Int? {
        let left = [UInt8](a), right = [UInt8](b)
        guard left != right else { return nil }
        return zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(left.count, right.count)
    }

    /// 원본 행을 표 규칙으로 읽고 작성기로 다시 만든다
    static func reencode(_ kind: PdbFileKind, _ type: Int, _ bytes: Data) throws -> PdbEncodedRow {
        var reader = PdbRowReader(bytes)
        switch kind {
        case .export:
            switch PdbTableType(rawValue: type) {
            case .tracks: return try PdbRowEncoder.track(PdbRows.track(&reader).0).row
            case .genres, .labels:
                let (id, name) = try PdbRows.idName(&reader)
                return try PdbRowEncoder.idName(id: id, name: name)
            case .artwork:
                let (id, path) = try PdbRows.idName(&reader)
                return try PdbRowEncoder.artwork(id: id, path: path)
            case .artists: return try PdbRowEncoder.artist(PdbRows.artist(&reader))
            case .albums: return try PdbRowEncoder.album(PdbRows.album(&reader))
            case .keys: return try PdbRowEncoder.key(PdbRows.key(&reader))
            case .colors: return try PdbRowEncoder.color(PdbRows.color(&reader))
            case .playlistTree:
                let node = try PdbRows.playlistTree(&reader)
                return try PdbRowEncoder.playlistTree(id: node.id, name: node.name, parentID: node.parentID, sortOrder: node.sortOrder,
                                                      isFolder: node.isFolder)
            case .playlistEntries:
                let entry = try PdbRows.playlistEntry(reader)
                return try PdbRowEncoder.playlistEntry(index: entry.index, trackID: entry.trackID, playlistID: entry.playlistID)
            case .columns: return try PdbRowEncoder.column(PdbRows.column(&reader))
            case .category: return try PdbRowEncoder.category(PdbRows.category(reader))
            case .sort: return try PdbRowEncoder.sort(PdbRows.sort(reader))
            case .history19:
                let property = try PdbRows.property(&reader)
                return try PdbRowEncoder.property(trackCount: property.count, date: property.date)
            default: throw UsbError.readFailed(detail: "pdb table \(type) has no writer")
            }
        case .exportExt:
            switch PdbExtTableType(rawValue: type) {
            case .tags: return try PdbRowEncoder.tag(PdbRows.tag(&reader))
            case .myTagProperty: return try PdbRowEncoder.myTagProperty(masterDBID: PdbRows.myTagProperty(reader))
            default: throw UsbError.readFailed(detail: "pdb ext table \(type) has no writer")
            }
        }
    }
}
