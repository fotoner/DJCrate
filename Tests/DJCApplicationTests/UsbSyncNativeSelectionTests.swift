import DJCApplication
import DJCDomain
import Testing

@Suite("USB의 rekordbox 동기화 선택 우선순위")
struct UsbSyncNativeSelectionTests {
    private let localDBID: Int64 = 42
    private let native = ITunesSyncSelection(selectedIDs: ["itunes:DJ"])
    private let app = ITunesSyncSelection(selectedIDs: ["local-list"])

    private func preferences(fingerprint: String?, dbid: Int64 = 42) -> UsbSyncPreferences {
        UsbSyncPreferences(volumeKey: "synthetic", localDBID: dbid, selection: app, syncPlaylists: false,
                           nativeSelectionFingerprint: fingerprint)
    }

    @Test("기존 앱 설정에 지문이 없으면 USB에 저장된 선택과 켜짐을 채택한다")
    func legacyPreferencesFollowNativeSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "native-first",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == native)
        #expect(choice.enabled)
        #expect(!choice.usesSavedPreferences)
    }

    /// 2026-10-08 실험 G2a·G5b: rekordbox는 동기화하지 않고 닫으면 체크 변경을 버리고, 꺼진 동안에는 체크를 바꿀 수 없다.
    /// 그래서 앱이 저장한 옛 선택(꺼진 채 바꾼 체크 포함)을 다시 채택하지 않고 USB 선택 파일을 따른다.
    @Test("USB 원본 지문이 같아도 선택과 켜짐은 USB 선택 파일을 따르고 저장한 연결만 이어 쓴다")
    func unchangedNativeSelectionFollowsNativeFiles() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "native-first"), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "native-first",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == native)
        #expect(choice.enabled)
        #expect(choice.usesSavedPreferences)
    }

    @Test("rekordbox가 USB 선택을 바꾸면 앱의 옛 선택보다 새 원본을 우선한다")
    func changedNativeSelectionReplacesOldAppPreferences() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "old"), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "new",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(choice.enabled)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("두 형식 충돌로 지문을 만들 수 없으면 nil끼리 같다고 앱 선택을 채택하지 않는다")
    func conflictingFilesNeverMatchNilFingerprint() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: nil,
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("선택 파일이 없는 기존 DJCrate USB는 저장된 앱 선택을 이어 쓴다")
    func noNativeFilesKeepsExistingAppSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: nil), localDBID: localDBID,
                                                     hasNativeFiles: false, fingerprint: nil,
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: ITunesSyncSelection())
        #expect(choice.selection == app)
        #expect(!choice.enabled)
        #expect(choice.usesSavedPreferences)
    }

    @Test("다른 로컬 DB에서 저장한 앱 선택은 지문이 같아도 쓰지 않는다")
    func differentLocalDatabaseRejectsSavedSelection() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: preferences(fingerprint: "same", dbid: 99), localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "same",
                                                     nativeSelection: native, nativeEnabled: true,
                                                     fallbackSelection: app)
        #expect(choice.selection == native)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("USB 켜짐을 확인하지 못하면 현재 화면 값을 참으로 바꾸지 않는다")
    func unknownEnabledStateKeepsTheCurrentControl() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: nil, localDBID: localDBID,
                                                     hasNativeFiles: true, fingerprint: "same",
                                                     nativeSelection: native, nativeEnabled: nil,
                                                     fallbackSelection: app, currentEnabled: false)
        #expect(choice.selection == native)
        #expect(!choice.enabled)
    }

    /// 2026-10-08 빈 USB 실험: rekordbox는 선택 파일이 없는 USB를 동기화 꺼짐으로 열고, 켜면 행 없는 선택 파일을 만든다.
    @Test("선택 파일과 앱 설정이 없는 USB는 동기화 꺼짐으로 연다")
    func noNativeFilesStartDisabled() {
        let choice = UsbSyncPreferenceChoice.resolve(preferences: nil, localDBID: localDBID, hasNativeFiles: false, fingerprint: nil,
                                                     nativeSelection: native, nativeEnabled: nil, fallbackSelection: app)
        #expect(choice.selection == app)
        #expect(!choice.enabled)
        #expect(!choice.usesSavedPreferences)
    }

    @Test("닫을 때 켜짐 쓰기: 파일이 없으면 라이브러리가 있는 USB에서 켰을 때만 쓴다")
    func enabledChangeWithoutNativeFiles() {
        typealias Model = UsbSyncPreferenceChoice
        #expect(Model.enabledChanged(hasNativeFiles: false, nativeEnabled: nil, hasLibrary: true, syncPlaylists: true))
        #expect(!Model.enabledChanged(hasNativeFiles: false, nativeEnabled: nil, hasLibrary: true, syncPlaylists: false))
        // 라이브러리가 없는 빈 USB는 켜짐만 쓰지 않는다(SYNC 때 DB와 함께 만든다).
        #expect(!Model.enabledChanged(hasNativeFiles: false, nativeEnabled: nil, hasLibrary: false, syncPlaylists: true))
        #expect(Model.enabledChanged(hasNativeFiles: true, nativeEnabled: true, hasLibrary: true, syncPlaylists: false))
        #expect(!Model.enabledChanged(hasNativeFiles: true, nativeEnabled: true, hasLibrary: true, syncPlaylists: true))
        // 두 파일의 켜짐이 달라 확인하지 못하면 쓰지 않는다.
        #expect(!Model.enabledChanged(hasNativeFiles: true, nativeEnabled: nil, hasLibrary: true, syncPlaylists: true))
    }

    @Test("닫을 때는 동기화가 켜진 채 체크를 바꿨거나 켰을 때만 지금 동기화할지 묻는다")
    func closePromptConditions() {
        typealias Model = UsbSyncPreferenceChoice
        // G2a·G3: 체크를 바꾸고 닫으면 묻는다. G5c: 켜기만 하고 닫아도 묻는다. G5a: 끄고 닫으면 묻지 않는다.
        #expect(Model.asksToSyncOnClose(syncPlaylists: true, canSync: true, selectionDiffers: true, enabledChanged: false))
        #expect(Model.asksToSyncOnClose(syncPlaylists: true, canSync: true, selectionDiffers: false, enabledChanged: true))
        #expect(!Model.asksToSyncOnClose(syncPlaylists: false, canSync: false, selectionDiffers: false, enabledChanged: true))
        #expect(!Model.asksToSyncOnClose(syncPlaylists: true, canSync: true, selectionDiffers: false, enabledChanged: false))
        // SYNC를 누를 수 없는 상태(선택 파일 문제 등)에서는 "예"가 쓸 수 없으니 묻지 않는다.
        #expect(!Model.asksToSyncOnClose(syncPlaylists: true, canSync: false, selectionDiffers: true, enabledChanged: false))
    }

    @Test("선택 비교는 폴더 자체 체크와 하위를 모두 체크한 것을 구분한다")
    func selectionDifferenceKeepsFolderCheckType() {
        let nodes: [ITunesSyncSelection.Node] = [.init(id: "f", parentID: nil, isFolder: true),
                                                 .init(id: "a", parentID: "f", isFolder: false),
                                                 .init(id: "b", parentID: "f", isFolder: false)]
        let folder = ITunesSyncSelection(selectedIDs: ["f"])
        // G1: 하위를 하나씩 모두 체크한 폴더는 선택 파일에 CheckType 2(부분 체크)로 적혔다.
        let children = ITunesSyncSelection(selectedIDs: ["a", "b"])
        #expect(UsbSyncPreferenceChoice.selectionDiffers(folder, from: children, nodes: nodes))
        #expect(!UsbSyncPreferenceChoice.selectionDiffers(folder, from: ITunesSyncSelection(selectedIDs: ["f", "a", "b"]), nodes: nodes))
        #expect(UsbSyncPreferenceChoice.selectionDiffers(ITunesSyncSelection(selectedIDs: ["0"]), from: ITunesSyncSelection(selectedIDs: ["f"]), nodes: nodes))
    }
}
