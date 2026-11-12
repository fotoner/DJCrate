@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// 사이드바 재생 기록 줄의 저장 상태 표시(#311): 상태 → 아이콘·낱말·툴팁. 상태를 고르는 규칙은 `ArchivedHistoryStatusTests`가 본다.
/// 연결은 `HistoryStore.archivedStatus`가 줄이 읽는 값(쓰기 대기·뺌·연결 중 LINK 세션)을 규칙에 넘기는지만 본다.
@MainActor
@Suite("재생 기록 줄 — 저장 상태 표시")
struct SidebarHistoryStatusTests {
    private func mark(_ status: ArchivedHistoryStatus, link: Bool = false) -> HistoryStatusMark {
        HistoryStatusMark.of(status, isLink: link)
    }

    @Test func 상태마다_낱말이_정해져_있다() {
        #expect(mark(.recording, link: true).word == "기록 중")
        #expect(mark(.pending).word == "저장 대기")
        #expect(mark(.written).word == "저장함")
        #expect(mark(.excluded).word == "저장 안 함")
        #expect(mark(.repeatedTracks).word == "저장 안 함")
        #expect(mark(.noCollectionTracks).word == "저장 안 함")
        #expect(mark(.notInRekordbox).word == "rekordbox에 없음")
    }

    @Test func 툴팁은_낱말_한_줄이고_할_일이_있는_상태에만_할_일이_붙는다() {
        // 할 일이 없는 상태: 툴팁이 상태 낱말 그대로다
        for status in [ArchivedHistoryStatus.pending, .written, .excluded, .noCollectionTracks, .notInRekordbox] {
            for link in [false, true] { #expect(mark(status, link: link).help == mark(status, link: link).word) }
        }
        // 할 일이 있는 상태: LINK를 끄면 저장 대기에 오른다 / 같은 곡이 두 번 든 USB 기록은 rekordbox에서 직접 가져온다
        #expect(mark(.recording, link: true).help == "기록 중 · LINK를 끄면 저장 대기에 오릅니다")
        #expect(mark(.repeatedTracks, link: false).help == "저장 안 함 · rekordbox에서 USB를 연결해 직접 가져오세요")
        // LINK 기록은 USB를 꽂아 가져올 수 없으므로 같은 상태에도 할 일이 없다
        #expect(mark(.repeatedTracks, link: true).help == "저장 안 함")
    }

    @Test func 툴팁은_한_줄_75자_이내이고_줄바꿈이_없다() {
        for status in ArchivedHistoryStatus.allCases {
            for link in [false, true] {
                let help = mark(status, link: link).help
                #expect(help.count <= 75 && !help.contains("\n"))
                #expect(help.hasPrefix(mark(status, link: link).word))
            }
        }
    }

    @Test func 모든_상태가_아이콘을_가지고_저장_대기만_초안_표식과_색을_쓴다() {
        for status in ArchivedHistoryStatus.allCases {
            #expect(!mark(status).symbol.isEmpty)
            #expect(mark(status).usesDraftColor == (status == .pending))
        }
        #expect(mark(.pending).symbol == DraftMark.symbol)
        #expect(mark(.pending).word == DraftMark.spoken)
        // 같은 낱말을 쓰는 상태끼리 아이콘이 같고, 낱말이 다른 상태끼리는 아이콘이 다르다
        let symbols = Dictionary(grouping: ArchivedHistoryStatus.allCases, by: { mark($0).word }).mapValues { Set($0.map { mark($0).symbol }) }
        #expect(symbols.values.allSatisfy { $0.count == 1 })
        #expect(Set(symbols.values.flatMap { $0 }).count == symbols.count)
    }

    @Test func 줄이_읽는_값이_상태로_이어진다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })
        // 라이브러리를 읽기 전이라 쓰기 대기에 오르지 않는다: 컬렉션 짝이 있으면 rekordbox에 없음, 뺐으면 뺌, 짝이 없으면 컬렉션 곡 없음
        let plain = UsbHistoryWriteTests.archived("plain", ["1"], sequence: 1)
        let excluded = UsbHistoryWriteTests.archived("excluded", ["1"], sequence: 2, excluded: true)
        let unmatched = UsbHistoryWriteTests.archived("unmatched", [nil], sequence: 3)
        store.history.archivedHistories = [plain, excluded, unmatched]
        #expect(store.history.archivedStatus(plain) == .notInRekordbox)
        #expect(store.history.archivedStatus(excluded) == .excluded)
        #expect(store.history.archivedStatus(unmatched) == .noCollectionTracks)
    }

    /// 쓰기 대기(`pendingHistoryIDs`)·rekordbox 기록(`historyIndex`)·연결 중 LINK 세션(`openLinkSessions`)이 줄 상태로 이어진다.
    /// 라이브러리를 읽어야 쓰기 대기가 서므로 합성 사본을 쓴다(`UsbHistoryWriteTests.makeStore`, 관문은 열려 있다)
    @Test func 쓰기_대기와_쓴_기록과_연결_중_세션이_상태로_이어진다() async throws {
        let scratch = UsbHistoryWriteTests.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let pending = UsbHistoryWriteTests.archived("pending", ["102", "101"], sequence: 1)
        // 쓴 표시가 유효하고(라이브러리 ID 같음) 그 기록이 rekordbox에 있다. 짝 없는 곡이 있어 rekordbox 기록과 같다고 보지 않아 숨기지 않는다
        let written = UsbHistoryWriteTests.archived("written", ["102", nil], sequence: 2, written: "new-a")
        var link = UsbHistoryWriteTests.archived("link", ["101"], sequence: 3)
        link.source = LinkHistory.source(session: "live")
        let (store, _) = try await UsbHistoryWriteTests.makeStore(fixture, scratch: scratch, archived: [pending, written, link])
        #expect(store.history.pendingHistoryIDs == [pending.id, link.id])
        #expect(store.history.archivedStatus(pending) == .pending)
        #expect(store.history.archivedStatus(written) == .written)
        #expect(store.history.archivedStatus(link) == .pending)

        // 곡이 계속 붙는 동안(세션이 열림) LINK 기록은 대기에서 빠지고 기록 중이다. USB 기록은 그대로다
        store.history.recordLinkPlay(LinkPlay(contentID: "not-in-collection", linkID: 1, session: 1), session: "live")
        #expect(store.history.archivedStatus(link) == .recording)
        #expect(store.history.archivedStatus(pending) == .pending)
        // LINK를 끄면 다시 대기에 오른다
        store.history.closeLinkSessions()
        #expect(store.history.archivedStatus(link) == .pending)
    }
}
