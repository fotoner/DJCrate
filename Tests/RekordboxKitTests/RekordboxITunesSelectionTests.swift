import Foundation
import RekordboxKit
import Testing

@Suite("rekordbox iTunes 동기화 선택")
struct RekordboxITunesSelectionTests {
    static func xml(_ nodes: String) -> Data {
        Data("<SYNC_ITUNES_PLAYLIST><PLAYLISTS>\(nodes)</PLAYLISTS></SYNC_ITUNES_PLAYLIST>".utf8)
    }

    @Test func 선택된_목록과_부분_선택_폴더를_구분하고_ID를_정규화한다() throws {
        let selection = try RekordboxITunesSelection.parse(Self.xml("""
            <NODE Id="0" ParentId="0" Attribute="1" Lib_Type="1" CheckType="2"/>
            <NODE Id="00af" ParentId="0" Attribute="1" Lib_Type="1" CheckType="2"/>
            <NODE Id="0010" ParentId="00af" Attribute="0" Lib_Type="1" CheckType="1"/>
            <NODE Id="20" ParentId="af" Attribute="0" Lib_Type="1" CheckType="0"/>
            """))
        #expect(selection.nodes.map(\.id) == ["0", "AF", "10", "20"])
        #expect(selection.selectedIDs == ["10"])
        #expect(selection.nodes[2].parentID == "AF")
        #expect(selection.nodes[1].isFolder)
        #expect(!selection.nodes[2].isFolder)
    }

    @Test func 다른_라이브러리는_섞지_않는다() throws {
        let selection = try RekordboxITunesSelection.parse(Self.xml("""
            <NODE Id="10" ParentId="0" Attribute="0" Lib_Type="1" CheckType="1"/>
            <NODE Id="10" ParentId="0" Attribute="0" Lib_Type="2" CheckType="1"/>
            """))
        #expect(selection.nodes.count == 1)
        #expect(selection.selectedIDs == ["10"])
    }

    @Test func 빈_동기화_목록을_전체_선택으로_해석하지_않는다() throws {
        #expect(try RekordboxITunesSelection.parse(Self.xml("")).selectedIDs.isEmpty)
    }

    @Test(arguments: [
        "<wrong><PLAYLISTS/></wrong>",
        "<SYNC_ITUNES_PLAYLIST/>",
        "<SYNC_ITUNES_PLAYLIST><PLAYLISTS>",
        "<SYNC_ITUNES_PLAYLIST><PLAYLISTS><FOLDER><NODE/></FOLDER></PLAYLISTS></SYNC_ITUNES_PLAYLIST>",
        "<SYNC_ITUNES_PLAYLIST><PLAYLISTS><PLAYLIST/></PLAYLISTS></SYNC_ITUNES_PLAYLIST>",
        "<SYNC_ITUNES_PLAYLIST><PLAYLISTS/><NODE/></SYNC_ITUNES_PLAYLIST>",
        "<SYNC_ITUNES_PLAYLIST><PLAYLISTS><NODE Id='1' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'><NODE/></NODE></PLAYLISTS></SYNC_ITUNES_PLAYLIST>",
        String(decoding: xml("<NODE Id='not-hex' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/>"), as: UTF8.self),
        String(decoding: xml("<NODE Id='1' ParentId='0' Attribute='0' Lib_Type='1' CheckType='7'/>"), as: UTF8.self),
        String(decoding: xml("<NODE Id='1' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/><NODE Id='01' ParentId='0' Attribute='0' Lib_Type='1' CheckType='1'/>"), as: UTF8.self),
    ])
    func 잘못된_파일은_거부한다(_ xml: String) {
        #expect(throws: (any Error).self) { try RekordboxITunesSelection.parse(Data(xml.utf8)) }
    }
}
