import DJCDomain
import Foundation
import RekordboxKit

/// USB 동기화 선택(`usb-sync-selections/<볼륨키>.json`). 손상 파일은 오류로 알리고 그대로 보존한다.
public final class UsbSyncPreferencesStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(volumeKey: String) throws -> UsbSyncPreferences? {
        let url = try file(volumeKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let preferences = try JSONDecoder().decode(UsbSyncPreferences.self, from: Data(contentsOf: url))
        guard preferences.volumeKey == volumeKey else {
            throw UsbError.readFailed(detail: "sync preferences volume key mismatch")
        }
        return preferences
    }

    public func save(_ preferences: UsbSyncPreferences) throws {
        let url = try file(preferences.volumeKey)
        // 새 선택으로 손상 파일을 덮지 않게, 기존 선택을 읽을 수 있는지 먼저 확인한다.
        _ = try load(volumeKey: preferences.volumeKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try UsbDurableFile.write(encoder.encode(preferences), to: url)
    }

    private func file(_ volumeKey: String) throws -> URL {
        guard !volumeKey.isEmpty, volumeKey != ".", volumeKey != "..", !volumeKey.contains("/"), !volumeKey.contains("\0") else {
            throw UsbError.readFailed(detail: "bad volume key")
        }
        return directory.appending(path: volumeKey + ".json")
    }
}
