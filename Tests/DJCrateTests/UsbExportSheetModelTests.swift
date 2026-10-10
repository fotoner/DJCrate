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

    /// 시트 화면 모델과 그 쓰기 흐름(가짜 창구·확인 창). 볼륨은 빈 FAT32 디스크 이미지
    @MainActor
    private func sheet(_ request: UsbExportSheetRequest? = nil) async -> (UsbExportSheetModel, UsbStore, FakeUsbWriteService,
                                                                          FakeUsbWriteHost, ScriptedPrompter) {
        let usbHost = FakeUsbHost([image])
        usbHost.serveEmpty(image)
        let service = FakeUsbWriteService(), host = FakeUsbWriteHost(), prompter = ScriptedPrompter()
        let usb = UsbTestData.store(usbHost, service: service)
        await usb.refresh()
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        let source = UsbSyncSource(layout: Self.layout, rekordbox: Self.layout, iTunes: PlaylistLayout(), notices: [:], iTunesStatus: .ready)
        let ports = UsbExportSheetModel.Ports(
            snapshot: { URL(filePath: "/tmp/djc-fixture/m.db") }, share: { URL(filePath: "/tmp/djc-fixture/share") },
            playlists: { Self.layout }, syncSource: { source }, catalogRevision: { 1 }, readEpoch: { 0 },
            sourceIsCurrent: { _, _, _ in true }, coordinator: { coordinator })
        let model = UsbExportSheetModel(request: request ?? UsbExportSheetRequest(volume: image), usb: usb, selectedTrackIDs: ["104"], ports: ports)
        return (model, usb, service, host, prompter)
    }

    @Test("시트 화면 모델: 미리 보기는 그동안 진행을 보이고 요약을 남긴다. 그 사이 고른 것이 바뀌면 그 요약을 버린다")
    @MainActor
    func sheetModelPreview() async throws {
        let (model, _, service, _, _) = await sheet()
        #expect(!model.canPreview && !model.canExport)
        model.selection.setPlaylist("2", selected: true)
        #expect(model.canPreview && !model.canExport)

        let gate = TestGate()
        service.update { $0.onPreview = { gate.pass() } }
        let previewing = model.previewTapped()
        #expect(await waitForState { model.isPreviewing && gate.arrivals == 1 })
        #expect(!model.canPreview && !model.canExport)
        gate.open()
        await previewing.value
        #expect(!gate.timedOut && !model.isPreviewing)
        #expect(model.selection.summary == service.current.summary && model.canExport)

        let again = TestGate()
        service.update { $0.onPreview = { again.pass() } }
        let second = model.previewTapped()
        #expect(await waitForState { again.arrivals == 1 })
        model.selection.setFormat(.deviceLibrary, on: false)
        again.open()
        await second.value
        #expect(!again.timedOut && model.selection.summary == nil && !model.canExport)
    }

    @Test("USB에 쓰기는 시트를 먼저 닫고, 미리 본 요약으로 확인 창 없이 쓴다(시트의 쓰기 단추가 쓰기 동의, #212)")
    @MainActor
    func sheetModelWriteIsConsent() async throws {
        let (model, usb, service, host, prompter) = await sheet()
        model.selection.setPlaylist("2", selected: true)
        var dismissed = 0
        // 미리 보기 전에는 쓰지 않는다
        #expect(model.writeTapped(dismiss: { dismissed += 1 }) == nil && dismissed == 0)
        await model.previewTapped().value
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
}
