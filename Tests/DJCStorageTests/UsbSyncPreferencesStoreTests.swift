import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import Testing

@Suite("USB 동기화 선택 저장소")
struct UsbSyncPreferencesStoreTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-usb-sync-preferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("볼륨·라이브러리·부분 선택·동기화 연결을 함께 저장하고 다시 읽는다")
    func roundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsbSyncPreferencesStore(directory: directory)
        let preferences = UsbSyncPreferences(volumeKey: "SYNTHETIC-USB", localDBID: Int64.max - 42,
                                            selection: ITunesSyncSelection(selectedIDs: ["folder", "playlist"]),
                                            syncPlaylists: false,
                                            bindings: ["playlist": UsbSyncPlaylistBinding(usbID: 17, path: ["시험 폴더", "시험 목록"], isFolder: false),
                                                       "folder": UsbSyncPlaylistBinding(usbID: 16, path: ["시험 폴더"], isFolder: true)],
                                            nativeSelectionFingerprint: "synthetic-semantic-fingerprint")
        try store.save(preferences)
        #expect(try store.load(volumeKey: preferences.volumeKey) == preferences)

        var changed = preferences
        changed.selection = ITunesSyncSelection(selectedIDs: ["0"])
        changed.syncPlaylists = true
        try store.save(changed)
        #expect(try store.load(volumeKey: preferences.volumeKey) == changed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["SYNTHETIC-USB.json"])
    }

    @Test("새 선택은 비어 있고 플레이리스트 동기화는 켜져 있다")
    func defaults() {
        let preferences = UsbSyncPreferences(volumeKey: "SYNTHETIC-USB", localDBID: 42)
        #expect(preferences.selection.selectedIDs.isEmpty)
        #expect(preferences.syncPlaylists)
        #expect(preferences.bindings.isEmpty)
        #expect(preferences.nativeSelectionFingerprint == nil)
    }

    @Test("지문 칸이 없는 옛 설정도 선택을 잃지 않고 읽는다")
    func legacyPreferencesDecodeWithoutNativeFingerprint() throws {
        let original = Data(#"{"volumeKey":"synthetic","localDBID":42,"selection":{"selectedIDs":["folder"]},"syncPlaylists":true,"bindings":{}}"#.utf8)
        let preferences = try JSONDecoder().decode(UsbSyncPreferences.self, from: original)
        #expect(preferences.selection.selectedIDs == ["folder"])
        #expect(preferences.nativeSelectionFingerprint == nil)
    }

    @Test("선택 파일이 없으면 폴더를 만들지 않고 nil을 돌려준다")
    func missingFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "not-created")
        let store = UsbSyncPreferencesStore(directory: directory)
        #expect(try store.load(volumeKey: "SYNTHETIC-USB") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("손상 파일은 읽기·저장이 실패해도 원문이 그대로 남는다")
    func damagedFileIsPreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volumeKey = "SYNTHETIC-USB"
        let file = directory.appending(path: volumeKey + ".json")
        let original = Data("{\"broken".utf8)
        try original.write(to: file)
        let store = UsbSyncPreferencesStore(directory: directory)
        #expect(throws: DecodingError.self) { try store.load(volumeKey: volumeKey) }
        #expect(throws: DecodingError.self) { try store.save(UsbSyncPreferences(volumeKey: volumeKey, localDBID: 42)) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [volumeKey + ".json"])
    }

    @Test("다른 USB의 선택이 들어 있는 파일은 읽거나 덮어쓰지 않는다")
    func mismatchedVolumeIsPreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volumeKey = "SYNTHETIC-USB"
        let file = directory.appending(path: volumeKey + ".json")
        let original = try JSONEncoder().encode(UsbSyncPreferences(volumeKey: "OTHER-SYNTHETIC-USB", localDBID: 42))
        try original.write(to: file)
        let store = UsbSyncPreferencesStore(directory: directory)
        #expect(throws: UsbError.self) { try store.load(volumeKey: volumeKey) }
        #expect(throws: UsbError.self) { try store.save(UsbSyncPreferences(volumeKey: volumeKey, localDBID: 42)) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("볼륨 키가 다른 폴더를 가리키면 읽기·저장을 거부한다", arguments: ["", ".", "..", "../outside", "nested/name", "/absolute", "nul\0key"])
    func unsafeKeys(volumeKey: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsbSyncPreferencesStore(directory: directory)
        #expect(throws: UsbError.self) { try store.load(volumeKey: volumeKey) }
        #expect(throws: UsbError.self) { try store.save(UsbSyncPreferences(volumeKey: volumeKey, localDBID: 42)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
