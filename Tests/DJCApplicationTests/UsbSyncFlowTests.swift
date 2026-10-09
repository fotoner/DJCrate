import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// USB 동기화 창의 유스케이스(`UsbSync`): 열기·체크 저장·SYNC·닫기·큐 그리드 가져오기의 순서와 판정. 라이브러리·USB·파일·창은 가짜(`UsbSyncWorld`).
/// 유스케이스는 화면 상태를 들지 않는다. 오류·안내는 알림(`UsbSyncNotice`)으로, 흐름 상태는 `UsbSyncState`로 내보낸다(가짜 화면 `world.problem`·`world.info`가 받는다).
@MainActor
@Suite("USB 동기화 흐름")
struct UsbSyncFlowTests {
    func world(selection: Set<String> = ["10"], enabled: Bool? = true) -> UsbSyncWorld {
        let world = UsbSyncWorld(sources: UsbSyncSamples.source(), usbLibrary: UsbSyncSamples.usb())
        world.box.native.withLock {
            $0.selection = ITunesSyncSelection(selectedIDs: selection)
            $0.enabled = enabled
            $0.playlistIDs = ["10": 1]
        }
        return world
    }

    func session(_ world: UsbSyncWorld) -> UsbSync {
        let sync = UsbSync(volumeKey: "SYNC", library: world.usbLibrary)
        sync.output = world.output
        return sync
    }

    func opened(_ world: UsbSyncWorld) async -> UsbSync {
        let sync = session(world)
        await sync.load(world.ports())
        return sync
    }

    // MARK: - 열기

    @Test func 스냅샷이나_볼륨이_없으면_읽지_않고_다시_읽으라고_알린다() async {
        let world = world()
        world.library.snapshot = nil
        let sync = await opened(world)
        #expect(world.problem == "로컬 라이브러리와 USB를 다시 읽은 뒤 동기화 창을 여세요")
        #expect(!sync.state.isLoading && world.leaseCount == 0 && world.box.native.withLock { $0.reads } == 0)
    }

    @Test func 오류는_화면_상태로_들지_않고_알림으로_보내고_흐름_상태는_바뀔_때마다_내보낸다() async {
        let world = world()
        world.library.snapshot = nil
        let sync = await opened(world)
        // 여는 차례: 지난 오류·안내를 지우고 막힌 이유를 보낸다
        #expect(world.notices == [.clearProblem, .clearInfo, .problem("로컬 라이브러리와 USB를 다시 읽은 뒤 동기화 창을 여세요")])
        #expect(world.published.contains { $0.isLoading } && world.published.last?.isLoading == false)
        #expect(world.published.last?.library == sync.state.library)
    }

    @Test func 사본을_빌리는_동안_라이브러리가_바뀌면_파일을_읽지_않는다() async {
        let world = world()
        world.onLease = { world.library.revision += 1 }
        let sync = await opened(world)
        #expect(world.problem == "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
        #expect(world.box.native.withLock { $0.reads } == 0 && !sync.state.canSync)
    }

    @Test func 연_USB의_선택_파일을_따르고_원본을_USB_목록에_잇는다() async {
        let world = world()
        let sync = await opened(world)
        #expect(world.problem == nil && !sync.state.isLoading)
        #expect(sync.selection == ITunesSyncSelection(selectedIDs: ["10"]) && sync.state.usbSelection == sync.selection)
        #expect(sync.syncPlaylists && sync.state.canSync)
        #expect(sync.state.unlinkedUsbIDs.isEmpty, "목록 A는 USB 목록 1에 이어진다")
        #expect(!sync.state.selectionDiffersFromUsb && !sync.state.enabledChanged)
    }

    @Test func 설정을_읽지_못해도_열고_이유를_알린다() async {
        let world = world()
        world.preferencesFail = true
        let sync = await opened(world)
        #expect(world.problem == "USB 동기화 설정을 읽지 못했습니다. 데이터 폴더의 usb-sync-selections 파일을 확인한 뒤 다시 시도하세요")
        #expect(sync.state.canSync)
    }

    @Test func 파일_포트가_없으면_읽지_못한_것으로_알린다() async {
        let world = world()
        var ports = world.ports()
        ports.files = nil
        let sync = session(world)
        await sync.load(ports)
        #expect(world.problem == "USB 동기화 선택이나 로컬 라이브러리를 읽지 못했습니다. USB와 라이브러리를 새로고침한 뒤 다시 시도하세요")
        #expect(!sync.state.canSync)
    }

    @Test func 체크를_바꿀_때마다_설정에_저장하고_마지막_저장이_지금_선택이다() async throws {
        let world = world()
        let sync = await opened(world)
        #expect(world.box.preferences.saves.isEmpty, "여는 동안은 저장하지 않는다")
        sync.toggle("11")
        sync.toggle("11")
        sync.toggle("10")
        // 저장은 뒤에서 누른 차례로 한다(앞선 저장이 나중에 남지 않는다)
        try await waitUntil { world.box.preferences.saves.count == 3 }
        let saved = world.box.preferences.saves
        #expect(saved.last?.selection == sync.selection && sync.selection.selectedIDs.isEmpty)
        #expect(saved.allSatisfy { $0.localDBID == UsbSyncWorld.localDBID && $0.volumeKey == "SYNC" && $0.nativeSelectionFingerprint == "native-1" })
    }

    @Test func 설정_폴더가_없으면_저장하지_않는다() async throws {
        let world = world()
        let sync = session(world)
        await sync.load(world.ports(preferences: false))
        sync.toggle("11")
        try await Task.sleep(for: .milliseconds(20))
        #expect(world.box.preferences.saves.isEmpty && world.problem == nil)
    }

    // MARK: - SYNC

    @Test func rekordbox가_켜져_있으면_초안을_만들지_않는다() async {
        let world = world()
        let sync = await opened(world)
        world.service.state.withLock { $0.rekordboxRunning = true }
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.problem == "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")
        #expect(world.appended.isEmpty && world.written.isEmpty)
    }

    @Test func 다른_앱이_선택_파일을_바꿨으면_덮지_않는다() async {
        let world = world()
        let sync = await opened(world)
        world.box.native.withLock { $0.baseFiles[.oneLibrary] = Data("other".utf8); $0.fingerprint = "native-2" }
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.problem == "USB 동기화 선택이 다른 앱에서 바뀌었습니다. 새로고침해 바뀐 선택을 확인한 뒤 동기화하세요")
        #expect(world.appended.isEmpty)
    }

    @Test func USB_DB가_바뀌었으면_쓰지_않는다() async {
        let world = world()
        let sync = await opened(world)
        world.service.state.withLock { $0.base = UsbFingerprint(files: [:]) }
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.problem == "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요" && world.appended.isEmpty)
    }

    @Test func masterPlaylists6에_없는_목록을_체크했으면_막는다() async {
        let world = world(selection: ["11"])
        let sync = await opened(world)
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.problem?.hasPrefix("masterPlaylists6.xml에서 동기화할 목록을 찾지 못했습니다") == true)
        #expect(world.appended.isEmpty)
    }

    @Test func SYNC는_계획을_초안에_넣고_빌린_사본으로_쓴_뒤_새_선택을_USB_선택으로_삼는다() async throws {
        let world = world()
        let sync = await opened(world)
        #expect(await sync.sync(world.ports()) == true, "\(world.problem ?? "")")
        #expect(world.calls.filter { $0 != "lease" } == ["append", "write"])
        let edits = try #require(world.appended.first)
        guard case let .syncSelection(draft)? = edits.last else { Issue.record("선택 파일 편집이 끝에 온다"); return }
        #expect(draft.localDBID == UsbSyncWorld.localDBID && draft.enabled && draft.selection == sync.selection)
        #expect(draft.baseFiles == world.box.native.withLock { $0.baseFiles }, "읽은 원문 그대로를 base로 싣는다")
        let (job, written) = try #require(world.written.first)
        #expect(written == edits)
        #expect(job.database == UsbSyncWorld.copy && job.share == UsbSyncWorld.share, "로컬은 빌린 사본·화면의 share")
        #expect(job.syncSourceContext?.catalogRevision == 1 && job.syncSourceContext?.snapshot?.provenance == UsbSyncWorld.provenance)
        #expect(sync.state.usbSelection == sync.selection && !sync.state.isSyncing)
        try await waitUntil { !world.box.preferences.saves.isEmpty }
    }

    @Test func 이_계획이_아닌_쓰기_대기_초안이_있으면_새로_계획하지_않는다() async {
        let world = world()
        let sync = await opened(world)
        world.draftEdits = [.playlist(edit: .rename(playlist: .id("1"), name: "다른 편집"))]
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.problem == "이 USB에 쓰기 대기 중인 초안이 있습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 동기화하세요")
        #expect(world.appended.isEmpty && world.written.isEmpty)
    }

    @Test func 초안을_넣은_뒤_라이브러리가_바뀌면_쓰지_않는다() async {
        let world = world()
        let sync = await opened(world)
        var ports = world.ports()
        let append = ports.drafts!.append
        ports.drafts!.append = { edits, detail in
            let saved = await append(edits, detail)
            world.library.revision += 1
            return saved
        }
        #expect(await sync.sync(ports) == false)
        #expect(world.problem == "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")
        #expect(world.appended.count == 1 && world.written.isEmpty)
    }

    @Test func 쓰기가_초안을_남기면_결과를_알리고_창을_남긴다() async {
        let world = world()
        let sync = await opened(world)
        world.writeSucceeds = false
        #expect(await sync.sync(world.ports()) == false)
        #expect(world.info == "쓰기 결과 설명")
    }

    @Test func 빈_USB는_체크한_목록을_동기화_선택과_함께_내보낸다() async throws {
        let world = world()
        world.usbLibrary = nil
        world.isEmptyExportable = true
        world.box.native.withLock { $0.baseFiles = [:]; $0.fingerprint = nil; $0.enabled = nil; $0.playlistIDs = [:] }
        let sync = await opened(world)
        // rekordbox처럼 선택 파일이 없는 USB는 동기화 꺼짐으로 연다
        #expect(!sync.syncPlaylists && !sync.state.canSync)
        sync.syncPlaylists = true
        sync.selection = ITunesSyncSelection(selectedIDs: ["10"])
        #expect(sync.state.canSync)
        _ = await sync.sync(world.ports())
        let job = try #require(world.exported.first)
        #expect(job.selection == .playlists(["10"]) && job.formats == UsbFormat.defaultSet && job.database == UsbSyncWorld.copy)
        #expect(job.syncSelection?.selection == ITunesSyncSelection(selectedIDs: ["10"]) && job.snapshotLease != nil)
        #expect(world.appended.isEmpty, "빈 USB는 초안 없이 내보낸다")
    }

    // MARK: - 닫기

    @Test func 바꾼_체크를_동기화하지_않고_닫으면_USB의_선택으로_되돌린다() async {
        let world = world()
        let sync = await opened(world)
        sync.toggle("11")
        world.answers = [false]
        #expect(await sync.close(world.ports()) == .close)
        #expect(world.prompts == [UsbSync.unsyncedClosePrompt])
        #expect(sync.selection == sync.state.usbSelection && world.written.isEmpty)
    }

    @Test func 닫으며_동기화하지_못하면_이유를_보이고_한_번_더_닫으면_묻지_않고_닫는다() async {
        let world = world()
        let sync = await opened(world)
        sync.toggle("11")
        world.answers = [true]
        world.service.state.withLock { $0.rekordboxRunning = true }
        // 창을 남기고 다음 닫기는 쓰지 않고 닫는다(그 안내 문구는 화면 모델이 이유 뒤에 붙인다)
        #expect(await sync.close(world.ports()) == .stayUntilNextClose)
        #expect(world.problem == "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")
        #expect(await sync.close(world.ports()) == .close)
        #expect(world.prompts.count == 1, "두 번째 닫기는 묻지 않는다")
    }

    @Test func 동기화를_끈_채_닫으면_켜짐_칸만_쓴다() async throws {
        let world = world()
        let sync = await opened(world)
        sync.syncPlaylists = false
        #expect(sync.state.enabledChanged && !sync.state.canSync)
        #expect(await sync.close(world.ports()) == .close, "\(world.problem ?? "")")
        #expect(world.prompts.isEmpty, "꺼진 채 닫으면 묻지 않는다")
        let edits = try #require(world.appended.first)
        guard case let .syncSelection(draft)? = edits.first, edits.count == 1 else { Issue.record("켜짐 칸만"); return }
        #expect(draft.enabledOnly && !draft.enabled && draft.localDBID == UsbSyncWorld.localDBID)
        #expect(world.written.count == 1)
    }

    @Test func 켜짐만_쓰지_못하면_이유를_알리고_다음_닫기까지_창을_남긴다() async {
        let world = world()
        let sync = await opened(world)
        sync.syncPlaylists = false
        world.draftEdits = [.playlist(edit: .rename(playlist: .id("1"), name: "다른 편집"))]
        #expect(await sync.close(world.ports()) == .stayUntilNextClose)
        #expect(world.problem == "이 USB에 쓰기 대기 중인 초안이 있어 동기화 켜짐을 저장하지 못했습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 다시 바꾸세요")
        #expect(world.appended.isEmpty && world.written.isEmpty)
        #expect(await sync.close(world.ports()) == .close, "두 번째 닫기는 쓰지 않고 닫는다")
        #expect(world.appended.isEmpty)
    }

    @Test func 닫는_중에_다시_닫으면_들어가지_않는다() async {
        let world = world()
        let sync = await opened(world)
        #expect(sync.beginClosing())
        #expect(await sync.close(world.ports()) == .stay)
        sync.endClosing()
        #expect(await sync.close(world.ports()) == .close)
    }

    // MARK: - 큐·그리드 가져오기

    @Test func 큐_그리드_가져오기는_묻고_취소하면_가져오지_않는다() async {
        let world = world()
        let sync = await opened(world)
        // 짝이 있는 곡이 없으면 단추가 꺼져 있다
        #expect(!sync.state.canImport)
        await sync.importCueGrid(world.ports())
        #expect(world.prompts.isEmpty && !world.calls.contains("import"))
    }

    // MARK: - 도우미

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
