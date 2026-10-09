import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import Testing

/// '폴더에서 찾기…' 화면의 상태(#62): 훑기·미리 보기·고르기. 입출력은 가짜로 바꿔 끼우고 rekordbox·음원·폴더를 열지 않는다.
@Suite("파일 없는 곡 후보 미리 보기")
@MainActor
struct RelocateModelTests {
    nonisolated static func track(_ id: String, _ name: String, length: Int = 200) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "아티스트", album: nil, albumArtist: nil, genre: nil, composer: nil,
              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: length, folderPath: "/Volumes/Old/\(name)", comment: "",
              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
    }

    nonisolated static let folder = URL(filePath: "/tmp/djc-relocate-model")
    nonisolated static let tracks = [track("1", "Song.mp3"), track("2", "Pair.mp3"), track("3", "Nope.mp3", length: 5)]

    /// 곡 1은 확실, 곡 2는 애매(후보 둘), 곡 3은 없음
    nonisolated static func output(root: String = folder.path) -> RelocateScanner.Output {
        let targets = tracks.map { RelocateTarget(track: $0, fileSize: 5_000_000) }
        let files = [RelocateFile(path: "\(root)/Song.mp3", size: 5_000_000, durationSeconds: 200.3),
                     RelocateFile(path: "\(root)/A/Pair.mp3", size: 5_000_000, durationSeconds: 200.1),
                     RelocateFile(path: "\(root)/B/Pair.mp3", size: 5_000_000, durationSeconds: 200.2)]
        return RelocateScanner.Output(report: RelocateMatcher.match(targets: targets, files: files),
                                      summary: RelocateScanner.Summary(audioFiles: 3, comparedFiles: 3))
    }

    /// 호출을 적고 정해 둔 결과를 돌려주는 가짜 입출력
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [URL] = []
        var scannedFolders: [URL] { lock.withLock { calls } }
        func dependencies(output: @escaping @Sendable (URL) -> RelocateScanner.Output = { _ in RelocateModelTests.output() },
                          loadError: (any Error)? = nil,
                          delay: Duration = .zero,
                          progress: [RelocateScanner.Progress] = [],
                          mounted: [String] = ["/", "/Volumes/Old"]) -> RelocateSource {
            RelocateSource(
                targets: { tracks, _ in
                    if let loadError { throw loadError }
                    return tracks.map { RelocateTarget(track: $0, fileSize: 5_000_000) }
                },
                scan: { _, folder, report in
                    self.lock.withLock { self.calls.append(folder) }
                    for item in progress { report(item) }
                    if delay != .zero { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    return output(folder)
                },
                mountedVolumes: { mounted })
        }
    }

    func model(_ source: RelocateSource, snapshot: URL? = URL(filePath: "/tmp/djc-relocate-model.db")) -> RelocateModel {
        RelocateModel(tracks: Self.tracks, snapshot: snapshot, folder: Self.folder, relocate: RelocateTracks(source: source))
    }

    @Test func 훑기가_끝나면_미리_보기가_되고_확실한_곡만_미리_고른다() async throws {
        let fake = Fake()
        let model = model(fake.dependencies())
        #expect(model.isScanning)
        model.start()
        #expect(await waitUntil { !model.isScanning })
        #expect(model.phase == .reviewing)
        #expect(model.report.results.map(\.outcome.kind) == [.confident, .ambiguous, .none])
        #expect(model.selection.chosen(for: "1")?.file.name == "Song.mp3")
        #expect(model.selection.chosenCount == 1)
        #expect(model.summary == RelocateScanner.Summary(audioFiles: 3, comparedFiles: 3))
        #expect(fake.scannedFolders == [Self.folder])
    }

    @Test func 분류별로_거르고_개수를_센다() async throws {
        let model = model(Fake().dependencies())
        model.start()
        #expect(await waitUntil { !model.isScanning })
        let counts: [Int] = [model.count(.all), model.count(.confident), model.count(.ambiguous), model.count(.noCandidate)]
        #expect(counts == [3, 1, 1, 1])
        model.filter = .ambiguous
        #expect(model.visibleResults.map(\.id) == ["2"])
        model.filter = .noCandidate
        #expect(model.visibleResults.map(\.id) == ["3"])
        model.filter = .all
        #expect(model.visibleResults.map(\.id) == ["1", "2", "3"])
    }

    @Test func 애매한_곡은_사람이_고르고_고른_것은_개수에_든다() async throws {
        let model = model(Fake().dependencies())
        model.start()
        #expect(await waitUntil { !model.isScanning })
        model.choose("\(Self.folder.path)/B/Pair.mp3", for: "2")
        #expect(model.selection.chosen(for: "2")?.file.path == "\(Self.folder.path)/B/Pair.mp3")
        #expect(model.selection.chosenCount == 2)
        model.choose(nil, for: "1")
        #expect(model.selection.chosenCount == 1)
        // 후보가 아닌 파일은 고를 수 없다
        model.choose("/elsewhere/Pair.mp3", for: "2")
        #expect(model.selection.chosen(for: "2")?.file.path == "\(Self.folder.path)/B/Pair.mp3")
    }

    @Test func 연결되지_않은_외장_디스크의_곡은_빼지_않고_디스크_이름을_붙인다() async throws {
        let model = model(Fake().dependencies(mounted: ["/", "/Volumes/Other"]))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        // 대상에서 빼지 않는다: 세 곡 모두 그대로 맞춘다
        #expect(model.report.results.map(\.id) == ["1", "2", "3"])
        #expect(model.absence(for: "1") == .volumeNotMounted(name: "Old"))
        #expect(model.unmountedVolumeCount == 3)
        #expect(RelocateText.absence(.volumeNotMounted(name: "Old")) == "외장 디스크 연결 안 됨: Old")
    }

    @Test func 디스크가_연결돼_있는데_파일이_없는_곡에는_디스크_표시를_붙이지_않는다() async throws {
        let model = model(Fake().dependencies(mounted: ["/", "/Volumes/Old/"]))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        #expect(model.absence(for: "1") == .fileMissing)
        #expect(model.unmountedVolumeCount == 0)
        #expect(RelocateText.absence(.fileMissing) == nil)
    }

    @Test func 다시_찾을_때_연결된_디스크를_다시_읽는다() async throws {
        let mounted = Mounted(["/"])
        let base = Fake().dependencies()
        let model = model(RelocateSource(targets: base.targets, scan: base.scan, mountedVolumes: { mounted.value }))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        #expect(model.absence(for: "1") == .volumeNotMounted(name: "Old"))
        mounted.value = ["/", "/Volumes/Old"]
        model.rescan(in: Self.folder)
        #expect(await waitUntil { !model.isScanning })
        #expect(model.absence(for: "1") == .fileMissing)
    }

    final class Mounted: @unchecked Sendable {
        private let lock = NSLock()
        private var volumes: [String]
        init(_ volumes: [String]) { self.volumes = volumes }
        var value: [String] {
            get { lock.withLock { volumes } }
            set { lock.withLock { volumes = newValue } }
        }
    }

    @Test func 진행_알림을_화면_상태에_반영한다() async throws {
        let reading = RelocateScanner.Progress(phase: .reading, audioFiles: 10, filesToRead: 4, filesRead: 2)
        let model = model(Fake().dependencies(delay: .seconds(60), progress: [reading]))
        model.start()
        #expect(await waitUntil { model.phase == .scanning(reading) })
        model.cancel()
    }

    @Test func 곡_크기를_읽지_못하면_이유를_보여_주고_멈춘다() async throws {
        let model = model(Fake().dependencies(loadError: DJCError.snapshotNotFound))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        guard case let .failed(message) = model.phase else {
            Issue.record("실패여야 한다")
            return
        }
        #expect(message == DJCError.snapshotNotFound.localizedDescription)
        #expect(model.report.results.isEmpty)
    }

    @Test func 라이브러리_사본이_없으면_훑기_전에_멈춘다() async throws {
        // 실제 입출력 경로: 사본이 없으면 DB도 폴더도 열기 전에 실패한다
        let model = RelocateModel(tracks: Self.tracks, snapshot: nil, folder: URL(filePath: "/nonexistent-djc-folder"),
                                  relocate: RelocateTracks(source: .live))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        #expect(model.phase == .failed(DJCError.snapshotNotFound.localizedDescription))
    }

    @Test func 폴더_오류는_이유를_그대로_보여_준다() async throws {
        let dependencies = RelocateSource(
            targets: { tracks, _ in tracks.map { RelocateTarget(track: $0, fileSize: nil) } },
            scan: { _, _, _ in throw RelocateScanner.ScanError.protectedFolder }, mountedVolumes: { [] })
        let model = model(dependencies)
        model.start()
        #expect(await waitUntil { !model.isScanning })
        #expect(model.phase == .failed(RelocateScanner.ScanError.protectedFolder.localizedDescription))
    }

    @Test func 훑는_중_취소하면_멈추고_늦게_끝난_결과는_버린다() async throws {
        let model = model(Fake().dependencies(delay: .seconds(60)))
        model.start()
        model.cancel()
        #expect(!model.isScanning)
        guard case .failed = model.phase else {
            Issue.record("취소하면 폴더를 다시 고르라고 알려야 한다")
            return
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.report.results.isEmpty)
    }

    @Test func 다른_폴더로_다시_찾으면_앞의_결과를_버리고_새_폴더로_훑는다() async throws {
        let fake = Fake()
        let other = URL(filePath: "/tmp/djc-relocate-other")
        let model = model(fake.dependencies(output: { folder in RelocateModelTests.output(root: folder.path) }))
        model.start()
        #expect(await waitUntil { !model.isScanning })
        model.rescan(in: other)
        #expect(model.isScanning)
        #expect(model.report.results.isEmpty)
        #expect(await waitUntil { !model.isScanning })
        #expect(model.folder == other)
        #expect(fake.scannedFolders == [Self.folder, other])
        #expect(model.selection.chosen(for: "1")?.file.path == "\(other.path)/Song.mp3")
    }

    @Test func 후보_경로는_훑은_폴더_기준_상대_경로로_보여_준다() async throws {
        let model = model(Fake().dependencies())
        #expect(model.displayPath("\(Self.folder.path)/A/Pair.mp3") == "A/Pair.mp3")
        #expect(model.displayPath("/elsewhere/Pair.mp3") == "/elsewhere/Pair.mp3")
        // 폴더 이름만 접두가 같은 다른 폴더는 상대 경로로 줄이지 않는다
        #expect(model.displayPath("\(Self.folder.path)-2/Pair.mp3") == "\(Self.folder.path)-2/Pair.mp3")
    }

    @Test func 경로_쓰기는_막아_두었고_이유를_한_문장으로_알린다() {
        let reason = RelocateModel.writeBlockedReason
        #expect(reason.contains("Relocate"))
        #expect(reason.hasSuffix("."))
        // 한 문장: 마침표가 끝에 하나뿐이다
        #expect(reason.filter { $0 == "." }.count == 1)
    }

    @Test func 근거_문구는_맞은_것만_말한다() {
        let full = RelocateEvidence(name: .exact, sameExtension: true, size: .equal, duration: .equal, title: .equal, artist: .unknown)
        #expect(RelocateText.evidence(full) == "이름 일치 · 크기 일치 · 길이 일치 · 제목 일치")
        let odd = RelocateEvidence(name: .stemOnly, sameExtension: false, size: .different, duration: .unknown, title: .different, artist: .unknown)
        #expect(RelocateText.evidence(odd) == "확장자만 다름 · 크기 다름")
        let none = RelocateEvidence(name: .different, sameExtension: true, size: .unknown, duration: .unknown, title: .unknown, artist: .unknown)
        #expect(RelocateText.evidence(none).isEmpty)
    }
}
