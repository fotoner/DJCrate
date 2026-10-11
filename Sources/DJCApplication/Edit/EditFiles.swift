import DJCDomain
import Foundation

/// 곡 편집이 파일에 하는 것(포트): 편집본 폴더·파일 있음, 렌더. 추가한 곡에 넣기는 `StageEdit`.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 모두 메인 스레드 밖에서 불린다.
public struct EditFiles: Sendable {
    /// 렌더한 편집본을 둘 폴더(앱은 음악 폴더의 DJCrate 편집본)
    public var outputDirectory: @Sendable () -> URL
    public var fileExists: @Sendable (URL) -> Bool
    public var createDirectory: @Sendable (URL) throws -> Void
    public var removeFile: @Sendable (URL) -> Void
    /// 원곡 프레임을 이어 PCM 파일로 쓴다(`EditRenderer`). 부른 작업을 취소하면 반쯤 쓴 파일을 지우고 `CancellationError`.
    public var render: @Sendable (EditRenderJob, URL, EditRenderProgress?) throws -> Void

    public init(outputDirectory: @escaping @Sendable () -> URL,
                fileExists: @escaping @Sendable (URL) -> Bool,
                createDirectory: @escaping @Sendable (URL) throws -> Void,
                removeFile: @escaping @Sendable (URL) -> Void,
                render: @escaping @Sendable (EditRenderJob, URL, EditRenderProgress?) throws -> Void) {
        self.outputDirectory = outputDirectory
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.removeFile = removeFile
        self.render = render
    }
}

/// 렌더할 결과: 마디 편집 또는 Flip, 원곡과 그 rekordbox 시간축 오프셋
public struct EditRenderJob: Sendable {
    public enum Plan: Sendable {
        case bars(TrackEdit)
        case flip(FlipEdit)
    }

    public var plan: Plan
    public var source: URL
    /// 원곡의 rekordbox 시간축 − 음원 시간축(초, 인코더 지연)
    public var sourceOffset: Double

    public init(plan: Plan, source: URL, sourceOffset: Double) {
        self.plan = plan
        self.source = source
        self.sourceOffset = sourceOffset
    }
}

/// 추가한 곡에 넣을 편집본: 렌더한 파일, 출력 그리드(비면 그리드 초안 없음), 옮긴 큐, 원곡(태그 초안), 새 제목
public struct EditStagingRequest: Sendable {
    public var file: URL
    public var grid: [GridSegment]
    public var cues: [EditableCue]
    public var source: Track?
    public var title: String

    public init(file: URL, grid: [GridSegment], cues: [EditableCue], source: Track?, title: String) {
        self.file = file
        self.grid = grid
        self.cues = cues
        self.source = source
        self.title = title
    }
}
