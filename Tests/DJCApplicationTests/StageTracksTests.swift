import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 추가한 곡(유스케이스). 음원·분석·DB 없이 가짜 파일·가짜 분석·메모리 초안으로 넣기·가져온 뒤 확인·그리드·키 추정 규칙을 본다.
@Suite("추가한 곡")
struct StageTracksTests {
    /// 가짜 파일: 있는 경로, 태그를 읽지 못하는 경로, 태그 키
    final class Files: Sendable {
        let existing: Set<String>
        let unreadable: Set<String>
        let tagKeys: [String: String]
        let made = Mutex<[String]>([])
        init(existing: Set<String> = [], unreadable: Set<String> = [], tagKeys: [String: String] = [:]) {
            self.existing = existing; self.unreadable = unreadable; self.tagKeys = tagKeys
        }
        var port: TrackFiles {
            TrackFiles(exists: { [existing] in existing.contains($0) }, audioFiles: { $0 },
                       stagedTrack: { [self] url, addedOn in
                           made.withLock { $0.append(url.path) }
                           guard !unreadable.contains(url.path) else { throw CocoaError(.fileReadCorruptFile) }
                           return StagedTrack(uuid: "s-\(url.lastPathComponent)", path: url.path, title: url.lastPathComponent,
                                              duration: 120, addedOn: addedOn)
                       },
                       tagKey: { [tagKeys] in tagKeys[$0.path] }, read: { _ in Data() })
        }
    }

    static func row(_ id: String, path: String, analysis: String? = nil, length: Int = 120) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: length, folderPath: path, comment: "",
                              importedOn: nil, analysisDataPath: analysis, imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    static func stage(files: Files = Files(), drafts: DraftStore = MemoryDrafts().store, grids: [String: BeatGrid] = [:],
                      estimate: GridEstimate? = nil, offset: Double = 0.02, mainKey: String?? = nil,
                      onEstimate: @escaping @Sendable () -> Void = {}) -> StageTracks {
        StageTracks(files: files.port,
                    analysis: StagingAnalysis(estimateGrid: { _, _ in onEstimate(); return estimate }, timelineOffset: { _ in offset },
                                              mainKey: { _, _, _, _, _ in mainKey }),
                    drafts: drafts, source: .memory([:], grids: grids), today: { "2026-10-09" },
                    staging: StagingStore(tracks: { [] }, save: { _ in }), imports: .none, newKey: { "key" })
    }

    // MARK: - 넣기

    @Test func 컬렉션에_있는_곡은_고르고_추가한_곡은_출처만_덧붙이고_새_곡만_읽는다() async {
        let files = Files(unreadable: ["/m/bad.mp3"])
        let stage = Self.stage(files: files)
        let library = [Self.row("1", path: "/m/있는.mp3")]
        let current = [StagedTrack(uuid: "s-old", path: "/m/old.mp3", title: "old", duration: 60, addedOn: "2026-01-01")]
        let origin = AppleMusicOrigin(libraryID: "L", trackID: 7, playlists: [])
        // 경로는 NFC로 견준다: 분해형으로 들어와도 같은 곡이다
        let urls = ["/m/있는.mp3".decomposedStringWithCanonicalMapping, "/m/old.mp3", "/m/new.mp3", "/m/new.mp3", "/m/bad.mp3"]
            .map { URL(filePath: $0) }
        let addition = await stage.add(urls, current: current, library: library, origins: ["/m/old.mp3": [origin]])

        #expect(addition.libraryRows.map(\.track.id) == ["1"])
        #expect(addition.stagedIDs == [current[0].id])
        #expect(addition.added.map(\.path) == ["/m/new.mp3"] && addition.added.first?.addedOn == "2026-10-09")
        #expect(addition.failed == 1)
        #expect(addition.origins[current[0].id] == [origin])
        #expect(files.made.withLock { $0 } == ["/m/new.mp3", "/m/bad.mp3"], "같은 묶음의 같은 파일은 한 번만 읽는다")
        let summary = addition.summary(linksPlaylists: false)
        #expect(summary.warning && summary.text == "1곡 추가 · rekordbox에 이미 있는 1곡을 골랐습니다 · 이미 추가한 1곡을 골랐습니다 · 1곡은 읽지 못함")
    }

    @Test func 넣는_동안_다른_곳이_고친_줄은_덮지_않고_결과만_얹는다() async {
        let stage = Self.stage()
        let old = StagedTrack(uuid: "s-old", path: "/m/old.mp3", title: "old", duration: 60, addedOn: "2026-01-01")
        let addition = await stage.add([URL(filePath: "/m/new.mp3"), URL(filePath: "/m/old.mp3")], current: [old], library: [],
                                       origins: ["/m/old.mp3": [AppleMusicOrigin(libraryID: "L", trackID: 1, playlists: [])]])
        // 읽는 동안 그리드 추정이 옛 곡의 BPM을 적고, 편집본 넣기가 줄 하나를 더했다
        var list = [old]
        list[0].bpm = 128
        list.append(StagedTrack(uuid: "s-edit", path: "/m/edit.wav", title: "편집본", duration: 30, addedOn: "2026-10-09"))
        addition.apply(to: &list)
        #expect(list.map(\.uuid) == ["s-old", "s-edit", "s-new.mp3"])
        #expect(list[0].bpm == 128 && list[0].appleMusicOrigins?.count == 1)
        #expect(addition.playlistPaths(in: list) == ["/m/new.mp3", "/m/old.mp3"])
    }

    // MARK: - 가져온 뒤 확인

    @Test func 가져온_곡의_그리드를_넘긴_초안과_비교해_적는다() {
        let drafts = MemoryDrafts()
        let segment = GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)
        drafts.save(GridDraft(trackUUID: "s1", base: [], segments: [segment]))
        let grid = BeatGrid(beats: (0..<240).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
        let stage = Self.stage(drafts: drafts.store, grids: ["/A.DAT": grid])
        let staged = [StagedTrack(uuid: "s1", path: "/m/a.mp3", title: "a", duration: 120, addedOn: "2026-10-01"),
                      StagedTrack(uuid: "s2", path: "/m/b.mp3", title: "b", duration: 120, addedOn: "2026-10-01")]
        let rows = [Self.row("1", path: "/m/a.mp3", analysis: "/A.DAT")]

        let verified = stage.verifyImports(staged, rows: rows, shareRoot: URL(filePath: "/share"))
        let list = try? #require(verified.list)
        #expect(list?.first?.importCheck?.result == .matched && list?.first?.importCheck?.checkedOn == "2026-10-09")
        #expect(list?.last?.importCheck == nil)
        #expect(verified.summary?.text == "rekordbox 가져오기 확인 1곡 · 그리드 일치 1" && verified.summary?.allMatched == true)
        // 다시 확인해도 바뀌지 않으면 저장할 목록이 없다
        #expect(stage.verifyImports(list ?? [], rows: rows, shareRoot: URL(filePath: "/share")).list == nil)
    }

    // MARK: - 그리드·키 추정

    static let estimate = GridEstimate(segments: [GridSegment(start: 0.5, bpm: 125, firstBeatNumber: 1)], medianResidualMs: 4,
                                       inlierRatio: 0.9, downbeatConfidence: 0.8)

    @MainActor
    @Test func 그리드를_추정해_rekordbox_시간축_초안으로_저장한다() async {
        let drafts = MemoryDrafts()
        let stage = Self.stage(files: Files(existing: ["/m/a.mp3"]), drafts: drafts.store, estimate: Self.estimate, offset: 0.026)
        let result = await stage.estimateGrid(GridJobItem(uuid: "s1", path: "/m/a.mp3", staged: true))
        #expect(result == .saved(bpm: 125, confident: true, failure: nil))
        #expect(drafts.grid("s1")?.segments.first?.start == 0.526)
    }

    @MainActor
    @Test func 이미_초안이_있거나_파일이_없거나_추정하는_동안_초안이_생기면_덮지_않는다() async {
        let drafts = MemoryDrafts()
        drafts.save(GridDraft(trackUUID: "s1", base: [], segments: [GridSegment(start: 0.1, bpm: 140, firstBeatNumber: 1)]))
        let calls = Mutex(0)
        let stage = Self.stage(files: Files(existing: ["/m/a.mp3"]), drafts: drafts.store, estimate: Self.estimate,
                               onEstimate: { calls.withLock { $0 += 1 } })
        #expect(await stage.estimateGrid(GridJobItem(uuid: "s1", path: "/m/a.mp3", staged: true)) == .existing(bpm: 140))
        #expect(await stage.estimateGrid(GridJobItem(uuid: "s2", path: "/m/없음.mp3", staged: true)) == .skipped)
        #expect(calls.withLock { $0 } == 0)
        // 추정하는 동안 덱이 초안을 만들었다
        let racing = MemoryDrafts()
        let late = Self.stage(files: Files(existing: ["/m/b.mp3"]), drafts: racing.store, estimate: Self.estimate, onEstimate: {
            racing.save(GridDraft(trackUUID: "s3", base: [], segments: [GridSegment(start: 0.2, bpm: 99, firstBeatNumber: 1)]))
        })
        #expect(await late.estimateGrid(GridJobItem(uuid: "s3", path: "/m/b.mp3", staged: true)) == .skipped)
        #expect(racing.grid("s3")?.segments.first?.bpm == 99)
    }

    @MainActor
    @Test func 키는_태그가_먼저이고_없으면_추정하고_파일이_없으면_다음에_다시_본다() async {
        let track = StagedTrack(uuid: "s1", path: "/m/a.mp3", title: "a", duration: 120, addedOn: "2026-10-09")
        let tagged = Self.stage(files: Files(existing: ["/m/a.mp3"], tagKeys: ["/m/a.mp3": "4A"]), mainKey: .some("8A"))
        let fromTag = await tagged.findKey(track)
        #expect(fromTag?.key == "4A" && fromTag?.source == .tag)
        let estimated = Self.stage(files: Files(existing: ["/m/a.mp3"]), mainKey: .some("8A"))
        let fromEstimate = await estimated.findKey(track)
        #expect(fromEstimate?.key == "8A" && fromEstimate?.source == .estimate)
        // 소리가 없어 조성을 못 찾아도 추정한 것으로 적어 되풀이하지 않는다
        let silent = Self.stage(files: Files(existing: ["/m/a.mp3"]), mainKey: .some(nil))
        let found = await silent.findKey(track)
        #expect(found != nil && found?.key == nil && found?.source == .estimate)
        // 파일이 없거나 읽지 못하면 아무것도 적지 않는다
        #expect(await Self.stage(mainKey: .some("8A")).findKey(track) == nil)
        #expect(await Self.stage(files: Files(existing: ["/m/a.mp3"]), mainKey: nil).findKey(track) == nil)
    }
}
