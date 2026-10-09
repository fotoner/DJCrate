import DJCEnvironment
@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 파일 메뉴의 "라이브러리 XML 내보내기…"(#72): 읽기만 하고 고른 파일 하나에만 쓰며, 진행·완료·실패를 알린다.
@Suite("라이브러리 XML 내보내기 화면 흐름")
@MainActor
struct LibraryXMLExportTests {
    func library() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        var spec = TrackSpec(id: "101", uuid: "uuid-101")
        spec.title = "합성 곡 A"
        spec.folderPath = "/Music/합성 A.mp3"
        spec.analysisDataPath = "/PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT"
        spec.cues = [CueSpec(id: "c1", kind: 1, inMsec: 20_000)]
        try fixture.add(spec)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 128, first: 50, count: 100)), ext: nil)
        var streaming = TrackSpec(id: "102", uuid: "uuid-102")
        streaming.title = "합성 스트리밍"
        streaming.folderPath = "apple-music:track:1"
        try fixture.add(streaming)
        try fixture.insert("djmdPlaylist", ["ID": .text("p1"), "Name": .text("합성 목록"), "ParentID": .text("root"), "Attribute": .int(0), "Seq": .int(1)])
        try fixture.insert("djmdSongPlaylist", ["ID": .text("s1"), "PlaylistID": .text("p1"), "ContentID": .text("101"), "TrackNo": .int(1)])
        return fixture
    }

    func loadedStore(_ fixture: RekordboxFixture) async -> LibraryStore {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        return store
    }

    @Test func 불러온_라이브러리에서만_메뉴가_켜지고_내보내는_동안은_꺼진다() async throws {
        let fixture = try library()
        let empty = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        #expect(!LibraryMenuAction.exportLibraryXML.isEnabled(in: empty))
        #expect(LibraryMenuAction.exportLibraryXML.disabledReason(in: empty)?.contains("불러온") == true)
        let store = await loadedStore(fixture)
        #expect(LibraryMenuAction.exportLibraryXML.isEnabled(in: store))
        #expect(LibraryMenuAction.exportLibraryXML.disabledReason(in: store) == nil)
        store.xmlExportJob = LibraryXMLExportJob()
        #expect(store.hasXMLExportJob && !LibraryMenuAction.exportLibraryXML.isEnabled(in: store))
        #expect(LibraryMenuAction.exportLibraryXML.disabledReason(in: store)?.contains("끝난 뒤") == true)
    }

    @Test func 내보내면_파일을_쓰고_진행_줄을_거둔_뒤_완료를_알린다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let out = fixture.root.appending(path: "export.xml")
        let before = try Data(contentsOf: fixture.database)
        store.exportLibraryXML(to: out, shareRoot: fixture.shareRoot)
        #expect(store.hasXMLExportJob, "시작하자마자 진행 줄이 선다(메인 스레드를 막지 않고 돌아온다)")
        await store.xmlExportTask?.value
        #expect(store.xmlExportJob == nil && !store.hasXMLExportJob && store.xmlExportTask == nil)
        let xml = try String(contentsOf: out, encoding: .utf8)
        #expect(xml.contains(#"<COLLECTION Entries="1">"#) && xml.contains("<TEMPO ") && xml.contains(#"Num="0""#))
        let message = try #require(store.stagingMessage)
        #expect(message.kind == .success)
        #expect(message.text.contains("export.xml") && message.text.contains("뺀 것: 스트리밍 곡 1"))
        #expect(message.text.contains("쓰지 않은 초안은 넣지 않았습니다"))
        #expect(try Data(contentsOf: fixture.database) == before, "라이브러리 사본은 바뀌지 않는다")
        #expect(LibraryMenuAction.exportLibraryXML.isEnabled(in: store), "끝나면 다시 켜진다")
    }

    @Test func 쓰지_않은_초안은_넣지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        let row = try #require(store.rows.first { $0.track.id == "101" })
        var draft = TagDraft(track: row.track)
        draft.fields.title = "초안으로 바꾼 제목"
        draft.fields.comment = "초안 코멘트"
        store.tagDrafts[row.track.uuid] = draft
        let out = fixture.root.appending(path: "export.xml")
        store.exportLibraryXML(to: out, shareRoot: fixture.shareRoot)
        await store.xmlExportTask?.value
        let xml = try String(contentsOf: out, encoding: .utf8)
        #expect(xml.contains(#"Name="합성 곡 A""#) && !xml.contains("초안"))
    }

    @Test func rekordbox_폴더와_연동_파일_자리는_거부하고_아무것도_쓰지_않는다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        for out in [LibrarySnapshot.realRekordboxDirectory.appending(path: "export.xml"), DJCIdentity.linkedXMLFile,
                    fixture.root.appending(path: "master.db")] {
            store.stagingMessage = nil
            store.exportLibraryXML(to: out, shareRoot: fixture.shareRoot)
            #expect(store.xmlExportJob == nil && store.xmlExportTask == nil, "작업을 시작하지 않는다")
            let message = try #require(store.stagingMessage)
            #expect(message.kind == .failure && message.text.hasPrefix("라이브러리 XML을 내보내지 못했습니다"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "export.xml").path))
    }

    @Test func 읽다_실패하면_이유를_알리고_진행_줄을_거둔다() async throws {
        let fixture = try library()
        let store = await loadedStore(fixture)
        try FileManager.default.removeItem(at: fixture.database)
        let out = fixture.root.appending(path: "export.xml")
        store.exportLibraryXML(to: out, shareRoot: fixture.shareRoot)
        await store.xmlExportTask?.value
        #expect(store.xmlExportJob == nil)
        #expect(store.stagingMessage?.kind == .failure)
        #expect(!FileManager.default.fileExists(atPath: out.path), "실패하면 파일을 만들지 않는다")
    }

    @Test func 진행은_읽기가_앞_70퍼센트이고_거꾸로_가지_않는다() {
        var job = LibraryXMLExportJob()
        #expect(job.isPreparing && job.fraction == 0)
        job.apply(.init(phase: .readingGrids, done: 50, total: 100))
        #expect(!job.isPreparing && abs(job.fraction - 0.35) < 1e-9)
        job.apply(.init(phase: .readingGrids, done: 10, total: 100))
        #expect(abs(job.fraction - 0.35) < 1e-9, "늦게 온 이전 진행은 무시한다")
        job.apply(.init(phase: .writing, done: 50, total: 100))
        #expect(abs(job.fraction - 0.85) < 1e-9)
        job.apply(.init(phase: .writing, done: 100, total: 100))
        #expect(abs(job.fraction - 1) < 1e-9)
    }

    @Test func 기본_파일_이름은_날짜가_붙은_xml이다() {
        let name = LibraryXMLPanels.defaultFileName(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(name.hasPrefix("DJCrate-library-") && name.hasSuffix(".xml"))
    }
}
