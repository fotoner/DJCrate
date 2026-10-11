@testable import DJCrate
import AppKit
import Testing

@Suite("쓰기 잠금 — 키·종료·편집")
struct WriteLockPolicyTests {
    @MainActor @Test func 종료_입구는_잠금을_읽고_거절_이유를_알린다() {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil))
        let delegate = AppDelegate()
        delegate.store = store
        var messages: [String] = []
        delegate.inform = { messages.append($0) }
        store.setWriteLock(true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(messages == ["rekordbox에 쓰는 중입니다. 끝난 뒤 종료하세요"])
        store.setWriteLock(false)
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

    @Test func 준비부터_다시읽기까지_종료와_라이브러리_조작을_거절한다() {
        for cancellable in [true, false] {
            let policy = WriteLockPolicy(isWriting: true, canCancelPreparation: cancellable)
            #expect(!policy.allowsTermination)
            #expect(!policy.allowsLibraryInteraction)
        }
        let unlocked = WriteLockPolicy(isWriting: false)
        #expect(unlocked.allowsTermination && unlocked.allowsLibraryInteraction)
        #expect(!unlocked.blocksKey(49, in: .init()))
    }
}
