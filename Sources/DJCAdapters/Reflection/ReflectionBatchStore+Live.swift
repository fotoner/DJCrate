import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension ReflectionBatchStore {
    /// 계획 묶음 파일 하나(`url`, 앱은 데이터 폴더의 `reflection.json`)
    public static func live(url: URL) -> Self {
        Self(load: { ReflectionStore.load(url: url) }, save: { try ReflectionStore.save($0, url: url) })
    }
}
