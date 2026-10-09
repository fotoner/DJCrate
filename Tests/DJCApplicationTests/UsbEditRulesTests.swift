import DJCApplication
import DJCDomain
import DJCTestKit
import Testing

/// USB 초안 편집의 막힘 미리 판정(`UsbEditRules`). 문구 대신 이유 이름(`UsbEditRules.Reason`)·관문 막힘과 비교한다
@Suite("USB 편집 막힘 판정")
struct UsbEditRulesTests {
    static let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    static let physical = FakeUsbVolume.physicalFAT32()

    /// 곡 1·2·3과 일반 목록(10), 두 형식의 항목이 다른 목록(4)·폴더(5)·폴더 안 목록(6)
    static func library() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        var library = UsbLibrary(formats: both, property: UsbProperty(dbVersion: "1000"))
        library.tracks = [1, 2, 3].map { UsbTrack(id: $0, presentIn: both) }
        library.playlists = [
            UsbPlaylist(id: 10, name: "시험 목록", presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [2, 1, 2], .deviceLibrary: [2, 1, 2]]),
            UsbPlaylist(id: 4, name: "다름", presentIn: both, sortOrder: [.oneLibrary: 1, .deviceLibrary: 1],
                        entries: [.oneLibrary: [1, 2, 3], .deviceLibrary: [3, 1, 2, 3]]),
            UsbPlaylist(id: 5, name: "폴더", attribute: 1, presentIn: both, sortOrder: [.oneLibrary: 2, .deviceLibrary: 2]),
            UsbPlaylist(id: 6, name: "폴더 안", parentID: 5, presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [3], .deviceLibrary: [3]]),
        ]
        return library
    }

    func reason(_ edit: UsbLibraryEdit, _ volume: UsbVolumeInfo? = image, scratch: Bool = true,
                gate: UsbPhysicalWriteGate = .init(), info: UsbInfo? = nil) -> String? {
        UsbEditRules.blockReason(edit, volume: volume, library: Self.library(), info: info, isScratchMount: { _ in scratch }, physicalGate: gate,
                                 syncGate: .open)
    }

    /// 동의 없는 관문이 실물을 막는 이유(볼륨 이름 확인은 앱 확인 창이 대신한다)
    func gateReason(_ volume: UsbVolumeInfo) -> String? {
        UsbPhysicalWriteGate().blocks(volume.judgedForWrite(underScratch: false), confirmName: volume.name).first?.message
    }

    @Test("볼륨: 동의 없는 실물·임시 폴더 밖 이미지는 관문이 막고, 동의하면 실물도 막지 않으며, 볼륨 모양은 정책이 막는다")
    func volumeGate() throws {
        let add = UsbLibraryEdit.addTracks(localContentIDs: ["11"], playlist: nil)
        let gate = try #require(gateReason(Self.physical))
        #expect(reason(add, Self.physical) == gate)
        #expect(reason(.removeTracks(usbContentIDs: [1]), Self.physical) == gate)
        #expect(reason(add, Self.image) == nil)
        // 임시 폴더 밖에 붙인 디스크 이미지는 실물처럼 판정한다(쓰기 때 세션 판정과 같다)
        #expect(reason(add, Self.image, scratch: false) == gate)
        #expect(reason(.playlist(edit: .rename(playlist: .id("4"), name: "새 이름")), Self.image, scratch: false) == gate)
        // 앱(확인 창이 동의)은 실물에도 곡 정보 갱신까지 막지 않는다(확인 안 된 규칙은 확인 창이 알린다)
        let consented = UsbPhysicalWriteGate(consented: true)
        #expect(reason(add, Self.physical, gate: consented) == nil)
        #expect(reason(.refreshTracks(usbContentIDs: [1], parts: [.info]), Self.physical, gate: consented) == nil)
        #expect(reason(add, FakeUsbVolume.exfat(), gate: consented) == nil)
        let apfs = FakeUsbVolume.apfs()
        #expect(reason(add, apfs, gate: consented) == UsbVolumePolicy.problems(apfs, purpose: .edit).first?.message)
        #expect(reason(add, apfs, gate: consented) != nil)
    }

    @Test("목록·곡: 두 형식 항목이 다른 목록은 곡만 막고, 폴더에는 곡을 못 넣고, 곡이 다 빠지거나 대상이 없으면 막는다")
    func libraryRules() {
        let differ = UsbEditRules.Reason.entriesDiffer
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: .id("4"))) == differ)
        #expect(reason(.playlist(edit: .addTracks(playlist: .id("4"), contentIDs: ["1"]))) == differ)
        #expect(reason(.playlist(edit: .removeTracks(playlist: .id("4"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")]))) == differ)
        // 이름·위치는 바꿀 수 있다
        #expect(reason(.playlist(edit: .rename(playlist: .id("4"), name: "새 이름"))) == nil)
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: .id("5"))) == UsbEditRules.Reason.notEntryList)
        #expect(reason(.removeTracks(usbContentIDs: [1, 2, 3])) == UsbEditRules.Reason.noTracksLeft)
        #expect(reason(.playlist(edit: .delete(playlist: .id("99")))) == UsbEditRules.Reason.missingTarget)
        // 두 형식의 곡 번호가 다른 USB는 모든 편집을 막는다
        var info = UsbInfo(root: Self.image.mountPoint)
        info.consistency = UsbInfo.Consistency(trackIDsMatch: false, editBlocked: true)
        #expect(reason(.addTracks(localContentIDs: ["11"], playlist: nil), info: info) == UsbEditRules.Reason.trackIDsDiffer)
    }

    @Test("동기화 편집은 항목 편집의 막힘을 따른다")
    func syncPlaylistFollowsEntryRules() {
        func sync(_ ref: PlaylistRef) -> String? { reason(.syncPlaylist(playlist: ref, localContentIDs: ["101"]), nil) }
        #expect(sync(.id("10")) == nil)
        #expect(sync(.new("sync")) == nil)
        #expect(sync(.id("4")) == UsbEditRules.Reason.entriesDiffer)
        #expect(sync(.id("5")) == UsbEditRules.Reason.notEntryList)
        #expect(sync(.id("999")) == UsbEditRules.Reason.missingTarget)
    }

    @Test("동기화 초안 설명은 목록 이름과 중복을 포함한 곡 수를 보인다")
    func syncDraftDescription() {
        let edit = UsbLibraryEdit.syncPlaylist(playlist: .id("10"), localContentIDs: ["101", "102", "101"])
        #expect(UsbEditText.describe(edit, library: Self.library()) == "‘시험 목록’ 동기화 · 곡 3개")
        #expect(UsbEditText.describe(.syncPlaylist(playlist: .new("sync"), localContentIDs: []), library: Self.library(),
                                    created: ["sync": "새 동기화 목록"]) == "‘새 동기화 목록’ 동기화 · 곡 0개")
    }

    @Test("묶음 검사도 두 형식의 충돌과 실물 관문을 유지하고 새 참조는 최종 엔진에 맡긴다")
    func batchPrecheckKeepsExistingSafetyGuards() {
        let library = Self.library()
        let edits: [UsbLibraryEdit] = [.playlist(edit: .rename(playlist: .id("10"), name: "변경"))]
        var info = UsbInfo(root: "/synthetic")
        info.consistency.editBlocked = true
        info.consistency.trackIDsMatch = false
        #expect(UsbEditRules.blockReason(edits, volume: nil, library: library, info: info, isScratchMount: { _ in true }, syncGate: .open)
            == UsbEditRules.Reason.trackIDsDiffer)
        var physical = Self.image
        physical.isDiskImage = false
        #expect(UsbEditRules.blockReason(edits, volume: physical, library: library, info: nil,
                                          isScratchMount: { _ in false }, syncGate: .open) == gateReason(physical))
        #expect(UsbEditRules.blockReason([
            .playlist(edit: .create(key: "new-parent", name: "새 부모", isFolder: true, parent: .root)),
            .playlist(edit: .move(playlist: .id("5"), into: .new("new-parent"))),
            .addTracks(localContentIDs: ["unknown-local"], playlist: .new("new-list")),
        ], volume: nil, library: library, info: nil, isScratchMount: { _ in true }, syncGate: .open) == nil)
    }

    @Test("동기화 선택 편집은 엔진이 준 관문 규칙(생산 계약·두 형식 선택 파일·초안 원문)으로 막는다")
    func syncSelectionUsesEngineGate() {
        let draft = UsbSyncSelectionDraft.enabledOnly(localDBID: 1, enabled: true, baseFiles: [:])
        let partial = UsbBlock(code: "syncSelectionPartialFiles", scope: .volume, message: "한 형식만")
        let unverified = UsbBlock(code: "syncWriteUnverified", scope: .volume, message: "계약 없음")
        let pending = UsbBlock(code: "syncSelectionPendingRekordboxSync", scope: .volume, message: "다시 쓴 원문")
        func reason(_ gate: UsbSyncSelectionGate, library: UsbLibrary?) -> String? {
            UsbEditRules.blockReason(.syncSelection(draft: draft), volume: nil, library: library, info: nil, isScratchMount: { _ in true },
                                     syncGate: gate)
        }
        let gated = UsbSyncSelectionGate(gateBlock: { _, formats in formats == UsbFormat.defaultSet ? partial : nil },
                                         productionBlock: { unverified }, draftBlock: { _ in nil })
        // 라이브러리를 읽었으면 그 형식으로 관문을 보고, 아직 못 읽었으면 생산 계약만 본다
        #expect(reason(gated, library: Self.library()) == partial.message)
        #expect(reason(gated, library: nil) == unverified.message)
        #expect(reason(UsbSyncSelectionGate(gateBlock: { _, _ in nil }, productionBlock: { nil }, draftBlock: { _ in pending }),
                       library: Self.library()) == pending.message)
        #expect(reason(.open, library: Self.library()) == nil)
    }
}
