@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import RekordboxFixtures
import Foundation
import RekordboxKit
import Testing

/// 실제 볼륨을 읽지 않고 이벤트 목록과 한 번 늦는 다른 볼륨 읽기를 만든다.
@MainActor
private final class UsbHistoryEventHost: UsbHost {
    let base: FakeUsbHost
    let volumeEvents: AsyncStream<[UsbVolumeInfo]>
    let continuation: AsyncStream<[UsbVolumeInfo]>.Continuation
    var delayedKey: String?
    private var delayedRead: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { delayedRead != nil }

    init(_ volumes: [UsbVolumeInfo]) {
        base = FakeUsbHost(volumes)
        (volumeEvents, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self, bufferingPolicy: .bufferingNewest(1))
    }

    func volumes() -> [UsbVolumeInfo] { base.mounted }
    func info(for volume: UsbVolumeInfo) async throws -> UsbInfo { try await base.info(for: volume) }
    func library(for volume: UsbVolumeInfo) async throws -> UsbLibrary {
        let library = try await base.library(for: volume)
        if delayedKey == volume.usbKey {
            delayedKey = nil
            await withCheckedContinuation { delayedRead = $0 }
        }
        return library
    }
    func eject(_ volume: UsbVolumeInfo) async throws { try await base.eject(volume) }

    func emit(_ volumes: [UsbVolumeInfo]) {
        base.mounted = volumes
        continuation.yield(volumes)
    }

    func resume() {
        let read = delayedRead
        delayedRead = nil
        read?.resume()
    }
}

@MainActor
@Suite("USB 재연결 이벤트와 기기 기록 보존(앱)")
struct UsbHistoryVolumeEventTests {
    static func changedLibrary() -> UsbLibrary {
        var library = UsbHistoryAppTests.usbLibrary()
        library.histories.append(.init(format: .oneLibrary, id: 2, name: "HISTORY 002", entries: [1, 2]))
        return library
    }

    @Test("빠른 분리·재연결로 중간 빈 목록이 합쳐져도 새 이벤트는 같은 정보의 볼륨을 다시 읽는다")
    func coalescedReconnectRereadsCachedVolume() async throws {
        let scratch = UsbHistoryAppTests.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await UsbHistoryAppTests.libraryStore(fixture, histories: UsbHistoryAppTests.histories(scratch))
        let volume = FakeUsbVolume.diskImageFAT32()
        let host = UsbHistoryEventHost([volume])
        host.base.serve(volume, library: UsbHistoryAppTests.usbLibrary())
        let local = UsbHistoryAppTests.localKeys()
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: FakeUsbWriteService(), localLibrary: { local })
        await UsbHistoryAppTests.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.count == 1)

        host.base.serve(volume, library: Self.changedLibrary())
        host.emit([])
        host.emit([volume])
        host.continuation.finish()
        await usb.watch()
        await store.history.waitForHistoryImports()
        #expect(host.base.libraryCalls == [volume.usbKey, volume.usbKey])
        #expect(store.history.archivedHistories.count == 2)
        #expect(usb.libraries[volume.usbKey]?.histories.count == 2)
    }

    @Test("다른 볼륨 읽기가 늦는 동안 같은 정보의 USB가 다시 연결돼도 최신 기기 기록을 다시 읽어 보존한다")
    func reconnectDuringAnotherVolumeRead() async throws {
        let scratch = UsbHistoryAppTests.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await UsbHistoryAppTests.libraryStore(fixture, histories: UsbHistoryAppTests.histories(scratch))
        var first = FakeUsbVolume.diskImageFAT32()
        first.name = "A 시험 USB"
        var second = FakeUsbVolume.diskImageFAT32()
        second.name = "B 시험 USB"
        second.volumeUUID = UsbTestData.otherUUID
        second.mountPoint = "/synthetic/usb-history-delayed"
        let host = UsbHistoryEventHost([first])
        host.base.serve(first, library: UsbHistoryAppTests.usbLibrary())
        host.base.serve(second, library: UsbTestData.library(formats: [.oneLibrary]))
        let local = UsbHistoryAppTests.localKeys()
        let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: FakeUsbWriteService(), localLibrary: { local })
        await UsbHistoryAppTests.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        host.base.mounted = [first, second]
        host.delayedKey = second.usbKey
        let watch = Task { await usb.watch() }
        defer {
            host.resume()
            host.continuation.finish()
            watch.cancel()
        }
        try #require(await waitUntil(timeout: .seconds(5)) { host.isWaiting })
        host.emit([second])
        host.base.serve(first, library: Self.changedLibrary())
        host.emit([first, second])
        host.resume()
        host.continuation.finish()
        await watch.value
        await store.history.waitForHistoryImports()
        #expect(host.base.libraryCalls.filter { $0 == first.usbKey }.count == 2)
        #expect(store.history.archivedHistories.count == 2)
        #expect(usb.libraries[first.usbKey]?.histories.count == 2)
    }
}
