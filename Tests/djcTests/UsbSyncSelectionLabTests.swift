import RekordboxFixtures
@testable import djc
import DJCDomain
import Darwin
import Foundation
@testable import RekordboxKit
import Testing

@Suite("USB sync 전후 사본 비교 출력")
struct UsbSyncSelectionLabTests {
    private func file(rootTime: Int, nodeTime: Int, deviceID: String) throws -> UsbSyncSelectionFile {
        try .parse(Data("""
            <Sync DBID="-1234567" AutomaticSync="1" AllPlaylists="0" ForcedSync="0" IncludeCue="1" Timestamp="\(rootTime)">
              <Playlists>
                <NODE Lib_Type="1" Id="0" ParentId="0" Attribute="1" CheckType="2" Dev_ID="0" Timestamp="0"/>
                <NODE Lib_Type="1" Id="ABCD1234" ParentId="0" Attribute="0" CheckType="1" Dev_ID="\(deviceID)" Timestamp="\(nodeTime)"/>
              </Playlists>
            </Sync>
            """.utf8))
    }

    @Test("원본 식별값을 내보내지 않고 바뀐 칸만 출력한다")
    func changedFieldsAreReportedWithoutValues() throws {
        let lines = UsbSyncSelectionLab.differences(before: try file(rootTime: 1700000000000, nodeTime: 1700000000000, deviceID: "4021"),
                                                    after: try file(rootTime: 1800000000000, nodeTime: 1800000000000, deviceID: "5012"),
                                                    format: .deviceLibrary)
        #expect(lines.contains("playlists3.sync: 루트 칸 Timestamp"))
        #expect(lines.contains("기존 NODE 칸 Dev_ID 1 · Timestamp 1"))
        let output = lines.joined(separator: "\n")
        for value in ["-1234567", "ABCD1234", "4021", "5012", "1700000000000", "1800000000000"] {
            #expect(!output.contains(value))
        }
    }

    @Test("체크 해제 때 파일 생성·제거도 구분한다")
    func creationAndRemovalAreVisible() throws {
        let sample = try file(rootTime: 0, nodeTime: 0, deviceID: "1")
        #expect(UsbSyncSelectionLab.differences(before: nil, after: sample, format: .oneLibrary) == ["playlists3Plus.sync: 파일 생성"])
        #expect(UsbSyncSelectionLab.differences(before: sample, after: nil, format: .oneLibrary) == ["playlists3Plus.sync: 파일 제거"])
    }
}


extension UsbSyncSelectionLabTests {
    @Test func lab의_중첩_사본_읽기도_부모_교체_때_외부_읽기는_0이다() throws {
        let fixture = UsbTreeFixture(), outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        let data = try file(rootTime: 0, nodeTime: 0, deviceID: "1").data
        fixture.write(UsbSyncSelectionFile.relativePath(for: .deviceLibrary), data)
        outside.write("playlists3.sync", data)
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        var swapped = false, reads = 0
        probe.onReadFile = { root, path, limit in
            try UsbAnchoredFileReader.read(root: root, relativePath: path, maxBytes: limit, beforeOpen: { component in
                if component == "rekordbox", !swapped {
                    swapped = true
                    try FileManager.default.moveItem(at: fixture.url("PIONEER/rekordbox"), to: fixture.url("PIONEER/original"))
                    fixture.symlink("PIONEER/rekordbox", to: outside.base.path)
                }
            }, willRead: { _ in reads += 1 })
        }
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionLab.read(format: .deviceLibrary, from: fixture.base, fileSystem: probe)
        }
        #expect(swapped && reads == 0 && probe.anchoredCalls == 2 && probe.urlReads == 0 && probe.urlHashes == 0)
    }

    @Test func lab는_직접_두_이름의_사본도_안전_입구로_읽는다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let data = try file(rootTime: 0, nodeTime: 0, deviceID: "1").data
        fixture.write("playlists3.sync", data)
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        #expect(try UsbSyncSelectionLab.read(format: .deviceLibrary, from: fixture.base, fileSystem: probe)?.data == data)
        #expect(probe.anchoredCalls == 1 && probe.urlReads == 0 && probe.urlHashes == 0)
    }

    @Test func Slow파일시스템은_안전읽기_인자와_결과_오류_없음을_그대로_전달한다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        let value = UsbFileRead(data: Data("합성".utf8), stat: .init(kind: .file, size: 6, modificationDate: .distantPast))
        probe.onReadFile = { root, relative, limit in
            #expect(root == fixture.root && relative == path && limit == 123)
            return value
        }
        let slow = SlowUsbFileSystem(inner: probe, delayMilliseconds: 0)
        #expect(try slow.readFile(root: fixture.root, relativePath: path, maxBytes: 123) == value)
        probe.onReadFile = { _, _, _ in nil }
        #expect(try slow.readFile(root: fixture.root, relativePath: path, maxBytes: 123) == nil)
        probe.onReadFile = { _, _, _ in throw UsbSyncSelectionFile.ParseError.changedDuringRead }
        #expect(throws: UsbSyncSelectionFile.ParseError.changedDuringRead) {
            try slow.readFile(root: fixture.root, relativePath: path, maxBytes: 123)
        }
        #expect(probe.anchoredCalls == 3 && probe.urlReads == 0 && probe.urlHashes == 0)
    }
}
