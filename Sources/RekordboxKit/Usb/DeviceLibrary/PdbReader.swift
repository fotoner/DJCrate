import DJCDomain
import Foundation

/// 파일 하나를 읽은 결과(lab·진단용). 쪽까지 들고 있다.
public struct PdbFileReport: Sendable {
    public var kind: PdbFileKind
    public var header: PdbFileHeader
    /// 표 포인터 순서
    public var tables: [PdbTableScan]
    /// 사슬·쪽·행 문제 전부
    public var issues: [PdbIssue]
    public var stringKinds: [String: Int]
    public var longestShortASCII: Int
    public var misalignedUTF16: Int
    public var unknownRows: [UsbUnknownRows]
    /// 사슬에 든 쪽 순번 중 가장 큰 것(파일 머리 순번보다 작아야 한다)
    public var maxPageSequence: UInt32
    /// 표 이름 → 먼 오프셋 모양으로 읽은 산 행 수
    public var farShapeRows: [String: Int]
}

/// `export.pdb`·`exportExt.pdb` → `UsbLibrary`(formats = [.deviceLibrary]).
/// 산 행은 presence 비트로만 판단한다(index_shift·인덱스 쪽 항목·패딩은 보지 않는다). 구조 문제는 멈추지 않고 보고서에 모으고
/// 그 표는 읽은 데까지만 쓴다. 파일 머리(쪽 크기·표 수)가 다르면 `UsbError.readFailed`로 멈춘다.
public enum PdbReader {
    public static func read(export: Data, exportExt: Data?) throws -> (UsbLibrary, PdbReadReport) {
        let exportFile = try PdbFile(data: export)
        guard exportFile.kind == .export else {
            throw UsbError.readFailed(detail: "export.pdb has \(exportFile.header.numTables) tables")
        }
        var parser = Parser()
        let exportReport = parser.parse(exportFile)
        var extReport: PdbFileReport?
        if let exportExt {
            let extFile = try PdbFile(data: exportExt)
            guard extFile.kind == .exportExt else {
                throw UsbError.readFailed(detail: "exportExt.pdb has \(extFile.header.numTables) tables")
            }
            extReport = parser.parse(extFile)
        }
        let library = parser.finish()
        let files = [exportReport] + (extReport.map { [$0] } ?? [])
        var counts: [String: (live: Int, slots: Int)] = [:], pages: [String: Int] = [:], kinds: [String: Int] = [:]
        var farShapeRows: [String: Int] = [:]
        for file in files {
            for table in file.tables {
                counts[table.name] = (table.liveRows, table.slotCount)
                pages[table.name] = table.pages.count
            }
            kinds.merge(file.stringKinds) { $0 + $1 }
            farShapeRows.merge(file.farShapeRows) { $0 + $1 }
        }
        let issues = files.flatMap(\.issues)
        let report = PdbReadReport(exportHeader: exportReport.header, extHeader: extReport?.header, tableCounts: counts,
                                   unknownRows: library.unknownRows, issues: issues.map(\.description), stringKinds: kinds,
                                   issueDetails: issues, pageCounts: pages,
                                   longestShortASCII: files.map(\.longestShortASCII).max() ?? 0,
                                   misalignedUTF16: files.reduce(0) { $0 + $1.misalignedUTF16 }, farShapeRows: farShapeRows)
        return (library, report)
    }

    /// `UsbSnapshot`으로 뜬 사본에서 읽는다. 사본에 export.pdb가 없으면 nil
    public static func read(snapshot: UsbSnapshot) throws -> (UsbLibrary, PdbReadReport)? {
        guard let export = snapshot.exportPdb else { return nil }
        let exportData = try Data(contentsOf: export)
        let extData = try snapshot.exportExtPdb.map { try Data(contentsOf: $0) }
        return try read(export: exportData, exportExt: extData)
    }

    /// 파일 하나를 표 수로 가려(20 export, 9 exportExt) 읽고 쪽·문제를 돌려준다
    public static func inspect(_ data: Data) throws -> PdbFileReport {
        var parser = Parser()
        return parser.parse(try PdbFile(data: data))
    }

    /// 행 하나를 그 표 규칙으로 해석해 문자열 모양(종류·UTF-16 글자 수)만 돌려준다(진단용, 값은 돌려주지 않음).
    /// 문자열이 없거나 모르는 표면 빈 배열, 해석하지 못하면 nil
    public static func stringShapes(kind: PdbFileKind, table: UInt32, row: Data) -> [(kind: PdbStringKind, length: Int)]? {
        var reader = PdbRowReader(row)
        do {
            switch kind {
            case .export:
                switch PdbTableType(rawValue: Int(table)) {
                case .tracks: _ = try PdbRows.track(&reader)
                case .genres, .labels, .historyPlaylists, .artwork: _ = try PdbRows.idName(&reader)
                case .artists: _ = try PdbRows.artist(&reader)
                case .albums: _ = try PdbRows.album(&reader)
                case .keys: _ = try PdbRows.key(&reader)
                case .colors: _ = try PdbRows.color(&reader)
                case .playlistTree: _ = try PdbRows.playlistTree(&reader)
                case .columns: _ = try PdbRows.column(&reader)
                case .history19: _ = try PdbRows.property(&reader)
                default: return []
                }
            case .exportExt:
                switch PdbExtTableType(rawValue: Int(table)) {
                case .tags: _ = try PdbRows.tag(&reader)
                default: return []
                }
            }
        } catch {
            return nil
        }
        return reader.strings.map { ($0.kind, $0.length) }
    }

    /// 두 파일의 행을 모델로 모은다
    struct Parser {
        var library = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty())
        var propertyRow: PdbRows.PropertyRow?
        var myTagMasterDBID: Int64 = 0
        var nodes: [PdbRows.PlaylistNode] = []
        var entries: [(ref: RowRef, index: Int, trackID: Int, playlistID: Int)] = []

        /// 파일 하나를 읽는 동안의 통계
        private var issues: [PdbIssue] = []
        private var stringKinds: [String: Int] = [:]
        private var longestShortASCII = 0
        private var misalignedUTF16 = 0
        private var farShapeRows: [String: Int] = [:]

        struct RowRef {
            var page: Int
            var slot: Int
            var reader: PdbRowReader
        }

        mutating func parse(_ file: PdbFile) -> PdbFileReport {
            issues = []
            stringKinds = [:]
            longestShortASCII = 0
            misalignedUTF16 = 0
            farShapeRows = [:]
            var unknown: [UsbUnknownRows] = []
            let scans = file.header.tables.map(file.walk)
            for (position, pointer) in file.header.tables.enumerated() where pointer.type != UInt32(position) {
                issues.append(PdbIssue(kind: .tableOrder, table: file.kind.tableName(pointer.type)))
            }
            // 기록 표(11·12)는 둘 다 해석될 때만 모델에 넣는다
            var historyRows: [PdbTableType: (scan: PdbTableScan, live: [RowRef])] = [:]
            for scan in scans {
                issues += scan.issues
                let (live, dead) = rows(scan)
                switch file.kind {
                case .export:
                    let type = PdbTableType(rawValue: Int(scan.pointer.type))
                    if let type {
                        for row in dead {
                            if let found = PdbRows.deadID(type, row.reader) { library.deadIDs[found.kind, default: []].insert(found.id) }
                        }
                    }
                    switch type {
                    case .some(let type) where [.historyPlaylists, .historyEntries].contains(type): historyRows[type] = (scan, live)
                    case .some(let type) where Self.modeled(type): exportRows(type, live, table: scan.name)
                    default: if !live.isEmpty { unknown.append(unknownRows(file, scan, live.count)) }
                    }
                case .exportExt:
                    switch PdbExtTableType(rawValue: Int(scan.pointer.type)) {
                    case .some(let type) where [.tags, .tagTracks, .myTagProperty].contains(type): extRows(type, live, table: scan.name)
                    default: if !live.isEmpty { unknown.append(unknownRows(file, scan, live.count)) }
                    }
                }
            }
            if file.kind == .export {
                unknown += histories(file, historyRows)
                reportOrphanEntries()
            }
            library.unknownRows += unknown
            let maxSequence = scans.flatMap(\.pages).map(\.header.sequence).max() ?? 0
            return PdbFileReport(kind: file.kind, header: file.header, tables: scans, issues: issues, stringKinds: stringKinds,
                                 longestShortASCII: longestShortASCII, misalignedUTF16: misalignedUTF16,
                                 unknownRows: unknown.sorted { $0.tableType < $1.tableType }, maxPageSequence: maxSequence,
                                 farShapeRows: farShapeRows)
        }

        /// 모델에 담는 export 표(기록 표는 따로)
        static func modeled(_ type: PdbTableType) -> Bool {
            switch type {
            case .unknown9, .unknown10, .unknown14, .unknown15, .historyPlaylists, .historyEntries: false
            default: true
            }
        }

        func unknownRows(_ file: PdbFile, _ scan: PdbTableScan, _ live: Int) -> UsbUnknownRows {
            UsbUnknownRows(format: .deviceLibrary, file: file.kind.fileName, tableType: Int(scan.pointer.type), liveRows: live)
        }

        /// 산 행(힙 안, 겹치지 않음)과 죽은 행. 쪽 단위 문제는 여기서 모은다
        mutating func rows(_ scan: PdbTableScan) -> (live: [RowRef], dead: [RowRef]) {
            var live: [RowRef] = [], dead: [RowRef] = []
            for page in scan.pages where !page.header.isIndex {
                let number = Int(page.header.pageIndex)
                if page.slots.filter(\.isLive).count != page.header.liveRows {
                    issues.append(PdbIssue(kind: .liveCountMismatch, table: scan.name, page: number))
                }
                if PdbPage.heapStart + Int(page.header.usedSize) > page.heapLimit {
                    issues.append(PdbIssue(kind: .rowOutsideHeap, table: scan.name, page: number))
                }
                var liveOffsets: Set<Int> = []
                for slot in page.slots {
                    guard slot.isLive else {
                        if page.isInsideHeap(slot) { dead.append(RowRef(page: number, slot: slot.index, reader: PdbRowReader(page.row(slot)))) }
                        continue
                    }
                    guard page.isInsideHeap(slot) else {
                        issues.append(PdbIssue(kind: .rowOutsideHeap, table: scan.name, page: number, slot: slot.index))
                        continue
                    }
                    guard liveOffsets.insert(slot.offset).inserted else {
                        issues.append(PdbIssue(kind: .rowOverlap, table: scan.name, page: number, slot: slot.index))
                        continue
                    }
                    live.append(RowRef(page: number, slot: slot.index, reader: PdbRowReader(page.row(slot))))
                }
            }
            return (live, dead)
        }

        /// 행을 하나씩 해석한다. 실패한 행은 문제 목록에 넣고 건너뛴다. 해석에 성공한 행의 문자열·먼 모양만 통계에 넣는다.
        /// 돌려주는 RowRef의 reader는 해석을 마친 것이다(`farShape` 등).
        mutating func each<Value>(_ rows: [RowRef], table: String, _ parse: (inout PdbRowReader) throws -> Value) -> [(RowRef, Value)] {
            var values: [(RowRef, Value)] = []
            for row in rows {
                var reader = row.reader
                do {
                    let value = try parse(&reader)
                    record(reader.strings)
                    if reader.farShape { farShapeRows[table, default: 0] += 1 }
                    values.append((RowRef(page: row.page, slot: row.slot, reader: reader), value))
                } catch {
                    issues.append(PdbIssue(kind: .rowUnreadable, table: table, page: row.page, slot: row.slot))
                }
            }
            return values
        }

        mutating func record(_ strings: [PdbRowReader.DecodedString]) {
            for string in strings {
                stringKinds[string.kind.rawValue, default: 0] += 1
                if string.kind == .shortASCII { longestShortASCII = max(longestShortASCII, string.length) }
                if string.kind == .utf16LE, string.offset % 4 != 0 { misalignedUTF16 += 1 }
            }
        }

        /// 같은 id 산 행은 첫 행만 남기고 나머지는 문제로 보고한다
        mutating func unique<Value>(_ values: [(RowRef, Value)], table: String, id: (Value) -> Int64) -> [Value] {
            var seen: Set<Int64> = [], result: [Value] = []
            for (row, value) in values {
                if seen.insert(id(value)).inserted {
                    result.append(value)
                } else {
                    issues.append(PdbIssue(kind: .duplicateID, table: table, page: row.page, slot: row.slot))
                }
            }
            return result
        }

        mutating func exportRows(_ type: PdbTableType, _ rows: [RowRef], table: String) {
            switch type {
            case .tracks:
                let parsed = unique(each(rows, table: table, PdbRows.track), table: table) { Int64($0.0.id) }
                library.tracks = parsed.map(\.0)
                library.trackRowExtras = Dictionary(parsed.map { ($0.0.id, $0.1) }) { first, _ in first }
            case .genres:
                library.genres = named(rows, table: table) { UsbNamedRow(id: $0.id, name: $0.name) }
            case .labels:
                library.labels = named(rows, table: table) { UsbNamedRow(id: $0.id, name: $0.name) }
            case .artists:
                library.artists = unique(each(rows, table: table, PdbRows.artist), table: table) { Int64($0.id) }
            case .albums:
                library.albums = unique(each(rows, table: table, PdbRows.album), table: table) { Int64($0.id) }
            case .keys:
                library.keys = unique(each(rows, table: table, PdbRows.key), table: table) { Int64($0.id) }
            case .colors:
                library.colors = unique(each(rows, table: table, PdbRows.color), table: table) { Int64($0.id) }
            case .playlistTree:
                nodes = unique(each(rows, table: table, PdbRows.playlistTree), table: table) { Int64($0.id) }
            case .playlistEntries:
                entries = each(rows, table: table) { try PdbRows.playlistEntry($0) }
                    .map { (ref: $0.0, index: $0.1.index, trackID: $0.1.trackID, playlistID: $0.1.playlistID) }
            case .artwork:
                library.images = unique(each(rows, table: table, PdbRows.idName), table: table) { Int64($0.id) }
                    .map { UsbImage(id: $0.id, oneLibraryPath: nil, pdbPath: $0.name) }
            case .columns:
                library.menuItems = unique(each(rows, table: table, PdbRows.column), table: table) { Int64($0.id) }
            case .category:
                library.categories = unique(each(rows, table: table) { try PdbRows.category($0) }, table: table) { Int64($0.id) }
            case .sort:
                library.sorts = unique(each(rows, table: table) { try PdbRows.sort($0) }, table: table) { Int64($0.id) }
            case .history19:
                let parsed = each(rows, table: table, PdbRows.property)
                for (row, _) in parsed.dropFirst() {
                    issues.append(PdbIssue(kind: .multipleRows, table: table, page: row.page, slot: row.slot))
                }
                propertyRow = parsed.first?.1
            case .unknown9, .unknown10, .unknown14, .unknown15, .historyPlaylists, .historyEntries:
                break
            }
        }

        mutating func named(_ rows: [RowRef], table: String, _ make: ((id: Int, name: String)) -> UsbNamedRow) -> [UsbNamedRow] {
            unique(each(rows, table: table, PdbRows.idName), table: table) { Int64($0.id) }.map(make)
        }

        mutating func extRows(_ type: PdbExtTableType, _ rows: [RowRef], table: String) {
            switch type {
            case .tags:
                let parsed = each(rows, table: table, PdbRows.tag)
                // 먼 모양 태그 행은 칸 자리를 확인하지 못했다. 모델에는 넣되 편집·다시 쓰기가 막히게 문제로 남긴다
                for (row, _) in parsed where row.reader.farShape {
                    issues.append(PdbIssue(kind: .unconfirmedRowShape, table: table, page: row.page, slot: row.slot))
                }
                library.myTags = unique(parsed, table: table) { $0.id }
            case .tagTracks:
                library.myTagLinks = each(rows, table: table) { try PdbRows.tagTrack($0) }.map(\.1)
            case .myTagProperty:
                let parsed = each(rows, table: table) { try PdbRows.myTagProperty($0) }
                for (row, _) in parsed.dropFirst() {
                    issues.append(PdbIssue(kind: .multipleRows, table: table, page: row.page, slot: row.slot))
                }
                myTagMasterDBID = parsed.first?.1 ?? 0
            default:
                break
            }
        }

        /// 기록 표 11·12. 한 행이라도 해석되지 않거나 없는 기록을 가리키면 두 표 모두 행 수만 남긴다
        mutating func histories(_ file: PdbFile, _ tables: [PdbTableType: (scan: PdbTableScan, live: [RowRef])]) -> [UsbUnknownRows] {
            let playlistScan = tables[.historyPlaylists]?.scan, entryScan = tables[.historyEntries]?.scan
            let playlistRows = tables[.historyPlaylists]?.live ?? []
            let entryRows = tables[.historyEntries]?.live ?? []
            guard !playlistRows.isEmpty || !entryRows.isEmpty else { return [] }
            var strings: [PdbRowReader.DecodedString] = []
            var playlists: [(id: Int, name: String)] = [], historyEntries: [(index: Int, trackID: Int, playlistID: Int)] = []
            var readable = true
            for row in playlistRows {
                var reader = row.reader
                guard let value = try? PdbRows.idName(&reader) else { readable = false; break }
                strings += reader.strings
                playlists.append(value)
            }
            for row in entryRows where readable {
                guard let value = try? PdbRows.historyEntry(row.reader) else { readable = false; break }
                historyEntries.append(value)
            }
            let ids = Set(playlists.map(\.id))
            if readable, ids.count == playlists.count, historyEntries.allSatisfy({ ids.contains($0.playlistID) }) {
                record(strings)
                library.histories = playlists.map { playlist in
                    let items = historyEntries.enumerated().filter { $0.element.playlistID == playlist.id }
                        .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element.trackID)
                    return UsbHistory(format: .deviceLibrary, id: playlist.id, name: playlist.name, entries: items)
                }
                return []
            }
            return [(playlistScan, playlistRows.count), (entryScan, entryRows.count)].compactMap { scan, count in
                guard let scan, count > 0 else { return nil }
                return unknownRows(file, scan, count)
            }
        }

        /// 산 목록 항목이 산 목록을 가리키지 않으면 모델에 담을 곳이 없어 빠진다. 다시 쓸 때 조용히 지워지지 않게 문제로 남긴다
        /// (rekordbox는 목록을 지울 때 그 항목도 함께 죽인다)
        mutating func reportOrphanEntries() {
            let ids = Set(nodes.map(\.id))
            for entry in entries where !ids.contains(entry.playlistID) {
                issues.append(PdbIssue(kind: .orphanEntry, table: PdbTableType.playlistEntries.name, page: entry.ref.page, slot: entry.ref.slot))
            }
        }

        /// 모은 행으로 모델을 마무리한다(목록 항목·property)
        func finish() -> UsbLibrary {
            var library = library
            library.playlists = nodes.map { node in
                let items = entries.enumerated().filter { $0.element.playlistID == node.id }
                    .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element.trackID)
                return UsbPlaylist(id: node.id, name: node.name, parentID: node.parentID, attribute: node.isFolder ? 1 : 0, imageID: nil,
                                   presentIn: [.deviceLibrary], sortOrder: [.deviceLibrary: node.sortOrder], entries: [.deviceLibrary: items])
            }
            library.property = UsbProperty(deviceName: "", dbVersion: propertyRow?.version ?? "", numberOfContents: propertyRow?.count ?? 0,
                                           createdDate: "", backgroundColorType: 0, myTagMasterDBID: myTagMasterDBID,
                                           pdbDate: propertyRow?.date, pdbDeviceName: propertyRow?.name)
            return library.canonicalized()
        }
    }
}
