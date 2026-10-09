import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 그림 초안 저장소(#66): 초안(JSON)과 고른 그림의 사본(`.image`)을 곡마다 둔다. 원본 그림이 옮겨져도 초안이 남는다.
/// 읽지 못한 초안·사본이 없거나 바뀐 초안은 지우지 않고 사본과 함께 `damaged-drafts`로 옮긴다(#174와 같은 규칙).
@Suite("그림 초안 저장소", .serialized)
struct ArtworkDraftStoreTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-artwork-drafts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    let image = ImageFixture.image(width: 64, height: 64)
    let base = ArtworkBase(imagePath: "")

    @Test func 그림을_고른_초안은_사본과_함께_저장하고_다시_읽는다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        let edit = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: "표지.jpg")
        #expect(edit.draft.change == .set && edit.draft.imageName == "표지.jpg" && edit.draft.imageSHA256?.count == 64)
        try ArtworkDraftStore.save(edit, directory: directory)
        #expect(FileManager.default.fileExists(atPath: ArtworkDraftStore.imageURL(for: edit.draft, directory: directory).path))
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == edit)
        #expect(ArtworkDraftStore.uuids(directory: directory) == ["곡-1"])
        #expect(ArtworkDraftStore.all(directory: directory) == ["곡-1": edit.draft])
    }

    @Test func 지우기_초안으로_바꾸면_사본도_지우고_초안을_버리면_둘_다_지운다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        let set = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil)
        try ArtworkDraftStore.save(set, directory: directory)
        let delete = ArtworkEdit(draft: ArtworkDraft(trackUUID: "곡-1", change: .delete, base: ArtworkBase(imagePath: "/PIONEER/Artwork/x/artwork.jpg")),
                                 image: nil)
        try ArtworkDraftStore.save(delete, directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == delete)
        #expect(!FileManager.default.fileExists(atPath: ArtworkDraftStore.imageURL(for: set.draft, directory: directory).path))
        try ArtworkDraftStore.remove(trackUUID: "곡-1", directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == nil && ArtworkDraftStore.uuids(directory: directory).isEmpty)
        try ArtworkDraftStore.remove(trackUUID: "없는 곡", directory: directory)
    }

    @Test(arguments: ["깨진 JSON", "사본 없음", "사본이 다름", "다른 곡의 초안"])
    func 읽지_못한_초안은_사본과_함께_옮겨_보관한다(damage: String) throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        let edit = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil)
        try ArtworkDraftStore.save(edit, directory: directory)
        let json = directory.appending(path: "곡-1.json"), copy = ArtworkDraftStore.imageURL(for: edit.draft, directory: directory)
        switch damage {
        case "깨진 JSON": try Data("{\"깨진".utf8).write(to: json)
        case "사본 없음": try FileManager.default.removeItem(at: copy)
        case "사본이 다름": try Data("다른 그림".utf8).write(to: copy)
        default: try FileManager.default.moveItem(at: json, to: directory.appending(path: "곡-2.json"))
        }
        let uuid = damage == "다른 곡의 초안" ? "곡-2" : "곡-1"
        #expect(throws: DraftFileDamaged.self) { try ArtworkDraftStore.load(trackUUID: uuid, directory: directory) }
        #expect(ArtworkDraftStore.all(directory: directory).isEmpty, "목록에는 읽은 초안만")
        DamagedDrafts.preserveAll(home: home)
        let moved = DamagedDrafts.take(home: home)
        #expect(moved.map(\.trackUUID) == [uuid] && moved.first?.name == "artwork-drafts/\(uuid).json")
        #expect(ArtworkDraftStore.uuids(directory: directory).isEmpty)
        let kept = FileManager.default.enumerator(at: home.appending(path: DamagedDrafts.folderName), includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        #expect(kept.contains { $0.hasPrefix(uuid) && $0.hasSuffix(".json") })
        if damage == "다른 곡의 초안" {
            // 곡-1의 사본은 초안이 없는 사본이라 손상이 아니다(곡-1을 저장하거나 버릴 때 지운다).
            #expect(FileManager.default.fileExists(atPath: copy.path))
        } else {
            #expect(!FileManager.default.fileExists(atPath: copy.path), "사본도 함께 옮긴다")
            if damage != "사본 없음" { #expect(kept.contains { $0.hasSuffix(".image") }) }
        }
    }

    @Test func 손상된_초안_위에_저장하면_옮겨_보관한_뒤_새_초안을_쓴다() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"깨진".utf8).write(to: directory.appending(path: "곡-1.json"))
        let edit = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: nil)
        try ArtworkDraftStore.save(edit, directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == edit)
        #expect(DamagedDrafts.take(home: home).map(\.name) == ["artwork-drafts/곡-1.json"])
    }

    // MARK: 저장 중간 상태 (#66 리뷰 6)

    @Test func 저장_중간에_보아도_초안과_사본은_늘_짝이_맞는다() throws {
        // 사본은 내용 해시를 이름에 넣어 새로 쓰고, 초안을 바꾼 뒤에 옛 사본을 지운다. 그 사이 손상 검사(뒤에서 도는 읽기)가 보아도
        // 옛 초안은 옛 사본을 찾으니 옮기지 않는다.
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "artwork-drafts")
        let first = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: image, imageName: "첫째.jpg")
        try ArtworkDraftStore.save(first, directory: directory)
        let other = ImageFixture.image(width: 32, height: 32, blue: 10)
        let second = ArtworkDraftStore.edit(trackUUID: "곡-1", base: base, image: other, imageName: "둘째.jpg")
        // 둘째 사본만 쓴 순간(초안은 아직 첫째)
        try other.write(to: ArtworkDraftStore.imageURL(for: second.draft, directory: directory))
        DamagedDrafts.preserveAll(home: home)
        #expect(try DamagedDrafts.take(home: home).isEmpty && ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == first)
        // 초안이 없는 새 곡의 사본만 있는 순간도 손상이 아니다
        let lone = ArtworkDraftStore.edit(trackUUID: "곡-2", base: base, image: other, imageName: nil)
        try other.write(to: ArtworkDraftStore.imageURL(for: lone.draft, directory: directory))
        DamagedDrafts.preserveAll(home: home)
        #expect(DamagedDrafts.take(home: home).isEmpty)
        #expect(FileManager.default.fileExists(atPath: ArtworkDraftStore.imageURL(for: lone.draft, directory: directory).path))
        // 저장을 마치면 옛 사본은 지운다
        try ArtworkDraftStore.save(second, directory: directory)
        #expect(try ArtworkDraftStore.load(trackUUID: "곡-1", directory: directory) == second)
        #expect(!FileManager.default.fileExists(atPath: ArtworkDraftStore.imageURL(for: first.draft, directory: directory).path))
        // 버리면 그 곡의 사본을 모두 지운다(끝나지 않은 저장이 남긴 것까지)
        try ArtworkDraftStore.remove(trackUUID: "곡-2", directory: directory)
        #expect(!FileManager.default.fileExists(atPath: ArtworkDraftStore.imageURL(for: lone.draft, directory: directory).path))
    }
}
