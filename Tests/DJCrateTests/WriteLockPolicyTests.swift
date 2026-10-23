@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Testing

@Suite("쓰기 잠금 — 키·종료·편집")
struct WriteLockPolicyTests {
    /// 쓰는 중 앱 종료(#300): 거절 알림 대신 기다렸다 끈다. 이번 요청은 취소로 답하고(종료를 미루면 메인 큐 블록 안에서 불렸을 때 쓰기가 멈춘다),
    /// 쓰기가 끝나면(다시 읽기에 들어서면) 앱이 종료를 다시 요청한다.
    @MainActor @Test func 종료_입구는_rekordbox에_쓰는_중이면_알림_없이_기다리고_끝나면_다시_종료한다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var messages: [String] = [], replies: [Bool] = [], terminations = 0
        delegate.inform = { messages.append($0) }
        delegate.replyToTermination = { replies.append($0) }
        delegate.terminateApp = { terminations += 1 }
        delegate.store = store
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(store.quitWait.isWaiting && messages.isEmpty && replies.isEmpty && terminations == 0)
        store.setWriteLock(false)
        store.writeStage = nil
        #expect(await waitForState { terminations == 1 })
        #expect(!store.quitWait.isWaiting && messages.isEmpty && replies.isEmpty)
    }

    /// 앱 업데이트(#59)의 다시 켜기·끌 때 설치도 이 입구를 지난다. USB에 쓰는 중에 꺼지면 USB DB가 반쯤 쓴 채로 남는다.
    /// USB는 기다리지 않고 거절하되 이유와 할 일을 쓴다.
    @MainActor @Test func 종료_입구는_USB_쓰기_중에도_거절한다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let volume = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
        let usb = UsbTestData.store(FakeUsbHost([volume]))
        store.usb = usb
        let delegate = AppDelegate()
        delegate.store = store
        var messages: [String] = []
        delegate.inform = { messages.append($0) }
        _ = try #require(usb.beginWrite(volume, title: "합성 쓰기"))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(messages == ["USB에 쓰는 중이라 지금은 종료하지 않았습니다. 쓰기가 끝나면 다시 종료하세요"])
        usb.endWrite(volume.usbKey)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(messages.count == 1)
    }

    @Test(arguments: [4, 46, 12, 14])
    func 쓰기_중에도_시스템_조합키를_넘긴다(_ key: UInt16) {
        let policy = WriteLockPolicy(isWriting: true)
        #expect(!policy.blocksKey(key, in: .init(hasShortcutModifiers: true)))
    }

    @Test(arguments: [KeyRoutingPolicy.Focus.deck, .trackList, .sheet])
    func 쓰기_중에는_덱과_목록_키를_막는다(_ focus: KeyRoutingPolicy.Focus) {
        let policy = WriteLockPolicy(isWriting: true)
        for key: UInt16 in [49, 123, 125, 51, 53] {
            #expect(policy.blocksKey(key, in: .init(focus: focus)))
        }
    }

    @Test func 준비_취소만_Escape를_넘긴다() {
        #expect(!WriteLockPolicy(isWriting: true, canCancelPreparation: true).blocksKey(53, in: .init()))
        #expect(WriteLockPolicy(isWriting: true).blocksKey(53, in: .init()))
    }

    @Test func 경고창과_다른_창과_입력_컨트롤에는_끼어들지_않는다() {
        let policy = WriteLockPolicy(isWriting: true)
        for context: KeyRoutingPolicy.Context in [
            .init(isMainWindow: false), .init(hasModalWindow: true), .init(hasAttachedSheet: true),
            .init(focus: .textInput), .init(focus: .control), .init(focus: .table)
        ] {
            #expect(!policy.blocksKey(49, in: context))
        }
    }

    /// 종료 판단은 `AppQuitPolicy`(#300)가, 라이브러리 조작 거절은 저장소의 용도별 값(#301)이 한다. 이 구조체는 키 입력만 가른다
    @Test func 쓰지_않을_때는_키를_막지_않는다() {
        let unlocked = WriteLockPolicy(isWriting: false)
        #expect(!unlocked.blocksKey(49, in: .init()))
    }

    /// 쓰는 동안 용도별 값이 모두 켜지고 끝나면 꺼진다(#301). 종료 판단(`writeActivity`)도 `quitBlocked`를 따른다
    @MainActor @Test func 쓰는_동안_라이브러리_조작과_종료를_거절한다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        #expect(!store.libraryBusy && !store.editsFrozen && !store.quitBlocked)
        #expect(store.writeActivity.rekordbox == .idle)
        store.setWriteLock(true)
        #expect(store.libraryBusy && store.editsFrozen && store.quitBlocked)
        #expect(store.writeActivity.rekordbox != .idle)
        store.setWriteLock(false)
        #expect(!store.libraryBusy && !store.editsFrozen && !store.quitBlocked)
        #expect(store.writeActivity.rekordbox == .idle)
    }
}
