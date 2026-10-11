import DJCDomain
import Foundation
import Testing

@Suite("USB 편집 표현")
struct UsbLibraryEditTests {
    /// 재생 목록 편집 8종(USB 목록 ID·USB content_id 문자열)
    let playlistEdits: [PlaylistEdit] = [
        .create(key: "새 목록", name: "새 목록", isFolder: false, parent: .root),
        .rename(playlist: .id("3"), name: "이름"),
        .move(playlist: .id("3"), into: .new("폴더")),
        .reorder(playlist: .id("4"), index: 2),
        .delete(playlist: .id("5")),
        .addTracks(playlist: .id("3"), contentIDs: ["7", "8"]),
        .removeTracks(playlist: .id("3"), entries: [PlaylistEntry(trackNo: 2, contentID: "8")]),
        .moveTracks(playlist: .id("3"), entries: [PlaylistEntry(trackNo: 1, contentID: "7")], to: 2),
    ]

    var edits: [UsbLibraryEdit] {
        [
            .addTracks(localContentIDs: ["101", "102"], playlist: .id("3")),
            .addTracks(localContentIDs: ["103"], playlist: nil),
            .removeTracks(usbContentIDs: [5, 6]),
            .refreshTracks(usbContentIDs: [2], parts: [.info, .cues, .grid, .artwork]),
        ] + playlistEdits.map { .playlist(edit: $0) }
    }

    @Test("JSON으로 적고 다시 읽는다")
    func codableRoundTrip() throws {
        for edit in edits {
            let data = try JSONEncoder().encode(edit)
            #expect(try JSONDecoder().decode(UsbLibraryEdit.self, from: data) == edit)
        }
        let all = try JSONEncoder().encode(edits)
        #expect(try JSONDecoder().decode([UsbLibraryEdit].self, from: all) == edits)
    }

    @Test("편집마다 필요한 확인 안 된 규칙")
    func requiredRules() {
        #expect(UsbLibraryEdit.addTracks(localContentIDs: ["1"], playlist: nil).requiredRules == [.editAddTracks])
        #expect(UsbLibraryEdit.removeTracks(usbContentIDs: [1]).requiredRules == [.editRemoveTracks, .trackRemovalFiles])
        #expect(UsbLibraryEdit.refreshTracks(usbContentIDs: [1], parts: [.info]).requiredRules == [.editRefreshTracks])
        for edit in playlistEdits {
            #expect(UsbLibraryEdit.playlist(edit: edit).requiredRules == [.editPlaylists])
        }
    }

    func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test("재생 목록 편집은 {\"playlist\":{\"edit\":…}} 모양")
    func playlistEditJSONShape() throws {
        for edit in playlistEdits {
            let wrapped = try object(JSONEncoder().encode(UsbLibraryEdit.playlist(edit: edit)))
            #expect(wrapped.allKeys as? [String] == ["playlist"])
            let inner = try #require(wrapped["playlist"] as? NSDictionary)
            #expect(inner.allKeys as? [String] == ["edit"])
            let alone = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? NSObject
            #expect((inner["edit"] as? NSObject) == alone)

            let editJSON = try #require(String(data: JSONEncoder().encode(edit), encoding: .utf8))
            let text = #"{"playlist":{"edit":"# + editJSON + "}}"
            #expect(try JSONDecoder().decode(UsbLibraryEdit.self, from: Data(text.utf8)) == .playlist(edit: edit))
            let unlabeled = #"{"playlist":{"_0":"# + editJSON + "}}"
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(UsbLibraryEdit.self, from: Data(unlabeled.utf8))
            }
        }
    }

    @Test("곡 편집 세 가지의 바깥 모양")
    func trackEditJSONShapes() throws {
        func decode(_ text: String) throws -> UsbLibraryEdit {
            try JSONDecoder().decode(UsbLibraryEdit.self, from: Data(text.utf8))
        }
        #expect(try decode(#"{"removeTracks":{"usbContentIDs":[5]}}"#) == .removeTracks(usbContentIDs: [5]))
        #expect(try decode(#"{"refreshTracks":{"usbContentIDs":[2],"parts":["info","cues"]}}"#)
            == .refreshTracks(usbContentIDs: [2], parts: [.info, .cues]))
        #expect(try decode(#"{"addTracks":{"localContentIDs":["101"],"playlist":"3"}}"#)
            == .addTracks(localContentIDs: ["101"], playlist: .id("3")))
        #expect(try decode(#"{"addTracks":{"localContentIDs":["101"]}}"#) == .addTracks(localContentIDs: ["101"], playlist: nil))

        let encoded = try object(JSONEncoder().encode(UsbLibraryEdit.refreshTracks(usbContentIDs: [2], parts: [.grid])))
        let inner = try #require(encoded["refreshTracks"] as? NSDictionary)
        #expect(Set(inner.allKeys as? [String] ?? []) == ["usbContentIDs", "parts"])
        #expect(inner["parts"] as? [String] == ["grid"])
    }
}
