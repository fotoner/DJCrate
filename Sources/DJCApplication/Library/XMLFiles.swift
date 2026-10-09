import DJCDomain
import Foundation

/// rekordbox XML 파일(포트): 다른 도구가 만든 XML 읽기, 사본 라이브러리의 XML 모양 읽기, 라이브러리·추가한 곡·반영 XML 쓰기.
/// 형식(요소·값 규칙)은 실제 구현(`XMLFiles.live`, RekordboxKit)이 안다. rekordbox 라이브러리에는 쓰지 않는다.
public struct XMLFiles: Sendable {
    /// 파일 자리의 종류
    public enum Item: Sendable, Equatable { case none, file, directory }

    /// rekordbox XML 파일을 읽는다(문서가 깨졌거나 rekordbox XML이 아니면 `XMLReadError`)
    public var read: @Sendable (URL) throws -> XMLLibrary
    /// 사본 라이브러리를 XML 비교 모양으로 읽는다. 분석 파일 뿌리가 nil이면 그리드를 읽지 않고, `gridsFor`를 주면 그 XML에 그리드가 있는 곡만 읽는다
    public var library: @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ gridsFor: XMLLibrary?) throws -> XMLLibrary
    /// 내보낼 자리를 써도 되는지(아무것도 쓰지 않는다). 아니면 `LibraryXMLOutputError`
    public var checkOutput: @Sendable (URL) throws -> Void
    /// 사본 라이브러리 전체를 XML로 읽어(분석 파일 뿌리가 있으면 그리드 포함) `out`에 쓴다. `out`이 nil이면 읽기만 한다(미리 보기). 센 것을 돌려준다
    public var exportLibrary: @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ out: URL?,
                                         _ progress: (@Sendable (LibraryXMLProgress) -> Void)?) throws -> LibraryXMLSummary
    /// 그 자리에 무엇이 있는지
    public var item: @Sendable (URL) -> Item
    /// 이미 rekordbox에 있는 곡의 초안을 XML로 넘길 계획(큐·그리드, 넘길 수 없는 이유)
    public var reflectionPlan: @Sendable (_ track: Track, _ rawCues: [Cue], _ cue: CueDraft?, _ grid: GridDraft?) -> ReflectionXMLPlan
    /// rekordbox가 가져온 뒤 계획대로 들어갔는지(새 사본의 곡·큐·분석 그리드로 본다)
    public var verifyReflection: @Sendable (_ plan: ReflectionXMLPlan, _ track: Track, _ cues: [Cue], _ grid: BeatGrid?) -> ReflectionXMLCheck
    /// 반영 계획을 XML 문서 한 파일로 쓴다(재생 목록 이름 `playlistName`)
    public var writeReflection: @Sendable (_ plans: [ReflectionXMLPlan], _ playlistName: String, _ out: URL) throws -> Void
    /// 추가한 곡을 XML 문서 한 파일로 쓴다
    public var writeStaged: @Sendable (_ entries: [StagedXMLEntry], _ playlistName: String, _ out: URL) throws -> Void

    public init(read: @escaping @Sendable (URL) throws -> XMLLibrary,
                library: @escaping @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ gridsFor: XMLLibrary?) throws -> XMLLibrary,
                checkOutput: @escaping @Sendable (URL) throws -> Void,
                exportLibrary: @escaping @Sendable (_ snapshot: URL, _ shareRoot: URL?, _ out: URL?,
                                                    _ progress: (@Sendable (LibraryXMLProgress) -> Void)?) throws -> LibraryXMLSummary,
                item: @escaping @Sendable (URL) -> Item,
                reflectionPlan: @escaping @Sendable (_ track: Track, _ rawCues: [Cue], _ cue: CueDraft?, _ grid: GridDraft?) -> ReflectionXMLPlan,
                verifyReflection: @escaping @Sendable (_ plan: ReflectionXMLPlan, _ track: Track, _ cues: [Cue], _ grid: BeatGrid?) -> ReflectionXMLCheck,
                writeReflection: @escaping @Sendable (_ plans: [ReflectionXMLPlan], _ playlistName: String, _ out: URL) throws -> Void,
                writeStaged: @escaping @Sendable (_ entries: [StagedXMLEntry], _ playlistName: String, _ out: URL) throws -> Void) {
        self.read = read
        self.library = library
        self.checkOutput = checkOutput
        self.exportLibrary = exportLibrary
        self.item = item
        self.reflectionPlan = reflectionPlan
        self.verifyReflection = verifyReflection
        self.writeReflection = writeReflection
        self.writeStaged = writeStaged
    }
}

/// 추가한 곡 XML의 곡 하나(태그 초안을 얹은 곡, 그리드·큐 초안)
public struct StagedXMLEntry: Sendable {
    public var track: StagedTrack
    /// 템포 구간(rekordbox 시간축). 비어 있으면 TEMPO를 쓰지 않는다(rekordbox가 분석한다)
    public var tempos: [GridSegment]
    public var cues: [EditableCue]

    public init(track: StagedTrack, tempos: [GridSegment], cues: [EditableCue]) {
        self.track = track
        self.tempos = tempos
        self.cues = cues
    }
}
