import DJCApplication
import DJCDomain
import Foundation

/// 편집 창(곡 편집·Flip)이 앱에서 받는 것. 조립 지점(`AppComposition`)이 한 번 만들어 두 창에 붙인다.
@MainActor
struct EditWindowLinks {
    /// 열 때 원곡을 읽고, 창 재생이 덱과 겹치지 않게 한다.
    weak var deck: DeckModel?
    /// 막힌 초안 비교 시트를 곡 편집 창에 붙인다(#232).
    weak var store: LibraryStore?
    /// 막힌 그리드 초안의 비교 시트를 여는 rekordbox 쓰기 화면 쪽
    weak var reflection: ReflectionCoordinator?
    /// 편집본 쓰기(렌더 → 추가한 곡에 넣기)
    var writer: RenderEdit
    /// 창마다 새 재생기(덱과 따로). 조립 지점이 실제 재생기(DJCAdapters `EditAudioPlayer`)를 고른다.
    var makeAudio: @MainActor () -> any EditAudio
    /// 렌더해 넣은 편집본을 추가한 곡에서 고르고 덱에 올린다. 둘째 값은 그리드 초안을 함께 넣었는지.
    var showStaged: (StagedTrack, Bool) -> Void
}
