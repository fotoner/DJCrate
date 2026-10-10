import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 연결되지 않은 초안 시트의 화면 모델(#175, #249). 목록을 읽고, 고른 것만 확인한 뒤 버린다. 버리지 못하면 이유와 할 일을 보인다.
@MainActor @Observable
final class UnlinkedDraftsModel: Identifiable {
    private(set) var drafts: [UnlinkedDraft] = []
    private(set) var selected: Set<String> = []
    /// 버리기 확인 창
    var confirming = false
    private(set) var failure: String?
    @ObservationIgnored private let details: @MainActor () -> [UnlinkedDraft]
    @ObservationIgnored private let discardDrafts: @MainActor (Set<String>) -> Int
    @ObservationIgnored private let isWriting: @MainActor () -> Bool

    /// - Parameters:
    ///   - details: 연결되지 않은 초안의 자세한 목록(최근에 고친 것부터)
    ///   - discard: 고른 곡의 초안을 버리고 버리지 못한 곡 수를 돌려준다
    ///   - isWriting: rekordbox에 쓰는 중인지(그동안은 버리지 않는다)
    init(details: @escaping @MainActor () -> [UnlinkedDraft], discard: @escaping @MainActor (Set<String>) -> Int,
         isWriting: @escaping @MainActor () -> Bool) {
        self.details = details
        discardDrafts = discard
        self.isWriting = isWriting
    }

    convenience init(store: LibraryStore) {
        let watch = store.useCases.watch
        self.init(details: { [weak store] in store.map { watch.unlinkedDetails($0.unlinkedDraftUUIDs) } ?? [] },
                  discard: { [weak store] in store?.discardUnlinkedDrafts($0) ?? 0 },
                  isWriting: { [weak store] in store?.isWritingRekordbox ?? false })
    }

    var canChooseAll: Bool { !drafts.isEmpty && selected.count != drafts.count }
    var canDiscard: Bool { !selected.isEmpty && !isWriting() }

    func isSelected(_ uuid: String) -> Bool { selected.contains(uuid) }

    func setSelected(_ uuid: String, _ on: Bool) {
        if on { selected.insert(uuid) } else { selected.remove(uuid) }
    }

    func chooseAll() { selected = Set(drafts.map(\.uuid)) }

    /// 목록을 다시 읽고, 사라진 곡은 고른 것에서 뺀다.
    func reload() {
        drafts = details()
        selected.formIntersection(drafts.map(\.uuid))
    }

    func askDiscard() { confirming = true }

    /// 확인 창의 "초안 버리기". 고른 곡의 초안을 버리고 목록을 다시 읽는다.
    func discard() {
        let failed = discardDrafts(selected)
        failure = failed == 0 ? nil : String(ui: "\(failed)곡의 초안을 버리지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 다시 버리세요.")
        reload()
    }
}
