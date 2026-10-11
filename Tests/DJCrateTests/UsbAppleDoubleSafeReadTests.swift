@testable import DJCrate
import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

#if DEBUG
struct UsbAppleDoubleSafeReadTests {
    @Test func recorder는_안전읽기의_인자_결과_없음_오류를_그대로_전달한다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let probe = UsbReadFileProbe(base: FaultyUsbFileSystem(root: fixture.base))
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        let value = UsbFileRead(data: Data("합성".utf8), stat: .init(kind: .file, size: 6, modificationDate: .distantPast))
        probe.onReadFile = { root, relative, limit in
            #expect(root == fixture.root && relative == path && limit == 456)
            return value
        }
        let recorder = UsbAppleDoubleRecorder(base: probe)
        #expect(try recorder.readFile(root: fixture.root, relativePath: path, maxBytes: 456) == value)
        probe.onReadFile = { _, _, _ in nil }
        #expect(try recorder.readFile(root: fixture.root, relativePath: path, maxBytes: 456) == nil)
        probe.onReadFile = { _, _, _ in throw UsbSyncSelectionFile.ParseError.changedDuringRead }
        #expect(throws: UsbSyncSelectionFile.ParseError.changedDuringRead) {
            try recorder.readFile(root: fixture.root, relativePath: path, maxBytes: 456)
        }
        #expect(probe.anchoredCalls == 3 && probe.urlReads == 0 && probe.urlHashes == 0)
        #expect(recorder.removedAppleDoubles.isEmpty)
    }
}
#endif
