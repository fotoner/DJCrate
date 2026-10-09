import DJCApplication
import DJCDomain
import Foundation
import Testing

/// USB 초안 파일(`UsbDraftFiles`): 없는 초안은 nil, 더하기는 처음 base를 지키고 끝에 붙이며, 저장한 초안을 그대로 읽고(시각은 초 단위),
/// 지우기는 없어도 넘어간다
public func usbDraftFilesContract(_ files: UsbDraftFiles) throws {
    let base = UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 1, mtime: Date(timeIntervalSince1970: 1_800_000_000), sha256: "b")])
    let other = UsbFingerprint(files: [UsbLayout.exportPdb: .init(size: 2, mtime: Date(timeIntervalSince1970: 1_800_000_000), sha256: "o")])
    #expect(try files.load("K") == nil)
    try files.append(.removeTracks(usbContentIDs: [1]), "K", base)
    try files.append(.removeTracks(usbContentIDs: [2]), "K", other)
    let appended = try #require(try files.load("K"))
    #expect(appended.volumeKey == "K" && appended.base == base)
    #expect(appended.edits == [.removeTracks(usbContentIDs: [1]), .removeTracks(usbContentIDs: [2])])
    let saved = UsbDraft(volumeKey: "K", base: other, edits: [.playlist(edit: .rename(playlist: .id("1"), name: "합성"))],
                         createdAt: Date(timeIntervalSince1970: 1_800_000_123))
    try files.save(saved)
    #expect(try files.load("K") == saved)
    try files.discard("K")
    #expect(try files.load("K") == nil)
    try files.discard("K")
    #expect(try files.load("다른 볼륨") == nil)
}

/// USB 동기화 설정(`UsbSyncPreferencesFiles`): 없는 볼륨은 nil, 저장한 것을 볼륨키별로 그대로 읽고, 다시 저장하면 덮는다
public func usbSyncPreferencesContract(_ files: UsbSyncPreferencesFiles) throws {
    #expect(try files.load("SYNC") == nil)
    let saved = UsbSyncPreferences(volumeKey: "SYNC", localDBID: 42, selection: ITunesSyncSelection(selectedIDs: ["10"]), syncPlaylists: true,
                                   nativeSelectionFingerprint: "native-1")
    try files.save(saved)
    #expect(try files.load("SYNC") == saved && files.load("OTHER") == nil)
    var changed = saved
    changed.selection = ITunesSyncSelection(selectedIDs: ["10", "11"])
    try files.save(changed)
    #expect(try files.load("SYNC") == changed)
}
