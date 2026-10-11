import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation

extension StageEdit {
    /// 시험용 넣기(파일만, 추가 목록 파일을 바로 읽고 쓴다): 렌더한 파일 `file`을 초안 폴더 `home`의 추가한 곡에 넣는다.
    /// 제목을 주지 않으면 원곡 제목 + " (Edit)", 원곡도 없으면 파일 이름.
    static func put(_ file: URL, grid: [GridSegment], cues: [EditableCue] = [], source: Track? = nil, title: String? = nil,
                    home: URL) async throws -> StagedTrack {
        let name = title ?? source.map { "\($0.title) (Edit)" } ?? file.deletingPathExtension().lastPathComponent
        return try await StageEdit.files(home: home).stage(EditStagingRequest(file: file, grid: grid, cues: cues, source: source, title: name))
    }
}
