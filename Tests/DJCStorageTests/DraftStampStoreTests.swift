import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 초안 도장 사이드카(R5·R22 저장소 몫): 출처·판·내용 해시를 초안 폴더 옆 `draft-stamps/`에 적고, 판 지정 삭제·제안 전환은
/// 앱·CLI가 같은 초안 잠금 안에서 한다. 도장은 초안 파일을 쓴 뒤에 적어, 중간에 멈춰도 해시가 어긋나는(제안) 쪽으로만 틀어진다.
@Suite("초안 도장 사이드카")
struct DraftStampStoreTests {
    static func cue(_ uuid: String, at time: Double = 1) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(kind: .memory, time: time)]
        return draft
    }

    static func grid(_ uuid: String, bpm: Double = 124) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)],
                  segments: [GridSegment(start: 0.2, bpm: bpm, firstBeatNumber: 1)])
    }

    static func tag(_ uuid: String, comment: String? = "코멘트") -> TagDraft {
        var draft = TagDraft(trackUUID: uuid, base: TagFields())
        if let comment { draft.fields.comment = comment }
        return draft
    }

    static func hash(_ cue: CueDraft) throws -> DraftContentHash { try DraftContentHash(of: cue) }

    /// 잠금 파일을 비차단으로 잡아 보아, 지금 누가 잠금을 쥐고 있는지 본다
    static func isLockHeld(home: URL) -> Bool {
        let descriptor = open(DraftStampStore.lockURL(home: home).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    @Test func 저장하면_출처와_판과_해시를_초안_폴더_옆_사이드카에_적는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(stamp.origins == [.human] && stamp.isHumanOnly)
        // 해시는 디스크에서 읽은 값의 해시다(쓰기 묶음이 읽어 넣는 값과 같다)
        #expect(try stamp.contentHash == Self.hash(#require(CueDraftStore.load(trackUUID: "a", directory: places.cue))))
        // 초안 폴더에는 초안 파일만 있고, 사이드카는 그 옆 폴더에 있다
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.cue.path) == ["a.json"])
        #expect(DraftStampStore.folder(home: folder.url) == folder.url.appending(path: "draft-stamps", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(atPath: DraftStampStore.folder(home: folder.url).path))
    }

    @Test func 다시_저장하면_새_판이고_다른_출처가_고치면_출처가_모인다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        let first = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        try StampedDrafts.saveCue(Self.cue("a", at: 2), directory: places.cue, origin: .human)
        let second = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(second.revision > first.revision && second.isHumanOnly && second.contentHash != first.contentHash)
        try StampedDrafts.saveCue(Self.cue("a", at: 3), directory: places.cue, origin: .cli)
        let third = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(third.revision > second.revision && third.origins == [.human, .cli] && !third.isHumanOnly)
    }

    @Test func 판은_종류와_곡에_상관없이_저장소_전체에서_겹치지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let image = Data("그림".utf8)
        let artwork = ArtworkDraftStore.edit(trackUUID: "w", base: ArtworkBase(imagePath: ""), image: image, imageName: "a.png")
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "m", title: "가", duration: 60, offset: 0, cues: []),
                                        removing: [], base: "b")
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(Self.cue("b"), directory: places.cue, origin: .human)
        try StampedDrafts.saveGrid(Self.grid("a"), directory: places.grid, origin: .human)
        try StampedDrafts.saveTag(Self.tag("a"), directory: places.tags, origin: .human)
        try StampedDrafts.saveGain(-3, trackUUID: "a", url: places.gain, origin: .human)
        try StampedDrafts.saveGain(-4, trackUUID: "b", url: places.gain, origin: .human)
        try StampedDrafts.saveArtwork(artwork, directory: places.artwork, origin: .human)
        try StampedDrafts.saveMerges([merge], url: places.merge, origin: .human)
        let keys = [DraftKey(.cue, "a"), DraftKey(.cue, "b"), DraftKey(.grid, "a"), DraftKey(.tag, "a"), DraftKey(.gain, "a"),
                    DraftKey(.gain, "b"), DraftKey(.artwork, "w"), DraftKey(.merge, "m")]
        let revisions = try keys.map { try #require(DraftStampStore.stamp($0, home: folder.url)).revision }
        #expect(Set(revisions).count == keys.count)
        // 다른 곡의 게인 저장이 앞 곡의 도장을 건드리지 않는다
        #expect(try DraftStampStore.stamp(DraftKey(.gain, "a"), home: folder.url)?.contentHash == DraftContentHash(of: -3.0))
        #expect(try DraftStampStore.stamp(DraftKey(.gain, "b"), home: folder.url)?.contentHash == DraftContentHash(of: -4.0))
        #expect(try DraftStampStore.stamp(DraftKey(.artwork, "w"), home: folder.url)?.contentHash == DraftContentHash(artwork: artwork))
        #expect(try DraftStampStore.stamp(DraftKey(.merge, "m"), home: folder.url)?.contentHash == DraftContentHash(of: merge))
    }

    @Test func 판_번호_파일을_잃어도_번호를_다시_쓰지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(Self.cue("b"), directory: places.cue, origin: .human)
        let highest = try #require(DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url)).revision
        // 번호 파일이 사라지거나 읽지 못해도 남은 도장 가운데 가장 큰 판 뒤로 이어 간다
        try FileManager.default.removeItem(at: DraftStampStore.folder(home: folder.url).appending(path: "revision"))
        try StampedDrafts.saveCue(Self.cue("c"), directory: places.cue, origin: .human)
        #expect(try #require(DraftStampStore.stamp(DraftKey(.cue, "c"), home: folder.url)).revision > highest)
        try Data("쓰레기".utf8).write(to: DraftStampStore.folder(home: folder.url).appending(path: "revision"))
        try StampedDrafts.saveCue(Self.cue("d"), directory: places.cue, origin: .human)
        let revisions = try ["a", "b", "c", "d"].map { try #require(DraftStampStore.stamp(DraftKey(.cue, $0), home: folder.url)).revision }
        #expect(Set(revisions).count == 4 && revisions[3] > revisions[2])
    }

    @Test func 고친_것이_없는_저장은_초안과_도장을_지운다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(CueDraft(trackUUID: "a"), directory: places.cue, origin: .human)
        #expect(CueDraftStore.load(trackUUID: "a", directory: places.cue) == nil)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == nil)
        // 지운 뒤 다시 만들면 이전 출처를 이어받지 않는다
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        try StampedDrafts.removeCue(trackUUID: "a", directory: places.cue)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == nil)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .cli)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url)?.origins == [.cli])
    }

    @Test func 도장_없는_옛_초안은_출처를_모르고_고치면_모름이_섞인다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        // 업데이트 전부터 있던 초안: 파일만 있고 도장이 없다
        try CueDraftStore.save(Self.cue("a"), directory: places.cue)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == nil)
        #expect(DraftSuggestion.judge(stamp: nil, currentHash: try Self.hash(Self.cue("a"))) == .unknownOrigin)
        // 사람이 그 위에 고쳐도 옛 내용의 출처를 모르니 모름이 섞인다(제안)
        try StampedDrafts.saveCue(Self.cue("a", at: 5), directory: places.cue, origin: .human)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(stamp.origins == [.human, .unknown] && !stamp.isHumanOnly)
    }

    @Test func 초안_파일만_바깥에서_바뀌면_해시가_어긋나_제안이다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        // 도장을 적지 않는 쓰기(바깥)
        try CueDraftStore.save(Self.cue("a", at: 9), directory: places.cue)
        let current = try Self.hash(#require(CueDraftStore.load(trackUUID: "a", directory: places.cue)))
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == stamp)
        #expect(DraftSuggestion.judge(stamp: stamp, currentHash: current) == .contentChanged)
    }

    /// S11: 도장을 초안 파일보다 먼저 쓴다. 도장 기록이 실패하면 초안 파일은 한 바이트도 바뀌지 않고 오류를 던진다
    @Test func 도장_기록이_실패하면_초안_파일은_바뀌지_않고_오류를_던진다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        let before = try Data(contentsOf: places.cue.appending(path: "a.json"))
        let stamp = DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url)
        // 도장 폴더 자리를 일반 파일로 막아 도장 쓰기를 실패시킨다
        let stamps = DraftStampStore.folder(home: folder.url)
        try FileManager.default.moveItem(at: stamps, to: folder.url.appending(path: "옮긴-도장"))
        try Data("막음".utf8).write(to: stamps)
        #expect(throws: (any Error).self) { try StampedDrafts.saveCue(Self.cue("a", at: 2), directory: places.cue, origin: .cli) }
        #expect(try Data(contentsOf: places.cue.appending(path: "a.json")) == before)
        // 도장을 못 읽어도 지금 파일은 옛 내용 그대로다
        try FileManager.default.removeItem(at: stamps)
        try FileManager.default.moveItem(at: folder.url.appending(path: "옮긴-도장"), to: stamps)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == stamp)
    }

    /// S11: 도장을 쓴 뒤 초안 파일을 쓰기 전에 멈추면(파일 쓰기 실패) 안전한 쪽으로만 틀어진다: 새 도장의 해시가 파일과 달라 제안이다
    @Test func 도장을_쓴_뒤_초안_파일_쓰기가_실패하면_제안_쪽으로만_틀어진다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        let first = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        // 초안 폴더를 쓰기 금지로 바꿔 파일 쓰기만 실패시킨다(도장 폴더는 쓸 수 있다)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: places.cue.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: places.cue.path) }
        #expect(throws: (any Error).self) { try StampedDrafts.saveCue(Self.cue("a", at: 2), directory: places.cue, origin: .cli) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: places.cue.path)
        // 파일은 옛 내용이고 도장만 새 판이다: 해시가 어긋나 사람 편집만 든 도장이어도 자동 저장 대상이 아니다
        let file = try Self.hash(#require(CueDraftStore.load(trackUUID: "a", directory: places.cue)))
        #expect(file == first.contentHash)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(stamp.revision > first.revision && stamp.contentHash != file)
        #expect(DraftSuggestion.judge(stamp: stamp, currentHash: file) != nil)
    }

    /// 재리뷰 S11: 지우기도 도장을 먼저 고친다. 도장 기록이 실패하면 초안 파일(바깥이 고친 내용 포함)은 지워지지 않고 오류를 던진다
    @Test func 도장_기록이_실패하면_초안_지우기도_파일을_남긴다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        // 앱이 아직 읽지 않은 바깥(CLI) 편집
        try CueDraftStore.save(Self.cue("a", at: 7), directory: places.cue)
        let before = try Data(contentsOf: places.cue.appending(path: "a.json"))
        let stamps = DraftStampStore.folder(home: folder.url)
        try FileManager.default.moveItem(at: stamps, to: folder.url.appending(path: "옮긴-도장"))
        try Data("막음".utf8).write(to: stamps)
        #expect(throws: (any Error).self) { try StampedDrafts.removeCue(trackUUID: "a", directory: places.cue) }
        #expect(try Data(contentsOf: places.cue.appending(path: "a.json")) == before)
    }

    /// 재리뷰 S12: 같은 내용을 같은 출처로 다시 저장하면 파일도 도장도 그대로다(판이 그대로라 이미 쓴 판의 정리가 찾는다).
    /// 파일을 다시 쓰지 않으므로 초안 폴더에 쓸 수 없어도 실패하지 않는다
    @Test func 같은_내용을_같은_출처로_다시_저장하면_판이_그대로다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let draft = Self.cue("a", at: 1)
        try StampedDrafts.saveCue(draft, directory: places.cue, origin: .human)
        let first = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: places.cue.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: places.cue.path) }
        try StampedDrafts.saveCue(draft, directory: places.cue, origin: .human)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == first)
        // 다른 출처가 같은 내용을 저장하면 출처가 합쳐져 새 판이다(제안)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: places.cue.path)
        try StampedDrafts.saveCue(draft, directory: places.cue, origin: .cli)
        let merged = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(merged.revision > first.revision && merged.origins == [.human, .cli])
    }

    @Test func 도장_자리는_초안_폴더_밖_이름을_받지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        // 도장 자리를 이름으로 풀 때 도장 폴더 밖을 읽거나 쓰지 않는다(초안 파일 쪽 검사는 지금과 같다)
        try FileManager.default.createDirectory(at: DraftStampStore.folder(home: folder.url), withIntermediateDirectories: true)
        try Data("밖".utf8).write(to: DraftStampStore.folder(home: folder.url).appending(path: "밖.json"))
        for uuid in ["../밖", "a/b", "..", ".", ""] {
            #expect(DraftStampStore.stamp(DraftKey(.cue, uuid), home: folder.url) == nil)
        }
        // 이름을 쓸 수 없는 곡의 저장은 도장만 건너뛴다(초안 쓰기의 오류는 초안 저장소가 알린다)
        try? StampedDrafts.saveCue(Self.cue("a/b"), directory: places.cue, origin: .human)
        let stamps = (try? FileManager.default.subpathsOfDirectory(atPath: DraftStampStore.folder(home: folder.url).path)) ?? []
        #expect(stamps.allSatisfy { !$0.contains("..") && !$0.contains("a/b") })
    }

    @Test func 도장을_쓰는_동안_초안_잠금을_쥐고_쓰고_나면_푼다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        #expect(!Self.isLockHeld(home: folder.url))
        try DraftStampStore.withLock(home: folder.url) { #expect(Self.isLockHeld(home: folder.url)) }
        #expect(!Self.isLockHeld(home: folder.url))
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        #expect(!Self.isLockHeld(home: folder.url))
        // 같은 프로세스 안에서 따로 연 잠금끼리도 막는다: 쥔 동안 다른 스레드의 도장 쓰기는 끝나지 못하고, 풀면 끝난다
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? DraftStampStore.withLock(home: folder.url) {
                entered.signal()
                release.wait()
            }
        }
        entered.wait()
        DispatchQueue.global().async {
            try? StampedDrafts.saveCue(Self.cue("b"), directory: places.cue, origin: .human)
            finished.signal()
        }
        // 잠금이 쥐어진 사실만 확인한다(걸린 시간으로 판정하지 않는다). 풀면 저장이 끝난다
        #expect(Self.isLockHeld(home: folder.url))
        release.signal()
        finished.wait()
        #expect(DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url) != nil)
    }

    @Test func 여러_스레드가_저장해도_판이_겹치지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let uuids = (0..<40).map { "t\($0)" }
        DispatchQueue.concurrentPerform(iterations: uuids.count) { index in
            try? StampedDrafts.saveCue(Self.cue(uuids[index]), directory: places.cue, origin: index.isMultiple(of: 2) ? .human : .cli)
        }
        let revisions = uuids.compactMap { DraftStampStore.stamp(DraftKey(.cue, $0), home: folder.url)?.revision }
        #expect(revisions.count == uuids.count && Set(revisions).count == uuids.count)
    }

    // MARK: 판 지정 삭제

    @Test func 판과_해시가_같으면_지우고_판이_다르면_두고_해시만_다르면_제안으로_남긴다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a", at: 1), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(Self.cue("b", at: 1), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(Self.cue("c", at: 1), directory: places.cue, origin: .human)
        func written(_ uuid: String) throws -> WrittenDraft {
            let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, uuid), home: folder.url))
            return WrittenDraft(key: DraftKey(.cue, uuid), revision: stamp.revision, contentHash: stamp.contentHash)
        }
        let a = try written("a"), b = try written("b"), c = try written("c")
        // b는 쓰는 동안 새로 저장(판이 다름), c는 바깥에서 내용만 고침
        try StampedDrafts.saveCue(Self.cue("b", at: 2), directory: places.cue, origin: .human)
        let bBefore = DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url)
        try CueDraftStore.save(Self.cue("c", at: 9), directory: places.cue)
        let cOld = try #require(DraftStampStore.stamp(DraftKey(.cue, "c"), home: folder.url))

        let result = try StampedDrafts.removeWritten([a, b, c], home: folder.url)
        #expect(result == DraftRemovalResult(removed: [a], suggested: [c], kept: [b]))
        #expect(CueDraftStore.load(trackUUID: "a", directory: places.cue) == nil && DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == nil)
        #expect(DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url) == bBefore)
        // 제안으로 남긴 초안은 새 판과 모름 출처를 얻는다
        let suggested = try #require(DraftStampStore.stamp(DraftKey(.cue, "c"), home: folder.url))
        #expect(suggested.revision > cOld.revision && suggested.origins.contains(.unknown) && CueDraftStore.load(trackUUID: "c", directory: places.cue) != nil)
        // 같은 목록으로 정리를 다시 해도(다시 켠 뒤) 지우지 않는다
        #expect(try StampedDrafts.removeWritten([c], home: folder.url) == DraftRemovalResult(kept: [c]))
    }

    @Test func 읽지_못하는_초안은_지우지_않고_남긴다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision, contentHash: stamp.contentHash)
        try Data("깨짐".utf8).write(to: places.cue.appending(path: "a.json"))
        #expect(try StampedDrafts.removeWritten([written], home: folder.url) == DraftRemovalResult(kept: [written]))
        #expect(FileManager.default.fileExists(atPath: places.cue.appending(path: "a.json").path))
    }

    @Test func 게인은_곡마다_도장을_두고_쓴_곡만_지운다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveGain(-3, trackUUID: "x", url: places.gain, origin: .human)
        try StampedDrafts.saveGain(-5, trackUUID: "y", url: places.gain, origin: .human)
        let x = try #require(DraftStampStore.stamp(DraftKey(.gain, "x"), home: folder.url))
        let written = WrittenDraft(key: DraftKey(.gain, "x"), revision: x.revision, contentHash: x.contentHash)
        #expect(try StampedDrafts.removeWritten([written], home: folder.url) == DraftRemovalResult(removed: [written]))
        #expect(try GainDraftStore.read(url: places.gain) == ["y": -5])
        #expect(DraftStampStore.stamp(DraftKey(.gain, "x"), home: folder.url) == nil && DraftStampStore.stamp(DraftKey(.gain, "y"), home: folder.url) != nil)
        // nil은 지우기: 도장도 함께 지운다
        try StampedDrafts.saveGain(nil, trackUUID: "y", url: places.gain, origin: .human)
        #expect(DraftStampStore.stamp(DraftKey(.gain, "y"), home: folder.url) == nil)
    }

    @Test func 옛_형식_게인_초안은_그대로_읽고_도장이_없어_제안이다() throws {
        // 곡마다 dB 하나만 든 옛 파일(base 없음, R23): 격리하지 않고 읽되 출처를 모른다
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Data(#"{"old":-2.5}"#.utf8).write(to: places.gain)
        #expect(try GainDraftStore.read(url: places.gain) == ["old": -2.5])
        #expect(DraftStampStore.stamp(DraftKey(.gain, "old"), home: folder.url) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: DamagedDrafts.folderName).path))
        // 새 저장은 옛 곡을 그대로 두고 새 곡만 도장을 단다
        try StampedDrafts.saveGain(-4, trackUUID: "new", url: places.gain, origin: .human)
        #expect(try GainDraftStore.read(url: places.gain) == ["old": -2.5, "new": -4])
        #expect(DraftStampStore.stamp(DraftKey(.gain, "old"), home: folder.url) == nil)
        #expect(DraftStampStore.stamp(DraftKey(.gain, "new"), home: folder.url)?.isHumanOnly == true)
        // 옛 곡을 사람이 다시 저장하면 옛 내용의 출처를 모르니 모름이 섞인다
        try StampedDrafts.saveGain(-1, trackUUID: "old", url: places.gain, origin: .human)
        #expect(DraftStampStore.stamp(DraftKey(.gain, "old"), home: folder.url)?.origins == [.human, .unknown])
    }

    /// 게인 초안의 base(R23, #405): 초안을 만들 때 본 rekordbox 오토게인과 rekordbox 실행 경계를 옆 파일 `gain-draft-bases.json`에 둔다.
    /// 게인 파일 모양은 그대로라 옛 앱도 읽는다. base는 그 값의 판에 묶인다(값보다 뒤에, 초안 잠금 안에서 적는다). 값을 지우면 base도 지운다
    @Test func 게인_초안의_base는_값의_판에_묶이고_값을_지우면_함께_지운다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        func revision(_ uuid: String) -> DraftRevision? { DraftStampStore.stamp(DraftKey(.gain, uuid), home: folder.url)?.revision }
        try StampedDrafts.saveGain(-1, trackUUID: "a", url: places.gain, origin: .human)
        try GainDraftStore.saveBase(GainDraftBase(db: -3.5, run: "E1"), trackUUID: "a", url: places.gain)
        #expect(try GainDraftStore.read(url: places.gain) == ["a": -1])
        #expect(GainDraftStore.bases(url: places.gain)["a"] == GainDraftBase(db: -3.5, run: "E1", revision: revision("a")))
        // 지우면 base도 지운다
        try StampedDrafts.saveGain(nil, trackUUID: "a", url: places.gain, origin: .human)
        #expect(GainDraftStore.bases(url: places.gain).isEmpty)
        // 판 지정 삭제(쓴 뒤 정리)도 base를 함께 지운다
        try StampedDrafts.saveGain(-7, trackUUID: "c", url: places.gain, origin: .human)
        try GainDraftStore.saveBase(GainDraftBase(db: -2, run: "E1"), trackUUID: "c", url: places.gain)
        let c = try #require(DraftStampStore.stamp(DraftKey(.gain, "c"), home: folder.url))
        _ = try StampedDrafts.removeWritten([WrittenDraft(key: DraftKey(.gain, "c"), revision: c.revision, contentHash: c.contentHash)],
                                           home: folder.url)
        #expect(GainDraftStore.bases(url: places.gain)["c"] == nil)
    }

    /// 저장 큐는 값과 base를 한 차례에 쓴다: 값을 보관하지 못하면 base를 묶지 않고, 다시 보관하면 그때 묶는다(컨실 2라운드 L)
    @Test func 값_저장이_실패하면_base를_묶지_않고_다시_보관하면_묶는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var on = true
            var isOn: Bool { lock.withLock { on } }
            func set(_ value: Bool) { lock.withLock { on = value } }
        }
        let writer = DraftWriter(), failing = Flag()
        let write: @Sendable (Double?, String, URL) throws -> Void = { value, uuid, url in
            if failing.isOn { throw CocoaError(.fileWriteNoPermission) }
            try StampedDrafts.saveGain(value, trackUUID: uuid, url: url, origin: .human)
        }
        writer.save(gain: -1, base: GainDraftBase(db: -3, run: "E1"), trackUUID: "a", url: places.gain, write: write)
        writer.flush()
        #expect(GainDraftStore.bases(url: places.gain).isEmpty, "값을 보관하지 못했으면 base를 묶지 않는다")
        failing.set(false)
        writer.save(gain: -1, base: GainDraftBase(db: -3, run: "E1"), trackUUID: "a", url: places.gain, write: write)
        writer.flush()
        let revision = DraftStampStore.stamp(DraftKey(.gain, "a"), home: folder.url)?.revision
        #expect(GainDraftStore.bases(url: places.gain)["a"] == GainDraftBase(db: -3, run: "E1", revision: revision))
    }

    /// 값만 다시 저장하면(CLI 등) 판이 바뀌어 그 base는 이 값의 base가 아니다(컨실 S8: 예전 값에 새 base가 붙지 않는다)
    @Test func 값만_다시_저장하면_base는_새_값의_판에_묶이지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveGain(-1, trackUUID: "a", url: places.gain, origin: .human)
        try GainDraftStore.saveBase(GainDraftBase(db: -3, run: "E1"), trackUUID: "a", url: places.gain)
        try StampedDrafts.saveGain(-2, trackUUID: "a", url: places.gain, origin: .cli)
        let now = try #require(DraftStampStore.stamp(DraftKey(.gain, "a"), home: folder.url)?.revision)
        #expect(GainDraftStore.bases(url: places.gain)["a"]?.revision != now)
    }

    /// 그 곡 게인 초안과 base가 이미 있으면 base 값·실행 경계는 다시 적지 않고 새 값의 판에만 다시 묶는다(컨실 O6: 다시 고칠 때마다
    /// 지금 rekordbox 값으로 base를 바꾸면 그사이 rekordbox에서 바뀐 것을 쓰기가 못 막는다)
    @Test func 이미_base가_있으면_값과_경계는_그대로_두고_새_판에만_묶는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveGain(-1, trackUUID: "a", url: places.gain, origin: .human)
        try GainDraftStore.saveBase(GainDraftBase(db: -3, run: "E1"), trackUUID: "a", url: places.gain)
        try StampedDrafts.saveGain(-2, trackUUID: "a", url: places.gain, origin: .human)
        try GainDraftStore.saveBase(GainDraftBase(db: -5, run: "E2"), trackUUID: "a", url: places.gain)
        let now = DraftStampStore.stamp(DraftKey(.gain, "a"), home: folder.url)?.revision
        #expect(GainDraftStore.bases(url: places.gain)["a"] == GainDraftBase(db: -3, run: "E1", revision: now))
    }

    @Test func 옛_형식_게인_초안에는_base가_없다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try Data(#"{"old":-2.5}"#.utf8).write(to: places.gain)
        #expect(GainDraftStore.bases(url: places.gain).isEmpty)
        // 옆 파일이 손상돼도 base를 모를 뿐 게인 초안은 그대로 읽는다(자동으로 쓰지 않는다)
        try Data("깨짐".utf8).write(to: GainDraftStore.basesURL(for: places.gain))
        #expect(GainDraftStore.bases(url: places.gain).isEmpty)
        #expect(try GainDraftStore.read(url: places.gain) == ["old": -2.5])
    }

    @Test func 그림과_합치기_초안도_판_지정으로_지운다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let artwork = ArtworkDraftStore.edit(trackUUID: "w", base: ArtworkBase(imagePath: ""), image: Data("그림".utf8), imageName: "a.png")
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "1", trackUUID: "m", title: "가", duration: 60, offset: 0, cues: []),
                                        removing: [], base: "b")
        try StampedDrafts.saveArtwork(artwork, directory: places.artwork, origin: .human)
        try StampedDrafts.saveMerges([merge], url: places.merge, origin: .human)
        let keys = [DraftKey(.artwork, "w"), DraftKey(.merge, "m")]
        let written = try keys.map { key -> WrittenDraft in
            let stamp = try #require(DraftStampStore.stamp(key, home: folder.url))
            return WrittenDraft(key: key, revision: stamp.revision, contentHash: stamp.contentHash)
        }
        #expect(try StampedDrafts.removeWritten(written, home: folder.url) == DraftRemovalResult(removed: written))
        #expect(try ArtworkDraftStore.load(trackUUID: "w", directory: places.artwork) == nil && DuplicateMergeDraftStore.load(url: places.merge).isEmpty)
        #expect(keys.allSatisfy { DraftStampStore.stamp($0, home: folder.url) == nil })
        // 합치기 목록 저장은 내용이 같은 초안의 도장을 그대로 두고, 바뀌거나 새로 든 초안만 새 판을 받는다
        try StampedDrafts.saveMerges([merge], url: places.merge, origin: .human)
        let first = try #require(DraftStampStore.stamp(DraftKey(.merge, "m"), home: folder.url))
        try StampedDrafts.saveMerges([merge], url: places.merge, origin: .cli)
        #expect(DraftStampStore.stamp(DraftKey(.merge, "m"), home: folder.url) == first)
    }

    @Test func 이대로_둔다는_판이_같은_초안만_새_판과_모름으로_제안이_된다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        try StampedDrafts.saveCue(Self.cue("b"), directory: places.cue, origin: .human)
        let a = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        let b = try #require(DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url))
        let written = [WrittenDraft(key: DraftKey(.cue, "a"), revision: a.revision, contentHash: a.contentHash),
                       WrittenDraft(key: DraftKey(.cue, "b"), revision: DraftRevision(b.revision.value + 1_000), contentHash: b.contentHash)]
        let marked = try StampedDrafts.markSuggestions(written, playlistSteps: [], home: folder.url)
        let newA = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        #expect(marked == [a.revision: newA.revision] && newA.revision > a.revision && newA.origins == [.human, .unknown])
        #expect(DraftStampStore.stamp(DraftKey(.cue, "b"), home: folder.url) == b)
        // 새 판이라 같은 미정리 목록으로 정리를 다시 해도 지우지 않는다
        #expect(try StampedDrafts.removeWritten([written[0]], home: folder.url) == DraftRemovalResult(kept: [written[0]]))
    }

    // MARK: 재생 목록 단계

    static let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])

    static func playlist(_ edits: [PlaylistEdit]) throws -> PlaylistDraft {
        var draft = PlaylistDraft()
        for edit in edits { try draft.append(edit, rekordbox: rekordbox) }
        return draft
    }

    @Test func 재생_목록_단계는_저장마다_바뀐_단계만_새_판을_받는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let one = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])])
        try StampedDrafts.savePlaylist(one, url: places.playlist, origin: .human)
        let first = StampedDrafts.playlistStamps(home: folder.url)
        #expect(first.count == 1 && first[0].origins == [.human])
        #expect(try first[0].contentHash == DraftContentHash(step: one.steps[0], in: one))
        // CLI가 한 단계를 더하면 앞 단계는 도장을 그대로 두고 새 단계만 CLI 도장을 받는다
        // (CLI는 파일에서 읽은 초안에 이어 쌓는다: 앞 단계는 식별자를 가진다)
        var two = PlaylistDraftStore.load(url: places.playlist)
        try two.append(.rename(playlist: .id("B"), name: "새"), rekordbox: Self.rekordbox)
        try StampedDrafts.savePlaylist(two, url: places.playlist, origin: .cli)
        let second = StampedDrafts.playlistStamps(home: folder.url)
        #expect(second.count == 2 && second[0] == first[0] && second[1].origins == [.cli] && second[1].revision > first[0].revision)
        // 단계가 모두 빠지면 도장도 지운다
        try StampedDrafts.savePlaylist(PlaylistDraft(), url: places.playlist, origin: .human)
        #expect(StampedDrafts.playlistStamps(home: folder.url).isEmpty)
    }

    @Test func 도장_없는_옛_재생_목록_초안은_단계마다_모름_도장을_받는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let draft = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "새")])
        try PlaylistDraftStore.save(draft, url: places.playlist)
        let stamps = StampedDrafts.playlistStamps(home: folder.url)
        #expect(stamps.count == 2 && stamps.allSatisfy { $0.origins == [.unknown] } && Set(stamps.map(\.revision)).count == 2)
        for (stamp, step) in zip(stamps, draft.steps) { #expect(try stamp.contentHash == DraftContentHash(step: step, in: draft)) }
        // 다시 읽어도 같은 판이다(받은 도장은 사이드카에 남는다)
        #expect(StampedDrafts.playlistStamps(home: folder.url) == stamps)
    }

    /// 식별자를 모르는 쪽(옛 CLI)이 파일 전체를 다시 쓰고 단계 수까지 달라지면 도장을 해시로 다시 붙이지 않는다: 모든 단계가 새 식별자와 모름 도장을 받는다
    @Test func 식별자가_없고_수가_어긋난_파일은_해시로_잇지_않고_모두_모름으로_받는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let one = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])])
        try StampedDrafts.savePlaylist(one, url: places.playlist, origin: .human)
        let human = StampedDrafts.playlistStamps(home: folder.url)[0]
        // 식별자를 모르는 쪽이 단계를 더하며 파일을 다시 썼다(앞 단계와 내용이 같은 단계가 있다)
        let two = try Self.playlist([.rename(playlist: .id("B"), name: "새"), .addTracks(playlist: .id("A"), contentIDs: ["9"])])
        try PlaylistDraftStore.save(two, url: places.playlist)
        let stamps = StampedDrafts.playlistStamps(home: folder.url)
        #expect(stamps.count == 2 && stamps.allSatisfy { $0.origins == [.unknown] })
        #expect(!stamps.contains { $0.revision == human.revision })
        // 받은 식별자는 초안 파일에 적혀, 다시 읽어도 같은 판이다
        #expect(PlaylistDraftStore.load(url: places.playlist).stepIDs.allSatisfy { $0 != nil })
        #expect(StampedDrafts.playlistStamps(home: folder.url) == stamps)
    }

    /// S1(저장소): 단계마다 저장한 식별자가 판을 잇는다. 같은 내용의 단계가 둘이어도 정리 도중 멈춘 뒤 다른 단계의 판이 붙지 않는다
    @Test func 같은_내용의_단계도_식별자가_달라_멈춘_뒤에도_판이_섞이지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let add = PlaylistEdit.addTracks(playlist: .id("A"), contentIDs: ["9"])
        let draft = try Self.playlist([add, .rename(playlist: .id("B"), name: "중간"), add])
        try StampedDrafts.savePlaylist(draft, url: places.playlist, origin: .human)
        let saved = PlaylistDraftStore.load(url: places.playlist)
        let ids = saved.stepIDs.compactMap { $0 }
        #expect(ids.count == 3 && Set(ids).count == 3)
        let stamps = StampedDrafts.playlistStamps(home: folder.url)
        #expect(stamps[0].contentHash == stamps[2].contentHash && stamps[0].revision != stamps[2].revision)
        // 초안 파일에서 첫 단계를 빼고 도장 갱신 전에 멈춘다
        var remaining = saved
        remaining.removeSteps(at: [0])
        try PlaylistDraftStore.save(remaining, url: places.playlist)
        #expect(StampedDrafts.playlistStamps(home: folder.url).map(\.revision) == [stamps[1].revision, stamps[2].revision])
        // 같은 내용의 마지막 단계는 자기 판을 쓴다: 첫 단계의 판으로 정리해도 지워지지 않는다
        let result = try StampedDrafts.removeWrittenSteps([(stamps[0].revision, stamps[0].contentHash)], newPlaylistIDs: [:],
                                                          copyFolder: folder.url.appending(path: "b"), home: folder.url)
        #expect(result.removed.isEmpty && result.notFound == [stamps[0].revision])
        #expect(PlaylistDraftStore.load(url: places.playlist).steps.count == 2)
    }

    /// 원칙: 식별자 없는 저장은 지금 파일의 단계와 내용으로 맞춰 보지 않는다. 앱은 저장한 뒤 디스크에서 다시 읽어 식별자를 받아야 단계의 판이
    /// 저장마다 바뀌지 않는다
    @Test func 식별자_없는_저장은_새_단계로_받고_다시_읽은_초안은_판을_그대로_둔다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let add = PlaylistEdit.addTracks(playlist: .id("A"), contentIDs: ["9"])
        let remove = PlaylistEdit.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 1, contentID: "9")])
        var memory = try Self.playlist([add])
        try StampedDrafts.savePlaylist(memory, url: places.playlist, origin: .human)
        let first = StampedDrafts.playlistStamps(home: folder.url)
        // 식별자를 받지 않은 메모리를 다시 저장하면 같은 내용이어도 새 단계다(옛 판을 붙이지 않는다)
        try memory.append(remove, rekordbox: Self.rekordbox)
        try StampedDrafts.savePlaylist(memory, url: places.playlist, origin: .human)
        let blind = StampedDrafts.playlistStamps(home: folder.url)
        #expect(blind.count == 2 && !blind.map(\.revision).contains(first[0].revision))
        // 디스크에서 다시 읽어 식별자를 받은 초안을 이어 저장하면 판이 그대로다
        var reread = try StampedDrafts.identifiedPlaylist(home: folder.url)
        try reread.append(add, rekordbox: Self.rekordbox)
        try StampedDrafts.savePlaylist(reread, url: places.playlist, origin: .human)
        let third = StampedDrafts.playlistStamps(home: folder.url)
        #expect(third.count == 3 && third[0] == blind[0] && third[1] == blind[1] && Set(third.map(\.revision)).count == 3)
    }

    /// 읽을 때 식별자를 채운다: 식별자 없는 옛 파일을 앱이 받으면 단계가 식별자와 모름 도장을 가진다(저장이 새 단계로 보지 않는다)
    @Test func 식별자_없는_옛_파일을_읽으면_식별자를_채워_파일에_적는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try PlaylistDraftStore.save(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]), url: places.playlist)
        #expect(PlaylistDraftStore.load(url: places.playlist).stepIDs == [nil])
        let identified = try StampedDrafts.identifiedPlaylist(home: folder.url)
        #expect(identified.stepIDs.allSatisfy { $0 != nil } && PlaylistDraftStore.load(url: places.playlist).stepIDs == identified.stepIDs)
        #expect(StampedDrafts.playlistStamps(home: folder.url).map(\.origins) == [[.unknown]])
        // 식별자가 이미 있으면 파일을 다시 쓰지 않는다
        let stamp = try FileManager.default.attributesOfItem(atPath: places.playlist.path)[.modificationDate] as? Date
        #expect(try StampedDrafts.identifiedPlaylist(home: folder.url).stepIDs == identified.stepIDs)
        #expect(try FileManager.default.attributesOfItem(atPath: places.playlist.path)[.modificationDate] as? Date == stamp)
        // 읽지 못하는 파일은 던진다(빈 초안으로 받지 않는다)
        try Data("깨짐".utf8).write(to: places.playlist)
        #expect(throws: (any Error).self) { try StampedDrafts.identifiedPlaylist(home: folder.url) }
    }

    /// S6(저장소): 원본을 견주어 저장한다. 그 사이 정리가 쓴 단계를 뺐으면 저장하지 않아 쓴 단계가 되살아나지 않는다
    @Test func 원본이_달라졌으면_저장하지_않고_쓴_단계를_되살리지_않는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.savePlaylist(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])]), url: places.playlist, origin: .human)
        let base = PlaylistDraftStore.load(url: places.playlist)
        let stamp = StampedDrafts.playlistStamps(home: folder.url)[0]
        // CLI가 base로 계획하는 사이 정리가 쓴 단계를 뺐다
        _ = try StampedDrafts.removeWrittenSteps([(stamp.revision, stamp.contentHash)], newPlaylistIDs: [:],
                                                 copyFolder: folder.url.appending(path: "b"), home: folder.url)
        let planned = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "x")])
        #expect(try StampedDrafts.savePlaylist(planned, url: places.playlist, origin: .cli, expecting: base) == false)
        #expect(PlaylistDraftStore.load(url: places.playlist).isEmpty && StampedDrafts.playlistStamps(home: folder.url).isEmpty)
        // 원본이 그대로면 저장한다
        #expect(try StampedDrafts.savePlaylist(planned, url: places.playlist, origin: .cli, expecting: PlaylistDraft()) == true)
        #expect(PlaylistDraftStore.load(url: places.playlist).steps.count == 2)
    }

    @Test func 재생_목록_쓴_단계_정리는_판으로_찾아_빼고_해시가_다르면_사본을_먼저_남긴다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        let backups = folder.url.appending(path: "backups")
        let copyFolder = backups.appending(path: "2026-11-24_120000", directoryHint: .isDirectory)
        let edits: [PlaylistEdit] = [.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "x")]
        try StampedDrafts.savePlaylist(try Self.playlist(edits), url: places.playlist, origin: .human)
        let stamps = StampedDrafts.playlistStamps(home: folder.url)
        let written = stamps.map { (revision: $0.revision, contentHash: $0.contentHash) }
        // 둘째 단계만 바깥에서 고쳤다(식별자를 아는 편집기라 식별자는 그대로다)
        var outside = try Self.playlist([edits[0], .rename(playlist: .id("B"), name: "y")])
        outside.setStepIDs(PlaylistDraftStore.load(url: places.playlist).stepIDs)
        try PlaylistDraftStore.save(outside, url: places.playlist)
        let stray = DraftRevision(stamps.map(\.revision.value).max()! + 50)
        let result = try StampedDrafts.removeWrittenSteps(written + [(stray, stamps[0].contentHash)], newPlaylistIDs: [:],
                                                          copyFolder: copyFolder, home: folder.url)
        #expect(result.removed == Set(stamps.map(\.revision)) && result.copyFailed.isEmpty && result.notFound == [stray])
        let copyURL = try #require(result.copied[stamps[1].revision])
        #expect(copyURL == PlaylistStepCopy.url(folder: copyFolder, revision: stamps[1].revision))
        let copy = try JSONDecoder().decode(PlaylistStepCopy.self, from: Data(contentsOf: copyURL))
        #expect(copy.playlistID == "B" && copy.writtenHash == stamps[1].contentHash && copy.currentHash != copy.writtenHash)
        #expect(PlaylistDraftStore.load(url: places.playlist).isEmpty && StampedDrafts.playlistStamps(home: folder.url).isEmpty)
    }

    /// S5: 잠금 파일을 열거나 잡지 못하면 저장·삭제를 하지 않고 오류를 돌려준다(잠금 없이 쓰면 판 번호가 겹치고 정리가 섞인다)
    @Test func 잠금을_잡지_못하면_저장과_삭제를_하지_않고_오류를_돌려준다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        let stamp = try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url))
        let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision, contentHash: stamp.contentHash)
        // 잠금 경로를 폴더로 막는다
        try FileManager.default.removeItem(at: DraftStampStore.lockURL(home: folder.url))
        try FileManager.default.createDirectory(at: DraftStampStore.lockURL(home: folder.url), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try StampedDrafts.saveCue(Self.cue("b"), directory: places.cue, origin: .human) }
        #expect(throws: (any Error).self) { try StampedDrafts.saveGrid(Self.grid("b"), directory: places.grid, origin: .human) }
        #expect(throws: (any Error).self) { try StampedDrafts.saveTag(Self.tag("b"), directory: places.tags, origin: .human) }
        #expect(throws: (any Error).self) { try StampedDrafts.saveGain(-3, trackUUID: "b", url: places.gain, origin: .human) }
        #expect(throws: (any Error).self) { try StampedDrafts.removeCue(trackUUID: "a", directory: places.cue) }
        #expect(throws: (any Error).self) { try StampedDrafts.removeWritten([written], home: folder.url) }
        #expect(throws: (any Error).self) { try StampedDrafts.markSuggestions([written], playlistSteps: [], home: folder.url) }
        let playlist = try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"])])
        #expect(throws: (any Error).self) { try StampedDrafts.savePlaylist(playlist, url: places.playlist, origin: .human) }
        // 저장 0, 삭제 0
        #expect(CueDraftStore.load(trackUUID: "b", directory: places.cue) == nil && GridDraftStore.load(trackUUID: "b", directory: places.grid) == nil)
        #expect(TagDraftStore.load(trackUUID: "b", directory: places.tags) == nil && !FileManager.default.fileExists(atPath: places.gain.path))
        #expect(CueDraftStore.load(trackUUID: "a", directory: places.cue) != nil && DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url) == stamp)
        #expect(!FileManager.default.fileExists(atPath: places.playlist.path))
        // 읽는 쪽은 잠금 없이 읽는다
        #expect(StampedDrafts.playlistStamps(home: folder.url).isEmpty)
    }

    /// S7: 판 번호 파일을 잃었을 때 최고 판을 세는 곳이 재생 목록 단계 도장(`[PlaylistStampEntry]`)도 읽는다
    @Test func 판_번호_파일을_잃어도_재생_목록_단계의_판_뒤로_잇는다() throws {
        let folder = try TemporaryFolder(), places = DraftLocations(home: folder.url)
        try StampedDrafts.savePlaylist(try Self.playlist([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("B"), name: "x")]),
                                       url: places.playlist, origin: .human)
        let highest = try #require(StampedDrafts.playlistStamps(home: folder.url).map(\.revision).max())
        try FileManager.default.removeItem(at: DraftStampStore.folder(home: folder.url).appending(path: "revision"))
        try StampedDrafts.saveCue(Self.cue("a"), directory: places.cue, origin: .human)
        #expect(try #require(DraftStampStore.stamp(DraftKey(.cue, "a"), home: folder.url)).revision > highest)
    }
}
