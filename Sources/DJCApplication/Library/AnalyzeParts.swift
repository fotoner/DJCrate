import DJCDomain
import Foundation

/// 곡 하나의 음악 분석(피동 포트): 섹션·박·조성·음량 분석과 섹션 에너지·파트(사비·간주) 추정.
/// 실제 구현은 DJCAdapters(`PartAnalysisTools.live`, DJCAnalysis). 분석은 무거워 메인 밖에서 부른다.
public struct PartAnalysisTools: Sendable {
    /// 음원을 분석한다(캐시 열쇠 = 곡 UUID, nil이면 분석 캐시를 쓰지 않는다)
    public var analyze: @Sendable (_ file: URL, _ cacheKey: String?) async throws -> PartAnalysis
    public var energies: @Sendable (PartAnalysis) -> [SectionEnergy]
    public var parts: @Sendable (PartAnalysis) -> [PartMarker]

    public init(analyze: @escaping @Sendable (_ file: URL, _ cacheKey: String?) async throws -> PartAnalysis,
                energies: @escaping @Sendable (PartAnalysis) -> [SectionEnergy],
                parts: @escaping @Sendable (PartAnalysis) -> [PartMarker]) {
        self.analyze = analyze
        self.energies = energies
        self.parts = parts
    }
}

/// 곡 파트 분석(유스케이스, CLI `djc analyze`): 인자가 있는 음원 파일이면 그 파일을, 아니면 라이브러리 곡(ContentID)을
/// 사본(`--db`, 없으면 최신 스냅샷)에서 찾아 그 음원과 기존 큐를 함께 본다. rekordbox·초안에는 쓰지 않는다.
public struct AnalyzeParts: Sendable {
    public var source: LibrarySource
    public var files: TrackFiles
    public var tools: PartAnalysisTools
    /// 사본을 주지 않았을 때 최신 스냅샷을 찾는 폴더
    public var snapshotDirectory: URL

    public init(source: LibrarySource, files: TrackFiles, tools: PartAnalysisTools, snapshotDirectory: URL) {
        self.source = source
        self.files = files
        self.tools = tools
        self.snapshotDirectory = snapshotDirectory
    }

    /// 분석할 음원과 라이브러리 곡(파일로 주었으면 곡 없음)
    public struct Target: Sendable {
        public var file: URL
        public var track: Track?
        public var cues: [Cue]
    }

    public struct Result: Sendable {
        public var analysis: PartAnalysis
        public var energies: [SectionEnergy]
        public var parts: [PartMarker]
    }

    /// 무엇을 분석할지 정한다. 파일이 없고 그 ContentID의 곡도 사본에 없으면 nil
    public func target(_ argument: String, database: URL?) throws -> Target? {
        if files.exists(argument) { return Target(file: URL(filePath: argument), track: nil, cues: []) }
        let library = try source.library(try database ?? source.latestSnapshot(snapshotDirectory))
        guard let track = library.tracks.first(where: { $0.id == argument }) else { return nil }
        return Target(file: URL(filePath: track.folderPath), track: track, cues: library.cues(for: track))
    }

    /// 음원을 분석하고 섹션 에너지·파트를 함께 낸다. 라이브러리 곡이면 곡 UUID로 분석 캐시를 쓴다
    public func analyze(_ target: Target) async throws -> Result {
        let analysis = try await tools.analyze(target.file, target.track?.uuid)
        return Result(analysis: analysis, energies: tools.energies(analysis), parts: tools.parts(analysis))
    }
}
