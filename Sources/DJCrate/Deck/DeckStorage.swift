import DJCApplication
import DJCDomain
import Foundation

/// 덱이 쓰는 저장소: 곡 초안(큐·그리드·게인) 저장 유스케이스와 설정. 조립 지점이 라이브러리 저장소와 같은 초안 저장소(같은 저장 큐)·설정을 준다.
/// 덱은 초안 저장소를 들지 않고 유스케이스(`SaveDeckDrafts`)만 부른다. 시험은 메모리 초안 저장소(`MemoryDrafts`)를 넣는다.
struct DeckStorage: Sendable {
    /// 큐·그리드·게인 초안 저장(저장하지 못한 입력이 디스크보다 최신이다)
    let drafts: SaveDeckDrafts
    var settings: SettingsStore

    init(drafts: DraftStore, settings: SettingsStore) {
        self.drafts = SaveDeckDrafts(drafts: drafts)
        self.settings = settings
    }
}
