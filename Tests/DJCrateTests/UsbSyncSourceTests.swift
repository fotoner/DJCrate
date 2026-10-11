@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import RekordboxKit
import Testing

@Suite("USB 동기화의 rekordbox·iTunes 원본")
struct UsbSyncSourceTests {
    private typealias Playlist = ITunesLibrarySnapshot.Playlist

    private func track(_ id: String, _ path: String, deleted: Bool = false) -> Track {
        Track(id: id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil,
              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: nil,
              lengthSeconds: 180, folderPath: path, comment: "", importedOn: nil,
              analysisDataPath: nil, imagePath: nil, isDeleted: deleted)
    }

    private func layout(_ items: [PlaylistLayout.Item]) -> PlaylistLayout {
        PlaylistLayout(items.enumerated().map { (item: $0.element, seq: $0.offset) })
    }

    private func iTunes(_ playlists: [Playlist], status: ITunesLibrarySnapshot.Status = .ready,
                        sourcePlaylists: [Playlist]? = nil, tracks: [Track] = []) -> SyncedITunesLibrary {
        SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: playlists, status: status,
                                                           sourcePlaylists: sourcePlaylists), tracks: tracks)
    }

    @Test("동기화한 iTunes 목록만 합치고 ID·원래 폴더 경로를 유지한다")
    func combinedSourceIncludesSidebarPlaylistsWithoutSyntheticFolders() {
        let rekordbox = layout([.init(id: "A", name: "rekordbox 목록"),
                                .init(id: "new:draft", name: "미반영 목록"),
                                .init(id: "smart", name: "인텔리전트 목록", isSmart: true)])
        let synced = [Playlist(id: "F", name: "DJ", isFolder: true),
                      Playlist(id: "A", name: "iTunes 목록", parentID: "F", paths: ["/synthetic/a.mp3"])]
        let source = UsbSyncSource.make(rekordbox: rekordbox,
                                        iTunes: iTunes(synced, sourcePlaylists: synced + [Playlist(id: "B", name: "선택하지 않은 목록")],
                                                       tracks: [track("local-a", "/synthetic/a.mp3")]))

        #expect(source.rekordbox.outline.map(\.id) == ["A"])
        #expect(source.iTunes.outline.map(\.id) == ["itunes:F", "itunes:A"])
        #expect(source.layout.outline.map(\.id) == ["A", "itunes:F", "itunes:A"])
        #expect(source.layout.childIDs(of: PlaylistLayout.root) == ["A", "itunes:F"])
        #expect(source.layout.item("itunes:A")?.trackIDs == ["local-a"])
        #expect(source.layout.item("A")?.name == "rekordbox 목록")
        #expect(source.layout.item("itunes:A")?.name == "iTunes 목록")
        #expect(source.layout.item("itunes:B") == nil)
        #expect(UsbSyncPlan.path(source.layout.item("itunes:A")!, in: source.layout) == ["DJ", "iTunes 목록"])
        #expect(source.layout.item(UsbSyncSource.iTunesSelectionID) == nil)
        #expect(source.layout.item(UsbSyncSource.rekordboxSelectionID) == nil)
        #expect(source.notices.isEmpty)
    }

    @Test("자식 목록 순서와 반복 곡·원래 곡 순번을 그대로 옮긴다")
    func leafEntriesPreserveOrderDuplicatesAndOriginalTrackNumbers() {
        let playlists = [Playlist(id: "F", name: "폴더", isFolder: true),
                         Playlist(id: "B", name: "먼저", parentID: "F", paths: ["/synthetic/b.mp3", nil, "/synthetic/a.mp3", "/synthetic/b.mp3"]),
                         Playlist(id: "A", name: "나중", parentID: "F", paths: ["/synthetic/a.mp3"]),
                         Playlist(id: "C", name: "맨 위 목록")]
        let source = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: iTunes(playlists,
                                                                                  tracks: [track("local-a", "/synthetic/a.mp3"),
                                                                                           track("local-b", "/synthetic/b.mp3")]))

        #expect(source.iTunes.outline.map(\.id) == ["itunes:F", "itunes:B", "itunes:A", "itunes:C"])
        #expect(source.iTunes.childIDs(of: "itunes:F") == ["itunes:B", "itunes:A"])
        #expect(source.iTunes.item("itunes:F")?.entries.isEmpty == true)
        #expect(source.iTunes.item("itunes:B")?.trackIDs == ["local-b", "local-a", "local-b"])
        #expect(source.iTunes.item("itunes:B")?.entries.map(\.trackNo) == [1, 3, 4])
    }

    @Test("연결되지 않은 곡이 있는 iTunes 목록도 막지 않고, 그 곡만 빼고 순서대로 동기화하며 넣지 못한 곡으로 알린다")
    func unlinkedTracksAreSkippedAndReportedNotBlocking() throws {
        let playlists = [Playlist(id: "F", name: "DJ", isFolder: true),
                         Playlist(id: "A", name: "누락", parentID: "F",
                                  paths: ["/synthetic/b.mp3", "/synthetic/missing.mp3", nil, "/synthetic/a.mp3",
                                          "/synthetic/drm.m4p", "/synthetic/dup.mp3", "/synthetic/b.mp3"]),
                         Playlist(id: "B", name: "같은 누락", parentID: "F", paths: ["/synthetic/missing.mp3", "/synthetic/a.mp3"])]
        let source = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: iTunes(playlists, tracks: [
            track("local-a", "/synthetic/a.mp3"), track("local-b", "/synthetic/b.mp3"),
            track("dup-1", "/synthetic/dup.mp3"), track("dup-2", "/synthetic/dup.mp3"),
        ]))
        let selection = ITunesSyncSelection(selectedIDs: ["itunes:F"])

        // 동기화를 막지 않고 목록 옆 알림만 남긴다
        #expect(source.blockReason(selection: selection) == nil)
        #expect(Set(source.notices.keys) == ["itunes:A", "itunes:B"])
        #expect(source.layout.item("itunes:A")?.trackIDs == ["local-b", "local-a", "local-b"])
        #expect(source.layout.item("itunes:A")?.entries.map(\.trackNo) == [1, 4, 7])

        // 이유별로, 같은 음원은 여러 목록에 있어도 한 번 센다(위치 없는 곡은 항목마다)
        let skipped = source.skippedITunesTracks(selection: selection)
        #expect(skipped.map(\.code) == ["iTunes.notInCollection", "iTunes.noLocalFile", "iTunes.protectedFile", "iTunes.ambiguous"])
        #expect(Set(skipped.map(\.scope)).count == 4)
        #expect(skipped.allSatisfy { $0.isSkippableInSync })
        // 막힘 대상에 경로를 남기지 않는다
        #expect(!skipped.contains { "\($0.scope)".contains("synthetic") })
        #expect(source.skippedITunesTracks(selection: .init(selectedIDs: ["itunes:B"])).map(\.code) == ["iTunes.notInCollection"])
        #expect(source.skippedITunesTracks(selection: .init()).isEmpty)

        let summary = UsbSyncModel.skippedSummary(skipped)
        // 머리 줄 + 이유 4줄(이유마다 1곡)
        #expect(summary.split(separator: "\n").count == 5 && summary.contains("4"))

        // 계획은 연결된 곡만 순서·반복 그대로 USB 목록에 쓴다
        var usb = UsbLibrary.empty
        usb.formats = [.oneLibrary]
        let plan = try UsbSyncPlan.build(source: source, selection: selection, library: usb, matches: [:], badges: [:], bindings: [:])
        #expect(plan.trackIDs == ["local-b", "local-a"])
        #expect(plan.edits.contains(.addTracks(localContentIDs: ["local-b", "local-a"], playlist: nil)))
        let synced = plan.edits.compactMap { edit -> [String]? in
            if case let .syncPlaylist(_, ids) = edit { ids } else { nil }
        }
        #expect(synced == [["local-b", "local-a", "local-b"], ["local-a"]])
    }

    @Test("rekordbox 목록의 내보낼 수 없는 로컬 곡은 빼고 나머지 순서를 지키며 이유별로 알린다")
    func unexportableLocalTracksAreExcludedFromPlan() throws {
        let rekordbox = layout([.init(id: "L", name: "로컬 목록", entries: [
            .init(trackNo: 1, contentID: "stream"), .init(trackNo: 2, contentID: "ok-1"), .init(trackNo: 3, contentID: "staged"),
            .init(trackNo: 4, contentID: "gone"), .init(trackNo: 5, contentID: "ok-2"), .init(trackNo: 6, contentID: "ok-1"),
        ])])
        let source = UsbSyncSource.make(rekordbox: rekordbox, iTunes: iTunes([]))
        let selection = ITunesSyncSelection(selectedIDs: ["L"])
        let skips = UsbSyncSource.skippedLocalTracks(UsbSyncPlan.selectedLayout(source.layout, selection: selection)) { id in
            switch id {
            case "stream": .streaming
            case "staged": .staged
            case "gone": .missing
            default: nil
            }
        }
        #expect(Set(skips.keys) == ["stream", "staged", "gone"])
        #expect(skips.values.allSatisfy { $0.isSkippableInSync })
        var usb = UsbLibrary.empty
        usb.formats = [.oneLibrary]
        let plan = try UsbSyncPlan.build(source: source, selection: selection, library: usb, matches: [:], badges: [:], bindings: [:],
                                        excluding: Set(skips.keys))
        #expect(plan.trackIDs == ["ok-1", "ok-2"])
        let synced = plan.edits.compactMap { edit -> [String]? in
            if case let .syncPlaylist(_, ids) = edit { ids } else { nil }
        }
        #expect(synced == [["ok-1", "ok-2", "ok-1"]])
    }

    @Test(arguments: [ITunesLibrarySnapshot.Status.ready, .stale])
    func readyAndStaleSnapshotsKeepTheSameSidebarTree(status: ITunesLibrarySnapshot.Status) {
        let source = UsbSyncSource.make(rekordbox: PlaylistLayout(),
                                        iTunes: iTunes([Playlist(id: "A", name: "읽은 목록")], status: status))
        #expect(source.layout.outline.map(\.id) == ["itunes:A"])
    }

    @Test(arguments: [ITunesLibrarySnapshot.Status.loading, .notCaptured, .unavailable])
    func unavailableStatusesDoNotInventAnITunesSource(status: ITunesLibrarySnapshot.Status) {
        let rekordbox = layout([.init(id: "one", name: "rekordbox 목록")])
        let source = UsbSyncSource.make(rekordbox: rekordbox,
                                        iTunes: iTunes([Playlist(id: "A", name: "읽지 않은 목록")], status: status))
        #expect(source.layout.outline.map(\.id) == ["one"])
        #expect(source.iTunes.outline.isEmpty)
        #expect(source.notices.isEmpty)
    }

    @Test("읽기 실패의 전체·그룹·사라진 목록 선택은 빈 미러 삭제를 만들지 않는다",
          arguments: [ITunesLibrarySnapshot.Status.loading, .notCaptured, .unavailable])
    func unreadSelectedITunesSourceBlocksBeforePlanning(status: ITunesLibrarySnapshot.Status) {
        let source = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: iTunes([], status: status))
        var usb = UsbLibrary.empty
        usb.playlists = [.init(id: 1, name: "USB에 남아 있는 목록", presentIn: [.oneLibrary])]
        for id in ["0", UsbSyncSource.iTunesSelectionID, "itunes:missing"] {
            let selection = ITunesSyncSelection(selectedIDs: [id])
            #expect(source.blockReason(selection: selection) != nil)
            #expect(throws: PlaylistLayout.Blocked.self) {
                try UsbSyncPlan.build(source: source, selection: selection, library: usb,
                                      matches: [:], badges: [:], bindings: [:])
            }
        }
        #expect(source.blockReason(selection: .init(selectedIDs: [UsbSyncSource.rekordboxSelectionID])) == nil)
    }

    @Test("정상적으로 읽은 빈 iTunes 원본은 읽기 실패와 구분하고 USB 목록은 지우지 않는다")
    func readyEmptySourceIsDifferentFromUnreadSource() throws {
        let ready = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: iTunes([]))
        let loading = UsbSyncSource.make(rekordbox: PlaylistLayout(), iTunes: iTunes([], status: .loading))
        #expect(ready != loading)
        let selection = ITunesSyncSelection(selectedIDs: [UsbSyncSource.iTunesSelectionID])
        var usb = UsbLibrary.empty
        usb.playlists = [.init(id: 1, name: "연결만 끊길 목록", presentIn: [.oneLibrary])]
        let plan = try UsbSyncPlan.build(source: ready, selection: selection, library: usb,
                                        matches: [:], badges: [:], bindings: [:])
        #expect(plan.edits.isEmpty && plan.unlinkedPlaylistCount == 1)
    }

    @Test("iTunes 폴더의 부분 선택은 다른 원본과 형제 목록을 유지한다")
    func partialSelectionPreservesTheOtherSourceAndSiblings() {
        let source = UsbSyncSource.make(rekordbox: layout([.init(id: "local", name: "로컬 목록")]),
                                        iTunes: iTunes([Playlist(id: "F", name: "DJ", isFolder: true),
                                                        Playlist(id: "A", name: "해제", parentID: "F"),
                                                        Playlist(id: "B", name: "보존", parentID: "F")]))
        let nodes = UsbSyncPlan.nodes(source.layout)
        var selection = ITunesSyncSelection(selectedIDs: ["local", "itunes:F"])
        selection.setSelected(false, id: "itunes:A", in: nodes)
        #expect(selection.state(of: "itunes:F", in: nodes) == .mixed)
        #expect(UsbSyncPlan.selectedLayout(source.layout, selection: selection).outline.map(\.id) == ["local", "itunes:F", "itunes:B"])
    }

    @Test("원본별 전체 선택은 새로 생긴 하위 목록을 포함하고 다른 원본은 건드리지 않는다")
    func sourceSelectionIncludesFutureChildrenAndKeepsOtherSource() {
        let rekordbox = layout([.init(id: "local", name: "로컬 목록")])
        let first = UsbSyncSource.make(rekordbox: rekordbox, iTunes: iTunes([Playlist(id: "A", name: "기존 iTunes 목록")]))
        var selection = ITunesSyncSelection(selectedIDs: ["local"])
        selection.setSelected(true, id: UsbSyncSource.iTunesSelectionID, in: UsbSyncPlan.nodes(first.layout))
        #expect(selection.selectedIDs.contains(UsbSyncSource.iTunesSelectionID))
        let next = UsbSyncSource.make(rekordbox: rekordbox,
                                      iTunes: iTunes([Playlist(id: "A", name: "기존 iTunes 목록"), Playlist(id: "B", name: "새 iTunes 목록")]))
        #expect(UsbSyncPlan.selectedLayout(next.layout, selection: selection).outline.map(\.id) == ["local", "itunes:A", "itunes:B"])
        selection.setSelected(false, id: UsbSyncSource.iTunesSelectionID, in: UsbSyncPlan.nodes(next.layout))
        #expect(UsbSyncPlan.selectedLayout(next.layout, selection: selection).outline.map(\.id) == ["local"])

        selection.setSelected(true, id: UsbSyncSource.rekordboxSelectionID, in: UsbSyncPlan.nodes(next.layout))
        let updated = UsbSyncSource.make(rekordbox: layout([.init(id: "local", name: "로컬 목록"), .init(id: "new-local", name: "새 로컬 목록")]),
                                         iTunes: iTunes([Playlist(id: "A", name: "기존 iTunes 목록")]))
        #expect(UsbSyncPlan.selectedLayout(updated.layout, selection: selection).outline.map(\.id) == ["local", "new-local"])
    }

    @Test("옛 전체 선택 ID 0은 두 원본 모두 포함하고 원본 하나만 해제할 수 있다")
    func legacyGlobalSelectionCanExcludeOneSource() {
        let source = UsbSyncSource.make(rekordbox: layout([.init(id: "local", name: "로컬 목록")]),
                                        iTunes: iTunes([Playlist(id: "A", name: "iTunes 목록")]))
        var selection = ITunesSyncSelection(selectedIDs: ["0"])
        #expect(UsbSyncPlan.selectedLayout(source.layout, selection: selection).outline.map(\.id) == ["local", "itunes:A"])
        selection.setSelected(false, id: UsbSyncSource.rekordboxSelectionID, in: UsbSyncPlan.nodes(source.layout))
        #expect(UsbSyncPlan.selectedLayout(source.layout, selection: selection).outline.map(\.id) == ["itunes:A"])
    }

    @Test("원본 선택 파일에는 실제 목록만 전달하고 최상위 부모는 nil로 둔다")
    func nativeSourceNodesExcludeSelectionOnlyGroups() {
        let source = UsbSyncSource.make(rekordbox: layout([.init(id: "local", name: "로컬 목록")]),
                                        iTunes: iTunes([Playlist(id: "F", name: "DJ", isFolder: true),
                                                        Playlist(id: "A", name: "하위 목록", parentID: "F"),
                                                        Playlist(id: "B", name: "DJ BLOCKS", isFolder: true)]))
        let nativeNodes = source.nativeNodes
        #expect(nativeNodes.map(\.id) == ["local", "itunes:F", "itunes:A", "itunes:B"])
        #expect(nativeNodes.first { $0.id == "local" }?.parentID == nil)
        #expect(nativeNodes.first { $0.id == "itunes:F" }?.parentID == nil)
        #expect(nativeNodes.first { $0.id == "itunes:A" }?.parentID == "itunes:F")
        #expect(!nativeNodes.contains { $0.id == UsbSyncSource.iTunesSelectionID || $0.id == UsbSyncSource.rekordboxSelectionID })
        let selectedFolder = ITunesSyncSelection(selectedIDs: ["itunes:F"])
        let nodes = UsbSyncSource.nodes(source.layout)
        #expect(selectedFolder.state(of: "itunes:F", in: nodes) == .on)
        #expect(selectedFolder.state(of: UsbSyncSource.iTunesSelectionID, in: nodes) == .mixed)
        #expect(selectedFolder.state(of: UsbSyncSource.rekordboxSelectionID, in: nodes) == .off)
    }

    @Test("masterPlaylists6.xml의 같은 NODE가 있는 목록만 Timestamp를 싣고 체크할 목록이 없으면 알린다")
    func nativeNodesCarryMasterTimestamps() throws {
        let source = UsbSyncSource.make(rekordbox: layout([.init(id: "100", name: "폴더", isFolder: true),
                                                           .init(id: "101", name: "목록", parentID: "100"),
                                                           .init(id: "200", name: "부모가 다른 목록")]),
                                        iTunes: iTunes([Playlist(id: "F", name: "DJ", isFolder: true),
                                                        Playlist(id: "A", name: "하위 목록", parentID: "F")]))
        // 합성 masterPlaylists6.xml: 200(C8)은 부모가 달라 쓰지 않는다. iTunes Timestamp는 0이다.
        let xml = MasterPlaylistsXML(text: """
        <?xml version="1.0" encoding="UTF-8"?>
        
        <MASTER_PLAYLIST Version="1.0.0" AutomaticSync="0">
          <PLAYLISTS>
            <NODE Id="64" ParentId="0" Attribute="1" Timestamp="1700000000100" Lib_Type="0" CheckType="0"/>
            <NODE Id="65" ParentId="64" Attribute="0" Timestamp="1700000000101" Lib_Type="0" CheckType="0"/>
            <NODE Id="C8" ParentId="64" Attribute="0" Timestamp="1700000000200" Lib_Type="0" CheckType="0"/>
            <NODE Id="F" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="0"/>
            <NODE Id="A" ParentId="F" Attribute="0" Timestamp="0" Lib_Type="1" CheckType="0"/>
          </PLAYLISTS>
        </MASTER_PLAYLIST>

        """)
        let nodes = UsbSyncSource.nativeNodes(source.layout, master: xml.nodes)
        let stamps = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.timestamp) })
        #expect(stamps == ["100": 1_700_000_000_100, "101": 1_700_000_000_101, "200": nil, "itunes:F": 0, "itunes:A": 0])
        #expect(!UsbSyncSource.lacksMasterNode(nodes, selection: .init(selectedIDs: ["101", "itunes:F"])))
        #expect(UsbSyncSource.lacksMasterNode(nodes, selection: .init(selectedIDs: ["200"])))
        #expect(UsbSyncSource.lacksMasterNode(nodes, selection: .init(selectedIDs: [UsbSyncSource.rekordboxSelectionID])))
    }
}
