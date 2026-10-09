@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite("USB 내보내기 목록 전달")
struct UsbExportJobLayoutTests {
    @Test("목록 모델은 선택·확인 정보와 함께 세션 옵션에 전달하고 기존 작업은 nil을 쓴다")
    func customLayoutPassedToSessionOptions() {
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 USB")
        var job = UsbExportJob(database: URL(filePath: "/tmp/djc-fixture/snapshot.db"),
                               share: URL(filePath: "/tmp/djc-fixture/share"), volume: volume,
                               selection: .playlists(["itunes:A"]), formats: [.oneLibrary, .deviceLibrary], snapshotTime: nil)
        #expect(job.playlistLayout == nil)
        #expect(job.options.playlistLayout == nil)
        let layout = PlaylistLayout([(.init(id: "itunes:A", name: "합성 목록", entries: [
            .init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "101"),
        ]), 1)])
        job.playlistLayout = layout
        #expect(job.options.playlistLayout == layout)
        #expect(job.selection == .playlists(["itunes:A"]))
        #expect(job.options.formats == job.formats)
        #expect(job.options.confirmName == volume.name)
        #expect(job.options.expectedVolumeUUID == volume.volumeUUID)
    }

    @Test("동기화 Job → 재시도 시트 모델 → Job → 세션 옵션에서 원문과 모든 선택 인자를 유지한다")
    func syncRetryRoundTripPreservesTheNativeRequest() throws {
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 USB")
        let layout = PlaylistLayout([
            (.init(id: "itunes:F", name: "폴더", isFolder: true), 0),
            (.init(id: "itunes:B", name: "남긴 자식", parentID: "itunes:F",
                   entries: [.init(trackNo: 1, contentID: "101"), .init(trackNo: 2, contentID: "101")]), 0),
        ])
        let request = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [
            .init(id: "itunes:F", parentID: nil, isFolder: true),
            .init(id: "itunes:A", parentID: "itunes:F", isFolder: false),
            .init(id: "itunes:B", parentID: "itunes:F", isFolder: false),
        ], selection: .init(selectedIDs: ["itunes:B"]), enabled: true, playlistRefs: [:],
           baseFiles: [.oneLibrary: Data("원래 선택 원문".utf8)])
        let source = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: SyncedITunesLibrary(snapshot: .init(playlists: [
            .init(id: "F", name: "폴더", isFolder: true),
            .init(id: "A", name: "뺀 자식", parentID: "F", paths: ["/x/102.mp3"]),
            .init(id: "B", name: "남긴 자식", parentID: "F", paths: ["/x/101.mp3", "/x/101.mp3"]),
        ]), tracks: [UsbEditTestData.localRow("101").track, UsbEditTestData.localRow("102").track]))
        let job = UsbExportJob(database: URL(filePath: "/tmp/djc-synthetic/snapshot.db"),
                               share: URL(filePath: "/tmp/djc-synthetic/share"), volume: volume,
                               selection: .playlists(["itunes:F"]), formats: [.oneLibrary], snapshotTime: "2026-10-08T00:00:00Z",
                               playlistLayout: layout, syncSelection: request,
                               syncSourceContext: .init(source: source, catalogRevision: 1))
        var model = UsbExportSheetModel(volume: volume, selectedTrackIDs: ["different-current-track"])
        let summary = UsbTestData.summary()
        model.restore(job, summary: summary, layout: layout)
        #expect(model.summary == summary)
        let retry = try #require(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                                          syncSource: source, catalogRevision: 1))
        #expect(retry == job)
        #expect(retry.options.syncSelection == request)
        #expect(retry.options.playlistLayout == layout)
        #expect(retry.options.snapshotTime == job.snapshotTime)
        #expect(retry.options.expectedVolumeUUID == job.options.expectedVolumeUUID)
        #expect(model.hasFixedSource)

        model.setPlaylist("itunes:B", selected: true)
        model.setPlaylist("itunes:F", selected: false)
        model.includesSelectedTracks = true
        #expect(model.selection(layout: layout) == job.selection)
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: source, catalogRevision: 1)?.syncSelection == request)
        #expect(model.job(database: URL(filePath: "/tmp/djc-synthetic/new.db"), share: job.share,
                          volume: volume, layout: layout, syncSource: source, catalogRevision: 1) == nil)
        #expect(model.job(database: job.database, share: URL(filePath: "/tmp/djc-synthetic/new-share"),
                          volume: volume, layout: layout, syncSource: source, catalogRevision: 1) == nil)
        model.setFormat(.deviceLibrary, on: true)
        #expect(model.summary == nil)
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: source, catalogRevision: 1)?.syncSelection == request)
    }

    @Test("스냅샷 URL이 같아도 원본 값·읽기 상태·revision이 바뀐 native 재시도는 거부한다")
    func nativeRetryRejectsChangedSourceContext() {
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 USB")
        let layout = UsbExportSheetModelTests.layout
        let source = UsbSyncSource.make(rekordbox: layout, iTunes: SyncedITunesLibrary(snapshot: .init(), tracks: []))
        var job = UsbExportJob(database: URL(filePath: "/tmp/djc-synthetic/snapshot.db"),
                               share: URL(filePath: "/tmp/djc-synthetic/share"), volume: volume,
                               selection: .playlists(["11"]), formats: [.oneLibrary], snapshotTime: nil, playlistLayout: layout,
                               syncSelection: .init(localDBID: 42, sourceNodes: source.nativeNodes,
                                                    selection: .init(selectedIDs: ["11"]), enabled: true,
                                                    playlistRefs: [:], baseFiles: [:]),
                               syncSourceContext: .init(source: source, catalogRevision: 1))
        var model = UsbExportSheetModel(volume: volume, selectedTrackIDs: [])
        model.restore(job, summary: nil, layout: layout)
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: source, catalogRevision: 2) == nil)
        var changed = source
        changed.iTunesStatus = .unavailable
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: changed, catalogRevision: 1) == nil)
        changed = source
        changed.layout = PlaylistLayout([(.init(id: "11", name: "원본 변경", entries: [.init(trackNo: 1, contentID: "999")]), 0)])
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: changed, catalogRevision: 1) == nil)
        job.syncSourceContext = nil
        model.restore(job, summary: nil, layout: layout)
        #expect(model.job(database: job.database, share: job.share, volume: volume, layout: layout,
                          syncSource: source, catalogRevision: 1) == nil)
    }

    @Test("동기화 요청 없는 기존 재시도에서는 원본 선택을 계속 바꿀 수 있다")
    func ordinaryExportRetryStillAllowsSourceChanges() throws {
        let volume = FakeUsbVolume.diskImageFAT32(name: "합성 USB")
        let layout = UsbExportSheetModelTests.layout
        let job = UsbExportJob(database: URL(filePath: "/tmp/djc-synthetic/snapshot.db"),
                               share: URL(filePath: "/tmp/djc-synthetic/share"), volume: volume,
                               selection: .playlists(["11"]), formats: UsbFormat.defaultSet, snapshotTime: nil)
        var model = UsbExportSheetModel(volume: volume, selectedTrackIDs: [])
        model.restore(job, summary: nil, layout: layout)
        model.setPlaylist("11", selected: false)
        model.setPlaylist("12", selected: true)
        let retry = try #require(model.job(database: job.database, share: job.share, volume: volume, layout: layout))
        #expect(!model.hasFixedSource)
        #expect(retry.selection == .playlists(["12"]))
        #expect(retry.syncSelection == nil)
    }

    private func nativeRetryFixture() async throws -> (RekordboxFixture, LibraryStore, UsbStore, FakeUsbHost, UsbExportJob) {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "101"))
        try fixture.add(PlaylistSpec(id: "11", name: "합성 목록", seq: 1, contentIDs: ["101", "101"]))
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usb-retry"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"), rekordboxShareRoot: fixture.shareRoot)
        await store.load(snapshot: fixture.database)
        let lease = try #require(await store.leaseUsbSyncSnapshot(directory: fixture.root.appending(path: "copies")))
        let source = UsbSyncSource.make(rekordbox: store.rekordboxPlaylists, iTunes: store.iTunesLibrary)
        let context = UsbExportSyncSourceContext(source: source, catalogRevision: store.previewRevision,
                                                readEpoch: store.snapshotReadEpoch, snapshot: lease.reference)
        var volume = FakeUsbVolume.diskImageFAT32(name: "합성 재시도 USB")
        volume.mountPoint = fixture.root.appending(path: "fake-mount").path
        let host = FakeUsbHost([volume])
        host.serveEmpty(volume)
        let usb = UsbTestData.store(host)
        await usb.refresh()
        let draft = UsbSyncSelectionDraft(localDBID: 1, sourceNodes: source.nativeNodes,
                                          selection: .init(selectedIDs: ["11"]), enabled: true,
                                          playlistRefs: ["11": .id("11")],
                                          baseFiles: [.oneLibrary: Data("합성 OneLibrary 원문".utf8),
                                                      .deviceLibrary: Data("합성 Device Library 원문".utf8)])
        let job = UsbExportJob(database: lease.database, share: fixture.shareRoot, volume: volume,
                               selection: .both(playlists: ["11"], tracks: ["101"]), formats: [.oneLibrary],
                               snapshotTime: "2026-10-08T00:00:00Z", playlistLayout: source.layout,
                               syncSelection: draft, syncSourceContext: context, snapshotLease: lease)
        return (fixture, store, usb, host, job)
    }

    @Test("같은 USB의 여유 용량만 4096 줄어도 native 재시도 Job과 시트 버튼·원본 사본을 유지한다",
          .enabled(if: LiveDraftHome.isIsolated))
    func nativeRetryAllowsAvailableSpaceChanges() async throws {
        let (fixture, store, usb, host, job) = try await nativeRetryFixture()
        defer { withExtendedLifetime(fixture) {} }
        let layout = try #require(job.playlistLayout), context = try #require(job.syncSourceContext)
        let lease = try #require(job.snapshotLease), summary = UsbTestData.summary()
        var model = UsbExportSheetModel(volume: job.volume, selectedTrackIDs: job.selection.trackIDs)
        model.restore(job, summary: summary, layout: layout)
        let sheet = UsbExportSheet(store: store, usb: usb, request: .init(volume: job.volume, job: job, summary: summary))
        #expect(sheet.canPreview && sheet.canExport)
        var changed = job.volume
        changed.available -= 4096
        host.mounted = [changed]
        await usb.refresh()
        let current = try #require(usb.volume(job.volumeKey))
        #expect(current == changed && current != job.volume)
        #expect(store.usbSyncSourceIsCurrent(context, database: job.database, share: job.share))
        let snapshot = try #require(store.snapshotURL)
        let retry = try #require(model.job(database: snapshot, share: job.share, volume: current, layout: layout,
                                          syncSource: context.source, catalogRevision: store.previewRevision, readEpoch: store.snapshotReadEpoch))
        #expect(sheet.canPreview && sheet.canExport)
        #expect(model.canPreview(layout: layout) && model.canWrite && model.summary == summary)
        #expect(retry == job && model.retryJob == job)
        #expect(retry.volume == job.volume && retry.selection == job.selection)
        #expect(retry.syncSelection?.baseFiles == job.syncSelection?.baseFiles)
        #expect(retry.playlistLayout == layout && retry.syncSourceContext == context)
        #expect(retry.database == lease.database && retry.share == job.share)
        #expect(retry.snapshotLease === lease && retry.syncSourceContext?.snapshot?.lease === lease)
        #expect(retry.syncSourceContext?.snapshot == lease.reference)
        #expect(retry.snapshotTime == job.snapshotTime && retry.options.snapshotTime == job.snapshotTime)
        #expect(retry.options.syncSelection == job.syncSelection && retry.options.playlistLayout == layout)
    }

    @Test("native 재시도는 USB UUID·마운트·장치 정보 변경을 계속 거부한다", .enabled(if: LiveDraftHome.isIsolated))
    func nativeRetryRejectsVolumeIdentityChanges() async throws {
        let (fixture, store, usb, host, job) = try await nativeRetryFixture()
        defer { withExtendedLifetime(fixture) {} }
        let layout = try #require(job.playlistLayout), context = try #require(job.syncSourceContext)
        let summary = UsbTestData.summary()
        var model = UsbExportSheetModel(volume: job.volume, selectedTrackIDs: job.selection.trackIDs)
        model.restore(job, summary: summary, layout: layout)
        let sheet = UsbExportSheet(store: store, usb: usb, request: .init(volume: job.volume, job: job, summary: summary))
        #expect(sheet.canPreview && sheet.canExport)
        for field in ["uuid", "mount", "protocol", "image"] {
            var changed = job.volume
            switch field {
            case "uuid": changed.volumeUUID = UsbTestData.otherUUID
            case "mount": changed.mountPoint = fixture.root.appending(path: "other-mount").path
            case "protocol": changed.deviceProtocol = "USB"
            default: changed.diskImagePath = fixture.root.appending(path: "other.img").path
            }
            host.mounted = [changed]
            host.serveEmpty(changed)
            await usb.refresh()
            #expect(usb.volumes == [changed])
            #expect(store.usbSyncSourceIsCurrent(context, database: job.database, share: job.share))
            #expect(model.job(database: try #require(store.snapshotURL), share: job.share, volume: changed, layout: layout,
                              syncSource: context.source, catalogRevision: store.previewRevision, readEpoch: store.snapshotReadEpoch) == nil)
            #expect(!sheet.canPreview && !sheet.canExport)
            #expect(model.retryJob == job)
        }
    }

}
