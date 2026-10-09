import DJCApplication
import DJCDomain
import Foundation

/// 파일이 없는 곡(#126)
extension LibraryStore {
    /// 음원 파일이 있는지 뒤에서 확인해 행·'파일 없음' 개수에 반영한다. 읽은 뒤·디스크를 연결하거나 뺄 때·다시 확인 버튼에서 부른다.
    /// 큰 라이브러리의 확인(곡마다 파일 시스템 조회)이 메인 스레드를 막지 않게 한다.
    func checkMissingFiles() {
        missingFileTask?.cancel()
        let generation = reads.generation
        let tracks = rows.map(\.track), useCases = useCases
        setCheckingFiles(true)
        missingFileTask = Task { [weak self] in
            let result = await useCases.missingFiles(tracks)
            guard let self, !Task.isCancelled else { return }
            // 그사이 다시 읽기 시작했으면 버린다(새로 읽은 뒤 다시 확인한다).
            guard reads.isCurrent(generation) else {
                setCheckingFiles(false)
                return
            }
            applyMissingFiles(result)
        }
    }

}
