import DJCDomain
import Foundation

/// 표 하나를 사슬로 따라간 결과
public struct PdbTableScan: Sendable {
    public var pointer: PdbTablePointer
    public var name: String
    /// 인덱스 쪽부터 사슬 순서. 문제가 나면 그 앞까지
    public var pages: [PdbPage]
    public var issues: [PdbIssue]

    /// 데이터 쪽의 (쪽, 자리). 인덱스 쪽은 자리가 없다
    public var slots: [(page: PdbPage, slot: PdbRowSlot)] {
        pages.flatMap { page in page.slots.map { (page, $0) } }
    }

    public var liveRows: Int { pages.reduce(0) { $0 + $1.slots.filter(\.isLive).count } }
    public var slotCount: Int { pages.reduce(0) { $0 + $1.slots.count } }
}

/// Device Library 파일 하나(4096바이트 쪽 배열, 쪽 0 = 파일 머리, 모든 정수 little-endian)
public struct PdbFile: Sendable {
    public let header: PdbFileHeader
    public let data: Data
    public let kind: PdbFileKind

    /// 머리만 검사한다: 쪽 크기 4096, 표 수 20(export)·9(exportExt), 표 포인터가 파일 안
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count >= 0x1C else { throw UsbError.readFailed(detail: "pdb file too short (\(data.count) bytes)") }
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        let pageSize = u32(0x04), numTables = u32(0x08)
        guard pageSize == UInt32(PdbPage.size) else { throw UsbError.readFailed(detail: "pdb page size \(pageSize)") }
        guard let kind = PdbFileKind(tableCount: numTables) else { throw UsbError.readFailed(detail: "pdb table count \(numTables)") }
        guard data.count >= PdbPage.size, 0x1C + 16 * Int(numTables) <= PdbPage.size else {
            throw UsbError.readFailed(detail: "pdb file too short (\(data.count) bytes)")
        }
        let tables = (0..<Int(numTables)).map { index in
            let at = 0x1C + 16 * index
            return PdbTablePointer(type: u32(at), emptyCandidate: u32(at + 4), firstPage: u32(at + 8), lastPage: u32(at + 12))
        }
        header = PdbFileHeader(pageSize: pageSize, numTables: numTables, nextUnusedPage: u32(0x0C), flag10: u32(0x10),
                               sequence: u32(0x14), gap: u32(0x18), tables: tables)
        self.data = data
        self.kind = kind
    }

    /// 파일 안 쪽 수(끝의 모자란 쪽은 세지 않음)
    public var pageCount: Int { data.count / PdbPage.size }

    /// 쪽 `number`. 파일 밖이면 `UsbError.readFailed`
    public func page(_ number: UInt32) throws -> PdbPage {
        guard Int(number) < pageCount else { throw UsbError.readFailed(detail: "pdb page \(number) outside file") }
        let start = Int(number) * PdbPage.size
        return try PdbPage(data: data[start..<(start + PdbPage.size)])
    }

    /// 인덱스 쪽 → next … → empty_candidate 전까지. 구조 문제가 하나라도 있으면 `UsbError.readFailed`
    public func chain(of pointer: PdbTablePointer) throws -> [PdbPage] {
        let scan = walk(pointer)
        if let issue = scan.issues.first { throw UsbError.readFailed(detail: "pdb chain: \(issue)") }
        return scan.pages
    }

    /// 사슬을 따라가며 문제를 모은다(멈추지 않음). 문제가 난 쪽 앞까지를 돌려준다.
    public func walk(_ pointer: PdbTablePointer) -> PdbTableScan {
        let name = kind.tableName(pointer.type)
        var scan = PdbTableScan(pointer: pointer, name: name, pages: [], issues: [])
        var visited: Set<UInt32> = []
        var current = pointer.firstPage
        func issue(_ kind: PdbIssue.Kind, _ page: UInt32) {
            scan.issues.append(PdbIssue(kind: kind, table: name, page: Int(page)))
        }
        while current != pointer.emptyCandidate {
            guard visited.insert(current).inserted else { issue(.cycle, current); return scan }
            guard Int(current) < pageCount else { issue(.pageOutsideFile, current); return scan }
            let page: PdbPage
            do {
                page = try self.page(current)
            } catch {
                issue(.pageUnreadable, current)
                return scan
            }
            guard page.header.pageIndex == current else { issue(.pageIndexMismatch, current); return scan }
            guard page.header.type == pointer.type else { issue(.pageTypeMismatch, current); return scan }
            scan.pages.append(page)
            current = page.header.nextPage
        }
        if scan.pages.last?.header.pageIndex != pointer.lastPage {
            issue(.lastPageMismatch, scan.pages.last?.header.pageIndex ?? pointer.firstPage)
        }
        return scan
    }
}
