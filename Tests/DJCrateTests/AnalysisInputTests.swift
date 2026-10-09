@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 반영 때 분석 전 곡에 붙일 음원 정보(#6·#87). 합성 음원만 쓴다.
@Suite("분석 붙이기 입력")
@MainActor
struct AnalysisInputTests {
    func row(_ id: String, _ url: URL, analysisDataPath: String? = nil) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: id, title: "합성 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                              releaseYear: nil, trackNumber: nil, key: nil, bpm: nil, lengthSeconds: 2, folderPath: url.path, comment: "",
                              importedOn: nil, analysisDataPath: analysisDataPath, imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    @Test func 분석_전_곡은_음원_길이와_내장_그림을_넘긴다() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-analysis-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = ImageFixture.image(width: 300, height: 200)
        let art = try AudioFixture.mp3(try TestResources.url("mp3-notag-cbr.mp3"), artwork: image, in: directory)
        let plain = try AudioFixture.wav(seconds: 2, in: directory)
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        for row in [row("art", art), row("plain", plain), row("done", art, analysisDataPath: "/PIONEER/USBANLZ/abc/d/ANLZ0000.DAT")] {
            store.rowsByUUID[row.track.uuid] = row
        }
        let grids = ["art", "plain", "done"].map { GridDraft(trackUUID: $0, base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]) }
        let inputs = try await store.session.analysisInputs(for: grids, measuringLoudness: false)
        #expect(Set(inputs.keys) == ["art", "plain"], "분석 파일이 있는 곡은 붙이지 않는다")
        #expect(inputs["art"]?.artwork == image, "음원 내장 앨범아트로 앨범아트를 넣는다")
        #expect((inputs["art"]?.duration ?? 0) > 0 && inputs["plain"]?.artwork == nil)
    }
}
