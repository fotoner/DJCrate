import DJCDomain
import Foundation

extension LibraryUseCases {
    /// 복원이 되살린 재생 목록 편집을 쌓아 저장하는 유스케이스: 저장소는 같고 출처만 "복원이 되살림"이다(R8). 되살린 단계는 자동 저장하지 않는 제안이 되고,
    /// 그대로 둔 단계는 제 출처를 지킨다. 곡 초안의 되살리기는 반영 세션이 같은 출처로 한다(`ReflectionSession.reviveDrafts`)
    public var restoredPlaylists: EditPlaylists {
        EditPlaylists(imports: ports.playlistImports, drafts: ports.drafts.with(origin: .restored))
    }
}
