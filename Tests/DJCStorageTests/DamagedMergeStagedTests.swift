import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #178: 합치기 초안(`merge-drafts.json`)과 추가 목록(`staged.json`)이 손상되면 지우거나 빈 값으로 덮지 않고
/// `damaged-drafts`에 옮겨 보관한 뒤 알린다(#174와 같은 방식).
@Suite("합치기 초안·추가 목록 손상 파일 저장소", .serialized)
struct DamagedMergeStagedTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-damaged-merge-staged-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let broken = Data("{\"깨진".utf8)

    func preserved(in home: URL) -> [URL] {
        let root = home.appending(path: DamagedDrafts.folderName)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    func merge(_ id: String = "a") -> DuplicateMergeDraft {
        .init(keeping: .init(contentID: id, trackUUID: id, title: "남길 곡", duration: 30, offset: 0, cues: []),
              removing: [.init(contentID: "\(id)-뺄", trackUUID: "\(id)-뺄", title: "뺄 곡", duration: 30, offset: 0, cues: [])], base: "base")
    }

    func track(_ name: String = "a") -> StagedTrack {
        StagedTrack(uuid: UUID().uuidString.lowercased(), path: "/fixtures/\(name).wav", title: "합성 곡 \(name)", duration: 30, addedOn: "2026-10-02")
    }

    // MARK: - 합치기 초안 저장소

    @Test func 손상된_합치기_초안은_저장_전에_옮겨_보관하고_새_초안을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try broken.write(to: url)
        try DuplicateMergeDraftStore.save([merge()], url: url)
        #expect(DuplicateMergeDraftStore.load(url: url) == [merge()])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["merge-drafts.json"])
    }

    @Test func 손상된_합치기_초안을_비우기로_지우지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try broken.write(to: url)
        try DuplicateMergeDraftStore.save([], url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        _ = DamagedDrafts.take(home: home)
    }

    @Test func 읽지_못하는_합치기_초안은_덮지_않는다() throws {
        let home = try home()
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: home)
        }
        try DuplicateMergeDraftStore.save([merge("기존")], url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try DuplicateMergeDraftStore.save([merge("기존"), merge("새")], url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(DuplicateMergeDraftStore.load(url: url) == [merge("기존")])
        #expect(preserved(in: home).isEmpty)
    }

    @Test func 정상_합치기_초안은_저장해도_옮기지_않는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: DuplicateMergeDraftStore.fileName)
        try DuplicateMergeDraftStore.save([merge("a")], url: url)
        try DuplicateMergeDraftStore.save([merge("a"), merge("b")], url: url)
        #expect(DuplicateMergeDraftStore.load(url: url).count == 2)
        #expect(preserved(in: home).isEmpty && DamagedDrafts.take(home: home).isEmpty)
    }

    // MARK: - 추가 목록 저장소

    @Test func 손상된_추가_목록은_저장_전에_옮겨_보관하고_새_목록을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: StagedTrackFile.fileName)
        try broken.write(to: url)
        try StagedTrackFile.save([track()], url: url)
        #expect(StagedTrackFile.load(url: url).map(\.path) == [track().path])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["staged.json"])
    }

    @Test func 읽지_못하는_추가_목록은_덮지_않는다() throws {
        let home = try home()
        let url = home.appending(path: StagedTrackFile.fileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: home)
        }
        try StagedTrackFile.save([track("기존")], url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try StagedTrackFile.save([track("기존"), track("새")], url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(StagedTrackFile.load(url: url).map(\.path) == [track("기존").path])
        #expect(preserved(in: home).isEmpty)
    }

    // MARK: - 데이터 폴더 훑기

    @Test func 데이터_폴더를_훑으면_손상된_두_파일을_옮기고_정상_파일은_둔다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try broken.write(to: home.appending(path: DuplicateMergeDraftStore.fileName))
        try broken.write(to: home.appending(path: StagedTrackFile.fileName))
        DamagedDrafts.preserveAll(home: home)
        #expect(Set(DamagedDrafts.take(home: home).map(\.name)) == ["merge-drafts.json", "staged.json"])
        #expect(preserved(in: home).count == 2 && preserved(in: home).allSatisfy { (try? Data(contentsOf: $0)) == broken })
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: StagedTrackFile.fileName).path))

        try DuplicateMergeDraftStore.save([merge()], url: home.appending(path: DuplicateMergeDraftStore.fileName))
        try StagedTrackFile.save([track()], url: home.appending(path: StagedTrackFile.fileName))
        DamagedDrafts.preserveAll(home: home)
        #expect(DamagedDrafts.take(home: home).isEmpty)
        #expect(DuplicateMergeDraftStore.load(url: home.appending(path: DuplicateMergeDraftStore.fileName)) == [merge()])
        #expect(StagedTrackFile.load(url: home.appending(path: StagedTrackFile.fileName)).count == 1)
    }
}
