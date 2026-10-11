import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 있는 파일의 쪽을 칸 값만으로 다시 만들어 비교한다(lab pdb-verify)
@Suite("Device Library 쪽 다시 만들기 비교")
struct PdbPageCheckTests {
    /// 조립기의 행에 작성기와 같은 tx 모양을 준다(표마다 쪽 하나일 때): 한 번에 쓰는 표는 모든 자리, 나머지는 마지막 자리만
    static func writerShaped(_ builder: PdbBuilder) -> PdbBuilder {
        var builder = builder
        for (type, rows) in builder.tables {
            let bulk = PdbLayout.shape(builder.kind, type) == .bulk
            builder.tables[type] = rows.enumerated().map { index, row in
                var row = row
                row.inTransaction = bulk || index == rows.count - 1
                return row
            }
        }
        return builder
    }

    @Test func writerOutputIsReproducedPageByPage() throws {
        var model = PdbWriterTests.model()
        model.myTags = PdbLayoutTests.tags(categories: 2, tags: 5)
        model.labels = [UsbNamedRow(id: 1, name: "시험 레이블")]
        model.tracks[0].labelID = 1
        let files = try PdbWriter.files(model, mode: .edit(previousExportSequence: 40, previousExtSequence: 3))
        for data in [files.export, files.exportExt] {
            let report = try PdbPageCheck.check(data)
            #expect(report.compared.filter { !$0.isSame }.isEmpty)
            #expect(report.excluded.isEmpty)
            #expect(report.compared.count == report.pageCount)
            #expect(report.count(.header).same == 1 && report.count(.header).total == 1)
            #expect(report.count(.zero).total > 0 && report.count(.data).total > 0)
        }
        let index = try PdbPageCheck.check(files.exportExt).count(.index)
        #expect(index.same == 9 && index.total == 9)
    }

    @Test func reportsDifferingRowsAndExcludedPages() throws {
        var files = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        let export = try PdbFile(data: files.export)
        // 트랙 행 하나의 할당 끝 빈 바이트를 채운다(칸 값은 그대로라 다시 만든 행은 0이다)
        let page = try #require(PdbWriterTests.dataPages(export, 0).first)
        let row = page.row(page.slots[1])
        let at = Int(page.header.pageIndex) * PdbPage.size + PdbPage.heapStart + page.slots[1].offset + row.count - 1
        files.export[at] = 0x01
        let report = try PdbPageCheck.check(files.export)
        let differing = report.compared.filter { !$0.isSame }
        #expect(differing.map(\.number) == [Int(page.header.pageIndex)])
        #expect(differing.first?.table == "tracks" && differing.first?.category == .data)
        #expect(differing.first?.firstDifference == PdbPage.heapStart + page.slots[1].offset + row.count - 1)
        #expect(differing.first?.rows == [PdbPageCheck.RowDifference(slot: 1, originalSize: row.count, rebuiltSize: row.count,
                                                                      firstDifference: row.count - 1)])

        // 제자리 수정 이력(지운 행)이 있는 쪽과 지운 쪽 목록이 있는 인덱스 쪽은 뺀다
        let edited = Self.writerShaped(PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks()) { builder in
            var dead = PdbTrackSpec(id: 9)
            dead[.fileName] = "test9.mp3"
            builder.add(.tracks, PdbBuilder.Row(PdbBuilder.trackRow(dead).bytes, live: false, hasIndexShift: true))
        }).build()
        let editedReport = try PdbPageCheck.check(edited.data)
        #expect(editedReport.excluded.map(\.reason).sorted() == ["deadRows", "indexEntries"])
        #expect(editedReport.excluded.allSatisfy { $0.table == "tracks" })
    }

    /// 지운 행은 없어도 쪽 머리 0x20·0x22가 한 번에 씀·덧붙임 어느 모양도 아닌 쪽은 제자리 수정 이력이라 뺀다.
    /// 행 하나인 쪽은 두 모양이 같다
    @Test func inPlaceShapePagesAreExcluded() throws {
        let files = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        let export = try PdbFile(data: files.export)
        let tracks = try #require(PdbWriterTests.dataPages(export, PdbTableType.tracks.rawValue).first)
        let columns = try #require(PdbWriterTests.dataPages(export, PdbTableType.columns.rawValue).first)
        #expect(tracks.slots.count > 1 && columns.slots.count > 1)
        var data = files.export
        // 덧붙임 쪽의 0x22(마지막 자리)를 0으로, 한 번에 쓴 쪽의 0x20(자리 수)을 1로
        let tracksBase = Int(tracks.header.pageIndex) * PdbPage.size, columnsBase = Int(columns.header.pageIndex) * PdbPage.size
        data.replaceSubrange((tracksBase + 0x22)..<(tracksBase + 0x24), with: [0, 0])
        data.replaceSubrange((columnsBase + 0x20)..<(columnsBase + 0x22), with: [1, 0])
        let report = try PdbPageCheck.check(data)
        #expect(Set(report.excluded) == [
            PdbPageCheck.Excluded(number: Int(tracks.header.pageIndex), table: "tracks", reason: "inPlaceShape"),
            PdbPageCheck.Excluded(number: Int(columns.header.pageIndex), table: "columns", reason: "inPlaceShape"),
        ])
        #expect(report.compared.filter { !$0.isSame }.isEmpty)
        #expect(report.compared.count + report.excluded.count == report.pageCount)
        // 행 하나인 쪽(표 19)은 비교한다
        let history = try #require(PdbWriterTests.dataPages(export, PdbTableType.history19.rawValue).first)
        #expect(history.slots.count == 1)
        #expect(report.compared.contains { $0.number == Int(history.header.pageIndex) && $0.category == .data })
    }

    @Test func differentAllocationIsReportedPerRow() throws {
        // 합성 조립기는 행을 4바이트 경계까지만 할당한다(작성기 규칙보다 작다) → 행 크기가 다르다고 보고한다
        let built = Self.writerShaped(PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks())).build()
        let report = try PdbPageCheck.check(built.data)
        let tracks = try #require(report.compared.first { $0.table == "tracks" && $0.category == .data })
        #expect(!tracks.isSame)
        #expect(tracks.rows.contains { $0.originalSize != $0.rebuiltSize })
        // 해석할 수 없는 행은 -1
        var broken = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks())
        broken.tables[PdbTableType.genres.rawValue] = [PdbBuilder.opaqueRow(8, fill: 0xFF)]
        let brokenReport = try PdbPageCheck.check(Self.writerShaped(broken).build().data)
        #expect(brokenReport.compared.contains { $0.table == "genres" && $0.firstDifference == -1 && $0.rebuildFailure == .rowUnreadable })
    }

    /// 다시 만든 행이 원본보다 커서(합성 행은 4바이트 경계까지만, 작성기는 + 4) 한 쪽에 들어가지 않아도 죽지 않고 다시 만들지 못한 쪽으로 보고한다
    @Test func rebuiltRowsThatDoNotFitArePageFailure() throws {
        var builder = PdbReadTests.sampleExport(tracks: PdbRoundTripTests.sampleTracks())
        // 원본 132바이트 × 30행은 한 쪽에 들어가고, 다시 만든 140바이트 × 30행은 들어가지 않는다
        builder.tables[PdbTableType.artists.rawValue] = (1...30).map { PdbBuilder.artistRow($0, String(repeating: "g", count: 120)) }
        let built = Self.writerShaped(builder).build()
        let pages = try #require(built.dataPages[PdbTableType.artists.rawValue])
        #expect(pages.count == 1)
        let report = try PdbPageCheck.check(built.data)
        let artists = try #require(report.compared.first { $0.number == pages[0] })
        #expect(artists.category == .data && artists.table == "artists")
        #expect(artists.firstDifference == -1 && artists.rebuildFailure == .rowsDoNotFit)
        // 행마다 커진 크기를 남긴다
        #expect(artists.rows.count == 30)
        #expect(artists.rows.allSatisfy { $0.rebuiltSize > $0.originalSize })
    }
}
