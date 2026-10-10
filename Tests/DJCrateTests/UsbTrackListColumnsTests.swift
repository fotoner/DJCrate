@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import ImageIO
import Synchronization
import Testing

/// USB 목록의 곡 줄을 컬렉션 줄과 같은 칸·표현으로 채운다(#256). USB에 있는 값은 마운트한 볼륨에서 읽기 전용으로 읽는다
@MainActor
@Suite("USB 곡 목록 칸")
struct UsbTrackListColumnsTests {
    static let mount = "/Volumes/DJCSYNTH"
    static let artwork = "/PIONEER/Artwork/00001/b7.jpg"
    static let analysis = "/PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT"

    /// 아트워크·분석 파일·평점·곡 색·태그가 있는 USB 곡 하나와 그림·분석 파일이 없는 곡 하나
    static func library() -> UsbLibrary {
        var full = UsbTestData.track(1)
        full.imageID = 7
        full.analysisDataPath = analysis
        full.rating = 4
        full.colorID = 6
        full.albumID = 3
        full.genreID = 4
        full.composerID = 1
        full.releaseYear = 2024
        full.trackNo = 5
        full.comment = "합성 코멘트"
        full.dateAdded = "2026-10-01"
        full.djPlayCount = 12
        full.fileType = 1
        let bare = UsbTestData.track(2)
        var library = UsbTestData.library(tracks: [full, bare])
        library.images = [UsbImage(id: 7, oneLibraryPath: artwork, pdbPath: "/PIONEER/Artwork/00001/a7.jpg")]
        library.albums = [UsbAlbum(id: 3, name: "합성 앨범", artistID: 1)]
        library.genres = [UsbNamedRow(id: 4, name: "합성 장르")]
        return library
    }

    static func rows(revision: Int = 0) -> [TrackRow] {
        UsbLibraryRows.collection(library: library(), volumeKey: "synthetic", mountPoint: mount, badges: [:], revision: revision)
    }

    /// 비교할 로컬 곡(로컬 share 기준 그림 경로·평점·곡 색)
    static func localRow(imagePath: String? = nil, rating: Int = 0, colorID: String? = nil) -> TrackRow {
        TrackRow(track: Track(id: "1", uuid: "uuid-1", title: "로컬 곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/x/1.mp3", comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: imagePath, isDeleted: false, rating: rating, colorID: colorID),
                 cues: [], playCount: 0)
    }

    static func table(store: LibraryStore, columns: [String], rows: [TrackRow]) -> (TrackListCoordinator, NSTableView) {
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        for id in columns { table.addTableColumn(NSTableColumn(identifier: .init(id))) }
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        return (coordinator, table)
    }

    // MARK: - 줄

    @Test("USB 줄은 볼륨 뿌리와 볼륨 안 아트워크·분석 파일 경로를 들고 로컬 share 기준 경로는 비운다")
    func rowCarriesVolumeFiles() throws {
        let rows = Self.rows(revision: 3)
        let row = try #require(rows.first)
        // 덱·반영·미리 데우기처럼 로컬 share로 찾는 곳이 로컬의 다른 파일을 읽지 않게 한다
        #expect(row.track.imagePath == nil && row.track.analysisDataPath == nil)
        let files = try #require(row.usbFiles)
        #expect(files.root == URL(filePath: Self.mount))
        #expect(files.artwork == "PIONEER/Artwork/00001/b7.jpg")
        #expect(files.analysis == "PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT")
        #expect(files.revision == 3)
        let bare = try #require(rows.last?.usbFiles)
        #expect(bare.artwork == nil && bare.analysis == nil)

        // Device Library에만 그림이 있으면 그 그림, 재생 목록 줄도 같다
        var library = Self.library()
        library.images = [UsbImage(id: 7, pdbPath: "/PIONEER/Artwork/00001/a7.jpg")]
        let playlist = UsbLibraryRows.playlist(10, library: library, volumeKey: "synthetic", mountPoint: Self.mount, badges: [:])
        #expect(playlist.first { $0.track.title == "시험 곡 1" }?.usbFiles?.artwork == "PIONEER/Artwork/00001/a7.jpg")
    }

    @Test("USB DB의 경로가 아트워크·분석 폴더 밖을 가리키면 그 파일을 읽지 않는다")
    func unsafeVolumePathsAreDropped() throws {
        var library = Self.library()
        library.images = [UsbImage(id: 7, oneLibraryPath: "/PIONEER/Artwork/../CDP/b7.jpg")]
        library.tracks[0].analysisDataPath = "/PIONEER/USBANLZ/../extracted/ANLZ0000.DAT"
        let row = try #require(UsbLibraryRows.collection(library: library, volumeKey: "synthetic", mountPoint: Self.mount, badges: [:]).first)
        #expect(row.usbFiles?.artwork == nil && row.usbFiles?.analysis == nil)
    }

    @Test("USB 볼륨을 다시 읽으면 줄의 판이 오른다(같은 자리 그림을 덮어써도 썸네일을 새로 읽게)")
    func rereadBumpsRevision() async throws {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: Self.library())
        let usb = UsbTestData.store(host)
        await usb.refresh()
        let first = try #require(usb.rows(for: .collection(volumeKey: image.usbKey)).first?.usbFiles)
        #expect(first.root == URL(filePath: image.mountPoint))
        await usb.refresh()
        let second = try #require(usb.rows(for: .collection(volumeKey: image.usbKey)).first?.usbFiles)
        #expect(second.revision > first.revision)
    }

    /// 정렬·목록 전환마다 곡마다 경로를 가르고 코멘트를 분류하면 큰 USB에서 메인이 걸린다. 같은 대상·판이면 만든 줄을 다시 쓴다
    @Test("같은 대상을 다시 그리면 만든 줄을 다시 쓰고, 다시 읽거나 프리셋이 바뀌면 새로 만든다")
    func rowsAreReusedUntilInputsChange() async throws {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: Self.library())
        let usb = UsbTestData.store(host)
        await usb.refresh()
        let target = UsbSidebarTarget.collection(volumeKey: image.usbKey)
        func storage(_ rows: [TrackRow]) -> UnsafeRawPointer? { rows.withUnsafeBufferPointer { $0.baseAddress.map(UnsafeRawPointer.init) } }
        let first = usb.rows(for: target)
        #expect(storage(usb.rows(for: target)) == storage(first))
        let classified = usb.rows(for: target, commentPreset: .anisong)
        #expect(storage(classified) != storage(first) && !(classified.first?.commentClassName.isEmpty ?? true))
        #expect(usb.rows(for: target).first?.commentClassName == "")
        await usb.refresh()
        let reread = usb.rows(for: target)
        #expect(storage(reread) != storage(first) && reread.first?.usbFiles?.revision != first.first?.usbFiles?.revision)
    }

    // MARK: - 칸

    @Test("USB 줄의 앨범아트 칸은 볼륨 뿌리에서 그림을 읽고 로컬 share를 보지 않는다")
    func thumbnailReadsFromVolume() async throws {
        let usbCalls = Mutex<[(root: URL, path: String, pixels: Int)]>([])
        let localCalls = Mutex<[(path: String?, root: URL?)]>([])
        let jpeg = ImageFixture.image(width: 8, height: 8)
        let store = LibraryStore.test(saveTagDrafts: { _ in }, ports: { ports in
            // 볼륨 안 그림은 링크를 거르는 포트로만 읽는다. 느린 USB를 읽어도 협력 풀을 막지 않는다
            ports.artwork.volumeThumbnail = { root, path, pixels in
                expectBlockingOffPool()
                usbCalls.withLock { $0.append((root, path, pixels)) }
                return CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            ports.artwork.thumbnail = { _, _, _ in
                Issue.record("목록 칸은 share 기준 큰 그림을 읽지 않는다")
                return nil
            }
            ports.artwork.listThumbnail = { path, root in
                expectBlockingOffPool()
                localCalls.withLock { $0.append((path, root)) }
                return nil
            }
        })
        let rows = Self.rows() + [Self.localRow(imagePath: "/PIONEER/Artwork/1/artwork.jpg")]
        let (coordinator, table) = Self.table(store: store, columns: ["thumb"], rows: rows)
        let column = try #require(table.tableColumns.first)
        let cells = rows.indices.map { coordinator.tableView(table, viewFor: column, row: $0) }
        #expect(cells.allSatisfy { $0 is ThumbnailCell })
        #expect(await waitForState { !usbCalls.withLock(\.isEmpty) && !localCalls.withLock(\.isEmpty) })
        let usb = usbCalls.withLock { $0 }
        #expect(usb.count == 1)
        #expect(usb.first?.path == "PIONEER/Artwork/00001/b7.jpg" && usb.first?.root == URL(filePath: Self.mount))
        #expect(usb.first?.pixels == 64)
        // 로컬 곡만 로컬 share의 작은 그림을 읽는다
        #expect(localCalls.withLock { $0.map(\.path) } == ["/PIONEER/Artwork/1/artwork.jpg"])
        #expect(localCalls.withLock { $0.map(\.root) } == [store.shareRoot])

        // 그림이 없는 USB 곡은 아무 파일도 읽지 않는다
        let bare = try #require(Self.rows().last?.usbFiles)
        #expect(await store.thumbnails.usbImage(bare, key: "usb:synthetic:2") == nil)
        #expect(usbCalls.withLock(\.count) == 1 && localCalls.withLock(\.count) == 1)
    }

    @Test("USB 줄의 미리 보기 칸은 볼륨 안 분석 파일을 읽고 음원은 분석하지 않는다")
    func previewReadsVolumeAnalysis() throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let (coordinator, table) = Self.table(store: store, columns: ["preview"], rows: Self.rows())
        let column = try #require(table.tableColumns.first)
        let cell = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? PreviewWaveformCell)
        cell.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        cell.layout()
        let request = try #require(cell.request)
        // 볼륨 뿌리와 볼륨 안 경로만 넘긴다. 열 자리는 캐시가 링크를 거른 뒤 정한다
        #expect(request.url == nil)
        #expect(request.volume == PreviewWaveformRequest.VolumeFile(root: URL(filePath: Self.mount), path: "PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT"))
        #expect(request.audioURL == nil)
        #expect(request.trackKey == "usb:synthetic:1")

        let bare = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? PreviewWaveformCell)
        bare.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        bare.layout()
        #expect(bare.request?.url == nil && bare.request?.volume == nil && bare.request?.audioURL == nil)
    }

    @Test("미리 보기 캐시는 USB 분석 파일을 링크 확인을 거친 자리로만 읽고, 확인은 협력 풀 밖에서 한다")
    func previewCacheReadsOnlyCheckedVolumeFile() async throws {
        let checked = Mutex<[(root: URL, path: String)]>([])
        let read = Mutex<[URL?]>([])
        let approved = Mutex<URL?>(nil)
        let previews = PreviewWaveforms(warm: { _, _ in }, revision: { _, _ in 0 },
                                        waveform: { _, file in read.withLock { $0.append(file) }; return nil },
                                        audioColumns: { _, _ in nil }, clear: {},
                                        volumeFile: { root, path in
                                            expectBlockingOffPool()
                                            checked.withLock { $0.append((root, path)) }
                                            return approved.withLock { $0 }
                                        })
        let cache = PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: previews))
        var request = PreviewWaveformRequest(url: nil, revision: "링크", appearance: NSAppearance.Name.aqua.rawValue)
        request.trackKey = "usb:synthetic:1"
        request.volume = .init(root: URL(filePath: Self.mount), path: "PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT")
        // 링크를 거치면(확인이 nil) 아무 파일도 읽지 않는다
        _ = await cache.image(for: request)
        #expect(checked.withLock { $0.map(\.path) } == ["PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT"])
        #expect(checked.withLock { $0.map(\.root) } == [URL(filePath: Self.mount)])
        #expect(read.withLock { $0 } == [nil])

        let file = URL(filePath: Self.mount + Self.analysis)
        approved.withLock { $0 = file }
        request.revision = "확인"
        _ = await cache.image(for: request)
        #expect(read.withLock { $0 } == [nil, file])
    }

    @Test("USB 줄의 평점·곡 색은 같은 값의 컬렉션 줄과 똑같이 보인다")
    func ratingAndColorLookLikeCollection() throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let usb = try #require(Self.rows().first)
        let local = Self.localRow(rating: 4, colorID: "6")
        let (coordinator, table) = Self.table(store: store, columns: ["rating", "color"], rows: [usb, local])
        for column in table.tableColumns {
            let usbCell = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? TrackTextCell)
            let localCell = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? TrackTextCell)
            #expect(!usbCell.text.isEmpty)
            #expect(usbCell.text == localCell.text, "\(column.identifier.rawValue)")
            #expect(usbCell.label.textColor == localCell.label.textColor)
            #expect(usbCell.swatchShown == localCell.swatchShown)
        }
        let color = try #require(coordinator.tableView(table, viewFor: table.tableColumns[1], row: 0) as? TrackTextCell)
        #expect(color.text == "Aqua" && color.swatchShown)
        let rating = try #require(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) as? TrackTextCell)
        #expect(rating.text == TrackRating.stars("4"))
    }

    @Test("USB 줄의 분류 칸은 로컬 줄과 같은 코멘트 규칙(지금 프리셋)으로 가른다")
    func commentClassUsesCurrentPreset() async throws {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usb-class"), persist: false), saveTagDrafts: { _ in })
        store.commentPreset = .anisong
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: Self.library())
        let usb = UsbTestData.store(host)
        store.usb = usb
        await usb.refresh()
        store.sidebar = .usb(.collection(volumeKey: image.usbKey))
        let row = try #require(store.displayRows.first)
        let local = TrackRow(track: row.track, cues: [], playCount: 0, commentRule: CommentPreset.anisong.rule)
        #expect(!local.commentClassName.isEmpty)
        #expect(row.commentClassName == local.commentClassName)
        store.commentPreset = .none
        #expect(store.displayRows.first?.commentClassName == "")
        store.commentPreset = .anisong
        #expect(store.displayRows.first?.commentClassName == local.commentClassName)
    }

    @Test("USB 줄은 USB에 있는 값으로 칸을 채우고 USB에 없는 초안·변속·큐 칸은 비운다")
    func usbValuesFillColumnsAndUnknownStayEmpty() throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let columns = ["album", "albumArtist", "composer", "year", "trackNumber", "genre", "length", "format", "imported", "plays",
                       "bpm", "key", "comment", "tempo", "hotCues", "memoryCues"]
        let (coordinator, table) = Self.table(store: store, columns: columns + ["edited"], rows: Self.rows())
        func text(_ id: String) -> String? {
            let column = table.tableColumns.first { $0.identifier.rawValue == id }
            return (coordinator.tableView(table, viewFor: column, row: 0) as? TrackTextCell)?.text
        }
        #expect(text("album") == "합성 앨범" && text("albumArtist") == "시험 아티스트" && text("composer") == "시험 아티스트")
        #expect(text("year") == "2024" && text("trackNumber") == "5" && text("genre") == "합성 장르")
        #expect(text("length") == "3:20" && text("format") == "MP3" && text("imported") == "2026-10-01" && text("plays") == "12")
        #expect(text("bpm") == "128" && text("key") == "8A" && text("comment") == "합성 코멘트")
        // 큐·그리드는 USB 목록을 읽을 때 읽지 않는다(없음·0으로 보이면 틀린 정보다)
        #expect(text("tempo") == "" && text("hotCues") == "" && text("memoryCues") == "")
        let edited = table.tableColumns.first { $0.identifier.rawValue == "edited" }
        #expect(coordinator.tableView(table, viewFor: edited, row: 0) is EditedMarkCell)
        #expect(coordinator.edited.isEmpty)
    }
}
