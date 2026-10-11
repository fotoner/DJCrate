import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 작성기가 늘 지키는 파일 모양. 규칙마다 한 시험.
@Suite("Device Library 쓰기 거부·주의 목록")
struct PdbRejectionTests {
    static func files(_ model: UsbLibrary = PdbWriterTests.model()) throws -> (PdbFile, PdbFile) {
        let files = try PdbWriter.files(model, mode: .fresh)
        return (try PdbFile(data: files.export), try PdbFile(data: files.exportExt))
    }

    /// 모든 쪽 사슬을 따라가며 확인한다(구조 문제가 있으면 던진다)
    static func pages(_ file: PdbFile) throws -> [PdbPage] {
        try file.header.tables.flatMap { try file.chain(of: $0) }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func headerSequenceAboveAllPages() throws {
        for mode in [PdbWriteMode.fresh, .edit(previousExportSequence: 7, previousExtSequence: 9)] {
            let files = try PdbWriter.files(PdbWriterTests.model(), mode: mode)
            for data in [files.export, files.exportExt] {
                let file = try PdbFile(data: data)
                #expect(try Self.pages(file).allSatisfy { $0.header.sequence < file.header.sequence })
            }
        }
    }

    /// 옛 머리 순번이 u32 끝에 가까우면 새 순번이 넘친다: 죽지 않고 막는다. 머리가 끝에 딱 맞으면 쓴다
    @Test func editSequenceOverflowIsRefused() throws {
        let fresh = try PdbWriter.files(PdbWriterTests.model(), mode: .fresh)
        let exportTop = try PdbFile(data: fresh.export).header.sequence, extTop = try PdbFile(data: fresh.exportExt).header.sequence
        for mode in [PdbWriteMode.edit(previousExportSequence: .max - 2, previousExtSequence: 0),
                     .edit(previousExportSequence: 0, previousExtSequence: .max),
                     .edit(previousExportSequence: .max, previousExtSequence: .max),
                     .edit(previousExportSequence: .max - exportTop + 1, previousExtSequence: 0),
                     .edit(previousExportSequence: 0, previousExtSequence: .max - extTop + 1)] {
            do {
                _ = try PdbWriter.files(PdbWriterTests.model(), mode: mode)
                Issue.record("순번이 넘치는 파일을 만들었다: \(mode)")
            } catch let UsbError.writeRefused(blocks) {
                #expect(blocks.map(\.code) == ["pdbSequenceOverflow"])
            } catch {
                Issue.record("\(error)")
            }
        }
        let edge = try PdbWriter.files(PdbWriterTests.model(), mode: .edit(previousExportSequence: .max - exportTop,
                                                                          previousExtSequence: .max - extTop))
        #expect(try PdbFile(data: edge.export).header.sequence == .max)
        #expect(try PdbFile(data: edge.exportExt).header.sequence == .max)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func headerFlag10Is5() throws {
        let (export, ext) = try Self.files()
        #expect(export.header.flag10 == 5 && ext.header.flag10 == 5)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func emptyTablesHaveIndexAndCandidate() throws {
        let (export, ext) = try Self.files()
        for file in [export, ext] {
            #expect(file.header.tables.map(\.type) == (0..<file.header.numTables).map { $0 })
            var used: Set<UInt32> = []
            for pointer in file.header.tables {
                let chain = try file.chain(of: pointer)
                #expect(chain.first?.header.isIndex == true)
                #expect(pointer.emptyCandidate != pointer.firstPage && pointer.emptyCandidate >= 1)
                for page in chain { #expect(used.insert(page.header.pageIndex).inserted) }
            }
            // 빈 표의 인덱스 쪽은 후보를 가리키고, 본문 첫 데이터 쪽 칸은 0x03FFFFFF
            for pointer in file.header.tables where pointer.firstPage == pointer.lastPage {
                let index = try file.page(pointer.firstPage)
                #expect(index.header.nextPage == pointer.emptyCandidate)
                #expect(PdbWriterTests.u32(index.data, 0x2C) == 0x03FF_FFFF)
            }
        }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func history19HasOneLiveRow() throws {
        let (library, report) = try PdbReader.read(export: PdbWriter.files(PdbWriterTests.model(), mode: .fresh).export, exportExt: nil)
        #expect(report.tableCounts["history19"]?.live == 1 && report.tableCounts["history19"]?.slots == 1)
        #expect(library.property.numberOfContents == 3 && library.property.dbVersion == "1000")
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func columnsRowShape() throws {
        let (export, _) = try Self.files()
        for row in try PdbWriterTests.rows(export, 16) {
            // u16 id, u16 kind, @0x04 UTF-16(U+FFFA … U+FFFB), 4바이트 경계까지
            #expect(row[4] == 0x90 && row.count % 4 == 0)
            let name = try PdbStringDecoder.decode(row, at: 4)
            #expect(name.value.first == "\u{FFFA}" && name.value.last == "\u{FFFB}")
            #expect(row.count == (4 + name.byteLength + 3) / 4 * 4)
        }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func utf16AlignedInRows() throws {
        var model = PdbWriterTests.model()
        model.tracks[0].isrc = "ZZ0000000001"
        model.tracks[0].lyricist = "시험"
        model.artists.append(UsbNamedRow(id: 2, name: "é"))
        model.albums.append(UsbAlbum(id: 2, name: "é"))
        model.myTags = [UsbMyTag(id: 1, parentID: 0, sequenceNo: 0, name: "시", isCategory: true)]
        let files = try PdbWriter.files(model, mode: .fresh)
        let (_, report) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(report.misalignedUTF16 == 0)
        #expect((report.stringKinds["utf16LE"] ?? 0) >= 5 && report.stringKinds["isrc"] == 1)
        #expect(report.issues.isEmpty)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func noFileWithoutTracks() {
        var model = PdbWriterTests.model()
        model.tracks = []
        do {
            _ = try PdbWriter.files(model, mode: .fresh)
            Issue.record("곡 없는 파일을 만들었다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["pdbNoTracks"])
        } catch {
            Issue.record("\(error)")
        }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func fileTypeEqualsExtension() throws {
        let (export, _) = try Self.files()
        for row in try PdbWriterTests.rows(export, 0) {
            let name = try PdbStringDecoder.decode(row, at: PdbWriterTests.u16(row, 0x5E + 2 * 19)).value
            #expect(PdbWriterTests.u16(row, 0x5A) == 1 && name.hasSuffix(".mp3"))
        }
        var model = PdbWriterTests.model()
        model.tracks[0].fileType = 0
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func trackRowsAtLeast224() throws {
        var model = PdbWriterTests.model()
        model.tracks[0] = UsbTrack(id: 1, presentIn: [.deviceLibrary], fileName: "a.mp3", fileType: 1)
        let (export, _) = try Self.files(model)
        let page = try #require(PdbWriterTests.dataPages(export, 0).first)
        let sizes = zip(page.slots, page.slots.dropFirst()).map { $1.offset - $0.offset } + [Int(page.header.usedSize) - page.slots.last!.offset]
        #expect(sizes.allSatisfy { $0 >= 224 })
        #expect(sizes.first == PdbRowSize.track(model.tracks[0], library: model))
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func lastPageNextIsEmptyCandidate() throws {
        var model = PdbWriterTests.model()
        model.playlists[0].entries[.deviceLibrary] = (0..<600).map { $0 % 3 + 1 }
        let (export, ext) = try Self.files(model)
        for file in [export, ext] {
            for pointer in file.header.tables {
                let chain = try file.chain(of: pointer)
                #expect(chain.last?.header.pageIndex == pointer.lastPage)
                #expect(chain.last?.header.nextPage == pointer.emptyCandidate)
                // 후보는 0으로 채운 쪽이거나 파일 끝 너머
                if Int(pointer.emptyCandidate) < file.pageCount {
                    let start = Int(pointer.emptyCandidate) * PdbPage.size
                    #expect(file.data[start..<(start + PdbPage.size)].allSatisfy { $0 == 0 })
                }
                #expect(pointer.emptyCandidate < file.header.nextUnusedPage)
            }
        }
        #expect(try PdbWriterTests.dataPages(export, 8).count == 3)
    }
}
