@testable import DJCrate
import DJCDomain
import Testing

/// 머리 줄 오른쪽 끝의 목록 | 태그 시트 전환(#339): 막히는 조건과 이유는 툴바에 있던 때와 같고, ⓘ(초안 범례)는 태그 시트일 때만 보인다.
@MainActor
@Suite("머리 줄 — 목록·태그 시트 전환")
struct ListHeaderViewModeTests {
    private func loadedStore(_ sidebar: SidebarItem = .filter(.all)) -> LibraryStore {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.phase = .loaded
        store.sidebar = sidebar
        return store
    }

    @Test(arguments: [
        SidebarItem.filter(.all), .playlist("1"), .history("1"), .staged, .pending,
    ])
    func 곡_목록에서는_전환이_막히지_않는다(_ sidebar: SidebarItem) {
        #expect(loadedStore(sidebar).viewModeBlockReason == nil)
    }

    @Test func 쓰는_동안은_전환이_막히고_쓰기가_끝난_뒤_다시_시도하라고_알린다() {
        let store = loadedStore()
        store.isWritingRekordbox = true
        #expect(store.viewModeBlockReason == "rekordbox 쓰기가 끝난 뒤 다시 시도하세요")
        // 쓰는 동안이 USB·중복 후보 이유보다 먼저다(툴바 때와 같은 순서)
        store.sidebar = .duplicates
        #expect(store.viewModeBlockReason == "rekordbox 쓰기가 끝난 뒤 다시 시도하세요")
    }

    @Test func USB_곡은_읽기_전용이라_전환이_막힌다() {
        for sidebar in [SidebarItem.usb(.collection(volumeKey: "V")), .usb(.playlist(volumeKey: "V", id: 3)), .usb(.pending(volumeKey: "V"))] {
            #expect(loadedStore(sidebar).viewModeBlockReason == "USB 곡은 읽기 전용이니 로컬 라이브러리에서 태그를 편집하세요")
        }
    }

    @Test func 중복_후보에서는_태그_시트를_열_수_없다고_알린다() {
        #expect(loadedStore(.duplicates).viewModeBlockReason == "중복 후보에서는 태그 시트를 열 수 없으니 전체 목록에서 곡을 고르세요")
    }

    @Test func 태그_시트는_곡_목록에서_보기를_태그_시트로_골랐을_때만_보인다() {
        #expect(loadedStore().showsTagSheet(sheetMode: true))
        #expect(!loadedStore().showsTagSheet(sheetMode: false))
        // 중복 후보·USB는 태그 시트가 켜져 있어도 곡 목록으로 보이므로 ⓘ(초안 범례)도 없다
        #expect(!loadedStore(.duplicates).showsTagSheet(sheetMode: true))
        #expect(!loadedStore(.usb(.collection(volumeKey: "V"))).showsTagSheet(sheetMode: true))
        #expect(!loadedStore(.usb(.pending(volumeKey: "V"))).showsTagSheet(sheetMode: true))
    }
}
