@testable import DJCrate
import AppKit
import DJCDomain
import Foundation
import RekordboxFixtures
import Testing
import UniformTypeIdentifiers

@Suite("곡 목록 끌어내기와 문맥 메뉴")
@MainActor
struct TrackListControlsTests {
    private func row(_ id: String = "1", path: String) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: "합성 곡", artist: nil, album: nil,
                              albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil,
                              key: nil, bpm: 120, lengthSeconds: 1, folderPath: path, comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    private func list(_ rows: [TrackRow], selection: Set<String> = [], store: LibraryStore? = nil) -> (TrackListCoordinator, NSTableView) {
        _ = NSApplication.shared
        let store = store ?? LibraryStore.test(saveTagDrafts: { _ in })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: selection, sortOrder: [], snapshotURL: nil, previewRevision: 0)
        return (coordinator, table)
    }

    @Test(arguments: ["1", "djc-1"])
    func 파일_URL과_로컬_곡_ID를_함께_싣고_원본은_보존한다(id: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "합성 곡 #1.wav")
        let original = Data([0, 1, 2, 3])
        try original.write(to: file)
        let (coordinator, table) = list([row(id, path: file.path)])
        let item = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        #expect(item.string(forType: DeckDragType.pasteboard) == id)
        #expect(item.string(forType: PlaylistDragType.pasteboardTracks) == (id == "1" ? id : nil))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([item]))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls == [file])
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func 스트리밍_없는_파일_폴더는_외부_URL_없이_로컬_ID만_싣는다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["spotify:track:1", "", root.appending(path: "missing.wav").path, root.path]
        let rows = paths.enumerated().map { row(String($0.offset), path: $0.element) }
        let (coordinator, table) = list(rows)
        for index in rows.indices {
            let item = try #require(coordinator.tableView(table, pasteboardWriterForRow: index) as? NSPasteboardItem)
            #expect(item.string(forType: .fileURL) == nil)
            #expect(item.string(forType: DeckDragType.pasteboard) == String(index))
            #expect(item.string(forType: PlaylistDragType.pasteboardTracks) == String(index))
        }
        #expect(coordinator.tableView(table, pasteboardWriterForRow: -1) == nil)
        #expect(coordinator.tableView(table, pasteboardWriterForRow: rows.count) == nil)
    }

    @Test(arguments: 0..<8)
    func 초안과_선택_경계에서도_빈_반영_문장과_중복_구분선이_없다(state: Int) {
        let pending = state & 1 != 0
        let staged = state & 2 != 0
        let selected = state & 4 != 0
        let track = row(staged ? "djc-1" : "1", path: "/missing.wav")
        let (coordinator, table) = list([track], selection: selected ? [track.id] : [])
        if pending { coordinator.store.draftChanged(trackUUID: track.track.uuid, kind: .gain, exists: true) }
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        let actions = menu.items.compactMap(\.action).map(NSStringFromSelector)
        #expect(actions.contains("reflectSelected") == (pending && !staged && selected))
        #expect(actions.contains("exportReflectionXML") == (pending && !staged && selected))
        #expect(!menu.items.contains { $0.title == "rekordbox에 쓸 초안이 없습니다" })
        #expect(menu.items.first?.isSeparatorItem == false)
        #expect(menu.items.last?.isSeparatorItem == false)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
        withExtendedLifetime(table) {}
    }

    @Test func 보일_칸은_실제_섹션_머리글이다() throws {
        let (coordinator, table) = list([])
        let menu = coordinator.makeColumnMenu(table)
        coordinator.menuNeedsUpdate(menu)
        #expect(try #require(menu.items.first).isSectionHeader)
        withExtendedLifetime(table) {}
    }

    @Test(arguments: [false, true])
    func 재생_목록과_추가한_곡_메뉴를_함께_보여도_구분선이_겹치지_않는다(pending: Bool) async throws {
        let fixture = try historyFixture()
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        let library = try #require(store.rowsByID["101"])
        let staged = row("djc-1", path: "/missing.wav")
        let (coordinator, table) = list([library, staged], selection: [library.id, staged.id], store: store)
        if pending { store.draftChanged(trackUUID: library.track.uuid, kind: .cue, exists: true) }
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == "재생 목록에 넣기" })
        #expect(menu.items.compactMap(\.action).map(NSStringFromSelector).contains("addToRekordbox"))
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
        withExtendedLifetime(table) {}
    }

    @Test func 목록_파일_드롭은_내부_곡_끌기와_일반_URL을_받지_않는다() {
        let file = NSItemProvider(object: URL(filePath: "/tmp/synthetic.wav") as NSURL)
        let web = NSItemProvider(object: URL(string: "https://example.com/song")! as NSURL)
        let track = NSItemProvider(object: URL(filePath: "/tmp/synthetic.wav") as NSURL)
        track.registerDataRepresentation(forTypeIdentifier: DeckDragType.track.identifier, visibility: .all) { completion in
            completion(Data("1".utf8), nil)
            return nil
        }
        #expect(LibraryFileDropDelegate.accepts([file]))
        #expect(!LibraryFileDropDelegate.accepts([]))
        #expect(!LibraryFileDropDelegate.accepts([web]))
        #expect(!LibraryFileDropDelegate.accepts([track]))
        #expect(!LibraryFileDropDelegate.accepts([file, track]))
    }
}
