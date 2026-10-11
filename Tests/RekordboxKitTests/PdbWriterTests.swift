import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("Device Library 쓰기")
struct PdbWriterTests {
    // MARK: - 합성 모델(모든 값은 지어낸 것)

    static func track(_ id: Int) -> UsbTrack {
        UsbTrack(
            id: id, presentIn: [.deviceLibrary], title: "시험 곡 \(id)", subtitle: "", bpmx100: 12800 + id, lengthSeconds: 200 + id,
            trackNo: id, discNo: 1, artistID: 1, albumID: 1, genreID: 1, keyID: 1, colorID: 0, imageID: id,
            comment: "시험 코멘트", releaseYear: 2020, dateCreated: "2026-01-01", dateAdded: "2026-01-02",
            path: "/Contents/시험 아티스트/시험 앨범/test\(id).mp3", fileName: "test\(id).mp3", fileSize: 1_000_000 + Int64(id), fileType: 1,
            bitrate: 320, bitDepth: 16, sampleRate: 44100, hotCueAutoLoad: true, masterDbId: 1_000_001, masterContentId: 900_000 + Int64(id),
            analysisDataPath: String(format: "/PIONEER/USBANLZ/P000/%08X/ANLZ0000.DAT", id),
            cueUpdateCount: "0", analysisDataUpdateCount: "0", informationUpdateCount: "0",
            deviceFields: [.deviceLibrary: UsbTrackDeviceFields(rating: 0, playCount: 0, hasModified: nil)])
    }

    /// 곡 `tracks`개, 아티스트·앨범·장르·키 하나, 색 8, 목록 하나, 아트워크, 메뉴 3·카테고리 2·정렬 2. 레이블·기록은 없다
    static func model(tracks: Int = 3) -> UsbLibrary {
        let ids = Array(1...tracks)
        return UsbLibrary(
            formats: [.deviceLibrary],
            property: UsbProperty(dbVersion: "1000", numberOfContents: tracks, myTagMasterDBID: 123_456, pdbDate: "2026-01-03", pdbDeviceName: ""),
            tracks: ids.map(track), artists: [UsbNamedRow(id: 1, name: "시험 아티스트")], albums: [UsbAlbum(id: 1, name: "시험 앨범", artistID: 1)],
            genres: [UsbNamedRow(id: 1, name: "Genre")], keys: [UsbNamedRow(id: 1, name: "8A")],
            colors: ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"].enumerated().map { UsbNamedRow(id: $0 + 1, name: $1) },
            images: ids.map { UsbImage(id: $0, pdbPath: String(format: "/PIONEER/Artwork/00001/a%d.jpg", $0)) },
            playlists: [UsbPlaylist(id: 1, name: "시험 목록", parentID: 0, attribute: 0, presentIn: [.deviceLibrary],
                                    sortOrder: [.deviceLibrary: 0], entries: [.deviceLibrary: ids.reversed()])],
            menuItems: [UsbMenuItem(id: 1, kind: 257, name: "시험 메뉴"), UsbMenuItem(id: 2, kind: 258, name: "MENU"),
                        UsbMenuItem(id: 3, kind: 259, name: "시험 메뉴 3")],
            categories: [UsbCategory(id: 1, menuItemID: 2, sequenceNo: 2, isVisible: true, infoOrder: 1, disable: 0),
                         UsbCategory(id: 2, menuItemID: 1, sequenceNo: 1, isVisible: false, infoOrder: 0, disable: 1)],
            sorts: [UsbSort(id: 1, menuItemID: 3, sequenceNo: 2, isVisible: true, isSelectedAsSubColumn: true, disable: 2),
                    UsbSort(id: 2, menuItemID: 1, sequenceNo: 1, isVisible: false, isSelectedAsSubColumn: false, disable: 1)])
    }

    static func write(_ model: UsbLibrary = model(), mode: PdbWriteMode = .fresh) throws -> (PdbFiles, PdbFile, PdbFile) {
        let files = try PdbWriter.files(model, mode: mode)
        return (files, try PdbFile(data: files.export), try PdbFile(data: files.exportExt))
    }

    /// 표의 데이터 쪽(사슬 순서, 인덱스 쪽 뺌)
    static func dataPages(_ file: PdbFile, _ type: Int) throws -> [PdbPage] {
        Array(try file.chain(of: file.header.tables[type]).dropFirst())
    }

    /// 표의 행 바이트(자리 순서)
    static func rows(_ file: PdbFile, _ type: Int) throws -> [Data] {
        try dataPages(file, type).flatMap { page in page.slots.map { page.row($0) } }
    }

    static func u16(_ data: Data, _ at: Int) -> Int {
        Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8
    }

    static func u32(_ data: Data, _ at: Int) -> Int64 {
        (0..<4).reduce(Int64(0)) { $0 | Int64(data[data.startIndex + at + $1]) << (8 * $1) }
    }

    static func allPages(_ file: PdbFile) throws -> [PdbPage] {
        try file.header.tables.flatMap { try file.chain(of: $0) }
    }

    // MARK: - 파일·쪽 머리

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func headerFlag5_seqGreaterThanAll() throws {
        let (_, export, ext) = try Self.write()
        for file in [export, ext] {
            #expect(file.header.flag10 == 5)
            #expect(file.header.gap == 0)
            let maxSequence = try Self.allPages(file).map(\.header.sequence).max() ?? 0
            #expect(file.header.sequence == maxSequence + 1)
            #expect(Array(file.data[0..<4]) == [0, 0, 0, 0])
            let tail = 0x1C + 16 * Int(file.header.numTables)
            #expect(file.data[tail..<PdbPage.size].allSatisfy { $0 == 0 })
        }
        #expect(export.header.numTables == 20 && ext.header.numTables == 9)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func indexPageShape() throws {
        let (_, export, _) = try Self.write()
        for pointer in export.header.tables {
            let page = try export.page(pointer.firstPage)
            let bytes = page.data
            let firstData = try Self.dataPages(export, Int(pointer.type)).first?.header.pageIndex
            #expect(page.header.flags == 0x64 && page.header.pageIndex == pointer.firstPage && page.header.type == pointer.type)
            #expect(page.header.nextPage == firstData ?? pointer.emptyCandidate)
            #expect(page.header.txRowCount == 0x1FFF && page.header.txRowIndex == 0x1FFF)
            #expect(page.header.u6 == 0x03EC && page.header.u7 == 0)
            #expect(page.header.rowSlots == 0 && page.header.liveRows == 0 && page.header.freeSize == 0 && page.header.usedSize == 0)
            #expect(Self.u32(bytes, 0x28) == Int64(pointer.firstPage))
            #expect(Self.u32(bytes, 0x2C) == Int64(firstData ?? 0x03FF_FFFF))
            #expect(Self.u32(bytes, 0x30) == 0x03FF_FFFF && Self.u32(bytes, 0x34) == 0)
            #expect(Self.u16(bytes, 0x38) == 0 && Self.u16(bytes, 0x3A) == 0x1FFF)
            #expect((0..<1004).allSatisfy { Self.u32(bytes, 0x3C + 4 * $0) == 0x1FFF_FFF8 })
            #expect(bytes[0xFEC..<0x1000].allSatisfy { $0 == 0 })
            #expect(Array(bytes[0..<4]) == [0, 0, 0, 0] && Self.u32(bytes, 0x14) == 0)
        }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func dataPageShapes() throws {
        var model = Self.model()
        model.artists += [UsbNamedRow(id: 2, name: "Artist 2"), UsbNamedRow(id: 3, name: "Artist 3")]
        let (_, export, ext) = try Self.write(model)
        // 한 번에 씀(colors): tx 수 = 자리 수, 첫 자리 0, tx 비트 = presence 비트
        let colors = try #require(Self.dataPages(export, 6).first)
        #expect(colors.header.txRowCount == 8 && colors.header.txRowIndex == 0)
        #expect(colors.slots.allSatisfy { $0.isLive && $0.inTransaction })
        // 한 행씩 덧붙임(artists): tx 수 1, 마지막 자리 하나만
        let artists = try #require(Self.dataPages(export, 2).first)
        #expect(artists.header.txRowCount == 1 && artists.header.txRowIndex == 2)
        #expect(artists.slots.map(\.inTransaction) == [false, false, true])
        // 행 하나인 쪽은 두 모양이 같다
        let property = try #require(Self.dataPages(export, 19).first)
        #expect(property.header.txRowCount == 1 && property.header.txRowIndex == 0 && property.slots.map(\.inTransaction) == [true])
        let myTagProperty = try #require(Self.dataPages(ext, 7).first)
        #expect(myTagProperty.header.txRowCount == 1 && myTagProperty.header.txRowIndex == 0)
        for page in try Self.allPages(export) + Self.allPages(ext) where !page.header.isIndex {
            #expect(page.header.flags == 0x24 && page.header.u6 == 0 && page.header.u7 == 0 && page.header.u2 == 0)
            #expect(page.header.rowSlots == page.header.liveRows && page.slots.allSatisfy(\.isLive))
            #expect(page.header.txRowCount != 0x1FFF)
        }
    }

    @Test func freeFormulaHolds() throws {
        let (_, export, ext) = try Self.write()
        for page in try Self.allPages(export) + Self.allPages(ext) where !page.header.isIndex {
            let slots = page.header.rowSlots, used = Int(page.header.usedSize)
            #expect(Int(page.header.freeSize) == 4096 - 0x28 - used - 2 * slots - 4 * ((slots + 15) / 16))
            // 힙 = 행 할당 크기의 합, 힙과 행 인덱스 사이는 0
            let offsets = page.slots.map(\.offset)
            #expect(offsets.first == 0 && offsets == offsets.sorted())
            let indexStart = PdbPage.size - PdbPage.indexSize(slots: slots)
            #expect(page.data[(0x28 + used)..<indexStart].allSatisfy { $0 == 0 })
        }
    }

    @Test func rowIndexGroupBoundary16() throws {
        var model = Self.model()
        model.artists = (1...20).map { UsbNamedRow(id: $0, name: "Artist \($0)") }
        let (_, export, _) = try Self.write(model)
        let page = try #require(Self.dataPages(export, 2).first)
        #expect(page.slots.count == 20)
        let bytes = page.data
        // 묶음 0(자리 0–15)과 묶음 1(16–19)
        #expect(Self.u16(bytes, 4096 - 4) == 0xFFFF && Self.u16(bytes, 4096 - 2) == 0)
        #expect(Self.u16(bytes, 4096 - 0x24 - 4) == 0x000F && Self.u16(bytes, 4096 - 0x24 - 2) == 0x0008)
        #expect(Self.u16(bytes, 4096 - 0x24 - 6) == page.slots[16].offset)
        #expect(Self.u16(bytes, 4096 - 0x24 - 6 - 2 * 3) == page.slots[19].offset)
        // index_shift = 자리 × 0x20
        for slot in page.slots { #expect(Self.u16(page.row(slot), 2) == slot.index * 0x20) }
    }

    // MARK: - 트랙 행

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func trackRowConstants() throws {
        var model = Self.model()
        model.tracks[0].masterDbId = 3_000_000_000
        model.tracks[0].masterContentId = 2_900_000_001
        let row = try #require(try Self.rows(Self.write(model).1, 0).first)
        #expect(Self.u16(row, 0) == 0x0024 && Self.u16(row, 2) == 0)
        #expect(Self.u32(row, 0x04) == 0x000C_0700)
        #expect(Self.u16(row, 0x56) == 0x0029)
        #expect(Self.u16(row, 0x5C) == 3)
        #expect(Self.u32(row, 0x14) == 2_900_000_001)
        #expect(Self.u32(row, 0x18) == 3_000_000_000)
        #expect(Self.u32(row, 0x48) == 1)
    }

    @Test func trackStringOrder21() throws {
        var track = Self.track(1)
        track.isrc = "ZZ0000000001"
        track.lyricist = "시험 작사"
        track.informationUpdateCount = "9"
        track.analysisDataUpdateCount = "2"
        track.cueUpdateCount = "15"
        track.kuvoDeliver = true
        track.hotCueAutoLoad = false
        track.releaseDate = "2020-05-06"
        track.subtitle = "시험 믹스"
        var model = Self.model(tracks: 1)
        model.tracks = [track]
        let row = try #require(try Self.rows(Self.write(model).1, 0).first)
        let expected = ["ZZ0000000001", "시험 작사", "9", "2", "15", "", "ON", "", "", "", "2026-01-01", "2020-05-06", "시험 믹스", "",
                        track.analysisDataPath, "2026-01-02", "시험 코멘트", "시험 곡 1", "", "test1.mp3", track.path]
        var previous = 0x88
        for (index, value) in expected.enumerated() {
            let offset = Self.u16(row, 0x5E + 2 * index)
            #expect(offset >= previous, "문자열 \(index)")
            let decoded = try PdbStringDecoder.decode(row, at: offset, isrcAllowed: index == 0)
            #expect(decoded.value == value, "문자열 \(index)")
            previous = offset + decoded.byteLength
        }
        #expect(Self.u16(row, 0x5E) == 0x88)
    }

    @Test func trackRowAtLeast224() throws {
        var track = UsbTrack(id: 1, fileType: 1)
        track.fileName = ""
        #expect(PdbRowSize.track(track, library: .empty) == 224)
        #expect(try PdbRowEncoder.track(track).row.bytes.count == 224)
        // 할당 크기 = 0x88 + Σ align4(문자열 길이) + 4
        track.title = "abcde"
        #expect(PdbRowSize.track(track, library: .empty) == 224 + 4)
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func fileTypeMatchesExtension() throws {
        var model = Self.model()
        model.tracks[1].fileName = "test2.flac"
        model.tracks[1].fileType = 5
        #expect(throws: Never.self) { try PdbWriter.files(model, mode: .fresh) }
        model.tracks[2].fileType = 5
        do {
            _ = try PdbWriter.files(model, mode: .fresh)
            Issue.record("확장자와 다른 file_type을 막지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["pdbFileTypeMismatch"])
            #expect(blocks.first?.scope == .track("usb:3"))
        }
        // 확장자 대소문자는 가리지 않는다
        model.tracks[2].fileType = 1
        model.tracks[2].fileName = "TEST3.MP3"
        #expect(throws: Never.self) { try PdbWriter.files(model, mode: .fresh) }
    }

    // MARK: - 표별 행

    /// 모델의 키만 모델 id로 쓴다(고정된 키 목록을 쓰지 않는다)
    @Test func keysOnlyUsed() throws {
        var model = Self.model()
        model.keys = [UsbNamedRow(id: 7, name: "8A"), UsbNamedRow(id: 3, name: "11B")]
        model.tracks[0].keyID = 7
        model.tracks[1].keyID = 3
        model.tracks[2].keyID = nil
        let rows = try Self.rows(Self.write(model).1, 5)
        #expect(rows.count == 2)
        #expect(rows.map { Self.u32($0, 0) } == [3, 7] && rows.map { Self.u32($0, 4) } == [3, 7])
        #expect(try rows.map { try PdbStringDecoder.decode($0, at: 8).value } == ["11B", "8A"])
    }

    @Test func colors8() throws {
        let rows = try Self.rows(Self.write().1, 6)
        #expect(rows.count == 8)
        for (index, row) in rows.enumerated() {
            #expect(Self.u32(row, 0) == 0 && row[4] == UInt8(index + 1) && Self.u16(row, 5) == index + 1 && row[7] == 0)
        }
        #expect(try PdbStringDecoder.decode(rows[0], at: 8).value == "Pink")
    }

    @Test func columnsCategorySortOrder() throws {
        let export = try Self.write().1
        // columns: id 순, U+FFFA/B로 감싼 UTF-16
        let columns = try Self.rows(export, 16)
        #expect(columns.map { Self.u16($0, 0) } == [1, 2, 3] && columns.map { Self.u16($0, 2) } == [257, 258, 259])
        let menu = try PdbStringDecoder.decode(columns[1], at: 4)
        #expect(menu.value == "\u{FFFA}MENU\u{FFFB}" && menu.kind == .utf16LE)
        // category: (Seq, id) 순 — u16 menuItemID, u16 id, u8 InfoOrder, u8 Disable, u16 Seq
        let category = try Self.rows(export, 17)
        #expect(category.map { Array($0.prefix(8)) } == [[1, 0, 2, 0, 0, 1, 1, 0], [2, 0, 1, 0, 1, 0, 2, 0]])
        // sort: (Seq, id) 순 — u16 menuItemID, u16 id, u8 Disable, u8 Seq, u16 0
        let sort = try Self.rows(export, 18)
        #expect(sort.map { Array($0.prefix(8)) } == [[1, 0, 2, 0, 1, 1, 0, 0], [3, 0, 1, 0, 2, 2, 0, 0]])
        // Disable이 없는 행(OneLibrary에서 온 행)은 보임·보조 칸에서 정한다
        var model = Self.model()
        model.categories = [UsbCategory(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: false)]
        model.sorts = [UsbSort(id: 1, menuItemID: 1, sequenceNo: 1, isVisible: true, isSelectedAsSubColumn: true),
                       UsbSort(id: 2, menuItemID: 2, sequenceNo: 2, isVisible: false, isSelectedAsSubColumn: false),
                       UsbSort(id: 3, menuItemID: 3, sequenceNo: 3, isVisible: true, isSelectedAsSubColumn: false)]
        let rewritten = try Self.write(model).1
        #expect(try Self.rows(rewritten, 17).map { [$0[4], $0[5]] } == [[0, 1]])
        #expect(try Self.rows(rewritten, 18).map { $0[4] } == [2, 1, 0])
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func history19SingleRow() throws {
        let rows = try Self.rows(Self.write().1, 19)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.count == 40)
        #expect(Self.u16(row, 0) == 0x0280 && Self.u16(row, 2) == 0)
        #expect(Self.u32(row, 4) == 3 && Self.u32(row, 8) == 0)
        #expect(row[0x0C] == 0x17 && String(decoding: row[0x0D..<0x17], as: UTF8.self) == "2026-01-03")
        #expect(row[0x17] == 0x19 && row[0x18] == 0x1E)
        #expect(Array(row[0x19..<0x1F]) == [0x0B, 0x31, 0x30, 0x30, 0x30, 0x03])
        #expect(row[0x1F..<0x28].allSatisfy { $0 == 0 })
    }

    @Test func tagsCategoryThenTags() throws {
        var model = Self.model()
        model.myTags = [
            // 모델에 부모가 적힌 분류도 분류 모양(부모 0)으로 쓴다
            UsbMyTag(id: 11, parentID: 5, sequenceNo: 1, name: "시험 분류 B", isCategory: true),
            UsbMyTag(id: 10, parentID: 0, sequenceNo: 0, name: "Category A", isCategory: true),
            UsbMyTag(id: 21, parentID: 11, sequenceNo: 0, name: "Tag B0", isCategory: false),
            UsbMyTag(id: 22, parentID: 10, sequenceNo: 1, name: "Tag A1", isCategory: false),
            UsbMyTag(id: 20, parentID: 10, sequenceNo: 0, name: "시험 태그 A0", isCategory: false),
        ]
        let (files, _, ext) = try Self.write(model)
        let rows = try Self.rows(ext, 3)
        #expect(rows.map { Self.u32($0, 0x14) } == [10, 20, 22, 11, 21])
        #expect(Self.u32(rows[3], 0x0C) == 0 && Self.u32(rows[3], 0x18) == 0x0100_0000)
        #expect(files.written.myTags.first { $0.id == 11 }?.parentID == 0)
        let reread = try PdbReader.read(export: files.export, exportExt: files.exportExt).0
        #expect(PdbRoundTripTests.differences(reread, files.written).isEmpty)
        let first = rows[0], korean = rows[1]
        #expect(Self.u16(first, 0) == 0x0680 && Self.u32(first, 4) == 0 && Self.u32(first, 8) == 0)
        #expect(Self.u32(first, 0x0C) == 0 && Self.u32(first, 0x10) == 0 && Self.u32(first, 0x18) == 0x0100_0000)
        #expect(first[0x1C] == 0x03 && first[0x1D] == 0x1F)
        #expect(try PdbStringDecoder.decode(first, at: 0x1F).value == "Category A")
        let nameEnd = 0x1F + 1 + "Category A".utf8.count
        #expect(Int(first[0x1E]) == nameEnd && first[nameEnd] == 0x03)
        #expect(first.count == 32 + 12 + 4 + 4)
        // UTF-16 이름은 0x20
        #expect(korean[0x1D] == 0x20 && Self.u32(korean, 0x18) == 0 && Self.u32(korean, 0x0C) == 10)
        #expect(try PdbStringDecoder.decode(korean, at: 0x20).value == "시험 태그 A0")
        for (slot, row) in rows.enumerated() { #expect(Self.u16(row, 2) == slot * 0x20) }
    }

    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func type7Row60() throws {
        var model = Self.model()
        model.property.myTagMasterDBID = 4_000_000_000
        let rows = try Self.rows(Self.write(model).2, 7)
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row.count == 60)
        #expect(Self.u16(row, 0) == 0x0700 && Self.u16(row, 2) == 0)
        #expect(row[0x04..<0x18].allSatisfy { $0 == 0 })
        #expect(Self.u32(row, 0x18) == 4_000_000_000)
        #expect(Array(row[0x1C..<0x27]) == [0x03, 0x22, 0x23, 0x24, 0x25, 0x26, 0x03, 0x03, 0x03, 0x03, 0x03])
        #expect(row[0x27..<0x3C].allSatisfy { $0 == 0 })
    }

    @Test func playlistTreeAndEntries() throws {
        var model = Self.model()
        model.playlists = [
            UsbPlaylist(id: 5, name: "시험 폴더", parentID: 0, attribute: 1, presentIn: [.deviceLibrary], sortOrder: [.deviceLibrary: 0]),
            UsbPlaylist(id: 6, name: "List", parentID: 5, attribute: 0, presentIn: [.deviceLibrary], sortOrder: [.deviceLibrary: 3],
                        entries: [.deviceLibrary: [2, 3]]),
        ]
        let export = try Self.write(model).1
        let tree = try Self.rows(export, 7)
        #expect(tree.map { [Self.u32($0, 0), Self.u32($0, 4), Self.u32($0, 8), Self.u32($0, 0x0C), Self.u32($0, 0x10)] }
            == [[0, 0, 0, 5, 1], [5, 0, 3, 6, 0]])
        #expect(try PdbStringDecoder.decode(tree[1], at: 0x14).value == "List")
        let entries = try Self.rows(export, 8)
        #expect(entries.map { [Self.u32($0, 0), Self.u32($0, 4), Self.u32($0, 8)] } == [[1, 2, 6], [2, 3, 6]])
        let artwork = try Self.rows(export, 13)
        #expect(artwork.count == 3 && Self.u32(artwork[0], 0) == 1)
        #expect(try PdbStringDecoder.decode(artwork[0], at: 4).value == "/PIONEER/Artwork/00001/a1.jpg")
    }

    @Test func artistAlbumShapes() throws {
        var model = Self.model()
        model.artists = [UsbNamedRow(id: 1, name: "시험 아티스트"), UsbNamedRow(id: 2, name: "AB")]
        model.albums = [UsbAlbum(id: 4, name: "Album", artistID: 2), UsbAlbum(id: 5, name: "시험 앨범", artistID: nil)]
        let export = try Self.write(model).1
        let artists = try Self.rows(export, 2)
        #expect(Self.u16(artists[0], 0) == 0x0060 && Self.u32(artists[0], 4) == 1 && artists[0][8] == 0x03 && artists[0][9] == 0x0C)
        #expect(artists[1][9] == 0x0A && artists[1].count == 12 + 4 + 4)
        #expect(try PdbStringDecoder.decode(artists[0], at: 0x0C).value == "시험 아티스트")
        let albums = try Self.rows(export, 3)
        #expect(Self.u16(albums[0], 0) == 0x0080 && Self.u32(albums[0], 4) == 0 && Self.u32(albums[0], 8) == 2)
        #expect(Self.u32(albums[0], 0x0C) == 4 && Self.u32(albums[0], 0x10) == 0 && albums[0][0x14] == 0x03 && albums[0][0x15] == 0x16)
        #expect(albums[1][0x15] == 0x18 && Self.u32(albums[1], 8) == 0)
        #expect(try PdbStringDecoder.decode(albums[1], at: 0x18).value == "시험 앨범")
        #expect(PdbRowSize.artist(name: "AB") == 20 && PdbRowSize.album(name: "Album") == 24 + 8 + 4)
    }

    // MARK: - 편집 모드·막힘

    @Test func editModeSeqAboveOld() throws {
        let (fresh, _, _) = try Self.write()
        let (_, export, ext) = try Self.write(mode: .edit(previousExportSequence: 300, previousExtSequence: 50))
        let freshExport = try PdbFile(data: fresh.export)
        let exportPages = try Self.allPages(export), extPages = try Self.allPages(ext)
        #expect(exportPages.allSatisfy { $0.header.sequence > 300 })
        #expect(extPages.allSatisfy { $0.header.sequence > 50 })
        #expect(export.header.sequence == (exportPages.map(\.header.sequence).max() ?? 0) + 1)
        #expect(ext.header.sequence == (extPages.map(\.header.sequence).max() ?? 0) + 1)
        // 순번 = 옛 머리 순번 + 새 파일의 상대 번호(인덱스 쪽도)
        #expect(try zip(Self.allPages(freshExport), exportPages).allSatisfy { $0.header.sequence + 300 == $1.header.sequence })
        #expect(export.header.sequence == freshExport.header.sequence + 300)
    }

    @Test func zeroTracksThrows() {
        var model = Self.model()
        model.tracks = []
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
        // 다른 형식에만 있는 곡은 세지 않는다
        model = Self.model()
        for index in model.tracks.indices { model.tracks[index].presentIn = [.oneLibrary] }
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
    }

    @Test func historyRowsThrow() {
        var model = Self.model()
        model.histories = [UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [1])]
        do {
            _ = try PdbWriter.files(model, mode: .fresh)
            Issue.record("기록 행을 막지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.rule) == [.carriedDeviceRows])
        } catch {
            Issue.record("\(error)")
        }
        // OneLibrary 기록은 Device Library 투영에 없다
        model.histories = [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [1])]
        #expect(throws: Never.self) { try PdbWriter.files(model, mode: .fresh) }
        // 모델에 담지 않는 표의 행·My Tag 연결도 옮기지 못해 막는다
        model.histories = []
        model.unknownRows = [UsbUnknownRows(format: .deviceLibrary, file: "export.pdb", tableType: 9, liveRows: 1)]
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
        model.unknownRows = []
        model.myTagLinks = [UsbMyTagLink(myTagID: 1, contentID: 1, presentIn: [.deviceLibrary])]
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
    }

    /// 경계 실험 한 단계: 이름, 아티스트·앨범 행이 먼 모양인지, 아티스트·앨범 할당 크기, 이름 문자열 모양
    struct BoundaryCase: Sendable, CustomTestStringConvertible {
        var name: String
        var artistFar: Bool
        var albumFar: Bool
        var artistSize: Int
        var albumSize: Int
        var kind: PdbStringKind
        var testDescription: String { "\(name.first.map(String.init) ?? "") × \(name.count)" }

        init(_ letter: String, _ count: Int, far: Bool, artist: Int, album: Int, _ kind: PdbStringKind) {
            self.init(letter, count, artistFar: far, albumFar: far, artist: artist, album: album, kind)
        }

        init(_ letter: String, _ count: Int, artistFar: Bool, albumFar: Bool, artist: Int, album: Int, _ kind: PdbStringKind) {
            name = String(repeating: letter, count: count)
            self.artistFar = artistFar
            self.albumFar = albumFar
            artistSize = artist
            albumSize = album
            self.kind = kind
        }
    }

    static let boundaryCases: [BoundaryCase] = [
        // rekordbox 7.2.x 경계 실험(2026-10-08)
        BoundaryCase("A", 126, far: false, artist: 144, album: 156, .shortASCII),
        BoundaryCase("A", 127, far: false, artist: 148, album: 160, .longASCII),
        BoundaryCase("가", 116, far: true, artist: 252, album: 264, .utf16LE),
        BoundaryCase("가", 117, far: true, artist: 256, album: 268, .utf16LE),
        BoundaryCase("가", 119, far: true, artist: 260, album: 272, .utf16LE),
        BoundaryCase("가", 120, far: true, artist: 260, album: 272, .utf16LE),
        BoundaryCase("A", 236, far: true, artist: 256, album: 268, .longASCII),
        BoundaryCase("A", 244, far: true, artist: 264, album: 276, .longASCII),
        BoundaryCase("A", 250, far: true, artist: 272, album: 284, .longASCII),
        // rekordbox 7.2.19 실험 X1(2026-10-08): 이름 끝(아티스트 0x0C·앨범 0x18 + 문자열 바이트) 248부터 먼 모양
        BoundaryCase("가", 100, far: false, artist: 220, album: 232, .utf16LE),
        BoundaryCase("가", 108, far: false, artist: 236, album: 248, .utf16LE),
        BoundaryCase("가", 109, far: false, artist: 240, album: 252, .utf16LE),  // 앨범 이름 끝 246
        BoundaryCase("가", 110, artistFar: false, albumFar: true, artist: 240, album: 252, .utf16LE),  // 앨범 이름 끝 248
        BoundaryCase("가", 112, artistFar: false, albumFar: true, artist: 244, album: 256, .utf16LE),
        BoundaryCase("가", 113, artistFar: false, albumFar: true, artist: 248, album: 260, .utf16LE),
        BoundaryCase("가", 114, artistFar: false, albumFar: true, artist: 248, album: 260, .utf16LE),
        BoundaryCase("가", 115, artistFar: false, albumFar: true, artist: 252, album: 264, .utf16LE),  // 아티스트 이름 끝 246, 할당 252
        BoundaryCase("A", 200, far: false, artist: 220, album: 232, .longASCII),
        BoundaryCase("A", 220, artistFar: false, albumFar: true, artist: 240, album: 252, .longASCII),
        BoundaryCase("A", 226, artistFar: false, albumFar: true, artist: 248, album: 260, .longASCII),
        BoundaryCase("A", 228, artistFar: false, albumFar: true, artist: 248, album: 260, .longASCII),
        BoundaryCase("A", 229, artistFar: false, albumFar: true, artist: 252, album: 264, .longASCII),
        BoundaryCase("A", 231, artistFar: false, albumFar: true, artist: 252, album: 264, .longASCII),  // 아티스트 이름 끝 247
    ]

    /// 아티스트·앨범 행의 가까운·먼 모양 경계와 칸 자리.
    /// rekordbox 7.2.x 경계 실험(2026-10-08): 한 곡의 아티스트·앨범을 '가' × 116·117·119·120, 'A' × 126·127·236·244·250으로 차례로 바꿔
    /// USB 동기화한 뒤 행을 읽었다. rekordbox 7.2.19 실험 X1(2026-10-08): 같은 방법으로 '가' × 100·108·109·110·112·113·114·115,
    /// 'A' × 200·220·226·228·229·231. 모양·칸은 아래 표 그대로였고, 새로 붙인 행의 할당 크기(자리 사이 거리)도 같았다
    /// (지운 자리를 제자리에서 다시 쓴 행은 원래 자리 크기를 썼다)
    @Test(arguments: boundaryCases)
    func artistAlbumBoundaryGolden(_ golden: BoundaryCase) throws {
        let (name, artistSize, albumSize, kind) = (golden.name, golden.artistSize, golden.albumSize, golden.kind)
        let artistRow = try PdbRowEncoder.artist(UsbNamedRow(id: 7, name: name))
        let artist = artistRow.bytes, far = golden.artistFar
        #expect(artistRow.rules.isEmpty)
        #expect(artist.count == artistSize && PdbRowSize.artist(name: name) == artistSize)
        #expect(Self.u16(artist, 0) == (far ? 0x0064 : 0x0060) && Self.u32(artist, 4) == 7 && artist[8] == 0x03)
        // 먼 모양: 0x09는 0, u16 이름 오프셋 0x000C @0x0A. 가까운 모양: u8 오프셋 @0x09(짧은 ASCII 0x0A, 그 밖은 0x0C)
        let artistOffset = far ? Self.u16(artist, 0x0A) : Int(artist[9])
        if far {
            #expect(artist[9] == 0 && artistOffset == 0x0C)
        } else {
            #expect(artistOffset == (kind == .shortASCII ? 0x0A : 0x0C))
        }
        let artistName = try PdbStringDecoder.decode(artist, at: artistOffset)
        #expect(artistName.value == name && artistName.kind == kind)
        // 이름 앞 정렬 빈칸과 이름 뒤 할당 끝까지는 0
        let artistEnd = artistOffset + artistName.byteLength
        #expect((artistEnd >= PdbRowSize.farShapeNameEnd) == far)
        #expect(artist[artistEnd...].allSatisfy { $0 == 0 })
        if !far { #expect(artist[0x0A..<artistOffset].allSatisfy { $0 == 0 }) }

        let albumRow = try PdbRowEncoder.album(UsbAlbum(id: 9, name: name, artistID: 7))
        let album = albumRow.bytes, albumFar = golden.albumFar
        #expect(albumRow.rules.isEmpty)
        #expect(album.count == albumSize && PdbRowSize.album(name: name) == albumSize)
        #expect(Self.u16(album, 0) == (albumFar ? 0x0084 : 0x0080) && Self.u32(album, 4) == 0 && Self.u32(album, 8) == 7)
        #expect(Self.u32(album, 0x0C) == 9 && Self.u32(album, 0x10) == 0 && album[0x14] == 0x03)
        let albumOffset = albumFar ? Self.u16(album, 0x16) : Int(album[0x15])
        if albumFar {
            #expect(album[0x15] == 0 && albumOffset == 0x18)
        } else {
            #expect(albumOffset == (kind == .shortASCII ? 0x16 : 0x18))
        }
        let albumName = try PdbStringDecoder.decode(album, at: albumOffset)
        #expect(albumName.value == name && albumName.kind == kind)
        let albumEnd = albumOffset + albumName.byteLength
        #expect((albumEnd >= PdbRowSize.farShapeNameEnd) == albumFar)
        #expect(album[albumEnd...].allSatisfy { $0 == 0 })
        if !albumFar { #expect(album[0x16..<albumOffset].allSatisfy { $0 == 0 }) }
    }

    /// 모양은 할당 크기가 아니라 이름 끝(248 이상이면 먼 모양)으로 고른다. 실험이 보지 못한 앨범 이름 끝 247(긴 ASCII 219자)만
    /// 같은 기준(가까운 모양)으로 쓰고 pdbFarOffsetRows를 붙인다(쓰기를 막지 않고 CDJ 확인 항목으로 알린다)
    @Test func artistAlbumShapeByNameEnd() throws {
        // (글자, 수, 아티스트 먼 모양, 앨범 먼 모양, 앨범 규칙)
        let cases: [(String, Int, Bool, Bool, Bool)] = [
            ("A", 218, false, false, false),  // 222바이트: 앨범 이름 끝 246
            ("A", 219, false, false, true),  // 223바이트: 앨범 이름 끝 247(본 적 없음)
            ("A", 220, false, true, false),  // 224바이트: 앨범 이름 끝 248
            ("A", 232, true, true, false),  // 236바이트: 아티스트 이름 끝 248
            ("가", 64, false, false, false),  // 132바이트: 전에는 확인 안 된 길이
        ]
        for (letter, count, artistFar, albumFar, flagged) in cases {
            let name = String(repeating: letter, count: count)
            let artist = try PdbRowEncoder.artist(UsbNamedRow(id: 1, name: name))
            #expect((Self.u16(artist.bytes, 0) == 0x0064) == artistFar, "\(count)")
            #expect(artist.rules.isEmpty, "\(count)")
            let album = try PdbRowEncoder.album(UsbAlbum(id: 1, name: name, artistID: nil))
            #expect((Self.u16(album.bytes, 0) == 0x0084) == albumFar, "\(count)")
            #expect(album.rules == (flagged ? [.pdbFarOffsetRows] : []), "\(count)")
        }
        // 할당 크기는 기준이 아니다: 'A' × 231 아티스트는 할당 252인데 가까운 모양, '가' × 116은 같은 할당 252로 먼 모양
        let near = String(repeating: "A", count: 231), far = String(repeating: "가", count: 116)
        #expect(PdbRowSize.artist(name: near) == 252 && PdbRowSize.artist(name: far) == 252)
        #expect(Self.u16(try PdbRowEncoder.artist(UsbNamedRow(id: 1, name: near)).bytes, 0) == 0x0060)
        #expect(Self.u16(try PdbRowEncoder.artist(UsbNamedRow(id: 1, name: far)).bytes, 0) == 0x0064)
    }

    /// 먼 모양 아티스트·앨범 행을 쓴 파일을 다시 읽으면 같은 모델이고, 규칙은 작성기 규칙에 모인다
    @Test func farArtistAlbumRowsWrittenAndReread() throws {
        var model = Self.model()
        model.artists = [UsbNamedRow(id: 1, name: String(repeating: "가", count: 120)), UsbNamedRow(id: 2, name: String(repeating: "A", count: 250))]
        model.albums = [UsbAlbum(id: 1, name: String(repeating: "A", count: 127), artistID: 2)]
        let (files, export, _) = try Self.write(model)
        #expect(files.rules.isEmpty)
        let (reread, report) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(report.issues.isEmpty && report.farShapeRows == ["artists": 2])
        #expect(UsbLibraryDiff.compare(reread, files.written, options: .init(formats: [.deviceLibrary])).differences.isEmpty)
        let artists = try Self.rows(export, 2)
        #expect(artists.map { Self.u16($0, 0) } == [0x0064, 0x0064])
        // 실험이 보지 못한 이름 끝(앨범 247)의 이름은 쓰되 규칙을 싣는다
        model.albums[0].name = String(repeating: "A", count: 219)
        #expect(try PdbWriter.files(model, mode: .fresh).rules == [.pdbFarOffsetRows])
    }

    /// My Tag 먼 오프셋 모양(0x0684)은 rekordbox로 확인하지 못해 쓰지 않는다
    @Test func farOffsetTagRowsRefused() {
        var model = Self.model()
        model.myTags = [UsbMyTag(id: 1, parentID: 0, sequenceNo: 0, name: String(repeating: "가", count: 120), isCategory: true)]
        do {
            _ = try PdbWriter.files(model, mode: .fresh)
            Issue.record("먼 모양 태그 행을 막지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.rule) == [.pdbFarOffsetRows])
        } catch {
            Issue.record("\(error)")
        }
        #expect(PdbRowSize.tag(name: String(repeating: "가", count: 100)) <= PdbRowSize.nearShapeLimit)
        #expect(PdbRowSize.tag(name: String(repeating: "가", count: 120)) > PdbRowSize.nearShapeLimit)
    }

    @Test func rowTooLargeRefused() {
        var model = Self.model()
        model.tracks[0].comment = String(repeating: "가", count: 2000)
        #expect(!PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.track(model.tracks[0], library: model)))
        #expect(PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.pageCapacity - 6))
        #expect(!PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.pageCapacity - 5))
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
        model = Self.model()
        model.tracks[0].isrc = "시험"
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
        model = Self.model()
        model.tracks[0].discNo = 70_000
        #expect(throws: UsbError.self) { try PdbWriter.files(model, mode: .fresh) }
    }

    // MARK: - 확인 안 된 규칙 모으기

    @Test func writerReportsLongAsciiRules() throws {
        var model = Self.model()
        func path(_ length: Int, _ id: Int) -> String {
            let name = "/test\(id).mp3"
            return "/Contents/" + String(repeating: "p", count: length - "/Contents/".count - name.count) + name
        }
        model.tracks[0].path = path(126, 1)
        model.tracks[1].path = path(127, 2)
        let tracksOnly = try PdbWriter.files(model, mode: .fresh)
        // 트랙 행 문자열의 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08) 때 뜬 USB에서 본 모양이라 규칙이 없다
        #expect(tracksOnly.rulesByTrack.isEmpty && tracksOnly.rules.isEmpty)
        model.genres[0].name = String(repeating: "g", count: 127)
        let files = try PdbWriter.files(model, mode: .fresh)
        #expect(files.rulesByTrack.isEmpty)
        #expect(files.rules == [.pdbLongAscii])
        let second = try Self.rows(PdbFile(data: files.export), 0)[1]
        let offset = Self.u16(second, 0x5E + 2 * 20)
        #expect(second[offset] == 0x40 && offset % 4 == 0)
        #expect(try PdbStringDecoder.decode(second, at: offset).value == model.tracks[1].path)

        // 목록 이름만 긴 모델
        model = Self.model()
        model.playlists[0].name = String(repeating: "l", count: 127)
        let playlistOnly = try PdbWriter.files(model, mode: .fresh)
        #expect(playlistOnly.rules == [.pdbLongAscii] && playlistOnly.rulesByTrack.isEmpty)
        // 모두 짧으면 비었다
        #expect(try PdbWriter.files(Self.model(), mode: .fresh).rules.isEmpty)
    }

    // MARK: - 쓴 모델

    /// 다시 읽은 모델은 작성기가 돌려준 `written`과 같다(작성기가 정하는 칸: 행 관찰값·표 19 날짜·곡 수)
    @Test func writtenMatchesReread() throws {
        var model = Self.model()
        model.property.pdbDate = nil
        model.property.pdbDeviceName = nil
        model.property.createdDate = "2026-02-03"
        model.formats = [.oneLibrary, .deviceLibrary]
        model.trackRowExtras = [:]
        let files = try PdbWriter.files(model, mode: .fresh)
        let (reread, report) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        #expect(report.issues.isEmpty)
        #expect(reread == files.written)
        #expect(files.written.property.pdbDate == "2026-02-03" && files.written.property.pdbDeviceName == "")
        #expect(files.written.trackRowExtras[1]?.bitmask == 0x000C_0700)
        let diff = UsbLibraryDiff.compare(reread, files.written, options: .init(formats: [.deviceLibrary]))
        #expect(diff.differences.isEmpty)
    }
}
