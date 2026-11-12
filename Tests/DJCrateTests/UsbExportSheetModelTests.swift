@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

@Suite("USB 내보내기 시트 모델")
struct UsbExportSheetModelTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B12T")

    /// 폴더(1) 아래 목록 둘(11·12), 맨 위 목록 하나(2), 스마트 목록 하나(3). 곡 ID는 지어낸 값
    static let layout = PlaylistLayout([
        (item: PlaylistLayout.Item(id: "1", name: "폴더", parentID: PlaylistLayout.root, isFolder: true, isSmart: false, entries: []), seq: 1),
        (item: PlaylistLayout.Item(id: "11", name: "목록 가", parentID: "1", isFolder: false, isSmart: false,
                                   entries: [PlaylistEntry(trackNo: 1, contentID: "101"), PlaylistEntry(trackNo: 2, contentID: "102")]), seq: 1),
        (item: PlaylistLayout.Item(id: "12", name: "목록 나", parentID: "1", isFolder: false, isSmart: false,
                                   entries: [PlaylistEntry(trackNo: 1, contentID: "103")]), seq: 2),
        (item: PlaylistLayout.Item(id: "2", name: "목록 다", parentID: PlaylistLayout.root, isFolder: false, isSmart: false,
                                   entries: [PlaylistEntry(trackNo: 1, contentID: "104")]), seq: 2),
        (item: PlaylistLayout.Item(id: "3", name: "스마트", parentID: PlaylistLayout.root, isFolder: false, isSmart: true, entries: []), seq: 3),
    ])

    @Test("형식은 기본으로 둘 다 쓰고, 마지막 하나는 끌 수 없다")
    func formatsDefaultBoth() {
        var model = UsbExportSelection(volume: image, selectedTrackIDs: [])
        #expect(model.formats == [.oneLibrary, .deviceLibrary])
        model.setFormat(.deviceLibrary, on: false)
        #expect(model.formats == [.oneLibrary])
        model.setFormat(.oneLibrary, on: false)
        #expect(model.formats == [.oneLibrary])
        model.setFormat(.deviceLibrary, on: true)
        #expect(model.formats == UsbFormat.defaultSet)
        #expect(model.isTestVolume)
    }

    @Test("원본: 목록 트리에서 폴더를 고르면 안의 목록은 따로 넘기지 않고, 고른 곡을 함께 넘길 수 있다")
    func sourceSelection() {
        var model = UsbExportSelection(volume: image, selectedTrackIDs: ["104", "201"])
        #expect(model.selection(layout: Self.layout) == nil)
        #expect(!model.canPreview(layout: Self.layout))

        model.setPlaylist("11", selected: true)
        model.setPlaylist("1", selected: true)
        model.setPlaylist("2", selected: true)
        #expect(model.isCovered("11", layout: Self.layout))
        #expect(!model.isCovered("2", layout: Self.layout))
        // 트리 순서, 폴더 안 목록은 폴더가 품는다
        #expect(model.selection(layout: Self.layout) == .playlists(["1", "2"]))

        model.includesSelectedTracks = true
        #expect(model.selection(layout: Self.layout) == .both(playlists: ["1", "2"], tracks: ["104", "201"]))

        model.setPlaylist("1", selected: false)
        model.setPlaylist("2", selected: false)
        model.setPlaylist("11", selected: false)
        #expect(model.selection(layout: Self.layout) == .tracks(["104", "201"]))

        // 트리 줄: 깊이·스마트 목록 표시
        let rows = UsbExportSelection.rows(Self.layout)
        #expect(rows.map(\.id) == ["1", "11", "12", "2", "3"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0, 0])
        #expect(rows.first { $0.id == "3" }?.isSmart == true)
        #expect(rows.first { $0.id == "11" }?.trackCount == 2)

        // 고르는 것이 바뀌면 앞의 미리 보기는 버린다
        model.summary = UsbTestData.summary()
        model.setFormat(.deviceLibrary, on: false)
        #expect(model.summary == nil)
        model.summary = UsbTestData.summary()
        model.setPlaylist("2", selected: true)
        #expect(model.summary == nil)
    }

    @Test("막힌 곡은 이유(code)별로 곡 수를 센다")
    func blockCountsByCode() {
        let blocks = [
            UsbBlock(code: "analysisMissing", scope: .track("7"), message: "분석 먼저"),
            UsbBlock(code: "audioSizeMismatch", scope: .track("8"), message: "다시 분석"),
            UsbBlock(code: "analysisMissing", scope: .track("9"), message: "분석 먼저"),
            UsbBlock(code: "analysisMissing", scope: .track("9"), message: "분석 먼저"),
            UsbBlock(code: "smartPlaylist", scope: .playlist("3"), message: "스마트 목록"),
        ]
        let summary = UsbTestData.summary(blocks: blocks)
        #expect(summary.blockCounts == [
            UsbExportSummary.BlockCount(code: "analysisMissing", message: "분석 먼저", count: 2, kind: .track),
            UsbExportSummary.BlockCount(code: "audioSizeMismatch", message: "다시 분석", count: 1, kind: .track),
            UsbExportSummary.BlockCount(code: "smartPlaylist", message: "스마트 목록", count: 1, kind: .playlist),
        ])
        #expect(summary.blockedTrackCount == 3)
        #expect(summary.stopping.isEmpty)
        #expect(summary.canWrite)

        // 볼륨 단위 막힘은 쓰기를 멈춘다
        let stopped = UsbTestData.summary(blocks: blocks + [UsbTestData.physicalBlock], testVolume: false)
        #expect(stopped.stopping == [UsbTestData.physicalBlock.message])
        #expect(!stopped.canWrite)
        #expect(stopped.isPhysicalDisabled)
        // 곡이 없거나 준비한 변경이 없으면 쓰지 않는다
        #expect(!UsbTestData.summary(tracks: 0).canWrite)
        #expect(!UsbTestData.summary(hasChanges: false).canWrite)
    }

    @Test("막힘 줄: 곡 막힘만 빼고 쓰는 곡 아래, 재생 목록 막힘은 따로, 볼륨 막힘은 줄에 넣지 않는다(멈추는 까닭으로만 보인다)")
    @MainActor
    func blockLinesByScope() {
        let blocks = [
            UsbBlock(code: "analysisMissing", scope: .track("7"), message: "분석 먼저"),
            UsbBlock(code: "smartPlaylist", scope: .playlist("3"), message: "스마트 목록"),
            UsbBlock(code: "analysisMissing", scope: .track("9"), message: "분석 먼저"),
            UsbBlock(code: "insufficientSpace", scope: .volume, message: "공간 모자람"),
        ]
        let summary = UsbTestData.summary(blocks: blocks)
        #expect(summary.stopping == ["공간 모자람"])
        #expect(UsbWriteFlow.blockLines(summary) == [
            "빼고 쓰는 곡 2개:", "• 분석 먼저 (2)",
            "빼고 쓰는 재생 목록 1개:", "• 스마트 목록 (1)",
        ])
        // 곡 막힘이 없으면 재생 목록 막힘만
        let playlistsOnly = UsbTestData.summary(blocks: [blocks[1]])
        #expect(UsbWriteFlow.blockLines(playlistsOnly) == ["빼고 쓰는 재생 목록 1개:", "• 스마트 목록 (1)"])
    }

    @Test("용량이 모자라면 표시하고 쓰기를 막는다")
    func insufficientSpaceShown() {
        let enough = UsbTestData.summary(required: 2 << 20, available: 100 << 20)
        #expect(!enough.isShortOfSpace)
        #expect(enough.spaceText == "필요 공간 2MB · 여유 100MB")
        let block = UsbBlock(code: "insufficientSpace", scope: .volume, message: "USB 여유 공간이 모자랍니다")
        let short = UsbTestData.summary(blocks: [block], required: 300 << 20, available: 100 << 20)
        #expect(short.isShortOfSpace)
        #expect(!short.canWrite)
        #expect(short.spaceText == "필요 공간 300MB · 여유 100MB")
        // 막힘이 없어도 필요한 공간이 여유보다 크면 모자란 것으로 본다
        #expect(UsbTestData.summary(required: 101 << 20, available: 100 << 20).isShortOfSpace)
    }

    // MARK: - 시트 화면 모델

    /// 시트 화면 모델과 그 쓰기 흐름(가짜 창구·확인 창). 볼륨은 빈 FAT32 디스크 이미지.
    /// rekordbox가 켜졌는지는 가짜 창구 상태(`rekordboxRunning`)를 따른다
    @MainActor
    private func sheet(_ request: UsbExportSheetRequest? = nil, usbHost: FakeUsbHost? = nil, withCoordinator: Bool = true) async
        -> (UsbExportSheetModel, UsbStore, FakeUsbWriteService, FakeUsbWriteHost, ScriptedPrompter) {
        let usbHost = usbHost ?? FakeUsbHost([image])
        usbHost.serveEmpty(image)
        let service = FakeUsbWriteService(), host = FakeUsbWriteHost(), prompter = ScriptedPrompter()
        let usb = UsbTestData.store(usbHost, service: service)
        await usb.refresh()
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter,
                                              isRekordboxRunning: { service.current.rekordboxRunning })
        let source = UsbSyncSource(layout: Self.layout, rekordbox: Self.layout, iTunes: PlaylistLayout(), notices: [:], iTunesStatus: .ready)
        let ports = UsbExportSheetModel.Ports(
            snapshot: { URL(filePath: "/tmp/djc-fixture/m.db") }, share: { URL(filePath: "/tmp/djc-fixture/share") },
            playlists: { Self.layout }, syncSource: { source }, catalogRevision: { 1 }, readEpoch: { 0 },
            sourceIsCurrent: { _, _, _ in true }, coordinator: { withCoordinator ? coordinator : nil })
        let model = UsbExportSheetModel(request: request ?? UsbExportSheetRequest(volume: image), usb: usb, selectedTrackIDs: ["104"], ports: ports)
        return (model, usb, service, host, prompter)
    }

    /// 메인 액터 밖 가짜 창구가 미리 보기를 몇 번째로 받았는지 센다
    final class PreviewCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    @Test("시트 화면 모델: 원본을 고르면 단추 없이 미리 보기가 시작되고, 그동안 진행을 보이며, 끝나면 요약을 남긴다")
    @MainActor
    func sheetModelAutoPreview() async throws {
        let (model, _, service, _, _) = await sheet()
        // 고른 원본이 없으면 계산하지 않는다
        #expect(!model.canPreview && !model.canExport && !model.isPreviewing && service.current.calls.isEmpty)

        let gate = TestGate()
        service.update { $0.onPreview = { gate.pass() } }
        model.selection.setPlaylist("2", selected: true)
        #expect(await waitForState { model.isPreviewing && gate.arrivals == 1 })
        #expect(model.selection.summary == nil && !model.canExport)
        gate.open()
        await model.previewTask?.value
        #expect(!gate.timedOut && !model.isPreviewing)
        #expect(model.selection.summary == service.current.summary && model.canExport)
        #expect(service.current.calls == ["preview"])
    }

    @Test("형식을 바꾸면 요약을 버리고 다시 계산한다. 계산 중 다시 바꾸면 앞의 결과는 버리고 앞 계산이 끝난 뒤 마지막 선택만 계산한다")
    @MainActor
    func sheetModelRecomputesAndDropsStale() async throws {
        let (model, _, service, host, _) = await sheet()
        model.selection.setPlaylist("2", selected: true)
        await model.previewTask?.value
        #expect(model.selection.summary != nil)

        // 앞 계산은 stale을, 새 계산은 fresh를 돌려준다(훅이 계산마다 요약을 정한 뒤 문 앞에서 멈춘다)
        let stale = UsbTestData.summary(tracks: 1), fresh = UsbTestData.summary(tracks: 9)
        let first = TestGate(), second = TestGate(), counter = PreviewCounter()
        service.update {
            $0.calls = []
            $0.onPreview = {
                let number = counter.next()
                service.update { $0.summary = number == 1 ? stale : fresh }
                (number == 1 ? first : second).pass()
            }
        }
        model.selection.setFormat(.deviceLibrary, on: false)
        #expect(model.selection.summary == nil && model.isPreviewing)
        #expect(await waitForState { first.arrivals == 1 })

        // 앞 계산이 도는 동안 두 번 더 바꾼다: 가운데 선택은 계산하지 않는다
        model.selection.setFormat(.deviceLibrary, on: true)
        model.selection.setPlaylist("1", selected: true)
        first.open()
        #expect(await waitForState { second.arrivals == 1 })
        // 앞 계산(stale)은 이미 끝났다. 그 결과는 쓰지 않고, 새 계산이 끝날 때까지 진행을 보인다
        #expect(model.selection.summary == nil && model.isPreviewing && !model.canExport)
        second.open()
        await model.previewTask?.value
        #expect(!first.timedOut && !second.timedOut && !model.isPreviewing)
        #expect(model.selection.summary == fresh && model.canExport)
        #expect(service.current.calls == ["preview", "preview"])
        // 새 계산이 앞 계산과 겹쳐 시작했다면 볼륨 잠금에 걸려 "쓰는 중" 안내가 떴을 것이다
        #expect(host.toast == nil)
    }

    @Test("계산하는 동안 볼륨·읽은 사본 정보가 바뀌어 같은 계산이 아니게 되면 진행 표시를 남기지 않고 새 정보로 다시 계산한다")
    @MainActor
    func sheetModelRestartsWhenJobChanges() async throws {
        let usbHost = FakeUsbHost([image])
        let (model, usb, service, _, _) = await sheet(usbHost: usbHost)
        let gate = TestGate(), counter = PreviewCounter()
        service.update { $0.onPreview = { if counter.next() == 1 { gate.pass() } } }
        model.selection.setPlaylist("2", selected: true)
        #expect(await waitForState { gate.arrivals == 1 })

        // 선택은 그대로, 볼륨의 여유 용량만 달라진다(`job()`이 달라진다)
        var changed = image
        changed.available -= 4096
        usbHost.mounted = [changed]
        await usb.refresh()
        #expect(usb.volume(image.usbKey)?.available == changed.available)
        gate.open()
        // 앞 계산이 끝나면 새 계산이 이어 선다(그 Task는 지금 `previewTask`다). 진행 표시가 꺼질 때까지 기다린다
        #expect(await waitForState { !model.isPreviewing })
        await model.previewTask?.value
        #expect(!gate.timedOut && !model.isPreviewing)
        #expect(model.selection.summary == service.current.summary && model.canExport)
        #expect(service.current.calls == ["preview", "preview"])
    }

    @Test("계산이 막히면(rekordbox 켜짐) 요약 없이 멈추고, 선택을 바꾸지 않아도 다시 시도할 수 있다. 계산할 창구가 없어도 진행 표시를 남기지 않는다")
    @MainActor
    func sheetModelStoppedCanRetry() async throws {
        let (model, _, service, host, _) = await sheet()
        service.update { $0.rekordboxRunning = true }
        model.selection.setPlaylist("2", selected: true)
        await model.previewTask?.value
        #expect(!model.isPreviewing && model.previewStopped && model.selection.summary == nil && !model.canExport)
        #expect(host.toast != nil && service.current.calls.isEmpty)

        // rekordbox를 끈 뒤 [다시 시도]
        service.update { $0.rekordboxRunning = false }
        model.retryPreview()
        #expect(model.isPreviewing && !model.previewStopped)
        await model.previewTask?.value
        #expect(!model.isPreviewing && !model.previewStopped)
        #expect(model.selection.summary == service.current.summary && model.canExport)

        let (without, _, _, _, _) = await sheet(withCoordinator: false)
        without.selection.setPlaylist("2", selected: true)
        await without.previewTask?.value
        #expect(!without.isPreviewing && without.selection.summary == nil)
    }

    @Test("계산이 막힌 뒤에는 선택을 바꿔도 저절로 다시 계산하지 않는다(끝나지 않은 쓰기 회복 창이 선택마다 다시 뜨지 않게). [다시 시도]로만 다시 계산한다")
    @MainActor
    func sheetModelStoppedDoesNotReaskOnSelectionChange() async throws {
        let (model, _, service, _, prompter) = await sheet()
        service.update { $0.journal = .state(.committing) }
        prompter.answer = false
        model.selection.setPlaylist("2", selected: true)
        await model.previewTask?.value
        #expect(model.previewStopped && prompter.shown.count == 1, "회복 창을 한 번 묻는다([나중에])")

        // 선택을 두 번 바꾼다: 막힌 채로 두고 같은 창을 다시 띄우지 않는다
        model.selection.setFormat(.deviceLibrary, on: false)
        model.selection.setPlaylist("1", selected: true)
        await model.previewTask?.value
        #expect(model.previewStopped && !model.isPreviewing && model.selection.summary == nil)
        #expect(prompter.shown.count == 1)
        #expect(service.current.calls.isEmpty)

        // 원인을 푼 뒤 [다시 시도]는 바뀐 선택으로 계산한다
        service.update { $0.journal = .none }
        model.retryPreview()
        await model.previewTask?.value
        #expect(!model.previewStopped && model.selection.summary == service.current.summary)
        #expect(prompter.shown.count == 1 && service.current.calls == ["preview"])
    }

    @Test("고른 원본을 모두 빼면 계산 중인 미리 보기를 버리고 진행 표시를 끈다. 시트를 닫아도 결과를 남기지 않는다")
    @MainActor
    func sheetModelCancelsPreview() async throws {
        let (model, _, service, _, _) = await sheet()
        let gate = TestGate()
        service.update { $0.onPreview = { gate.pass() } }
        model.selection.setPlaylist("2", selected: true)
        #expect(await waitForState { gate.arrivals == 1 })
        model.selection.setPlaylist("2", selected: false)
        #expect(!model.isPreviewing && !model.canPreview)
        gate.open()
        await model.previewTask?.value
        #expect(model.selection.summary == nil && !model.canExport && !model.isPreviewing)

        let closing = TestGate()
        service.update { $0.onPreview = { closing.pass() }; $0.calls = [] }
        model.selection.setPlaylist("2", selected: true)
        #expect(await waitForState { closing.arrivals == 1 })
        model.disappeared()
        #expect(!model.isPreviewing)
        closing.open()
        await model.previewTask?.value
        #expect(model.selection.summary == nil && service.current.calls == ["preview"])
    }

    @Test("시트를 열 때 미리 본 요약이 없는 선택이면 계산하고, 요약이 있으면 다시 계산하지 않는다")
    @MainActor
    func sheetModelAppeared() async throws {
        let job = UsbExportJob(database: URL(filePath: "/tmp/djc-fixture/m.db"), share: URL(filePath: "/tmp/djc-fixture/share"), volume: image,
                               selection: .playlists(["2"]), formats: UsbFormat.defaultSet, snapshotTime: nil, playlistLayout: Self.layout)
        let (without, _, service, _, _) = await sheet(UsbExportSheetRequest(volume: image, job: job, summary: nil))
        #expect(without.selection.summary == nil && service.current.calls.isEmpty)
        without.appeared()
        await without.previewTask?.value
        #expect(without.selection.summary == service.current.summary && service.current.calls == ["preview"])

        let (with, _, other, _, _) = await sheet(UsbExportSheetRequest(volume: image, job: job, summary: UsbTestData.summary()))
        with.appeared()
        await with.previewTask?.value
        #expect(with.selection.summary == UsbTestData.summary() && other.current.calls.isEmpty)
    }

    @Test("USB에 쓰기는 시트를 먼저 닫고, 미리 본 요약으로 확인 창 없이 쓴다(시트의 쓰기 단추가 쓰기 동의, #212)")
    @MainActor
    func sheetModelWriteIsConsent() async throws {
        let (model, usb, service, host, prompter) = await sheet()
        var dismissed = 0
        // 고른 원본이 없으면(미리 본 요약이 없으면) 쓰지 않는다
        #expect(model.writeTapped(dismiss: { dismissed += 1 }) == nil && dismissed == 0)
        model.selection.setPlaylist("2", selected: true)
        await model.previewTask?.value
        service.update { $0.calls = [] }
        let writing = try #require(model.writeTapped(dismiss: { dismissed += 1 }))
        #expect(dismissed == 1)
        await writing.value
        #expect(service.current.wrote && !service.current.previewed && prompter.shown.isEmpty)
        #expect(host.toast?.title == UsbWriteFlow.Text.writtenTitle(tracks: 3) && usb.busyVolumes.isEmpty)
    }

    @Test("동기화 재시도 시트를 닫으면 지난 쓰기·시트 요청을 지우고, ‘USB 동기화…’를 눌렀으면 동기화 창을 연다. 보통 시트는 지난 쓰기를 남긴다")
    @MainActor
    func sheetModelDisappear() async throws {
        let plain = await sheet()
        let job = UsbExportJob(database: URL(filePath: "/tmp/djc-fixture/m.db"), share: URL(filePath: "/tmp/djc-fixture/share"), volume: image,
                               selection: .playlists(["2"]), formats: UsbFormat.defaultSet, snapshotTime: nil, playlistLayout: Self.layout)
        plain.1.lastExports[image.usbKey] = job
        plain.0.disappeared()
        #expect(plain.1.lastExports[image.usbKey] == job && plain.1.syncSheet == nil)

        var native = job
        native.syncSourceContext = UsbExportSyncSourceContext(
            source: UsbSyncSource(layout: Self.layout, rekordbox: Self.layout, iTunes: PlaylistLayout(), notices: [:], iTunesStatus: .ready),
            catalogRevision: 1)
        let request = UsbExportSheetRequest(volume: image, job: native, summary: UsbTestData.summary())
        let (model, usb, _, _, _) = await sheet(request)
        usb.lastExports[image.usbKey] = native
        usb.exportSheet = request
        var dismissed = 0
        model.syncTapped(dismiss: { dismissed += 1 })
        #expect(dismissed == 1)
        model.disappeared()
        #expect(usb.lastExports[image.usbKey] == nil && usb.exportSheet == nil)
        #expect(usb.syncSheet == UsbSyncSheetRequest(volumeKey: image.usbKey))
        #expect(model.selection.retryJob == nil && model.selection.summary == nil)
    }

    @Test("미리 보기를 막은 USB 안내는 시트 뒤 창 토스트가 저절로 닫혀도 시트에서 닫을 때까지 남는다(#296)")
    @MainActor
    func sheetKeepsUsbNotice() async throws {
        let (model, _, _, _, _) = await sheet()
        // USB 안내가 아닌 알림은 받지 않는다
        model.toastChanged(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        model.toastChanged(AppToast.notice("rekordbox가 켜져 있어 저장하지 않았습니다", nil))
        #expect(model.notice == nil)
        let notice = AppToast.notice("rekordbox가 켜져 있어 미리 보지 않았습니다", "rekordbox를 종료하세요", isUsb: true)
        model.toastChanged(notice)
        model.toastChanged(nil)
        #expect(model.notice == notice)
        #expect(model.closeNotice() == notice.id && model.notice == nil)
    }
}
