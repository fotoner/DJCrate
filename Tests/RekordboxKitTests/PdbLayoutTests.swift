import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 쪽 배치: 표마다 인덱스 쪽·빈 후보를 먼저 잡고, 정해진 순서로 표를 넣으며 후보를 데이터 쪽으로 쓰는 순간 새 후보를 잡는다.
/// 기대값은 모두 합성 모델에서 배치 규칙으로 계산한 것이다.
@Suite("Device Library 쪽 배치")
struct PdbLayoutTests {
    typealias Pointer = (type: UInt32, emptyCandidate: UInt32, first: UInt32, last: UInt32)

    static func pointers(_ file: PdbFile) -> [Pointer] {
        file.header.tables.map { ($0.type, $0.emptyCandidate, $0.firstPage, $0.lastPage) }
    }

    static func u32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + at + $1]) << (8 * $1) }
    }

    static func isZeroPage(_ data: Data, _ page: Int) -> Bool {
        data[(page * PdbPage.size)..<((page + 1) * PdbPage.size)].allSatisfy { $0 == 0 }
    }

    /// 분류 `categories`개와 분류마다 고르게 나눈 태그 `tags`개(이름은 `name`으로 짓는다)
    static func tags(categories: Int, tags: Int, name: (Bool, Int) -> String = { "\($0 ? "시험 분류" : "시험 태그") \($1)" }) -> [UsbMyTag] {
        var result: [UsbMyTag] = []
        for category in 0..<categories {
            result.append(UsbMyTag(id: Int64(1000 + category), parentID: 0, sequenceNo: category, name: name(true, category), isCategory: true))
        }
        for tag in 0..<tags {
            let parent = tag % categories
            result.append(UsbMyTag(id: Int64(2000 + tag), parentID: Int64(1000 + parent), sequenceNo: tag / categories,
                                   name: name(false, tag), isCategory: false))
        }
        return result
    }

    @Test func extTagsOnOnePage() throws {
        var model = PdbWriterTests.model()
        model.myTags = Self.tags(categories: 2, tags: 5)
        let data = try PdbWriter.files(model, mode: .fresh).exportExt
        let file = try PdbFile(data: data)
        let expected: [Pointer] = [(0, 2, 1, 1), (1, 4, 3, 3), (2, 6, 5, 5), (3, 20, 7, 8), (4, 10, 9, 9), (5, 12, 11, 11),
                                   (6, 14, 13, 13), (7, 19, 15, 16), (8, 18, 17, 17)]
        #expect(Self.pointers(file).map { [$0.0, $0.1, $0.2, $0.3] } == expected.map { [$0.0, $0.1, $0.2, $0.3] })
        #expect(file.header.nextUnusedPage == 21)
        #expect(data.count == 18 * PdbPage.size)
        for page in [2, 4, 6, 10, 12, 14] { #expect(Self.isZeroPage(data, page), "쪽 \(page)") }
        // 표 포인터 바이트 자리(0x1C + 16 × type)
        #expect(Self.u32(data, 0x1C + 16 * 3 + 4) == 20 && Self.u32(data, 0x1C + 16 * 3 + 12) == 8)
        #expect(try file.page(16).header.type == 7 && file.page(16).header.nextPage == 19)
        #expect(try file.page(8).header.type == 3 && file.page(8).header.nextPage == 20)
        #expect(try file.page(8).slots.count == 7)
    }

    @Test func extTagsOnTwoPages() throws {
        var model = PdbWriterTests.model()
        // 모두 ASCII 10자 이름 → 행 할당 52바이트
        model.myTags = Self.tags(categories: 2, tags: 78) { String(format: "%@%07d", $0 ? "cat" : "tag", $1) }
        #expect(PdbRowSize.tag(name: "tag0000001") == 52)
        let data = try PdbWriter.files(model, mode: .fresh).exportExt
        let file = try PdbFile(data: data)
        let tags = Self.pointers(file)[3]
        #expect([tags.0, tags.1, tags.2, tags.3] == [3, 21, 7, 20])
        let first = try file.page(8), second = try file.page(20)
        #expect(first.slots.count == 74 && second.slots.count == 6)
        #expect(first.header.nextPage == 20 && second.header.nextPage == 21)
        #expect(first.header.freeSize == 40)
        #expect(file.header.nextUnusedPage == 22)
        #expect(data.count == 21 * PdbPage.size)
        for page in [2, 4, 6, 10, 12, 14, 18, 19] { #expect(Self.isZeroPage(data, page), "쪽 \(page)") }
    }

    @Test func exportThreeTracksOnePageEach() throws {
        let data = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh).export
        let file = try PdbFile(data: data)
        // 표 → (데이터 쪽, 새 후보)
        let expected: [Int: (data: UInt32, candidate: UInt32)] = [
            19: (40, 41), 6: (14, 42), 16: (34, 43), 17: (36, 44), 18: (38, 45), 7: (16, 46), 2: (6, 47), 1: (4, 48),
            3: (8, 49), 5: (12, 50), 0: (2, 51), 13: (28, 52), 8: (18, 53),
        ]
        for pointer in file.header.tables {
            let type = Int(pointer.type)
            #expect(pointer.firstPage == UInt32(2 * type + 1), "표 \(type)")
            if let (page, candidate) = expected[type] {
                #expect(pointer.lastPage == page && pointer.emptyCandidate == candidate, "표 \(type)")
                #expect(try file.page(page).header.nextPage == candidate, "표 \(type)")
                #expect(try file.page(pointer.firstPage).header.nextPage == page, "표 \(type)")
            } else {
                // 빈 표(labels·9·10·11·12·14·15): 인덱스 쪽과 처음 잡은 후보
                #expect(pointer.lastPage == pointer.firstPage && pointer.emptyCandidate == UInt32(2 * type + 2), "표 \(type)")
            }
        }
        #expect(file.header.nextUnusedPage == 54)
        #expect(data.count == 41 * PdbPage.size)
        for page in [10, 20, 22, 24, 26, 30, 32] { #expect(Self.isZeroPage(data, page), "쪽 \(page)") }
        // 쪽 순번: 인덱스 쪽 1, 한 번에 쓰는 표 2…5, 그 뒤 닫는 순서, 표 19가 마지막
        let sequences: [UInt32: UInt32] = [14: 2, 34: 3, 36: 4, 38: 5, 16: 6, 6: 7, 4: 8, 8: 9, 12: 10, 2: 11, 28: 12, 18: 13, 40: 14]
        for (page, sequence) in sequences { #expect(try file.page(page).header.sequence == sequence, "쪽 \(page)") }
        for type in 0..<20 { #expect(try file.page(UInt32(2 * type + 1)).header.sequence == 1) }
        #expect(file.header.sequence == 15)
    }

    /// 12바이트 행은 쪽당 284개. 285번째 행에서 새 쪽
    @Test func fits284TwelveByteRows() throws {
        var model = PdbWriterTests.model()
        model.playlists[0].entries[.deviceLibrary] = (0..<285).map { $0 % 3 + 1 }
        let file = try PdbFile(data: try PdbWriter.files(model, mode: .fresh).export)
        let chain = try file.chain(of: file.header.tables[8])
        #expect(chain.count == 3)
        #expect(chain[1].slots.count == 284 && chain[2].slots.count == 1)
        #expect(chain[1].header.nextPage == chain[2].header.pageIndex)
        #expect(PdbPage.indexSize(slots: 284) + 12 * 284 <= PdbRowSize.pageCapacity)
        #expect(PdbPage.indexSize(slots: 285) + 12 * 285 > PdbRowSize.pageCapacity)
    }

    /// 후보 쪽을 데이터 쪽으로 쓰면 그때 다음 번호를 새 후보로 잡는다
    @Test func newCandidateOnConsume() {
        let layout = PdbLayout(kind: .exportExt, rows: [7: [PdbEncodedRow(bytes: Data(count: 60), hasIndexShift: true, rules: [])]])
        #expect(layout.dataPages[7]?.map(\.number) == [16])
        #expect(layout.candidates[7] == 19)
        #expect(layout.candidates[3] == 8)
        #expect(layout.nextUnused == 20)
        #expect(layout.pageCount == 18)
    }
}
