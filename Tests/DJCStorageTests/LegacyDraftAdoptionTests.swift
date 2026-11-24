@testable import DJCStorage
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 업데이트 전 곡 초안 이관(#295 E1): 도장 기능 전부터 있던 도장 없는 큐·그리드·태그·게인 초안에 사람 편집 출처를 한 번 붙인다.
/// 도장이 있는 초안(모름 포함)·손상 도장·읽지 못한 게인 도장·재생 목록 단계는 그대로 두고, 표지에 대상을 먼저 적은 뒤 도장을 붙이고 완료를 적는다.
@Suite("업데이트 전 곡 초안 이관")
struct LegacyDraftAdoptionTests {
    static func cue(_ uuid: String, at time: Double = 1) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(kind: .memory, time: time)]
        return draft
    }

    static func grid(_ uuid: String) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)],
                  segments: [GridSegment(start: 0.2, bpm: 124, firstBeatNumber: 1)])
    }

    static func tag(_ uuid: String) -> TagDraft {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        draft.fields.rating = "4"
        return draft
    }

    static func stamp(_ key: DraftKey, _ home: URL) -> DraftStamp? { DraftStampStore.stamp(key, home: home) }

    /// 도장 기능 전 빌드처럼 초안 파일만 쓴다(도장 없음)
    static func legacy(_ places: DraftLocations, cues: [String] = [], grids: [String] = [], tags: [String] = [], gains: [String: Double] = [:]) throws {
        for uuid in cues { try CueDraftStore.save(cue(uuid), directory: places.cue) }
        for uuid in grids { try GridDraftStore.save(grid(uuid), directory: places.grid) }
        for uuid in tags { try TagDraftStore.save(tag(uuid), directory: places.tags) }
        for (uuid, gain) in gains { try GainDraftStore.save(gain, trackUUID: uuid, url: places.gain) }
    }

    @Test func 도장_없는_큐_그리드_태그_게인_초안은_사람_편집_출처와_지금_해시를_받는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a"], grids: ["b"], tags: ["c"], gains: ["d": -2.5])
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 4)
        for key in [DraftKey(.cue, "a"), DraftKey(.grid, "b"), DraftKey(.tag, "c"), DraftKey(.gain, "d")] {
            let stamp = try #require(Self.stamp(key, folder.url), "\(key)")
            #expect(stamp.origins == [.human], "\(key)")
            #expect(DraftSuggestion.judge(stamp: stamp, currentHash: StampedDrafts.currentHash(key, places: places)) == nil, "\(key)는 자동 저장 대상이다")
        }
        // 판은 저장소 전체에서 겹치지 않는다
        let revisions = [DraftKey(.cue, "a"), DraftKey(.grid, "b"), DraftKey(.tag, "c"), DraftKey(.gain, "d")].compactMap { Self.stamp($0, folder.url)?.revision }
        #expect(Set(revisions).count == 4)
    }

    @Test func 도장이_있는_초안과_손상_도장과_재생_목록_단계는_그대로다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        // CLI가 만든 초안, 옛 초안을 업데이트 뒤 사람이 고친 초안({human, unknown})
        try StampedDrafts.saveCue(Self.cue("cli"), directory: places.cue, origin: .cli)
        try Self.legacy(places, cues: ["mixed"])
        try StampedDrafts.saveCue(Self.cue("mixed", at: 2), directory: places.cue, origin: .human)
        // 가져오기·곡 넣기 정리가 남긴 모름({unknown}) 초안
        try Self.legacy(places, grids: ["unknown"])
        let unknownHash = try #require(StampedDrafts.currentHash(DraftKey(.grid, "unknown"), places: places))
        try DraftStampStore.withLock(home: folder.url) {
            try DraftStampStore.write(DraftStamp(revision: DraftRevision(90), origins: [.unknown], contentHash: unknownHash),
                                      for: DraftKey(.grid, "unknown"), home: folder.url)
        }
        // 손상된 도장 파일
        try Self.legacy(places, tags: ["damaged"])
        let damaged = DraftStampStore.folder(home: folder.url).appending(path: "tag/damaged.json")
        try FileManager.default.createDirectory(at: damaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{망가짐".utf8).write(to: damaged)
        // 도장 없는 재생 목록 초안
        let playlist = try DraftStampStoreTests.playlist([.rename(playlist: .id("B"), name: "새")])
        try PlaylistDraftStore.save(playlist, url: places.playlist)
        let before = (cli: Self.stamp(DraftKey(.cue, "cli"), folder.url), mixed: Self.stamp(DraftKey(.cue, "mixed"), folder.url),
                      unknown: Self.stamp(DraftKey(.grid, "unknown"), folder.url))
        #expect(before.mixed?.origins == [.human, .unknown])

        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 0)
        #expect(Self.stamp(DraftKey(.cue, "cli"), folder.url) == before.cli)
        #expect(Self.stamp(DraftKey(.cue, "mixed"), folder.url) == before.mixed)
        #expect(Self.stamp(DraftKey(.grid, "unknown"), folder.url) == before.unknown)
        #expect(try Data(contentsOf: damaged) == Data("{망가짐".utf8), "손상 도장은 건드리지 않는다")
        #expect(StampedDrafts.playlistStamps(home: folder.url).allSatisfy { !$0.isHumanOnly }, "재생 목록 단계는 이관하지 않는다")
    }

    @Test func 게인_도장_묶음을_읽지_못하면_게인은_모두_빼고_읽히면_항목_없는_곡만_받는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveGain(-1, trackUUID: "stamped", url: places.gain, origin: .cli)
        try Self.legacy(places, gains: ["legacy": -3])
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 1)
        #expect(Self.stamp(DraftKey(.gain, "legacy"), folder.url)?.origins == [.human])
        #expect(Self.stamp(DraftKey(.gain, "stamped"), folder.url)?.origins == [.cli])

        let other = try TemporaryFolder(), otherPlaces = DraftLocations(home: other.url)
        try Self.legacy(otherPlaces, cues: ["a"], gains: ["g": -3])
        let gainStamps = DraftStampStore.folder(home: other.url).appending(path: "gain.json")
        try FileManager.default.createDirectory(at: gainStamps.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[망가짐".utf8).write(to: gainStamps)
        #expect(try LegacyDraftAdoption.adopt(home: other.url) == 1, "게인 도장을 읽지 못하면 게인은 빼고 큐만 받는다")
        #expect(try Data(contentsOf: gainStamps) == Data("[망가짐".utf8))
    }

    @Test func 두_번째_실행은_이관하지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a"])
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 1)
        // 그 뒤에 생긴 도장 없는 초안(다른 사본에서 옮겨 옴 등)은 계속 제안이다
        try Self.legacy(places, cues: ["late"])
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 0)
        #expect(Self.stamp(DraftKey(.cue, "late"), folder.url) == nil)
    }

    @Test func 표지_시작_쓰기가_실패하면_아무것도_이관하지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a"], gains: ["g": -1])
        #expect(throws: (any Error).self) {
            try LegacyDraftAdoption.adopt(home: folder.url, saveMarker: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(Self.stamp(DraftKey(.cue, "a"), folder.url) == nil && Self.stamp(DraftKey(.gain, "g"), folder.url) == nil)
    }

    @Test func 완료를_적지_못하면_다음_실행은_표지의_키_가운데_아직_도장_없고_해시가_같은_것만_한다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a", "b", "c"])
        // 첫 실행: 표지 시작은 쓰고 완료 쓰기만 실패한다 → 도장은 붙었고 표지는 끝나지 않았다
        let calls = Mutex(0)
        #expect(try LegacyDraftAdoption.adopt(home: folder.url, saveMarker: { data, url in
            let call = calls.withLock { value -> Int in value += 1; return value }
            if call == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }) == 3)
        // 중간에 멈춘 실행을 흉내 낸다: b의 도장이 아직 없고, c는 그새 CLI가 같은 내용으로 저장해 도장이 생겼고, d는 표지에 없는 새 초안이다
        try DraftStampStore.withLock(home: folder.url) {
            try DraftStampStore.write(nil, for: DraftKey(.cue, "b"), home: folder.url)
            try DraftStampStore.write(nil, for: DraftKey(.cue, "c"), home: folder.url)
        }
        try StampedDrafts.saveCue(Self.cue("c"), directory: places.cue, origin: .cli)
        let cli = Self.stamp(DraftKey(.cue, "c"), folder.url)
        try Self.legacy(places, cues: ["d"])
        let a = Self.stamp(DraftKey(.cue, "a"), folder.url)
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 1, "표지의 키 가운데 아직 도장 없는 b만")
        #expect(Self.stamp(DraftKey(.cue, "b"), folder.url)?.origins == [.human])
        #expect(Self.stamp(DraftKey(.cue, "a"), folder.url) == a, "이미 이관한 키는 다시 하지 않는다")
        #expect(Self.stamp(DraftKey(.cue, "c"), folder.url) == cli, "CLI가 저장한 키는 건너뛴다")
        #expect(Self.stamp(DraftKey(.cue, "d"), folder.url) == nil, "표지에 없는 새 초안은 넣지 않는다")
        // 완료를 적었으니 그 뒤로는 하지 않는다
        try DraftStampStore.withLock(home: folder.url) { try DraftStampStore.write(nil, for: DraftKey(.cue, "b"), home: folder.url) }
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 0)
    }

    @Test func 표지의_해시와_지금_내용이_다르면_다시_하지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a"])
        #expect(throws: (any Error).self) {
            // 시작만 적고(완료 전) 도장을 붙이기 전에 멈춘 실행
            try LegacyDraftAdoption.adopt(home: folder.url, saveMarker: { data, url in try data.write(to: url, options: .atomic) },
                                          beforeStamping: { throw CancellationError() })
        }
        #expect(Self.stamp(DraftKey(.cue, "a"), folder.url) == nil)
        // 그새 바깥에서 내용만 바뀌었다(도장 없음)
        try CueDraftStore.save(Self.cue("a", at: 9), directory: places.cue)
        #expect(try LegacyDraftAdoption.adopt(home: folder.url) == 0)
        #expect(Self.stamp(DraftKey(.cue, "a"), folder.url) == nil)
    }

    @Test func 이관은_초안_잠금_안에서_한다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Self.legacy(places, cues: ["a"])
        let held = Mutex(false)
        _ = try LegacyDraftAdoption.adopt(home: folder.url, saveMarker: { data, url in
            held.withLock { $0 = $0 || DraftStampStoreTests.isLockHeld(home: folder.url) }
            try data.write(to: url, options: .atomic)
        })
        #expect(held.withLock { $0 })
    }
}
