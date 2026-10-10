import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72): XML을 메인 스레드 밖에서 읽어 차이를 보이고, 고른 차이를 초안으로만 만든다.
/// 합성 사본과 임시 초안 폴더만 쓴다.
@Suite("rekordbox XML 가져오기 화면 흐름")
@MainActor
struct RekordboxXMLImportTests {
    func library() throws -> RekordboxFixture { try LibraryXMLExportTests().library() }

    /// 초안 폴더는 픽스처 아래 `home`(가져오기가 만든 초안을 시험이 그 폴더에서 확인한다)
    func loadedStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                      draftHome: fixture.root.appending(path: "home"), movesDamagedDrafts: false)
        await store.load(snapshot: fixture.database)
        return store
    }

    /// 사본을 내보낸 XML을 고쳐 파일로 둔다: 제목·핫큐 A를 바꾸고 새 재생 목록을 더한다.
    func changedXML(_ fixture: RekordboxFixture) throws -> URL {
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let xml = RekordboxLibraryXML.document(collection)
            .replacingOccurrences(of: #"Name="합성 곡 A""#, with: #"Name="가져온 제목""#)
            .replacingOccurrences(of: #"Start="20.000" Num="0""#, with: #"Start="24.000" Num="0""#)
            .replacingOccurrences(of: #"<NODE Name="합성 목록""#, with: #"<NODE Name="가져온 목록""#)
        let url = fixture.root.appending(path: "import.xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    @Test func 메뉴는_파일_메뉴에_있고_불러온_라이브러리에서만_켜진다() async throws {
        #expect(LibraryMenuAction.importRekordboxXML.title == "rekordbox XML 가져오기…")
        #expect(LibraryMenuAction.fileActions.contains(.importRekordboxXML))
        let empty = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        #expect(!LibraryMenuAction.importRekordboxXML.isEnabled(in: empty))
        let fixture = try library()
        let store = await loadedStore(fixture)
        #expect(LibraryMenuAction.importRekordboxXML.isEnabled(in: store))
        store.xmlImport.start(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        #expect(!LibraryMenuAction.importRekordboxXML.isEnabled(in: store))
        #expect(LibraryMenuAction.importRekordboxXML.disabledReason(in: store)?.contains("끝난 뒤") == true)
        // 미리 보기 시트가 열려 있는 동안도 막는다
        await store.xmlImport.task?.value
        #expect(store.xmlImport.preview != nil && !LibraryMenuAction.importRekordboxXML.isEnabled(in: store))
    }

    @Test func 읽으면_차이_미리_보기를_연다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        store.xmlImport.start(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        #expect(store.xmlImport.isReading, "시작하자마자 읽는 중이 되고 메인 스레드를 막지 않는다")
        await store.xmlImport.task?.value
        #expect(!store.xmlImport.isReading)
        let preview = try #require(store.xmlImport.preview)
        #expect(preview.fileName == "import.xml")
        #expect(preview.diff.counts.cueTracks == 1 && preview.diff.counts.tagTracks == 1 && preview.diff.counts.missingPlaylists == 1)
        #expect(preview.diff.matching.matched == 1)
    }

    @Test func 고른_차이만_초안으로_만들고_rekordbox_사본은_그대로다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let home = fixture.root.appending(path: "home")
        let before = try Data(contentsOf: fixture.database)
        store.xmlImport.start(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImport.task?.value
        let preview = try #require(store.xmlImport.preview)
        var selection = XMLImportDrafts.Selection.all
        selection.kinds = [.tag, .playlist]
        let result = await store.xmlImport.makeDrafts(preview, selection: selection)
        #expect(result.tags == 1 && result.cues == 0 && result.playlists == 1)
        #expect(store.tagDrafts["uuid-101"]?.fields.title == "가져온 제목", "만든 태그 초안을 바로 다시 읽는다")
        #expect(store.playlistDraft.project(onto: store.rekordboxPlaylists).layout.children(of: PlaylistLayout.root)
            .contains { $0.name == "가져온 목록" && $0.trackIDs == ["101"] })
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "cue-drafts/uuid-101.json").path))
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test func 메모리의_초안이_있는_곡은_덮지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let row = try #require(store.rows.first { $0.track.id == "101" })
        var draft = TagDraft(track: row.track)
        draft.fields.comment = "편집 중"
        store.tagDrafts[row.track.uuid] = draft
        store.xmlImport.start(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImport.task?.value
        let preview = try #require(store.xmlImport.preview)
        let result = await store.xmlImport.makeDrafts(preview, selection: XMLImportDrafts.Selection(kinds: [.tag]))
        #expect(result.tags == 0 && result.skipped.count == 1)
        #expect(store.tagDrafts[row.track.uuid]?.fields.comment == "편집 중")
    }

    /// 첫 곡의 그리드 BPM만 바꾼 XML
    func gridXML(_ fixture: RekordboxFixture) throws -> URL {
        let collection = try RekordboxLibraryXML.load(snapshot: fixture.database, shareRoot: fixture.shareRoot)
        let xml = RekordboxLibraryXML.document(collection).replacingOccurrences(of: #"Bpm="128.00""#, with: #"Bpm="130.00""#)
        let url = fixture.root.appending(path: "grid.xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    @Test func 덱에_올린_곡의_그리드_초안은_덱이_받아_저장한다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let home = fixture.root.appending(path: "home")
        var adopted: GridDraft?
        store.deckGridDraftState = { (uuid: "uuid-101", hasChanges: false) }
        store.adoptImportedGridDraft = { adopted = $0; return true }
        store.xmlImport.start(from: try gridXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImport.task?.value
        let preview = try #require(store.xmlImport.preview)
        #expect(preview.diff.counts.gridTracks == 1)
        let result = await store.xmlImport.makeDrafts(preview, selection: XMLImportDrafts.Selection(kinds: [.grid]))
        #expect(result.grids == 1)
        #expect(adopted?.trackUUID == "uuid-101" && adopted?.segments.first?.bpm == 130)
        // 덱이 자기 저장 경로로 쓴다(가져오기가 따로 쓰면 덱의 다음 편집이 그 파일을 덮는다)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "grid-drafts/uuid-101.json").path))
    }

    @Test func 덱에서_그리드를_고친_곡은_가져오기가_건너뛴다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let home = fixture.root.appending(path: "home")
        var adopted = false
        store.deckGridDraftState = { (uuid: "uuid-101", hasChanges: true) }
        store.adoptImportedGridDraft = { _ in adopted = true; return true }
        store.xmlImport.start(from: try gridXML(fixture), shareRoot: fixture.shareRoot)
        await store.xmlImport.task?.value
        let preview = try #require(store.xmlImport.preview)
        let result = await store.xmlImport.makeDrafts(preview, selection: XMLImportDrafts.Selection(kinds: [.grid]))
        #expect(result.grids == 0 && !adopted)
        #expect(result.skipped.map(\.kind) == [.grid] && result.skipped.first?.subject == "합성 곡 A")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "grid-drafts/uuid-101.json").path))
    }

    @Test func 가져오기를_취소하면_미리_보기를_열지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        store.xmlImport.start(from: try changedXML(fixture), shareRoot: fixture.shareRoot)
        store.xmlImport.cancel()
        await store.xmlImport.task?.value
        #expect(store.xmlImport.preview == nil && !store.xmlImport.isReading)
        #expect(store.stagingMessage == nil, "취소는 실패로 알리지 않는다")
    }

    @Test func rekordbox_XML이_아니면_이유를_알리고_미리_보기를_열지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let bad = fixture.root.appending(path: "bad.xml")
        try Data("<plist/>".utf8).write(to: bad)
        store.xmlImport.start(from: bad, shareRoot: fixture.shareRoot)
        await store.xmlImport.task?.value
        #expect(store.xmlImport.preview == nil && !store.xmlImport.isReading)
        #expect(store.stagingMessage?.kind == .failure && store.stagingMessage?.text.contains("DJ_PLAYLISTS") == true)
    }
}
