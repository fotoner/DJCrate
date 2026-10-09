import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension StagingStore {
    /// 초안 폴더 `home`의 추가 목록 파일(`staged.json`)을 바로 읽고 쓴다. 손상된 파일은 덮지 않고 옮겨 보관한다(#178).
    public static func live(home: URL) -> StagingStore {
        let url = home.appending(path: StagedTrackFile.fileName)
        return StagingStore(tracks: { StagedTrackFile.load(url: url) }, save: { try StagedTrackFile.save($0, url: url) })
    }
}
