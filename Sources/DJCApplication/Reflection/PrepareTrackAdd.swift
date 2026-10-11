import DJCDomain
import Foundation

/// CLI `djc track-add`가 넣기 전에 음원마다 하는 일(유스케이스): 태그 → 넣기 계획, `--analyze`면 그리드 추정(rekordbox 시간축으로
/// 옮긴다)과 음량(오토게인 −10 LUFS 목표). 넣기는 반영 세션(`ReflectionSession.addTracks`)이 한다. 파일 하나가 실패해도 나머지는 계속하고
/// 알릴 줄(`Line`)로 남긴다. 태그를 읽은 곡은 분석이 실패해도 분석 없이 넣는다.
public struct PrepareTrackAdd: Sendable {
    public var audio: TrackAudioReader
    public var analysis: StagingAnalysis
    /// 통합 음량을 잰다(재지 못하면 던진다)
    public var measureLoudness: @Sendable (URL) throws -> Loudness

    public init(audio: TrackAudioReader, analysis: StagingAnalysis, measureLoudness: @escaping @Sendable (URL) throws -> Loudness) {
        self.audio = audio
        self.analysis = analysis
        self.measureLoudness = measureLoudness
    }

    /// 파일마다 알릴 줄
    public enum Line: Sendable, Equatable {
        /// 그리드를 추정하지 못해 분석 없이 넣는다
        case withoutAnalysis(fileName: String)
        /// 추정한 BPM과 통합 음량(LUFS)
        case analyzed(fileName: String, bpm: Double, integrated: Double?)
        /// 그 파일에서 멈춘 오류(파일 이름, 오류 글)
        case failed(file: String, error: String)
    }

    public struct Prepared: Sendable {
        public var plans: [TrackAddPlan] = []
        /// 경로 → 함께 붙일 분석(그리드·음량)
        public var analyses: [String: RekordboxTrackAnalysis] = [:]
        public var lines: [Line] = []
    }

    /// - Parameter onLine: 줄이 생길 때마다 바로 부른다(CLI가 파일마다 바로 찍는다). 모은 줄은 결과에도 있다
    public func prepare(_ files: [URL], analyze: Bool, onLine: @Sendable (Line) -> Void = { _ in }) async -> Prepared {
        var prepared = Prepared()
        func note(_ line: Line) {
            prepared.lines.append(line)
            onLine(line)
        }
        for url in files {
            do {
                let plan = try audio.addPlan(url, try await audio.tags(url))
                prepared.plans.append(plan)
                guard analyze else { continue }
                guard var estimate = try await analysis.estimateGrid(url, "add-\(plan.fileID)") else {
                    note(.withoutAnalysis(fileName: plan.fileName))
                    continue
                }
                let offset = analysis.timelineOffset(url)
                for index in estimate.segments.indices { estimate.segments[index].start += offset }
                let loudness = try measureLoudness(url)
                prepared.analyses[plan.path] = RekordboxTrackAnalysis(segments: estimate.segments, loudness: loudness)
                note(.analyzed(fileName: plan.fileName, bpm: estimate.bpm, integrated: loudness.integrated))
            } catch {
                note(.failed(file: url.lastPathComponent, error: String(describing: error)))
            }
        }
        return prepared
    }
}
