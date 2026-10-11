import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 곡 파트 분석(CLI `djc analyze`). 음원·DB 없이 가짜 파일·메모리 라이브러리·가짜 분석기로 무엇을 분석할지와 분석 결과 묶음을 본다.
@Suite("곡 파트 분석")
struct AnalyzePartsTests {
    static let snapshots = URL(filePath: "/snapshots")
    static let latest = URL(filePath: "/snapshots/master-latest.db")
    static let copy = URL(filePath: "/copies/master.db")

    static func track(_ id: String, path: String) -> Track {
        Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 120, folderPath: path, comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    static let analysis = PartAnalysis(duration: 120, bpm: 128, beats: [0, 0.5], bars: [0, 2], sections: [.init(start: 0, end: 60)],
                                       segments: [], phrases: [], keys: [], pace: [], vocal: [], drum: [], loudness: [],
                                       integratedLoudness: -9)

    /// 분석기가 받은 (음원, 캐시 열쇠)를 남긴다
    final class Calls: Sendable {
        let analyzed = Mutex<[(String, String?)]>([])
    }

    static func useCase(existing: Set<String> = [], libraries: [URL: RekordboxLibrary] = [:], calls: Calls = Calls()) -> AnalyzeParts {
        let files = TrackFiles(exists: { existing.contains($0) }, audioFiles: { $0 },
                               stagedTrack: { _, _ in throw CancellationError() }, tagKey: { _ in nil }, read: { _ in Data() })
        let tools = PartAnalysisTools(analyze: { file, key in
                                          calls.analyzed.withLock { $0.append((file.path, key)) }
                                          return Self.analysis
                                      },
                                      energies: { _ in [SectionEnergy(span: .init(start: 0, end: 60), loudness: -8, vocal: 0.5, drum: 0.4, score: 1)] },
                                      parts: { _ in [PartMarker(label: .firstChorus, time: 30, bar: 16, confidence: 0.7)] })
        return AnalyzeParts(source: .memory(libraries, latest: latest), files: files, tools: tools, snapshotDirectory: snapshots)
    }

    @Test func 있는_파일은_라이브러리를_읽지_않고_그_파일을_캐시_없이_분석한다() async throws {
        let calls = Calls()
        let parts = Self.useCase(existing: ["/m/a.mp3"], calls: calls)
        let target = try #require(try parts.target("/m/a.mp3", database: nil))
        #expect(target.file.path == "/m/a.mp3" && target.track == nil && target.cues.isEmpty)
        let result = try await parts.analyze(target)
        #expect(calls.analyzed.withLock { $0.map(\.0) } == ["/m/a.mp3"])
        #expect(calls.analyzed.withLock { $0.map(\.1) } == [nil])
        #expect(result.analysis.bpm == 128 && result.energies.count == 1 && result.parts.map(\.label) == [.firstChorus])
    }

    @Test func 파일이_없으면_사본에서_ContentID로_곡과_큐를_찾아_곡_UUID를_캐시_열쇠로_분석한다() async throws {
        let song = Self.track("7", path: "/m/곡.mp3")
        let cue = Cue(id: "c1", contentID: "7", kind: 1, inMsec: 1_000, name: "", colorTableIndex: nil)
        let library = RekordboxLibrary(allTracks: [song], cues: [cue], playCounts: [:])
        let calls = Calls()
        // 사본을 주지 않으면 최신 스냅샷
        let parts = Self.useCase(libraries: [Self.latest: library, Self.copy: RekordboxLibrary(allTracks: [], cues: [], playCounts: [:])], calls: calls)
        let target = try #require(try parts.target("7", database: nil))
        #expect(target.file.path == "/m/곡.mp3" && target.track?.id == "7" && target.cues.map(\.id) == ["c1"])
        _ = try await parts.analyze(target)
        #expect(calls.analyzed.withLock { $0.map(\.1) } == ["u7"])
        // 사본을 주면 그 사본에서 찾는다(거기엔 곡이 없다)
        #expect(try parts.target("7", database: Self.copy) == nil)
    }

    @Test func 스냅샷이_없으면_던진다() {
        let parts = AnalyzeParts(source: .memory([:]), files: Self.useCase().files, tools: Self.useCase().tools, snapshotDirectory: Self.snapshots)
        #expect(throws: DJCError.self) { try parts.target("7", database: nil) }
    }
}
