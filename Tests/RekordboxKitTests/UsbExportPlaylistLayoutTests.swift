import DJCDomain
import Foundation
import RekordboxKit
import Testing

/// iTunes 목록은 로컬 DB에 만들지 않고 기존 내보내기 입력으로 바꾼다.
@Suite("USB 내보내기 목록 모델")
struct UsbExportPlaylistLayoutTests {
    private func list(_ id: String, parent: String = PlaylistLayout.root, tracks: [String] = []) -> PlaylistLayout.Item {
        .init(id: id, name: "합성 \(id)", parentID: parent, entries: tracks.enumerated().map {
            PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element)
        })
    }

    @Test("iTunes·로컬 목록에서 선택한 뿌리만 내보내고 곡 순서·중복을 보존한다")
    func mixedSourceTreeKeepsSelectionAndOccurrences() throws {
        let layout = PlaylistLayout([
            (item: .init(id: "itunes:F", name: "합성 iTunes 폴더", isFolder: true), seq: 2),
            (item: list("itunes:A", parent: "itunes:F", tracks: ["102", "101", "102"]), seq: 1),
            (item: list("itunes:B", parent: "itunes:F", tracks: ["101", "103"]), seq: 3),
            (item: list("itunes:excluded", tracks: ["104"]), seq: 3),
            (item: list("800", tracks: ["103", "101"]), seq: 1),
        ])
        let tree = try UsbExportCandidates.playlistTree(layout: layout, rootIDs: ["800", "itunes:F"])
        #expect(tree.map(\.localID) == ["800", "itunes:F", "itunes:A", "itunes:B"])
        #expect(tree.map(\.parentLocalID) == [nil, nil, "itunes:F", "itunes:F"])
        #expect(tree.map(\.attribute) == [0, 1, 0, 0])
        #expect(tree.map(\.trackLocalIDs) == [["103", "101"], [], ["102", "101", "102"], ["101", "103"]])
        // 하위 목록만 고르면 기존 DB 선택 경로처럼 USB 맨 위에 둔다.
        #expect(try UsbExportCandidates.playlistTree(layout: layout, rootIDs: ["itunes:B"]).map(\.parentLocalID) == [nil])
    }

    @Test("같은 선택을 중복해 넘겨도 목록은 한 번만, 목록 안 같은 곡은 그대로다")
    func repeatedRootDeduplicatedOnlyAsPlaylist() throws {
        let layout = PlaylistLayout([(item: list("itunes:A", tracks: ["101", "101"]), seq: 1)])
        let tree = try UsbExportCandidates.playlistTree(layout: layout, rootIDs: ["itunes:A", "itunes:A"])
        #expect(tree.count == 1)
        #expect(tree.first?.trackLocalIDs == ["101", "101"])
    }

    @Test("스마트 목록은 기존 계획기가 목록 단위로 막는다")
    func smartPlaylistUsesExistingBlock() throws {
        let layout = PlaylistLayout([
            (item: .init(id: "itunes:smart", name: "합성 스마트", isSmart: true), seq: 1),
        ])
        let tree = try UsbExportCandidates.playlistTree(layout: layout, rootIDs: ["itunes:smart"])
        #expect(tree.first?.attribute == 4)
        let plan = UsbExportPlanner.plan(UsbExportRequest(candidates: [], playlists: tree, snapshotTakenAt: .distantFuture))
        #expect(plan.blocked.contains { $0.code == "smartPlaylist" && $0.scope == .playlist("itunes:smart") })
        #expect(plan.playlists.isEmpty)
    }

    @Test("새 목록 초안은 iTunes 목록으로 둔갑해 내보내지 않는다")
    func pendingLocalPlaylistBlocked() throws {
        let layout = PlaylistLayout([(item: list("new:pending", tracks: ["101"]), seq: 1)])
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.playlistTree(layout: layout, rootIDs: ["new:pending"])
        }
    }

    @Test("부모가 없거나 폴더가 아니거나 순환·같은 목록 ID가 중복이면 내보내기를 막는다")
    func malformedLayoutsBlocked() throws {
        let duplicate = list("itunes:duplicate")
        let layouts = [
            PlaylistLayout([(item: list("itunes:orphan", parent: "missing"), seq: 1)]),
            PlaylistLayout([(item: list("itunes:parent"), seq: 1), (item: list("itunes:child", parent: "itunes:parent"), seq: 1)]),
            PlaylistLayout([
                (item: .init(id: "itunes:A", name: "A", parentID: "itunes:B", isFolder: true), seq: 1),
                (item: .init(id: "itunes:B", name: "B", parentID: "itunes:A", isFolder: true), seq: 1),
            ]),
            PlaylistLayout([(item: duplicate, seq: 1), (item: duplicate, seq: 2)]),
        ]
        for layout in layouts {
            #expect(throws: UsbError.self) {
                try UsbExportCandidates.playlistTree(layout: layout, rootIDs: Array(layout.items.keys))
            }
        }
    }

    @Test("선택한 목록이 없으면 빈 트리를 만들지 않고 알린다")
    func missingSelectionBlocked() throws {
        #expect(throws: UsbError.self) {
            try UsbExportCandidates.playlistTree(layout: PlaylistLayout(), rootIDs: ["itunes:missing"])
        }
    }
}
