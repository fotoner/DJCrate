import DJCDomain
import Foundation

/// 편집본 하나(제목·렌더할 결과·추가한 곡에 넣을 그리드와 큐)
public struct EditOutputRequest: Sendable {
    public var job: EditRenderJob
    /// 새 곡 제목(태그 초안)이자 파일 이름
    public var title: String
    public var grid: [GridSegment]
    public var cues: [EditableCue]
    /// 원곡(태그 초안을 채운다)
    public var sourceTrack: Track?

    public init(job: EditRenderJob, title: String, grid: [GridSegment], cues: [EditableCue], sourceTrack: Track?) {
        self.job = job
        self.title = title
        self.grid = grid
        self.cues = cues
        self.sourceTrack = sourceTrack
    }
}

/// 편집본 쓰기(유스케이스): 파일 이름 고르기 → 렌더 → 추가한 곡에 넣기(`StageEdit`). 넣기에 실패하면 렌더한 파일을 지운다.
/// 편집 창이 메인 스레드에서 하던 파일 입출력을 메인 밖에서 한다. 부른 작업을 취소하면 렌더도 멈춘다.
public struct RenderEdit: Sendable {
    public var files: EditFiles
    public var stager: StageEdit

    public init(files: EditFiles, stager: StageEdit) {
        self.files = files
        self.stager = stager
    }

    /// 창을 열 때 원곡 음원이 있는지
    @concurrent
    public func sourceExists(_ url: URL) async -> Bool {
        files.fileExists(url)
    }

    /// 이미 있는 파일은 덮지 않고 이름에 번호를 붙인다. 원곡·rekordbox에는 쓰지 않는다.
    @concurrent
    public func write(_ request: EditOutputRequest, progress: EditRenderProgress?) async throws -> StagedTrack {
        try Task.checkCancellation()
        let directory = files.outputDirectory()
        let output = EditOutputName.available(in: directory, name: EditOutputName.fileName(for: request.title), exists: files.fileExists)
        try files.createDirectory(directory)
        try files.render(request.job, output, progress)
        do {
            return try await stager.stage(EditStagingRequest(file: output, grid: request.grid, cues: request.cues,
                                                            source: request.sourceTrack, title: request.title))
        } catch {
            files.removeFile(output)
            throw error
        }
    }
}
