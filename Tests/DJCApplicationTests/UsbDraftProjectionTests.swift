import DJCApplication
import DJCDomain
import Testing

/// USB 끌어 놓기(#240)의 순수 규칙: 초안을 얹은 목록 항목(`UsbDraftProjection`), 끌어 넣을 곡(`UsbEditRules.tracksToAdd`),
/// 목록 안 순서 바꾸기 편집(`UsbEditRules.moveEntriesEdit`). 앱 흐름은 `UsbDragTests`가 본다
@Suite("USB 초안 얹기·끌어 놓기 규칙")
struct UsbDraftProjectionTests {
    /// 목록 10 '시험 목록'(곡 2·1·2), 목록 20 '둘째 목록'(곡 3), 폴더 30 '폴더'와 그 안 목록 40 '폴더 안'(곡 1)
    static func library() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        func list(_ id: Int, _ name: String, _ order: Int, parent: Int = 0, entries: [Int]? = nil) -> UsbPlaylist {
            UsbPlaylist(id: id, name: name, parentID: parent, attribute: entries == nil ? 1 : 0, presentIn: both,
                        sortOrder: [.oneLibrary: order, .deviceLibrary: order],
                        entries: entries.map { [.oneLibrary: $0, .deviceLibrary: $0] } ?? [:])
        }
        var library = UsbLibrary(formats: both, property: UsbProperty(dbVersion: "1000"))
        library.tracks = [1, 2, 3].map { UsbTrack(id: $0, presentIn: both) }
        library.playlists = [list(10, "시험 목록", 0, entries: [2, 1, 2]), list(20, "둘째 목록", 1, entries: [3]),
                             list(30, "폴더", 2), list(40, "폴더 안", 0, parent: 30, entries: [1])]
        return library
    }

    @Test("초안을 얹은 USB 목록 항목: 계획처럼 차례로 대 보고, 곡 번호를 모르는 편집이 닿으면 nil")
    func projection() throws {
        let library = Self.library()
        let list = try #require(library.playlists.first { $0.id == 10 })
        func entries(_ edits: [UsbLibraryEdit], _ playlist: UsbPlaylist? = nil) -> [Int]? {
            UsbDraftProjection.entries(of: playlist ?? list, library: library, edits: edits)
        }
        #expect(entries([]) == [2, 1, 2])
        // 다른 목록·컬렉션만 고치는 편집은 그대로
        #expect(entries([.playlist(edit: .addTracks(playlist: .id("20"), contentIDs: ["1"])), .refreshTracks(usbContentIDs: [1], parts: [.info]),
                         .addTracks(localContentIDs: ["11"], playlist: nil), .playlist(edit: .rename(playlist: .id("10"), name: "새 이름"))]) == [2, 1, 2])
        // 넣기 → 빼기 → 옮기기 → USB에서 곡 빼기
        #expect(entries([.playlist(edit: .addTracks(playlist: .id("10"), contentIDs: ["3"])),
                         .playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "2")])),
                         .playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 3, contentID: "3")], to: 1)),
                         .removeTracks(usbContentIDs: [1])]) == [3, 2])
        // 자리가 어긋난 편집(쓸 때 막힌다)
        #expect(entries([.playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "1")]))]) == nil)
        // 새 곡 번호·동기화 결과를 쓰기 전에는 모른다. 지운 목록·지운 폴더 안 목록도
        #expect(entries([.addTracks(localContentIDs: ["11"], playlist: .id("10"))]) == nil)
        #expect(entries([.syncPlaylist(playlist: .id("10"), localContentIDs: ["11"])]) == nil)
        #expect(entries([.playlist(edit: .delete(playlist: .id("10")))]) == nil)
        let inner = try #require(library.playlists.first { $0.id == 40 })
        #expect(entries([.playlist(edit: .delete(playlist: .id("30")))], inner) == nil)

        // 라이브러리 전체: 바뀐 목록만 두 형식에 함께 얹는다
        let projected = UsbDraftProjection.library(library, edits: [.playlist(edit: .addTracks(playlist: .id("20"), contentIDs: ["2"]))])
        #expect(projected.playlists.first { $0.id == 20 }?.entries == [.oneLibrary: [3, 2], .deviceLibrary: [3, 2]])
        #expect(projected.playlists.first { $0.id == 10 }?.entries == library.playlists.first { $0.id == 10 }?.entries)
    }

    @Test("옮길 항목과 놓은 자리 → 순서 바꾸기 편집(자리는 옮기는 곡을 뺀 목록 기준, 그대로면 없음)")
    func moveEntriesEdit() {
        let entries = [2, 1, 2]
        #expect(UsbEditRules.moveEntriesEdit([PlaylistEntry(trackNo: 3, contentID: "2")], before: 1, entries: entries, playlist: 10)
            == .playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 3, contentID: "2")], to: 1)))
        // 맨 끝으로
        #expect(UsbEditRules.moveEntriesEdit([PlaylistEntry(trackNo: 1, contentID: "2"), PlaylistEntry(trackNo: 2, contentID: "1")], before: nil,
                                               entries: entries, playlist: 10)
            == .playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "2"), PlaylistEntry(trackNo: 2, contentID: "1")],
                                           to: 2)))
        // 제자리
        #expect(UsbEditRules.moveEntriesEdit([PlaylistEntry(trackNo: 2, contentID: "1")], before: 3, entries: entries, playlist: 10) == nil)
        #expect(UsbEditRules.moveEntriesEdit([], before: 1, entries: entries, playlist: 10) == nil)
    }

    @Test("끈 USB 곡 → 넣을 곡(끈 차례, 같은 곡은 한 번)과 이미 든 곡 수")
    func tracksToAdd() {
        let result = UsbEditRules.tracksToAdd([3, 1, 3, 2, 1], current: [2, 1, 2])
        #expect(result.ids == [3])
        #expect(result.duplicates == 2)
        #expect(UsbEditRules.tracksToAdd([], current: [1]).ids.isEmpty)
    }
}
