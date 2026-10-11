import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 두 USB 폴더의 파일 트리·분석 파일 태그 비교(합성 트리만)
@Suite("USB 파일 비교")
struct UsbFileDiffTests {
    /// 합성 USB 하나(A)와 그 복사본(B). B를 고친 뒤 비교한다
    func pair(_ body: (UsbTreeFixture, UsbTreeFixture) throws -> Void) throws {
        let a = UsbTreeFixture()
        defer { a.remove() }
        try UsbLibraryFixture().write(to: a)
        let b = UsbTreeFixture()
        defer { b.remove() }
        try FileManager.default.removeItem(at: b.base)
        try FileManager.default.copyItem(at: a.base, to: b.base)
        try body(a, b)
    }

    /// 파일 수: DB 셋 + 곡마다 음원 1·아트워크 4·분석 파일 3
    static let fileCount = 3 + 3 * 8

    @Test func identicalZero() throws {
        try pair { a, b in
            let result = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options())
            #expect(result.fileSummary == "파일 \(Self.fileCount)/\(Self.fileCount) 같음, 한쪽에만 0/0, 내용 다름 0")
            #expect(result.anlzSummary == "ANLZ 9/9 바이트 같음")
            #expect(result.differences.isEmpty)
            // 한쪽만 보면 다른 쪽 요약은 비운다
            let filesOnly = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(anlz: false))
            #expect(filesOnly.anlzSummary.isEmpty && !filesOnly.fileSummary.isEmpty)
        }
    }

    @Test("--mtime: 같은 내용 파일의 수정 시각을 FAT 2초 단위로 내려 비교한다")
    func mtimeComparedInFatUnits() throws {
        try pair { a, b in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for tree in [a, b] {
                for (path, _) in tree.tree() {
                    try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: tree.url(path).path)
                }
            }
            let audio = "Contents/시험 아티스트/시험 앨범/test1.mp3"
            // 같은 2초 칸 안이면 같다
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(1.5)], ofItemAtPath: b.url(audio).path)
            let same = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(anlz: false, mtime: true))
            #expect(same.fileSummary.contains("mtime(2초 단위) 같음 \(Self.fileCount)/\(Self.fileCount)"))
            #expect(same.differences.isEmpty)
            // 옵션이 없으면 시각은 보지 않는다
            #expect(!(try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(anlz: false)).fileSummary.contains("mtime")))

            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(2)], ofItemAtPath: b.url(audio).path)
            let moved = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(anlz: false, mtime: true))
            #expect(moved.fileSummary.contains("mtime(2초 단위) 같음 \(Self.fileCount - 1)/\(Self.fileCount) (mtime 다름: Contents 1)"))
            #expect(moved.differences == ["파일 mtime 다름: Contents"])
        }
    }

    @Test func nfcNfdPathsEqual() throws {
        let a = UsbTreeFixture(), b = UsbTreeFixture()
        defer { a.remove(); b.remove() }
        let name = "Contents/가수/노래.mp3"
        a.write(name.precomposedStringWithCanonicalMapping, "synthetic audio")
        b.write(name.decomposedStringWithCanonicalMapping, "synthetic audio")
        let result = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options())
        #expect(result.fileSummary == "파일 1/1 같음, 한쪽에만 0/0, 내용 다름 0")
        #expect(result.differences.isEmpty)
    }

    @Test func appleDoubleIgnored() throws {
        try pair { a, b in
            b.write("Contents/시험 아티스트/시험 앨범/._test1.mp3", "synthetic xattr")
            b.write("PIONEER/._rekordbox", "synthetic xattr")
            b.write(".fseventsd/0000", "synthetic")
            let result = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options())
            #expect(result.fileSummary == "파일 \(Self.fileCount)/\(Self.fileCount) 같음, 한쪽에만 0/0, 내용 다름 0")
            #expect(result.differences.isEmpty)
        }
    }

    @Test func anlzTagDifferenceNamed() throws {
        try pair { a, b in
            let dat = String(UsbLibraryFixture.analysisPath(1).dropFirst())
            b.write(dat, UsbLibraryFixture.dat(path: UsbLibraryFixture.trackPath(1), hotCueA: 9_000))
            let result = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options())
            #expect(result.anlzSummary == "ANLZ 8/9 바이트 같음, 다른 태그: PCOB×1")
            #expect(result.fileSummary == "파일 \(Self.fileCount - 1)/\(Self.fileCount) 같음, 한쪽에만 0/0, 내용 다름 1 (내용 다름: USBANLZ 1)")
            // 경로 대신 곡 id·태그 이름만
            let named = try UsbFileDiff.compare(a.root, b.root,
                                                options: UsbFileDiff.Options(trackIDs: [UsbLibraryFixture.trackPath(1): 1]))
            #expect(named.differences.contains("ANLZ 곡 1 DAT: PCOB"))
            for line in result.differences + named.differences {
                #expect(!line.contains("Contents") && !line.contains("P000") && !line.contains("test1"))
            }
            // 태그 목록이 달라도 이름으로 적는다
            b.write(dat, AnlzBuilder.file([AnlzPathTag.encode(UsbLibraryFixture.trackPath(1)), AnlzBuilder.unknownTag(fourcc: "PVBR")]))
            let fewer = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(files: false))
            #expect(fewer.anlzSummary.hasPrefix("ANLZ 8/9 바이트 같음, 다른 태그: "))
            #expect(fewer.anlzSummary.contains("PQTZ×1") && fewer.anlzSummary.contains("PVBR×1"))
            #expect(fewer.fileSummary.isEmpty)
        }
    }

    @Test func ignoreAnalysisFolderMatchesByPPTH() throws {
        try pair { a, b in
            let old = String(UsbLibraryFixture.analysisPath(1).dropFirst().dropLast(4))
            for ext in [".DAT", ".EXT", ".2EX"] {
                b.write("PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000" + ext, try Data(contentsOf: b.url(old + ext)))
                try FileManager.default.removeItem(at: b.url(old + ext))
            }
            let strict = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options())
            #expect(strict.fileSummary == "파일 \(Self.fileCount - 3)/\(Self.fileCount) 같음, 한쪽에만 3/3, 내용 다름 0"
                + " (한쪽에만 A: USBANLZ 3 · 한쪽에만 B: USBANLZ 3)")
            // 분석 파일은 늘 (PPTH, 확장자)로 짝짓는다
            #expect(strict.anlzSummary == "ANLZ 9/9 바이트 같음")
            let loose = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(ignoreAnalysisFolder: true))
            #expect(loose.fileSummary == "파일 \(Self.fileCount)/\(Self.fileCount) 같음, 한쪽에만 0/0, 내용 다름 0")
            #expect(loose.differences.isEmpty)
        }
    }

    @Test func duplicatePPTHComparedAndCounted() throws {
        try pair { a, b in
            // B: 한 곡의 분석 파일 셋을 원래 폴더보다 뒤에 오는 폴더에 한 벌 더 두고 그쪽 .DAT의 핫큐 A만 바꾼다
            let old = String(UsbLibraryFixture.analysisPath(1).dropFirst().dropLast(4))
            let extra = "PIONEER/USBANLZ/P123/0ABCDEF0/ANLZ0000"
            for ext in [".EXT", ".2EX"] { b.write(extra + ext, try Data(contentsOf: b.url(old + ext))) }
            b.write(extra + ".DAT", UsbLibraryFixture.dat(path: UsbLibraryFixture.trackPath(1), hotCueA: 9_000))
            let options = UsbFileDiff.Options(files: false, trackIDs: [UsbLibraryFixture.trackPath(1): 1])
            // 겹친 파일도 다른 쪽 파일과 비교하고, 분모는 모든 분석 파일이다
            let result = try UsbFileDiff.compare(a.root, b.root, options: options)
            #expect(result.anlzSummary == "ANLZ 11/12 바이트 같음, 다른 태그: PCOB×1, PPTH 겹침 0/3")
            #expect(result.differences == ["ANLZ 곡 1 DAT B 겹침: PCOB"])
            #expect(!result.anlzSummary.contains("PPTH 못 읽음"))
            let swapped = try UsbFileDiff.compare(b.root, a.root, options: options)
            #expect(swapped.anlzSummary == "ANLZ 11/12 바이트 같음, 다른 태그: PCOB×1, PPTH 겹침 3/0")
            #expect(swapped.differences == ["ANLZ 곡 1 DAT A 겹침: PCOB"])
            // 같은 트리끼리는 겹친 파일도 차례대로 짝지어 차이가 없다
            let same = try UsbFileDiff.compare(b.root, b.root, options: options)
            #expect(same.anlzSummary == "ANLZ 12/12 바이트 같음, PPTH 겹침 3/3")
            #expect(same.differences.isEmpty)
            // 다른 쪽에 짝이 없으면 겹친 파일도 짝 없음으로 센다
            let empty = UsbTreeFixture()
            defer { empty.remove() }
            let lonely = try UsbFileDiff.compare(empty.root, b.root, options: options)
            #expect(lonely.anlzSummary == "ANLZ 0/12 바이트 같음, 짝 없음 0/12, PPTH 겹침 0/3")
        }
    }

    @Test func groupsNameEachArea() throws {
        try pair { a, b in
            b.write("PIONEER/rekordbox/export.pdb", "changed")
            b.write("PIONEER/MYSETTING.DAT", "new")
            b.write("PIONEER/Artwork/00001/a9.jpg", "new")
            try FileManager.default.removeItem(at: b.url("Contents/시험 아티스트/시험 앨범/test2.mp3"))
            let result = try UsbFileDiff.compare(a.root, b.root, options: UsbFileDiff.Options(anlz: false))
            #expect(result.fileSummary == "파일 \(Self.fileCount - 2)/\(Self.fileCount + 1) 같음, 한쪽에만 1/2, 내용 다름 1"
                + " (한쪽에만 A: Contents 1 · 한쪽에만 B: 설정 1, Artwork 1 · 내용 다름: DB 1)")
            #expect(result.differences.sorted() == ["파일 내용 다름: DB", "파일 한쪽에만 A: Contents", "파일 한쪽에만 B: Artwork",
                                                    "파일 한쪽에만 B: 설정"])
        }
    }

    @Test("PPTH를 읽지 못한 분석 파일은 비교 불가 차이로 센다", arguments: [false, true])
    func unreadableAnalysisCountsAsDifference(missingPPTH: Bool) throws {
        try pair { a, b in
            let bytes = missingPPTH ? AnlzBuilder.file([]) : Data("broken ANLZ".utf8)
            b.write("PIONEER/USBANLZ/P123/0ABCDEF0/ANLZ0000.DAT", bytes)
            let options = UsbFileDiff.Options(files: false)
            let result = try UsbFileDiff.compare(a.root, b.root, options: options)
            #expect(result.anlzSummary == "ANLZ 9/10 바이트 같음, PPTH 못 읽음 0/1")
            #expect(result.differences == ["ANLZ B: 비교 불가(PPTH 못 읽음)"])

            let swapped = try UsbFileDiff.compare(b.root, a.root, options: options)
            #expect(swapped.differences == ["ANLZ A: 비교 불가(PPTH 못 읽음)"])
            // 양쪽 모두 읽지 못해도 바이트 일치를 확인한 것은 아니다
            let unreadableBoth = try UsbFileDiff.compare(b.root, b.root, options: options)
            #expect(unreadableBoth.differences == ["ANLZ A: 비교 불가(PPTH 못 읽음)", "ANLZ B: 비교 불가(PPTH 못 읽음)"])
        }
    }
}
