import DJCDomain
import Foundation
import RekordboxKit

/// 시험용 Device Library 파일(`export.pdb`·`exportExt.pdb`) 조립기.
///
/// 칸 값을 받아 형식 규칙대로 쪽·행을 조립한다(rekordbox가 만든 바이트를 넣지 않는다). 쪽 배치는 단순하다:
/// 표마다 인덱스 쪽 → 데이터 쪽들 → 빈 후보 쪽 순서로 잇고, 마지막 표의 후보는 파일 끝 너머에 둔다.
/// 모든 값은 지어낸 것이다.
public struct PdbBuilder {
    /// 쪽에 넣을 행 하나
    public struct Row: Sendable {
        public var bytes: Data
        public var live: Bool
        public var inTransaction: Bool
        /// 행 뒤에 더 붙일 패딩 바이트 수(4바이트 경계 맞춤과 따로)
        public var extraPadding: Int
        /// 행 0x02에 index_shift가 있는 표(subtype이 있는 행)
        public var hasIndexShift: Bool

        public init(_ bytes: Data, live: Bool = true, inTransaction: Bool = false, extraPadding: Int = 0, hasIndexShift: Bool = false) {
            self.bytes = bytes
            self.live = live
            self.inTransaction = inTransaction
            self.extraPadding = extraPadding
            self.hasIndexShift = hasIndexShift
        }
    }

    public let kind: PdbFileKind
    /// 표 번호 → 행(넣은 순서가 자리 순서)
    public var tables: [Int: [Row]] = [:]
    public var flag10: UInt32 = 5
    /// 패딩 자리를 채울 바이트(찌꺼기 시험용)
    public var paddingFill: UInt8 = 0
    /// 자리 번호 → index_shift 값(기본 자리 × 0x20)
    public var indexShift: @Sendable (Int) -> UInt16 = { UInt16(truncatingIfNeeded: $0 * 0x20) }
    /// 쪽 하나에 넣을 최대 행 수(nil = 들어가는 만큼)
    public var maxRowsPerPage: Int?

    public init(kind: PdbFileKind) {
        self.kind = kind
    }

    public mutating func add(_ table: Int, _ row: Row) {
        tables[table, default: []].append(row)
    }

    public mutating func add(_ table: PdbTableType, _ row: Row) { add(table.rawValue, row) }
    public mutating func add(_ table: PdbExtTableType, _ row: Row) { add(table.rawValue, row) }

    /// 조립 결과와 쪽 배치
    public struct Built {
        public var data: Data
        /// 표 번호 → 인덱스 쪽 번호
        public var indexPages: [Int: Int]
        /// 표 번호 → 데이터 쪽 번호(사슬 순서)
        public var dataPages: [Int: [Int]]
        /// 표 번호 → 빈 후보 쪽 번호
        public var candidates: [Int: Int]

        /// 쪽 `page`의 `offset`에 u32를 쓴다(쪽 머리를 망가뜨리는 시험용)
        public mutating func setU32(page: Int, offset: Int, _ value: UInt32) {
            let at = page * PdbPage.size + offset
            for index in 0..<4 { data[at + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
    }

    public func build() -> Built {
        let tableCount = kind.tableCount
        // ① 행을 쪽으로 나눈다
        var pagesByTable: [Int: [[(slot: Int, row: Row)]]] = [:]
        for table in 0..<tableCount {
            var pages: [[(slot: Int, row: Row)]] = []
            var current: [(slot: Int, row: Row)] = [], used = 0
            for row in tables[table] ?? [] {
                let size = Self.heapSize(row)
                let fits = PdbPage.heapStart + used + size + PdbPage.indexSize(slots: current.count + 1) <= PdbPage.size
                if !current.isEmpty, !fits || current.count == (maxRowsPerPage ?? .max) {
                    pages.append(current)
                    current = []
                    used = 0
                }
                current.append((current.count, row))
                used += size
            }
            if !current.isEmpty { pages.append(current) }
            pagesByTable[table] = pages
        }

        // ② 쪽 번호: 머리 0, 표마다 인덱스 → 데이터 → 후보
        var next = 1
        var indexPages: [Int: Int] = [:], dataPages: [Int: [Int]] = [:], candidates: [Int: Int] = [:]
        for table in 0..<tableCount {
            indexPages[table] = next
            next += 1
            dataPages[table] = (pagesByTable[table] ?? []).map { _ in defer { next += 1 }; return next }
            candidates[table] = next
            next += 1
        }
        let nextUnused = next
        // 마지막 표의 후보는 파일 끝 너머(쓰지 않음)
        let fileSize = (nextUnused - 1) * PdbPage.size
        var data = Data(count: fileSize)
        var sequence: UInt32 = 1

        func put(_ value: UInt32, _ at: Int) {
            for index in 0..<4 { data[at + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func put16(_ value: UInt16, _ at: Int) {
            data[at] = UInt8(truncatingIfNeeded: value)
            data[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }

        for table in 0..<tableCount {
            let index = indexPages[table]!, pages = dataPages[table]!, candidate = candidates[table]!
            // 데이터 쪽
            var deadPages: [Int] = []
            for (position, rows) in (pagesByTable[table] ?? []).enumerated() {
                sequence += 1
                let number = pages[position]
                let base = number * PdbPage.size
                let nextPage = position + 1 < pages.count ? pages[position + 1] : candidate
                var heap = Data()
                var offsets: [Int] = []
                for (slot, row) in rows {
                    offsets.append(heap.count)
                    var bytes = row.bytes
                    if row.hasIndexShift, bytes.count >= 4 {
                        let shift = indexShift(slot)
                        bytes[2] = UInt8(truncatingIfNeeded: shift)
                        bytes[3] = UInt8(truncatingIfNeeded: shift >> 8)
                    }
                    heap.append(bytes)
                    heap.append(Data(repeating: paddingFill, count: Self.heapSize(row) - bytes.count))
                }
                let live = rows.filter(\.row.live).count
                let transaction = rows.filter(\.row.inTransaction).map(\.slot)
                if live < rows.count { deadPages.append(number) }
                put(0, base)
                put(UInt32(number), base + 0x04)
                put(UInt32(table), base + 0x08)
                put(UInt32(nextPage), base + 0x0C)
                put(sequence, base + 0x10)
                put(0, base + 0x14)
                let packed = PdbPage.packRowCounts(slots: rows.count, live: live)
                data.replaceSubrange(base + 0x18..<base + 0x1B, with: packed)
                data[base + 0x1B] = live < rows.count ? 0x34 : 0x24
                put16(UInt16(PdbPage.freeSize(used: heap.count, slots: rows.count)), base + 0x1C)
                put16(UInt16(heap.count), base + 0x1E)
                put16(UInt16(transaction.count), base + 0x20)
                put16(UInt16(transaction.first ?? 0), base + 0x22)
                data.replaceSubrange(base + PdbPage.heapStart..<base + PdbPage.heapStart + heap.count, with: heap)
                // 행 인덱스(쪽 끝에서 거꾸로 16자리씩)
                for group in 0..<(rows.count + 15) / 16 {
                    let groupBase = base + PdbPage.size - group * 0x24
                    var presence: UInt16 = 0, tx: UInt16 = 0
                    for j in 0..<16 {
                        let slot = group * 16 + j
                        guard slot < rows.count else { break }
                        put16(UInt16(offsets[slot]), groupBase - 6 - 2 * j)
                        if rows[slot].row.live { presence |= 1 << j }
                        if rows[slot].row.inTransaction { tx |= 1 << j }
                    }
                    put16(tx, groupBase - 2)
                    put16(presence, groupBase - 4)
                }
            }
            // 인덱스 쪽: 지운 행이 있는 데이터 쪽 목록
            // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
            let base = index * PdbPage.size
            put(0, base)
            put(UInt32(index), base + 0x04)
            put(UInt32(table), base + 0x08)
            put(UInt32(pages.first ?? candidate), base + 0x0C)
            put(1, base + 0x10)
            data[base + 0x1B] = 0x64
            put16(0x1FFF, base + 0x20)
            put16(0x1FFF, base + 0x22)
            put16(0x03EC, base + 0x24)
            put16(UInt16(deadPages.count), base + 0x26)
            put(UInt32(index), base + 0x28)
            put(UInt32(pages.first ?? 0x03FF_FFFF), base + 0x2C)
            put(0x03FF_FFFF, base + 0x30)
            put(0, base + 0x34)
            put16(UInt16(deadPages.count), base + 0x38)
            put16(0x1FFF, base + 0x3A)
            for entry in 0..<1004 {
                put(entry < deadPages.count ? UInt32(deadPages[entry]) << 3 : 0x1FFF_FFF8, base + 0x3C + 4 * entry)
            }
        }

        // 파일 머리
        put(0, 0)
        put(UInt32(PdbPage.size), 0x04)
        put(UInt32(tableCount), 0x08)
        put(UInt32(nextUnused), 0x0C)
        put(flag10, 0x10)
        put(sequence + 1, 0x14)
        put(0, 0x18)
        for table in 0..<tableCount {
            let at = 0x1C + 16 * table
            put(UInt32(table), at)
            put(UInt32(candidates[table]!), at + 4)
            put(UInt32(indexPages[table]!), at + 8)
            put(UInt32(dataPages[table]!.last ?? indexPages[table]!), at + 12)
        }
        return Built(data: data, indexPages: indexPages, dataPages: dataPages, candidates: candidates)
    }

    /// 힙에서 차지하는 크기(4바이트 경계 + 덧붙인 패딩)
    static func heapSize(_ row: Row) -> Int {
        (row.bytes.count + 3) / 4 * 4 + row.extraPadding
    }
}

// MARK: - 행 조립

extension PdbBuilder {
    /// 고정 칸 뒤에 문자열을 붙이는 행. UTF-16 문자열은 행 시작 기준 4바이트 경계에 둔다(앞 빈 바이트 0).
    public struct RowBytes {
        public var bytes: Data

        public init(count: Int) {
            bytes = Data(count: count)
        }

        public mutating func u8(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
        }

        public mutating func u16(_ value: Int, at offset: Int) {
            for index in 0..<2 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }

        public mutating func u32(_ value: Int64, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }

        /// 문자열을 끝에 붙이고 그 오프셋을 돌려준다. UTF-16·긴 ASCII(127자 이상 순수 ASCII)는 4바이트 경계에 둔다
        @discardableResult
        public mutating func append(_ value: String, isrc: Bool = false) -> Int {
            let encoded = isrc ? PdbStringEncoder.encodeISRC(value) : PdbStringEncoder.encode(value)
            if encoded.first == 0x90 || encoded.first == 0x40 { while bytes.count % 4 != 0 { bytes.append(0) } }
            let offset = bytes.count
            bytes.append(encoded)
            return offset
        }

        /// 고정 자리에 문자열을 쓴다(그 자리가 끝이어야 한다)
        public mutating func place(_ value: String, at offset: Int) {
            precondition(bytes.count == offset, "문자열 자리는 고정 칸 바로 뒤여야 한다")
            append(value)
        }
    }

    // MARK: export.pdb 표

    public static func trackRow(_ track: PdbTrackSpec) -> Row {
        var row = RowBytes(count: 0x88)
        row.u16(Int(track.subtype), at: 0x00)
        row.u32(Int64(track.bitmask), at: 0x04)
        row.u32(Int64(track.sampleRate), at: 0x08)
        row.u32(Int64(track.composerID), at: 0x0C)
        row.u32(track.fileSize, at: 0x10)
        row.u32(track.masterContentId, at: 0x14)
        row.u32(track.masterDbId, at: 0x18)
        row.u32(Int64(track.artworkID), at: 0x1C)
        row.u32(Int64(track.keyID), at: 0x20)
        row.u32(Int64(track.originalArtistID), at: 0x24)
        row.u32(Int64(track.labelID), at: 0x28)
        row.u32(Int64(track.remixerID), at: 0x2C)
        row.u32(Int64(track.bitrate), at: 0x30)
        row.u32(Int64(track.trackNo), at: 0x34)
        row.u32(Int64(track.bpmx100), at: 0x38)
        row.u32(Int64(track.genreID), at: 0x3C)
        row.u32(Int64(track.albumID), at: 0x40)
        row.u32(Int64(track.artistID), at: 0x44)
        row.u32(Int64(track.id), at: 0x48)
        row.u16(track.discNo, at: 0x4C)
        row.u16(track.playCount, at: 0x4E)
        row.u16(track.year, at: 0x50)
        row.u16(track.bitDepth, at: 0x52)
        row.u16(track.duration, at: 0x54)
        row.u16(Int(track.u5), at: 0x56)
        row.u8(track.colorID, at: 0x58)
        row.u8(track.rating, at: 0x59)
        row.u16(track.fileType, at: 0x5A)
        row.u16(Int(track.u7), at: 0x5C)
        for (index, value) in track.strings.enumerated() {
            let offset = row.append(value, isrc: index == 0 && track.isrcSpecial)
            row.u16(offset, at: 0x5E + 2 * index)
        }
        return Row(row.bytes, hasIndexShift: true)
    }

    /// genres·labels·history_playlists·artwork: u32 id, 문자열 @0x04
    public static func idNameRow(_ id: Int, _ name: String) -> Row {
        var row = RowBytes(count: 4)
        row.u32(Int64(id), at: 0)
        row.place(name, at: 4)
        return Row(row.bytes)
    }

    public static func artistRow(_ id: Int, _ name: String, far: Bool = false) -> Row {
        var row = RowBytes(count: far ? 0x0C : 0x0A)
        row.u16(far ? 0x0064 : 0x0060, at: 0)
        row.u32(Int64(id), at: 0x04)
        row.u8(0x03, at: 0x08)
        let offset = row.append(name)
        if far { row.u16(offset, at: 0x0A) } else { row.u8(offset, at: 0x09) }
        return Row(row.bytes, hasIndexShift: true)
    }

    public static func albumRow(_ id: Int, _ name: String, artistID: Int = 0, far: Bool = false) -> Row {
        var row = RowBytes(count: far ? 0x18 : 0x16)
        row.u16(far ? 0x0084 : 0x0080, at: 0)
        row.u32(Int64(artistID), at: 0x08)
        row.u32(Int64(id), at: 0x0C)
        row.u8(0x03, at: 0x14)
        let offset = row.append(name)
        if far { row.u16(offset, at: 0x16) } else { row.u8(offset, at: 0x15) }
        return Row(row.bytes, hasIndexShift: true)
    }

    public static func keyRow(_ id: Int, _ name: String) -> Row {
        var row = RowBytes(count: 8)
        row.u32(Int64(id), at: 0)
        row.u32(Int64(id), at: 4)
        row.place(name, at: 8)
        return Row(row.bytes)
    }

    public static func colorRow(_ id: Int, _ name: String) -> Row {
        var row = RowBytes(count: 8)
        row.u8(id, at: 4)
        row.u16(id, at: 5)
        row.place(name, at: 8)
        return Row(row.bytes)
    }

    public static func playlistTreeRow(id: Int, name: String, parentID: Int = 0, sortOrder: Int = 0, isFolder: Bool = false) -> Row {
        var row = RowBytes(count: 0x14)
        row.u32(Int64(parentID), at: 0)
        row.u32(Int64(sortOrder), at: 8)
        row.u32(Int64(id), at: 0x0C)
        row.u32(isFolder ? 1 : 0, at: 0x10)
        row.place(name, at: 0x14)
        return Row(row.bytes)
    }

    public static func playlistEntryRow(index: Int, trackID: Int, playlistID: Int) -> Row {
        var row = RowBytes(count: 12)
        row.u32(Int64(index), at: 0)
        row.u32(Int64(trackID), at: 4)
        row.u32(Int64(playlistID), at: 8)
        return Row(row.bytes)
    }

    public static func historyEntryRow(trackID: Int, playlistID: Int, index: Int) -> Row {
        var row = RowBytes(count: 12)
        row.u32(Int64(trackID), at: 0)
        row.u32(Int64(playlistID), at: 4)
        row.u32(Int64(index), at: 8)
        return Row(row.bytes)
    }

    public static func columnRow(id: Int, code: Int, name: String) -> Row {
        var row = RowBytes(count: 4)
        row.u16(id, at: 0)
        row.u16(code, at: 2)
        let encoded = PdbStringEncoder.encodeUTF16("\u{FFFA}\(name)\u{FFFB}")
        row.bytes.append(encoded)
        return Row(row.bytes)
    }

    public static func categoryRow(id: Int, menuItemID: Int, infoOrder: Int, disable: Int, sequence: Int) -> Row {
        var row = RowBytes(count: 8)
        row.u16(menuItemID, at: 0)
        row.u16(id, at: 2)
        row.u8(infoOrder, at: 4)
        row.u8(disable, at: 5)
        row.u16(sequence, at: 6)
        return Row(row.bytes)
    }

    public static func sortRow(id: Int, menuItemID: Int, disable: Int, sequence: Int) -> Row {
        var row = RowBytes(count: 8)
        row.u16(menuItemID, at: 0)
        row.u16(id, at: 2)
        row.u8(disable, at: 4)
        row.u8(sequence, at: 5)
        return Row(row.bytes)
    }

    /// 표 19(property): 곡 수, 날짜(10자), 버전 글자, 두 번째 글자. 40바이트보다 짧으면 0으로 채운다.
    public static func propertyRow(count: Int, date: String, version: String = "1000", name: String = "") -> Row {
        precondition(date.utf8.count == 10, "날짜는 YYYY-MM-DD")
        var row = RowBytes(count: 0x0C)
        row.u16(0x0280, at: 0)
        row.u32(Int64(count), at: 4)
        row.place(date, at: 0x0C)
        row.bytes.append(Data(count: 2))
        let versionOffset = row.append(version)
        row.u8(versionOffset, at: 0x17)
        let nameOffset = row.append(name)
        row.u8(nameOffset, at: 0x18)
        if row.bytes.count < 40 { row.bytes.append(Data(count: 40 - row.bytes.count)) }
        return Row(row.bytes, hasIndexShift: true)
    }

    // MARK: exportExt.pdb 표

    /// My Tag 행. 분류면 category 0·바이트 0x1B = 1. 먼 모양(0x0684)은 u16 0x0003 @0x1C, u16 이름 @0x1E, u16 두 번째 @0x20
    /// (Deep Symmetry 분석 문서·rekordcrate와 같은 자리). rekordbox로 확인하지 못한 모양이라 리더는 이 행을 구조 문제로 남긴다.
    public static func tagRow(id: Int64, name: String, parentID: Int64 = 0, position: Int, isCategory: Bool, far: Bool = false) -> Row {
        var row = RowBytes(count: far ? 0x22 : 0x1F)
        row.u16(far ? 0x0684 : 0x0680, at: 0)
        row.u32(parentID, at: 0x0C)
        row.u32(Int64(position), at: 0x10)
        row.u32(id, at: 0x14)
        row.u8(isCategory ? 1 : 0, at: 0x1B)
        if far { row.u16(0x0003, at: 0x1C) } else { row.u8(0x03, at: 0x1C) }
        let nameOffset = row.append(name)
        let secondOffset = row.append("")
        if far {
            row.u16(nameOffset, at: 0x1E)
            row.u16(secondOffset, at: 0x20)
        } else {
            row.u8(nameOffset, at: 0x1D)
            row.u8(secondOffset, at: 0x1E)
        }
        return Row(row.bytes, hasIndexShift: true)
    }

    public static func tagTrackRow(trackID: Int, tagID: Int64) -> Row {
        var row = RowBytes(count: 16)
        row.u32(Int64(trackID), at: 4)
        row.u32(tagID, at: 8)
        row.u32(3, at: 12)
        return Row(row.bytes)
    }

    /// exportExt 표 7(60바이트): myTagMasterDBID와 빈 문자열 다섯
    public static func myTagPropertyRow(masterDBID: Int64) -> Row {
        var row = RowBytes(count: 0x1D)
        row.u16(0x0700, at: 0)
        row.u32(masterDBID, at: 0x18)
        row.u8(0x03, at: 0x1C)
        row.bytes.append(Data(count: 5))
        for index in 0..<5 {
            let offset = row.append("")
            row.u8(offset, at: 0x1D + index)
        }
        row.bytes.append(Data(count: 60 - row.bytes.count))
        return Row(row.bytes, hasIndexShift: true)
    }

    /// 뜻 모를 표에 넣을 아무 행
    public static func opaqueRow(_ count: Int = 8, fill: UInt8 = 0x11) -> Row {
        Row(Data(repeating: fill, count: count))
    }
}

/// 합성 트랙 행 칸(모두 지어낸 값). 문자열 21개는 `strings`에 번호 순서로 둔다.
public struct PdbTrackSpec: Sendable {
    public var id: Int
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public var subtype: UInt16 = 0x0024
    public var bitmask: UInt32 = 0x000C_0700
    public var sampleRate = 44100
    public var composerID = 0
    public var fileSize: Int64 = 1_000_000
    public var masterContentId: Int64
    public var masterDbId: Int64 = 1_000_001
    public var artworkID = 0
    public var keyID = 0
    public var originalArtistID = 0
    public var labelID = 0
    public var remixerID = 0
    public var bitrate = 320
    public var trackNo = 0
    public var bpmx100 = 12800
    public var genreID = 0
    public var albumID = 0
    public var artistID = 0
    public var discNo = 0
    public var playCount = 0
    public var year = 0
    public var bitDepth = 16
    public var duration = 200
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public var u5: UInt16 = 0x0029
    public var colorID = 0
    public var rating = 0
    public var fileType = 1
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public var u7: UInt16 = 3
    /// ISRC를 특수형(0x90 … 03 … 00)으로 쓸지. 빈 ISRC는 짧은 ASCII
    public var isrcSpecial = false
    public var strings: [String]

    /// 문자열 번호
    public enum Field: Int, CaseIterable, Sendable {
        case isrc = 0, lyricist, informationUpdateCount, analysisDataUpdateCount, cueUpdateCount, message, kuvoPublic, autoloadHotcues,
             unknown8, unknown9, dateCreated, releaseDate, mixName, unknown13, analyzePath, dateAdded, comment, title, unknown18,
             fileName, filePath
    }

    public init(id: Int) {
        self.id = id
        masterContentId = 900_000 + Int64(id)
        strings = Array(repeating: "", count: 21)
        self[.informationUpdateCount] = "0"
        self[.analysisDataUpdateCount] = "0"
        self[.cueUpdateCount] = "0"
        self[.kuvoPublic] = ""
        self[.autoloadHotcues] = "ON"
        self[.dateCreated] = "2026-01-01"
        self[.dateAdded] = "2026-01-02"
        self[.title] = "시험 곡 \(id)"
        self[.fileName] = "test\(id).mp3"
        self[.filePath] = "/Contents/시험 아티스트/시험 앨범/test\(id).mp3"
        self[.analyzePath] = String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id)
    }

    public subscript(_ field: Field) -> String {
        get { strings[field.rawValue] }
        set { strings[field.rawValue] = newValue }
    }
}
