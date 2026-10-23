@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 쓰는 동안 시스템이 앱을 예고 없이 끝내지 못하게 막는다(#300): 걸고 푸는 짝이 맞는지 본다.
@MainActor
@Suite("쓰는 동안 시스템 보호")
struct WriteSystemGuardTests {
    final class Counts {
        var disabled = 0, enabled = 0, began = 0, ended = 0
        var balanced: Bool { disabled == enabled && began == ended }
    }

    static func hooks(_ counts: Counts) -> WriteSystemGuard.Hooks {
        WriteSystemGuard.Hooks(disableSuddenTermination: { counts.disabled += 1 }, enableSuddenTermination: { counts.enabled += 1 },
                               beginActivity: { counts.began += 1; return NSObject() }, endActivity: { _ in counts.ended += 1 })
    }

    let counts = Counts()

    @Test func 쓰기가_시작되면_걸고_끝나면_푼다() {
        let guardian = WriteSystemGuard(hooks: Self.hooks(counts))
        guardian.update(writing: true)
        #expect(guardian.isHolding && counts.disabled == 1 && counts.began == 1 && counts.enabled == 0 && counts.ended == 0)
        guardian.update(writing: false)
        #expect(!guardian.isHolding && counts.enabled == 1 && counts.ended == 1 && counts.balanced)
    }

    @Test func 같은_값을_거듭_알려도_한_번만_걸고_한_번만_푼다() {
        let guardian = WriteSystemGuard(hooks: Self.hooks(counts))
        for _ in 0..<3 { guardian.update(writing: true) }
        #expect(counts.disabled == 1 && counts.began == 1)
        for _ in 0..<3 { guardian.update(writing: false) }
        #expect(counts.enabled == 1 && counts.ended == 1 && counts.balanced)
    }

    @Test func 걸지_않았는데_풀기만_알려도_아무것도_하지_않는다() {
        let guardian = WriteSystemGuard(hooks: Self.hooks(counts))
        guardian.update(writing: false)
        #expect(counts.disabled == 0 && counts.enabled == 0 && counts.began == 0 && counts.ended == 0)
    }

    @Test func 쓰기가_여러_번_이어져도_짝이_맞는다() {
        let guardian = WriteSystemGuard(hooks: Self.hooks(counts))
        for _ in 0..<5 {
            guardian.update(writing: true)
            guardian.update(writing: false)
        }
        #expect(counts.disabled == 5 && counts.began == 5 && counts.balanced)
    }

    // MARK: - 저장소와 이음

    @Test func 저장소의_rekordbox_쓰기를_지켜보며_걸고_푼다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        delegate.systemGuard = WriteSystemGuard(hooks: Self.hooks(counts))
        delegate.store = store
        #expect(counts.disabled == 0)
        store.setWriteLock(true)
        // 미리 보기와 확인 창에서는 아직 아무것도 쓰지 않았다: 걸지 않는다(확인 창을 열어 둔 채 자리를 비워도 Mac이 잠들 수 있다)
        store.writeStage = WriteStage("미리 보기", cancellable: true)
        await drainMainActor()
        store.isAwaitingConfirmation = true
        await drainMainActor()
        #expect(counts.disabled == 0 && counts.began == 0)
        store.isAwaitingConfirmation = false
        // 끊지 않는 쓰기에 들어서면 건다
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(await waitForState { counts.disabled == 1 && counts.began == 1 })
        // 쓴 뒤 다시 읽기에는 쓰기가 끝났으니 푼다
        store.writeStage = .reloadingLibrary
        #expect(await waitForState { counts.enabled == 1 && counts.ended == 1 })
        store.setWriteLock(false)
        await drainMainActor()
        #expect(counts.balanced && counts.disabled == 1)
    }

    @Test func 이미_쓰는_중인_저장소를_이어도_건다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.setWriteLock(true)
        // 진행 안내가 없는 쓰기(iTunes 동기화 등)도 끊지 않는 쓰기다
        let delegate = AppDelegate()
        delegate.systemGuard = WriteSystemGuard(hooks: Self.hooks(counts))
        delegate.store = store
        #expect(counts.disabled == 1 && counts.began == 1)
    }

    @Test func USB_쓰기도_건다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let volume = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
        let usb = UsbTestData.store(FakeUsbHost([volume]))
        store.usb = usb
        let delegate = AppDelegate()
        delegate.systemGuard = WriteSystemGuard(hooks: Self.hooks(counts))
        delegate.store = store
        _ = try #require(usb.beginWrite(volume, title: "합성 쓰기"))
        #expect(await waitForState { counts.disabled == 1 })
        usb.endWrite(volume.usbKey)
        #expect(await waitForState { counts.enabled == 1 })
        #expect(counts.balanced)
    }
}
