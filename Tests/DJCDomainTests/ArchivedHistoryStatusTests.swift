import DJCDomain
import Foundation
import Testing

/// 보존 기록의 rekordbox 저장 상태 판정(#311, `ArchivedHistoryStatus.of`, 입출력 없음). 사이드바 줄의 표시 연결은 앱 시험
/// (`SidebarHistoryStatusTests`)이 본다. 곡·ID는 지어낸 값이다.
@Suite("보존 기록 저장 상태")
struct ArchivedHistoryStatusTests {
    static let usb = UsbHistoryRulesTests.archived("usb", ["101", "102"])

    /// LINK 세션 기록. `UsbHistoryRulesTests.archived`와 같은 곡 줄에 출처만 LINK로 바꾼다
    static func link(session: String = "s1", _ contentIDs: [String?] = ["101", "102"], excluded: Bool = false,
                     written: String? = nil) -> ArchivedHistory {
        var history = UsbHistoryRulesTests.archived("link", contentIDs, excluded: excluded, written: written)
        history.source = LinkHistory.source(session: session)
        return history
    }

    func status(_ history: ArchivedHistory, pending: Bool = false, open: Set<String> = [], inRekordbox: Set<String> = []) -> ArchivedHistoryStatus {
        ArchivedHistoryStatus.of(history, isPending: pending, openLinkSessions: open, rekordboxHasHistory: { inRekordbox.contains($0) })
    }

    @Test func 저장_대기에_오른_기록은_대기다() {
        #expect(status(Self.usb, pending: true) == .pending)
        #expect(status(Self.link(), pending: true) == .pending)
    }

    @Test func 사용자가_뺀_기록은_뺌이다() {
        #expect(status(UsbHistoryRulesTests.archived("usb", ["101"], excluded: true)) == .excluded)
        #expect(status(Self.link(excluded: true)) == .excluded)
    }

    @Test func rekordbox에_저장했고_지금_라이브러리에_있으면_저장함이다() {
        let written = UsbHistoryRulesTests.archived("usb", ["101"], written: "rb-1")
        #expect(status(written, inRekordbox: ["rb-1"]) == .written)
        #expect(status(Self.link(written: "rb-1"), inRekordbox: ["rb-1"]) == .written)
        // 쓴 표시가 있어도 지금 라이브러리에 없으면(복원 등) 저장함이 아니다
        #expect(status(written, inRekordbox: []) == .notInRekordbox)
    }

    @Test func 같은_곡이_두_번_이상_든_기록은_반복곡이다() {
        let repeated = UsbHistoryRulesTests.archived("usb", ["101", "102", "101"])
        #expect(status(repeated) == .repeatedTracks)
        #expect(status(Self.link(["101", "101"])) == .repeatedTracks)
    }

    @Test func 컬렉션에_있는_곡이_없는_기록은_컬렉션곡없음이다() {
        #expect(status(UsbHistoryRulesTests.archived("usb", [nil, nil])) == .noCollectionTracks)
        #expect(status(Self.link([nil])) == .noCollectionTracks)
    }

    @Test func 위_어디도_아니면_rekordbox에_없음이다() {
        #expect(status(Self.usb) == .notInRekordbox)
        #expect(status(Self.link()) == .notInRekordbox)
    }

    @Test func 연결_중인_LINK_세션의_기록은_기록_중이다() {
        #expect(status(Self.link(session: "s1"), open: ["s1"]) == .recording)
        // 다른 세션이 열려 있으면 이 기록은 닫힌 기록이다
        #expect(status(Self.link(session: "s1"), open: ["s2"]) == .notInRekordbox)
        // USB 기록은 LINK 세션과 상관없다
        #expect(status(Self.usb, open: ["s1"]) == .notInRekordbox)
    }

    @Test func 판정_순서는_기록_중_대기_뺌_저장함_반복곡_컬렉션곡없음_없음이다() {
        // 기록 중은 대기·뺌보다 앞선다
        #expect(status(Self.link(excluded: true), pending: true, open: ["s1"]) == .recording)
        // 대기는 뺌보다 앞선다(뺀 기록은 대기에 오르지 않지만 판정 순서는 옛 문구와 같게 둔다)
        #expect(status(UsbHistoryRulesTests.archived("usb", ["101"], excluded: true), pending: true) == .pending)
        // 뺌은 저장함·반복곡·컬렉션곡없음보다 앞선다
        let excludedRepeated = UsbHistoryRulesTests.archived("usb", ["101", "101"], excluded: true, written: "rb-1")
        #expect(status(excludedRepeated, inRekordbox: ["rb-1"]) == .excluded)
        // 저장함은 반복곡보다 앞선다
        let writtenRepeated = UsbHistoryRulesTests.archived("usb", ["101", "101"], written: "rb-1")
        #expect(status(writtenRepeated, inRekordbox: ["rb-1"]) == .written)
        // 반복곡은 컬렉션곡없음보다 앞선다(곡이 없으면 반복이 아니므로 겹치지 않는다)
        #expect(status(UsbHistoryRulesTests.archived("usb", [nil, nil])) == .noCollectionTracks)
    }
}
