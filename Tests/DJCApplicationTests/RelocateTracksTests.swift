import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 파일 없는 곡의 새 위치 찾기(유스케이스, #62). 사본 DB·폴더·볼륨 없이 가짜 포트로 순서와 판정을 본다.
@Suite("파일 없는 곡 새 위치 찾기")
struct RelocateTracksTests {
    static func track(_ id: String, path: String) -> Track {
        Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil, releaseYear: nil,
              trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 200, folderPath: path, comment: "", importedOn: nil,
              analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    @Test func 사본이_없으면_DB도_폴더도_열기_전에_멈춘다() async {
        let calls = Mutex<[String]>([])
        let relocate = RelocateTracks(source: RelocateSource(
            targets: { _, _ in calls.withLock { $0.append("targets") }; return [] },
            scan: { _, _, _ in calls.withLock { $0.append("scan") }; return RelocateOutput(report: RelocateReport(results: []), summary: RelocateSummary(audioFiles: 0, comparedFiles: 0)) },
            mountedVolumes: { calls.withLock { $0.append("volumes") }; return [] }))
        await #expect(throws: DJCError.self) { _ = try await relocate.find([Self.track("1", path: "/a.mp3")], snapshot: nil, folder: URL(filePath: "/m"), progress: { _ in }) }
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test func 크기를_읽고_훑은_뒤_빠진_외장_디스크를_가른다() async throws {
        let calls = Mutex<[String]>([])
        let tracks = [Self.track("1", path: "/Volumes/Old/a.mp3"), Self.track("2", path: "/Users/me/b.mp3")]
        let relocate = RelocateTracks(source: RelocateSource(
            targets: { tracks, _ in calls.withLock { $0.append("targets") }; return tracks.map { RelocateTarget(track: $0, fileSize: 1) } },
            scan: { targets, folder, progress in
                calls.withLock { $0.append("scan \(folder.path) \(targets.count)") }
                progress(RelocateProgress(phase: .matching, audioFiles: 2, filesToRead: 0, filesRead: 0))
                return RelocateOutput(report: RelocateReport(results: []), summary: RelocateSummary(audioFiles: 2, comparedFiles: 0))
            },
            mountedVolumes: { calls.withLock { $0.append("volumes") }; return ["/"] }))
        let progressed = Mutex(0)
        let found = try await relocate.find(tracks, snapshot: URL(filePath: "/s.db"), folder: URL(filePath: "/m"),
                                            progress: { _ in progressed.withLock { $0 += 1 } })
        #expect(calls.withLock { $0 } == ["targets", "scan /m 2", "volumes"])
        #expect(progressed.withLock { $0 } == 1 && found.output.summary.audioFiles == 2)
        #expect(found.absences["1"]?.unmountedVolumeName == "Old" && found.absences["2"]?.unmountedVolumeName == nil)
    }
}
