import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 초안 저장소: 볼륨마다 `usb-drafts/<볼륨키>.json` 하나. 폴더는 임시 폴더를 넘긴다(실제 데이터 폴더는 쓰지 않는다)
@Suite("USB 초안 저장소")
struct UsbDraftStoreTests {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbdrafts-\(UUID().uuidString)")
    }

    static let base = UsbFingerprint(files: [UsbLayout.oneLibrary: .init(size: 10, mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                                                         sha256: "aa")])
    static let volume = "00000000-0000-0000-0000-000000000001"

    @Test("쌓고 읽고 버린다: 순서 그대로, base는 처음 만든 때의 것")
    func appendLoadDiscard() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UsbDraftStore(directory: folder)
        #expect(try store.load(volumeKey: Self.volume) == nil)
        try store.append(.removeTracks(usbContentIDs: [5]), volumeKey: Self.volume, base: Self.base)
        let later = UsbFingerprint(files: [:])
        try store.append(.playlist(edit: .rename(playlist: .id("1"), name: "합성 이름")), volumeKey: Self.volume, base: later)
        let draft = try #require(try store.load(volumeKey: Self.volume))
        #expect(draft.volumeKey == Self.volume)
        #expect(draft.base == Self.base)
        #expect(draft.edits == [.removeTracks(usbContentIDs: [5]), .playlist(edit: .rename(playlist: .id("1"), name: "합성 이름"))])
        try store.discard(volumeKey: Self.volume)
        #expect(try store.load(volumeKey: Self.volume) == nil)
        // 없는 초안을 버려도 오류가 아니다
        try store.discard(volumeKey: Self.volume)
    }

    @Test("내구 쓰기: 바꾸는 도중 실패해도 옛 초안이 그대로이고 임시 파일이 남지 않는다")
    func durableWrite() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try UsbDraftStore(directory: folder).append(.removeTracks(usbContentIDs: [1]), volumeKey: Self.volume, base: Self.base)
        let before = try Data(contentsOf: folder.appending(path: Self.volume + ".json"))
        let fileSystem = FaultyUsbFileSystem(root: folder.appending(path: "no-usb"))
        fileSystem.failSide = .mac
        fileSystem.failAt = (operation: .rename, occurrence: 1, mode: .error)
        let store = UsbDraftStore(directory: folder, fileSystem: fileSystem)
        #expect(throws: (any Error).self) {
            try store.append(.removeTracks(usbContentIDs: [2]), volumeKey: Self.volume, base: Self.base)
        }
        #expect(try Data(contentsOf: folder.appending(path: Self.volume + ".json")) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [Self.volume + ".json"])
        #expect(fileSystem.calls.contains { $0.hasPrefix("fullSync") })
    }

    @Test("볼륨마다 파일 하나, 볼륨 키가 경로 성분이 아니면 거부")
    func perVolumeFiles() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UsbDraftStore(directory: folder)
        let other = "00000000-0000-0000-0000-000000000002"
        try store.append(.removeTracks(usbContentIDs: [1]), volumeKey: Self.volume, base: Self.base)
        try store.append(.removeTracks(usbContentIDs: [2]), volumeKey: other, base: Self.base)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [Self.volume + ".json", other + ".json"])
        #expect(try store.load(volumeKey: other)?.edits == [.removeTracks(usbContentIDs: [2])])
        try store.discard(volumeKey: other)
        #expect(try store.load(volumeKey: Self.volume)?.edits == [.removeTracks(usbContentIDs: [1])])
        for bad in ["", "..", "a/b", "."] {
            #expect(throws: UsbError.self) { try store.append(.removeTracks(usbContentIDs: [1]), volumeKey: bad, base: Self.base) }
        }
    }
}
