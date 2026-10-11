@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 인스펙터 그림 칸 화면 모델(#66·#250): 그림 넣기·바꾸기·지우기 초안, 안내, 보일 그림.
/// 그림 확인·사본·초안 저장은 가짜 포트(메모리 초안, 가짜 그림 포트)다. rekordbox 쓰기 전 과정은 `ArtworkReflectionTests`가 본다.
@Suite("인스펙터 그림 칸 화면 모델")
@MainActor
struct ArtworkInspectorModelTests {
    static func row(_ id: String, imagePath: String? = nil, staged: Bool = false, streaming: Bool = false, usb: Bool = false) -> TrackRow {
        let trackID = usb ? TrackRow.usbIDPrefix + id : staged ? "djc-\(id)" : id
        return TrackRow(track: Track(id: trackID, uuid: "uuid-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil,
                                     genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 30,
                                     folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: "", importedOn: nil,
                                     analysisDataPath: nil, imagePath: imagePath, isDeleted: false, dataStatus: staged ? nil : 0),
                        cues: [], playCount: 0)
    }

    static let refused = "JPEG·PNG 그림만 넣을 수 있으니 다른 그림을 고르세요"

    let memory = MemoryDrafts()
    let failSaves = TestSwitch()
    let image = ImageFixture.image(width: 8, height: 8)
    let store: LibraryStore

    init() {
        let memory = memory, failSaves = failSaves, refused = Self.refused
        store = LibraryStore.test(saveTagDrafts: { _ in }, ports: { ports in
            var drafts = memory.store
            drafts.saveArtwork = { edit in
                if failSaves.isOn { throw CocoaError(.fileWriteNoPermission) }
                try memory.store.saveArtwork(edit)
            }
            ports.drafts = drafts
            ports.artwork = ArtworkFiles(unsupportedReason: { $0.count < 4 ? refused : nil },
                                         edit: { uuid, base, image, name in
                                             ArtworkEdit(draft: ArtworkDraft(trackUUID: uuid, change: .set, base: base, imageName: name,
                                                                             imageSHA256: "해시-\(image.count)"), image: image)
                                         },
                                         thumbnail: { _, _, _ in nil }, listThumbnail: { _, _ in nil },
                                         volumeThumbnail: { _, _, _ in nil })
            ports.files.read = { url in
                guard url.lastPathComponent == "표지.jpg" else { throw CocoaError(.fileReadNoSuchFile) }
                return ImageFixture.image(width: 8, height: 8)
            }
        })
    }

    @Test func 고른_그림으로_초안을_만들고_고칠_수_없는_곡은_뺀다() {
        let model = ArtworkInspectorModel(store: store)
        let local = Self.row("a"), staged = Self.row("b", staged: true), streaming = Self.row("s", streaming: true), usb = Self.row("u", usb: true)
        #expect(model.editable([local, staged, streaming, usb]) == [local])
        model.setArtwork(image, name: "표지.jpg", rows: [local, staged, streaming, usb])
        #expect(Set(store.artworkDrafts.keys) == [local.track.uuid] && store.editedUUIDs == [local.track.uuid])
        #expect(model.draft(for: local)?.kind == .add && model.draft(for: local)?.imageName == "표지.jpg")
        #expect(model.drafts([local, staged]).count == 1)
        #expect(model.draftImage(trackUUID: local.track.uuid) == image && model.message == nil)
    }

    @Test func 확인하지_않은_그림과_읽지_못한_파일은_알리고_초안을_만들지_않는다() {
        let model = ArtworkInspectorModel(store: store)
        let local = Self.row("a")
        model.setArtwork(Data([1, 2]), name: "작은.jpg", rows: [local])
        #expect(store.artworkDrafts.isEmpty && model.message?.text == Self.refused)
        model.setArtwork(fileAt: URL(fileURLWithPath: "/없는 폴더/없는 그림.jpg"), rows: [local])
        #expect(store.artworkDrafts.isEmpty && model.message?.text.contains("다시 고르세요") == true)
        // 다음 동작이 모두 되면 지난 안내를 지운다
        model.setArtwork(fileAt: URL(fileURLWithPath: "/그림/표지.jpg"), rows: [local])
        #expect(store.artworkDrafts[local.track.uuid] != nil && model.message == nil)
    }

    @Test func 지우기는_그림_있는_곡만_초안을_만들고_버리기는_초안을_지운다() {
        let model = ArtworkInspectorModel(store: store)
        let withArt = Self.row("a", imagePath: "/PIONEER/Artwork/00001/a.jpg"), without = Self.row("b")
        #expect(model.hasArtwork(withArt) && !model.hasArtwork(without))
        model.setArtwork(image, name: nil, rows: [without])
        model.deleteArtwork(rows: [withArt, without])
        #expect(store.artworkDrafts[withArt.track.uuid]?.kind == .delete)
        #expect(store.artworkDrafts[without.track.uuid] == nil, "그림이 없는 곡은 남은 넣기 초안만 버린다")
        model.discardDrafts(rows: [withArt, without])
        #expect(store.artworkDrafts.isEmpty && store.editedUUIDs.isEmpty && model.message == nil)
    }

    @Test func 저장_실패는_한_동작에_한_번_세어_안내로_남긴다() {
        let model = ArtworkInspectorModel(store: store)
        let rows = [Self.row("a"), Self.row("b")]
        failSaves.set(true)
        model.setArtwork(image, name: nil, rows: rows)
        #expect(store.artworkDrafts.isEmpty && model.message?.text.contains("2곡") == true)
        failSaves.set(false)
        model.setArtwork(image, name: nil, rows: rows)
        #expect(store.artworkDrafts.count == 2 && model.message == nil)
    }

    @Test func 쓰는_동안에는_초안을_만들지도_지우지도_않는다() {
        let model = ArtworkInspectorModel(store: store)
        let local = Self.row("a", imagePath: "/PIONEER/Artwork/00001/a.jpg")
        model.setArtwork(image, name: nil, rows: [local])
        store.isWritingRekordbox = true
        #expect(model.isLocked)
        model.deleteArtwork(rows: [local])
        model.discardDrafts(rows: [local])
        model.setArtwork(Data([1, 2]), name: nil, rows: [local])
        #expect(store.artworkDrafts[local.track.uuid]?.change == .set && model.message == nil)
    }

    @Test func 그림_칸은_초안_그림을_읽고_지우기_초안과_곡_없음은_빈_칸이다() async {
        let model = ArtworkInspectorModel(store: store)
        let local = Self.row("a", imagePath: "/PIONEER/Artwork/00001/a.jpg")
        let empty = model.imageKey(for: local)
        model.setArtwork(image, name: nil, rows: [local])
        let set = model.imageKey(for: local)
        #expect(set != empty, "초안이 생기면 다시 읽는다")
        await model.loadImage(local)
        #expect(model.image != nil)
        model.deleteArtwork(rows: [local])
        #expect(model.imageKey(for: local) != set)
        await model.loadImage(local)
        #expect(model.image == nil, "지우기 초안이면 빈 칸")
        model.setArtwork(image, name: nil, rows: [local])
        await model.loadImage(local)
        #expect(model.image != nil)
        await model.loadImage(nil)
        #expect(model.image == nil, "곡 여럿을 고르면 빈 칸")
        #expect(model.imageKey(for: nil).isEmpty)
    }

    @Test func 그림_칸이_사라지면_읽은_그림을_잊는다() async {
        // 옛 그림 칸은 나타날 때마다 새 읽기(@State)로 빈 칸에서 시작했다. 모델은 조립 지점에 남으므로 사라질 때 비운다.
        let model = ArtworkInspectorModel(store: store)
        let local = Self.row("a")
        model.setArtwork(image, name: nil, rows: [local])
        await model.loadImage(local)
        #expect(model.image != nil)
        model.forgetImage()
        #expect(model.image == nil)
    }
}
