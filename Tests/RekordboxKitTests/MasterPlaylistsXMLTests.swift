import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// `masterPlaylists6.xml` 줄 단위 편집(고친 줄 말고는 바이트 그대로)
@Suite("masterPlaylists6.xml")
struct MasterPlaylistsXMLTests {
    static let sample = [
        #"<?xml version="1.0" encoding="UTF-8"?>"#, "",
        #"<MASTER_PLAYLIST Version="3.0.0" AutomaticSync="0">"#,
        #"  <PRODUCT Name="rekordbox" Version="6.6.11" Company="Pioneer DJ"/>"#,
        "  <PLAYLISTS>",
        #"    <NODE Id="207F1D3" ParentId="0" Attribute="1" Timestamp="1790400600945" Lib_Type="0" CheckType="0"/>"#,
        #"    <NODE Id="1A56E709" ParentId="207F1D3" Attribute="0" Timestamp="1790400858818" Lib_Type="0" CheckType="0"/>"#,
        "  </PLAYLISTS>", "</MASTER_PLAYLIST>", "",
    ].joined(separator: "\r\n")

    /// NODE가 없는 파일(재생 목록 쓰기 시험의 출발점)
    static let empty = sample.components(separatedBy: "\r\n").filter { !$0.contains("<NODE") }.joined(separator: "\r\n")

    @Test func ID는_16진수_대문자_맨_위는_0() {
        #expect(MasterPlaylistsXML.hex("34075091") == "207F1D3")
        #expect(MasterPlaylistsXML.hex("441902857") == "1A56E709")
        #expect(MasterPlaylistsXML.hex("root") == "0")
        #expect(MasterPlaylistsXML.hex("abc") == nil)
    }

    @Test func NODE를_읽는다() throws {
        let xml = MasterPlaylistsXML(text: Self.sample)
        #expect(xml.nodes.count == 2)
        let node = try #require(xml.node(id: "441902857"))
        #expect(node.parentID == "207F1D3" && node.attribute == 0 && node.timestamp == 1_790_400_858_818)
        #expect(node.libType == 0 && node.checkType == 0)
    }

    @Test func 새_NODE는_끝에_CRLF로_붙는다() throws {
        var xml = MasterPlaylistsXML(text: Self.sample)
        try xml.append(id: "4287917557", parentID: "34075091", isFolder: false, timestamp: 1_790_500_000_123)
        let expected = Self.sample.replacingOccurrences(of: "  </PLAYLISTS>", with:
            #"    <NODE Id="FF946DF5" ParentId="207F1D3" Attribute="0" Timestamp="1790500000123" Lib_Type="0" CheckType="0"/>"# + "\r\n  </PLAYLISTS>")
        #expect(xml.text == expected)
        #expect(xml.nodes.last?.id == "FF946DF5")
    }

    @Test func 고친_줄_말고는_그대로() throws {
        var xml = MasterPlaylistsXML(text: Self.sample)
        #expect(try xml.update(id: "441902857", parentID: "root", timestamp: 1_790_500_000_000))
        let expected = Self.sample.replacingOccurrences(of: #"Id="1A56E709" ParentId="207F1D3" Attribute="0" Timestamp="1790400858818""#,
                                                        with: #"Id="1A56E709" ParentId="0" Attribute="0" Timestamp="1790500000000""#)
        #expect(xml.text == expected)
        #expect(try xml.update(id: "1", timestamp: 5) == false)
        #expect(xml.text == expected)
    }

    @Test func 여러_목록의_Timestamp를_한_번에_고친다() {
        // 곡 정보 쓰기(#173)는 목록 여러 개의 Timestamp를 같은 시각으로 고친다. 줄을 한 번만 훑고, 없는 목록은 건너뛴다.
        var xml = MasterPlaylistsXML(text: Self.sample)
        #expect(xml.touch(ids: ["34075091", "441902857", "999"], timestamp: 1_790_500_000_000) == 2)
        let expected = Self.sample.replacingOccurrences(of: "Timestamp=\"1790400600945\"", with: "Timestamp=\"1790500000000\"")
            .replacingOccurrences(of: "Timestamp=\"1790400858818\"", with: "Timestamp=\"1790500000000\"")
        #expect(xml.text == expected)
    }
}
