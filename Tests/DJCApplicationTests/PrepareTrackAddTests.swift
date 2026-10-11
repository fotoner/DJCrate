import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// CLI `djc track-add`가 넣기 전에 음원마다 하는 일. 음원 없이 가짜 태그·추정·음량으로 계획·분석·알릴 줄을 본다.
@Suite("곡 넣기 준비")
struct PrepareTrackAddTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func plan(_ url: URL) -> TrackAddPlan {
        TrackAddPlan(path: url.path, fileName: url.lastPathComponent, title: url.lastPathComponent, comment: "", year: 0, trackNumber: 0,
                     discNumber: 0, isrc: "", lyricist: "", fileType: 1, fileSize: 1, fileID: "id-\(url.lastPathComponent)", length: 120,
                     duration: 120, dateCreated: "2026-10-09", stockDate: "2026-10-09")
    }

    /// 가짜: `bad`는 태그를 읽지 못하고, `nogrid`는 그리드를 추정하지 못하며, `quiet`는 음량을 재지 못한다
    static func useCase(offset: Double = 0.05, keys: @escaping @Sendable (String) -> Void = { _ in }) -> PrepareTrackAdd {
        let audio = TrackAudioReader(needsAnalysis: { _ in false },
                                     tags: { url in
                                         if url.lastPathComponent.hasPrefix("bad") { throw Failure(description: "태그 오류") }
                                         return AudioTags(title: url.lastPathComponent)
                                     },
                                     loudness: { _ in nil }, unsupported: { _ in nil }, addPlan: { url, _ in Self.plan(url) })
        let segment = GridSegment(start: 1, bpm: 128, firstBeatNumber: 1)
        let analysis = StagingAnalysis(estimateGrid: { url, key in
                                           keys(key)
                                           guard !url.lastPathComponent.hasPrefix("nogrid") else { return nil }
                                           return GridEstimate(segments: [segment], medianResidualMs: 1, inlierRatio: 1, downbeatConfidence: 1)
                                       },
                                       timelineOffset: { _ in offset }, mainKey: { _, _, _, _, _ in nil })
        return PrepareTrackAdd(audio: audio, analysis: analysis, measureLoudness: { url in
            if url.lastPathComponent.hasPrefix("quiet") { throw Failure(description: "음량 오류") }
            return Loudness(integrated: -9.5, peak: -1, clippedRuns: 0)
        })
    }

    @Test func 분석하지_않으면_태그를_읽은_곡만_계획하고_읽지_못한_파일은_오류_줄로_알린다() async {
        let files = ["/m/a.mp3", "/m/bad.mp3", "/m/b.mp3"].map { URL(filePath: $0) }
        let prepared = await Self.useCase().prepare(files, analyze: false)
        #expect(prepared.plans.map(\.path) == ["/m/a.mp3", "/m/b.mp3"])
        #expect(prepared.analyses.isEmpty)
        #expect(prepared.lines == [.failed(file: "bad.mp3", error: "태그 오류")])
    }

    @Test func 분석하면_그리드를_rekordbox_시간축으로_옮기고_음량을_붙이며_못한_곡은_분석_없이_넣는다() async {
        let files = ["/m/a.mp3", "/m/nogrid.mp3", "/m/quiet.mp3"].map { URL(filePath: $0) }
        let keys = KeyLog()
        let reported = Mutex<[PrepareTrackAdd.Line]>([])
        let prepared = await Self.useCase(offset: 0.05, keys: { key in keys.append(key) }).prepare(files, analyze: true) { line in
            // 파일마다 바로 알린다(CLI가 진행을 바로 찍는다): 다음 파일을 볼 때는 앞 파일의 줄이 이미 왔다
            reported.withLock { lines in
                #expect(lines.count == keys.values.count - 1)
                lines.append(line)
            }
        }
        #expect(reported.withLock { $0 } == prepared.lines)
        // 음량을 재지 못한 곡도 계획은 남는다(분석 없이 넣는다)
        #expect(prepared.plans.map(\.path) == ["/m/a.mp3", "/m/nogrid.mp3", "/m/quiet.mp3"])
        #expect(Array(prepared.analyses.keys) == ["/m/a.mp3"])
        #expect(prepared.analyses["/m/a.mp3"]?.segments.map(\.start) == [1.05])
        #expect(prepared.analyses["/m/a.mp3"]?.loudness == -9.5)
        #expect(prepared.lines == [.analyzed(fileName: "a.mp3", bpm: 128, integrated: -9.5), .withoutAnalysis(fileName: "nogrid.mp3"),
                                   .failed(file: "quiet.mp3", error: "음량 오류")])
        #expect(keys.values == ["add-id-a.mp3", "add-id-nogrid.mp3", "add-id-quiet.mp3"], "추정 캐시 열쇠는 파일 ID")
    }

    final class KeyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ key: String) { lock.withLock { stored.append(key) } }
        var values: [String] { lock.withLock { stored } }
    }
}
