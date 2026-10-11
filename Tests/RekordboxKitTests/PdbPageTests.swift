import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("Device Library 쪽·행 인덱스")
struct PdbPageTests {
    /// 표 하나에 행을 넣은 파일을 조립하고 그 표의 쪽들을 돌려준다
    func pages(_ rows: [PdbBuilder.Row], table: PdbTableType = .playlistEntries) throws -> (PdbFile, PdbBuilder.Built, [PdbPage]) {
        var builder = PdbBuilder(kind: .export)
        for row in rows { builder.add(table, row) }
        let built = builder.build()
        let file = try PdbFile(data: built.data)
        let pointer = try #require(file.header.tables.first { $0.type == UInt32(table.rawValue) })
        return (file, built, try file.chain(of: pointer))
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func packedRowCounts() throws {
        #expect(PdbPage.packRowCounts(slots: 7, live: 6) == Data([0x07, 0xC0, 0x00]))
        #expect(PdbPage.packRowCounts(slots: 284, live: 284) == Data([0x1C, 0x81, 0x23]))
        #expect(PdbPage.unpackRowCounts(Data([0x1C, 0x81, 0x23])) == (slots: 284, live: 284))
        #expect(PdbPage.unpackRowCounts(Data([0x07, 0xC0, 0x00])) == (slots: 7, live: 6))

        // 255행을 넘는 쪽: u8로 읽으면 행을 잃는다
        let rows = (1...284).map { PdbBuilder.playlistEntryRow(index: $0, trackID: $0, playlistID: 1) }
        let (_, _, chain) = try pages(rows)
        #expect(chain.count == 2)
        let page = chain[1]
        #expect(page.header.rowSlots == 284 && page.header.liveRows == 284)
        #expect(page.slots.count == 284 && page.slots.allSatisfy(\.isLive))
    }

    @Test func presenceAndTxBits() throws {
        // 20자리: 15·16·17 경계, 마지막 덜 찬 그룹(16–19)
        let rows = (0..<20).map { slot in
            PdbBuilder.Row(PdbBuilder.playlistEntryRow(index: slot + 1, trackID: slot + 1, playlistID: 1).bytes,
                           live: ![15, 17, 19].contains(slot), inTransaction: [15, 16, 18].contains(slot))
        }
        let (_, _, chain) = try pages(rows)
        let page = chain[1]
        #expect(page.header.rowSlots == 20 && page.header.liveRows == 17)
        #expect(page.slots.map(\.index) == Array(0..<20))
        #expect(page.slots.filter { !$0.isLive }.map(\.index) == [15, 17, 19])
        #expect(page.slots.filter(\.inTransaction).map(\.index) == [15, 16, 18])
        #expect(page.slots.map(\.offset) == (0..<20).map { $0 * 12 })
        // 행 범위: 다음 자리 오프셋까지, 마지막은 used까지
        #expect(page.row(page.slots[0]).count == 12)
        #expect(page.row(page.slots[19]).count == 12)
        #expect(page.row(page.slots[16]) == PdbBuilder.playlistEntryRow(index: 17, trackID: 17, playlistID: 1).bytes)
    }

    @Test func flags24_34_64() throws {
        let live = (1...3).map { PdbBuilder.playlistEntryRow(index: $0, trackID: $0, playlistID: 1) }
        var withDead = live
        withDead[1].live = false
        let (_, _, clean) = try pages(live)
        let (_, _, dirty) = try pages(withDead)
        #expect(clean[0].header.flags == 0x64 && clean[0].header.isIndex)
        #expect(clean[0].slots.isEmpty)
        #expect(clean[1].header.flags == 0x24 && !clean[1].header.isIndex)
        #expect(dirty[1].header.flags == 0x34)
        #expect(dirty[1].header.liveRows == 2 && dirty[1].header.rowSlots == 3)
        // 인덱스 쪽: 첫 데이터 쪽, 지운 행이 있는 쪽 목록
        #expect(clean[0].header.nextPage == clean[1].header.pageIndex)
        #expect(dirty[0].header.u7 == 1 && clean[0].header.u7 == 0)
    }

    @Test func freeFormula() throws {
        func formula(_ used: Int, _ slots: Int) -> Int { 4096 - 0x28 - used - 2 * slots - 4 * ((slots + 15) / 16) }
        for (used, slots) in [(0, 0), (12, 1), (192, 16), (204, 17), (3408, 284)] {
            #expect(PdbPage.freeSize(used: used, slots: slots) == formula(used, slots))
        }
        #expect(PdbPage.indexSize(slots: 17) == 2 * 17 + 8)
        let rows = (1...17).map { PdbBuilder.playlistEntryRow(index: $0, trackID: $0, playlistID: 1) }
        let (_, _, chain) = try pages(rows)
        let header = chain[1].header
        #expect(Int(header.usedSize) == 17 * 12)
        #expect(Int(header.freeSize) == formula(17 * 12, 17))
    }

    @Test func headerFieldsAndChain() throws {
        let rows = (1...300).map { PdbBuilder.playlistEntryRow(index: $0, trackID: $0, playlistID: 1) }
        let (file, built, chain) = try pages(rows)
        #expect(file.header.pageSize == 4096 && file.header.numTables == 20)
        #expect(file.header.tables.map(\.type) == (0..<20).map(UInt32.init))
        let pointer = file.header.tables[PdbTableType.playlistEntries.rawValue]
        let table = PdbTableType.playlistEntries.rawValue
        #expect(Int(pointer.firstPage) == built.indexPages[table])
        #expect(Int(pointer.lastPage) == built.dataPages[table]?.last)
        #expect(Int(pointer.emptyCandidate) == built.candidates[table])
        #expect(chain.map { Int($0.header.pageIndex) } == [built.indexPages[table]!] + built.dataPages[table]!)
        #expect(chain.last?.header.nextPage == pointer.emptyCandidate)
        #expect(chain.dropFirst().map(\.header.liveRows) == [284, 16])
        // 쪽 순번은 파일 머리 순번보다 작다
        #expect(chain.allSatisfy { $0.header.sequence < file.header.sequence })
        // 파일 끝 너머 후보까지 다음 쪽 번호에 든다
        #expect(Int(file.header.nextUnusedPage) * 4096 > built.data.count)
    }

    @Test func fileHeaderChecked() throws {
        var bad = PdbBuilder(kind: .export).build().data
        bad[4] = 0x00
        bad[5] = 0x08
        #expect(throws: UsbError.self) { try PdbFile(data: bad) }
        var tables = PdbBuilder(kind: .export).build().data
        tables[8] = 5
        #expect(throws: UsbError.self) { try PdbFile(data: tables) }
        #expect(throws: UsbError.self) { try PdbFile(data: Data(count: 100)) }
        // 쪽 하나 크기가 아니면 쪽 읽기 오류
        #expect(throws: UsbError.self) { try PdbPage(data: Data(count: 100)) }
    }

    @Test func strictChainThrowsOnBrokenLink() throws {
        var builder = PdbBuilder(kind: .export)
        builder.add(.genres, PdbBuilder.idNameRow(1, "시험 장르"))
        var built = builder.build()
        let table = PdbTableType.genres.rawValue
        built.setU32(page: built.indexPages[table]!, offset: 0x0C, 99_999)
        let file = try PdbFile(data: built.data)
        let pointer = file.header.tables[table]
        #expect(throws: UsbError.self) { try file.chain(of: pointer) }
        let scan = file.walk(pointer)
        #expect(scan.pages.count == 1)
        #expect(scan.issues.map(\.kind) == [.pageOutsideFile])
    }
}
