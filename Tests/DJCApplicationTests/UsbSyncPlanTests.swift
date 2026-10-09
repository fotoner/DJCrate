import DJCApplication
import DJCDomain
import Foundation
import Testing

@Suite("USB 재생 목록 동기화 계획")
struct UsbSyncPlanTests {
    private func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root,
                      folder: Bool = false, smart: Bool = false, tracks: [String] = []) -> PlaylistLayout.Item {
        PlaylistLayout.Item(id: id, name: name, parentID: parent, isFolder: folder, isSmart: smart,
                            entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    private func layout(_ items: [PlaylistLayout.Item]) -> PlaylistLayout {
        PlaylistLayout(items.enumerated().map { (item: $0.element, seq: $0.offset) })
    }

    private func playlist(_ id: Int, _ name: String, parent: Int = 0, folder: Bool = false,
                          order: Int = 0, tracks: [Int] = []) -> UsbPlaylist {
        UsbPlaylist(id: id, name: name, parentID: parent, attribute: folder ? 1 : 0,
                    presentIn: UsbFormat.defaultSet,
                    sortOrder: [.oneLibrary: order, .deviceLibrary: order],
                    entries: [.oneLibrary: tracks, .deviceLibrary: tracks])
    }

    private func library(_ playlists: [UsbPlaylist], tracks: [Int] = [], history: [Int] = []) -> UsbLibrary {
        var library = UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000"))
        library.playlists = playlists
        library.tracks = tracks.map { UsbTrack(id: $0, presentIn: UsbFormat.defaultSet) }
        if !history.isEmpty { library.histories = [UsbHistory(format: .oneLibrary, id: 1, name: "합성 기록", entries: history)] }
        return library
    }

    @Test("미반영 목록·인텔리전트 목록을 빼고 기존 트리와 곡 순서를 유지한다")
    func sourceExcludesUnsupportedPlaylists() {
        let raw = layout([item("folder", "폴더", folder: true),
                          item("one", "일반 목록", parent: "folder", tracks: ["local-two", "local-one"]),
                          item("smart", "인텔리전트 목록", parent: "folder", smart: true),
                          item("new:draft", "미반영 목록", parent: "folder"),
                          item("new:folder", "미반영 폴더", folder: true),
                          item("new:child", "미반영 하위 목록", parent: "new:folder"),
                          item("two", "다른 일반 목록")])
        let source = UsbSyncPlan.source(raw)
        #expect(source.outline.map(\.id) == ["folder", "one", "two"])
        #expect(source.item("one")?.trackIDs == ["local-two", "local-one"])
        #expect(source.item("folder")?.isFolder == true)
    }

    @Test("폴더 선택은 하위를 포함하고 하위 하나를 끄면 형제와 조상 폴더를 보존한다")
    func folderSelectionAndPartialSelection() {
        let source = layout([item("folder", "폴더", folder: true),
                             item("one", "목록 하나", parent: "folder"),
                             item("nested", "하위 폴더", parent: "folder", folder: true),
                             item("two", "목록 둘", parent: "nested"),
                             item("outside", "다른 목록")])
        let nodes = UsbSyncPlan.nodes(source)
        var selection = ITunesSyncSelection(selectedIDs: ["folder"])
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "one", "nested", "two"])
        selection.setSelected(false, id: "one", in: nodes)
        #expect(selection.state(of: "folder", in: nodes) == .mixed)
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "nested", "two"])
        #expect(nodes.first { $0.id == "folder" }?.parentID == UsbSyncSourceNode.rekordboxSelectionID)
    }

    @Test("처음 여는 선택은 전체 경로가 같은 일반 목록만 연결하고 NFC를 맞춘다")
    func initialSelectionMatchesWholeNormalizedPath() {
        let source = layout([item("folder", "가", folder: true),
                             item("one", "같은 이름", parent: "folder"),
                             item("other-folder", "다른 폴더", folder: true),
                             item("two", "같은 이름", parent: "other-folder"),
                             // "root"는 PlaylistLayout.root 표지와 겹쳐 자기 자신의 자식이 되므로 쓰지 않는다.
                             item("top-list", "같은 이름")])
        let usb = library([playlist(10, "\u{1100}\u{1161}", folder: true),
                           playlist(11, "같은 이름", parent: 10)])
        let selection = UsbSyncPlan.initialSelection(source: source, library: usb)
        #expect(selection.selectedIDs == ["one"])
        #expect(UsbSyncPlan.selectedLayout(source, selection: selection).outline.map(\.id) == ["folder", "one"])
    }

    @Test("이름이 바뀐 원본은 rekordbox처럼 새 USB 목록을 만들고 옛 목록은 옮기거나 지우지 않는다")
    func renamedSourceCreatesNewPlaylistAndKeepsOld() throws {
        let source = layout([item("new-parent", "남길 폴더", folder: true),
                             item("local-list", "바꾼 목록 이름", parent: "new-parent")])
        let usb = library([playlist(10, "옛 폴더", folder: true),
                           playlist(11, "예전 목록 이름", parent: 10),
                           playlist(20, "남길 폴더", folder: true, order: 1)])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["옛 폴더", "예전 목록 이름"], isFolder: false)]
        // 지난 선택 파일 행으로 이었어도 원본이 아직 선택돼 있으니 옛 목록은 지우지 않는다(2026-10-08 정상 USB 실험).
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings,
                                        linkedPlaylistIDs: ["local-list": 11], newKey: { "renamed" })
        #expect(plan.edits == [.playlist(edit: .create(key: "renamed", name: "바꾼 목록 이름", isFolder: false, parent: .id("20")))])
        #expect(plan.playlistRefs == ["new-parent": .id("20"), "local-list": .new("renamed")])
        #expect(plan.unlinkedPlaylistCount == 2 && plan.deletedPlaylists.isEmpty)
    }

    /// #233: Swift 문자열 ==는 NFC·NFD를 같다고 본다. 이은 USB 목록의 이름이 철자만 다르면 OneLibrary에 있는 목록은 바꾸고,
    /// Device Library에만 있는 목록은 작성기가 늘 NFC로 쓰므로 바꾸지 않는다(동기화마다 바뀐 것으로 보이지 않게)
    @Test("이은 목록 이름이 NFC·NFD만 달라도 OneLibrary 목록은 이름을 바꾸고 Device Library만의 목록은 그대로 둔다")
    func spellingOnlyNameDifference() throws {
        let nfc = "한글 목록".precomposedStringWithCanonicalMapping, nfd = "한글 목록".decomposedStringWithCanonicalMapping
        let source = layout([item("local-list", nfc)])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: [nfc], isFolder: false)]
        let both = library([playlist(11, nfd)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                         library: both, matches: [:], badges: [:], bindings: bindings,
                                         linkedPlaylistIDs: ["local-list": 11], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .rename(playlist: .id("11"), name: nfc))])
        if case let .playlist(edit: .rename(_, name))? = plan.edits.first {
            #expect(name.unicodeScalars.elementsEqual(nfc.unicodeScalars))
        }
        // 철자까지 같으면 바꾸지 않는다
        let same = try UsbSyncPlan.build(source: layout([item("local-list", nfd)]), selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                         library: both, matches: [:], badges: [:], bindings: bindings,
                                         linkedPlaylistIDs: ["local-list": 11], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(same.edits.isEmpty)
        // Device Library에만 있는 목록(USB 이름은 NFC로 읽힌다)은 로컬이 NFD여도 바꾸지 않는다
        var deviceOnly = library([playlist(11, nfc)])
        deviceOnly.formats = [.deviceLibrary]
        deviceOnly.playlists[0].presentIn = [.deviceLibrary]
        let device = try UsbSyncPlan.build(source: layout([item("local-list", nfd)]), selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                           library: deviceOnly, matches: [:], badges: [:], bindings: bindings,
                                           linkedPlaylistIDs: ["local-list": 11], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(device.edits.isEmpty)
    }

    /// 2026-10-08 실험 G3: 체크한 폴더 F를 F2로 바꾸고 SYNC하면 rekordbox는 두 형식에 새 F2와 새 하위 목록(새 Dev_ID)을 만들고,
    /// 옛 F와 그 안의 목록은 지우지도 옮기지도 않고 연결 없이(회색) 남겼다. 선택 파일에는 새 Dev_ID만 적혔다.
    @Test("이름을 바꾼 폴더는 하위 목록까지 새로 만들고 옛 폴더와 그 안의 목록은 연결 없이 남긴다")
    func renamedFolderCreatesNewChildrenAndKeepsOldFolder() throws {
        let source = layout([item("f", "F2", folder: true),
                             item("n", "N", parent: "f"),
                             item("sub", "하위 폴더", parent: "f", folder: true),
                             item("p1", "P1", parent: "sub", tracks: ["local-one"])])
        let usb = library([playlist(10, "F", folder: true),
                           playlist(11, "N", parent: 10),
                           playlist(12, "하위 폴더", parent: 10, folder: true, order: 1),
                           playlist(13, "P1", parent: 12, tracks: [1])], tracks: [1])
        let linked = ["f": 10, "n": 11, "sub": 12, "p1": 13]
        let bindings = linked.mapValues { UsbSyncPlaylistBinding(usbID: $0, path: [], isFolder: $0 == 10 || $0 == 12) }
        var keys = ["k-f", "k-n", "k-sub", "k-p1"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["f"]),
                                        library: usb, matches: [1: "local-one"], badges: [:], bindings: bindings,
                                        linkedPlaylistIDs: linked, newKey: { keys.next()! })
        #expect(plan.playlistRefs == ["f": .new("k-f"), "n": .new("k-n"), "sub": .new("k-sub"), "p1": .new("k-p1")])
        #expect(plan.edits == [.playlist(edit: .create(key: "k-f", name: "F2", isFolder: true, parent: .root)),
                               .playlist(edit: .create(key: "k-n", name: "N", isFolder: false, parent: .new("k-f"))),
                               .playlist(edit: .create(key: "k-sub", name: "하위 폴더", isFolder: true, parent: .new("k-f"))),
                               .playlist(edit: .create(key: "k-p1", name: "P1", isFolder: false, parent: .new("k-sub"))),
                               .syncPlaylist(playlist: .new("k-p1"), localContentIDs: ["local-one"])])
        // 옛 폴더와 하위 목록 넷이 그대로 남아 곡도 계속 가리키므로 뺄 곡이 없다.
        #expect(plan.deletedPlaylists.isEmpty && plan.unlinkedPlaylistCount == 4 && plan.orphanTrackIDs.isEmpty)
        var count = 0
        let preview = try UsbSyncPlan.playlistPlan(desired: UsbSyncPlan.selectedLayout(source, selection: ITunesSyncSelection(selectedIDs: ["f"])),
                                                   library: usb, bindings: bindings, linkedPlaylistIDs: linked,
                                                   newKey: { count += 1; return "preview-\(count)" })
        #expect(["10", "11", "12", "13"].allSatisfy { preview.marks[$0] == .unlinked })
        #expect(preview.result.childIDs(of: "10") == ["11", "12"] && preview.result.childIDs(of: "12") == ["13"])
    }

    @Test("이름이 그대로인 폴더 안에서는 하위 목록을 새로 만들지 않는다")
    func unchangedFolderKeepsChildren() throws {
        let source = layout([item("f", "F", folder: true), item("n", "N", parent: "f")])
        let usb = library([playlist(10, "F", folder: true), playlist(11, "N", parent: 10)])
        let linked = ["f": 10, "n": 11]
        let bindings = linked.mapValues { UsbSyncPlaylistBinding(usbID: $0, path: [], isFolder: $0 == 10) }
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["f"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings, linkedPlaylistIDs: linked,
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.isEmpty && plan.playlistRefs == ["f": .id("10"), "n": .id("11")])
    }

    @Test("이름과 위치가 그대로면 저장한 연결의 USB 목록을 쓴다")
    func unchangedPathKeepsLinkedPlaylist() throws {
        let source = layout([item("local-list", "현재 목록")])
        let usb = library([playlist(11, "현재 목록")])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["예전 목록"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings,
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.isEmpty)
        #expect(plan.playlistRefs == ["local-list": .id("11")])
    }

    @Test("다른 원본에 이어진 USB 목록은 이름이 같아도 잇지 않는다")
    func playlistLinkedToAnotherSourceIsNotReused() throws {
        let source = layout([item("renamed", "같은 이름"), item("other", "다른 원본")])
        let usb = library([playlist(10, "같은 이름")])
        let bindings = ["other": UsbSyncPlaylistBinding(usbID: 10, path: ["같은 이름"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["renamed"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings, newKey: { "fresh" })
        #expect(plan.playlistRefs == ["renamed": .new("fresh")])
        #expect(plan.edits == [.playlist(edit: .create(key: "fresh", name: "같은 이름", isFolder: false, parent: .root))])
    }

    /// 2026-10-08 정상 USB 실험: 옮긴 원본은 SYNC 뒤 새 자리에만 보이고 옛 자리에 남지 않았다.
    @Test("이름이 같은 원본을 옮기면 이은 USB 목록을 새 자리로 옮기고 어느 목록에도 없는 곡만 뺄 곡으로 알린다")
    func movedSourceMovesLinkedPlaylistAndReportsOrphans() throws {
        let source = layout([item("new-parent", "새 폴더", folder: true),
                             item("local-list", "남길 목록", parent: "new-parent", tracks: ["local-one"])])
        let usb = library([playlist(10, "옛 폴더", folder: true),
                           playlist(11, "남길 목록", parent: 10, tracks: [1]),
                           playlist(12, "선택하지 않은 목록", parent: 10, order: 1, tracks: [2])],
                          tracks: [1, 2, 3, 4], history: [4])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["옛 폴더", "남길 목록"], isFolder: false)]
        var keys = ["folder-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [1: "local-one"], badges: [:], bindings: bindings,
                                        newKey: { keys.next()! })
        #expect(plan.edits == [.playlist(edit: .move(playlist: .id("11"), into: .root)),
                               .playlist(edit: .create(key: "folder-key", name: "새 폴더", isFolder: true, parent: .root)),
                               .playlist(edit: .move(playlist: .id("11"), into: .new("folder-key")))])
        #expect(plan.playlistRefs == ["new-parent": .new("folder-key"), "local-list": .id("11")])
        #expect(plan.unlinkedPlaylistCount == 2)
        #expect(plan.trackIDs == ["local-one"])
        // 3은 어느 목록에도 없다. 4는 재생 기록에 있어 곡 빼기가 막으므로 넣지 않는다. 곡 빼기는 확인 뒤 모델이 더한다.
        #expect(plan.orphanTrackIDs == [3])
        #expect(!plan.edits.contains { if case .removeTracks = $0 { true } else { false } })
    }

    @Test("선택 파일 행으로 이은 적 없는 USB 목록은 전체 해제해도 지우지 않는다")
    func clearingSelectionKeepsUsbPlaylists() throws {
        let usb = library([playlist(10, "폴더", folder: true),
                           playlist(11, "하위 목록", parent: 10, tracks: [1]),
                           playlist(20, "다른 목록", order: 1, tracks: [2])], tracks: [1, 2])
        let plan = try UsbSyncPlan.build(source: PlaylistLayout(), selection: ITunesSyncSelection(),
                                        library: usb, matches: [:], badges: [:], bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 3)
        #expect(plan.trackIDs.isEmpty && plan.orphanTrackIDs.isEmpty)
    }

    // MARK: - 2026-10-08 정상 USB 실험(장치 동기화 켜짐, 두 형식이 맞는 USB)

    @Test("선택에서 뺀 원본에 지난 선택 파일 행으로 이었던 USB 목록은 지우고 그 곡은 뺄 곡으로 알린다")
    func uncheckedLinkedPlaylistIsDeleted() throws {
        let source = layout([item("folder", "시험 폴더", folder: true),
                             item("x", "X", parent: "folder"),
                             item("y", "Y", tracks: ["local-two"])])
        let usb = library([playlist(10, "시험 폴더", folder: true),
                           playlist(11, "X", parent: 10),
                           playlist(12, "Y", order: 1, tracks: [2]),
                           playlist(13, "USB에만 있는 목록", order: 2, tracks: [3])], tracks: [2, 3])
        let linked = ["folder": 10, "x": 11, "y": 12]
        let bindings = linked.mapValues { UsbSyncPlaylistBinding(usbID: $0, path: [], isFolder: $0 == 10) }
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["folder"]),
                                        library: usb, matches: [2: "local-two"], badges: [:], bindings: bindings,
                                        linkedPlaylistIDs: linked, newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .delete(playlist: .id("12")))])
        #expect(plan.deletedPlaylists.map(\.id) == ["12"])
        // 이은 적 없는 USB 목록은 남는다. 지운 목록에만 있던 곡은 확인을 받고 뺄 곡이 된다.
        #expect(plan.unlinkedPlaylistCount == 1)
        #expect(plan.orphanTrackIDs == [2])
    }

    @Test("로컬에서 지운 원본의 USB 목록은 지우고 같은 이름의 새 원본에 잇지 않는다")
    func removedSourcePlaylistIsDeletedAndNotReused() throws {
        let source = layout([item("fresh", "X2")])
        let usb = library([playlist(11, "X2")])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["fresh"]),
                                        library: usb, matches: [:], badges: [:], bindings: [:],
                                        removedPlaylistIDs: [11], newKey: { "fresh-key" })
        #expect(plan.playlistRefs == ["fresh": .new("fresh-key")])
        #expect(plan.edits == [.playlist(edit: .create(key: "fresh-key", name: "X2", isFolder: false, parent: .root)),
                               .playlist(edit: .delete(playlist: .id("11")))])
    }

    @Test("지울 폴더 안에 연결 없는 목록이 남으면 폴더는 남기고 안의 이은 목록만 지운다")
    func folderWithUnlinkedChildStays() throws {
        // 시험 폴더(10)를 로컬에서 지웠다. 안에는 이름을 바꾸기 전의 옛 X(11, 연결 없음)와 지운 X2(12)가 있었다.
        let usb = library([playlist(10, "시험 폴더", folder: true),
                           playlist(11, "X", parent: 10),
                           playlist(12, "X2", parent: 10, order: 1)])
        let plan = try UsbSyncPlan.build(source: PlaylistLayout(), selection: ITunesSyncSelection(), library: usb,
                                        matches: [:], badges: [:], bindings: [:], removedPlaylistIDs: [10, 12],
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .delete(playlist: .id("12")))])
        #expect(plan.unlinkedPlaylistCount == 2)
    }

    @Test("지울 폴더 안이 모두 지울 목록이면 폴더 하나만 지운다")
    func fullyLinkedFolderIsDeletedOnce() throws {
        let source = layout([item("folder", "폴더", folder: true), item("a", "A", parent: "folder"),
                             item("sub", "하위", parent: "folder", folder: true), item("b", "B", parent: "sub")])
        let usb = library([playlist(10, "폴더", folder: true), playlist(11, "A", parent: 10),
                           playlist(12, "하위", parent: 10, folder: true, order: 1), playlist(13, "B", parent: 12)])
        let linked = ["folder": 10, "a": 11, "sub": 12, "b": 13]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(), library: usb, matches: [:],
                                        badges: [:], bindings: [:], linkedPlaylistIDs: linked, newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .delete(playlist: .id("10")))])
        #expect(plan.deletedPlaylists.map(\.id) == ["10"] && plan.unlinkedPlaylistCount == 0)
    }

    /// 2026-10-08 정상 USB 실험: 이름이 같은 원본을 옮기면 rekordbox처럼 이은 USB 폴더를 새 자리로 옮긴다
    @Test("A/B → B/A 재부모화: 이은 폴더를 작성 순서대로 옮기고, 막힘 묶음 검사는 그 순서로 얹은 트리로 본다")
    func folderReparentBatchUsesTheProjectedTree() throws {
        var usb = UsbLibrary.empty
        usb.formats = [.oneLibrary]
        usb.playlists = [
            .init(id: 10, name: "A", attribute: 1, presentIn: [.oneLibrary]),
            .init(id: 20, name: "B", parentID: 10, attribute: 1, presentIn: [.oneLibrary]),
        ]
        let source = layout([item("B", "B", folder: true), item("A", "A", parent: "B", folder: true)])
        var keys = ["B-key", "A-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]), library: usb,
                                        matches: [:], badges: [:], bindings: [
                                            "A": .init(usbID: 10, path: ["A"], isFolder: true),
                                            "B": .init(usbID: 20, path: ["A", "B"], isFolder: true),
                                        ], newKey: { keys.next()! })
        let reparent: [UsbLibraryEdit] = [
            .playlist(edit: .move(playlist: .id("20"), into: .root)),
            .playlist(edit: .move(playlist: .id("10"), into: .id("20"))),
        ]
        #expect(plan.edits == reparent)
        #expect(UsbEditRules.blockReason(plan.edits, volume: nil, library: usb, info: nil, isScratchMount: { _ in true }, syncGate: .open) == nil)
        // 순서를 바꾸면(아직 B가 A 안) 자기 안으로 옮기기, 되돌려 다시 넣으면 막힌다
        #expect(UsbEditRules.blockReason([reparent[1]], volume: nil, library: usb, info: nil, isScratchMount: { _ in true }, syncGate: .open) != nil)
        #expect(UsbEditRules.blockReason(reparent + [.playlist(edit: .move(playlist: .id("20"), into: .id("10")))],
                                         volume: nil, library: usb, info: nil, isScratchMount: { _ in true }, syncGate: .open) != nil)
    }

    @Test("옮긴 원본은 이은 목록을 새 자리로 옮기고 남은 폴더와 다른 목록은 그대로 둔다")
    func movedOutOfFolderKeepsFolder() throws {
        // Y를 시험 폴더 밖 맨 위로 옮겼다. 폴더와 X2는 계속 선택돼 있다.
        let source = layout([item("folder", "시험 폴더", folder: true), item("x2", "X2", parent: "folder"), item("y", "Y")])
        let usb = library([playlist(10, "시험 폴더", folder: true), playlist(11, "Y", parent: 10),
                           playlist(12, "X2", parent: 10, order: 1)])
        let linked = ["folder": 10, "y": 11, "x2": 12]
        let bindings = linked.mapValues { UsbSyncPlaylistBinding(usbID: $0, path: [], isFolder: $0 == 10) }
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]), library: usb,
                                        matches: [:], badges: [:], bindings: bindings, linkedPlaylistIDs: linked,
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .move(playlist: .id("11"), into: .root))])
        #expect(plan.deletedPlaylists.isEmpty && plan.unlinkedPlaylistCount == 0)
    }

    @Test("동기화 후 미리 보기는 새로 만든 목록·옮긴 목록·연결 없는 목록과 지울 목록을 쓰기 계획과 같게 보인다")
    func previewMarksMatchPlan() throws {
        let source = layout([item("folder", "시험 폴더", folder: true), item("x2", "X2", parent: "folder"), item("y", "Y")])
        let usb = library([playlist(10, "시험 폴더", folder: true), playlist(11, "X", parent: 10),
                           playlist(12, "Y", parent: 10, order: 1), playlist(13, "Z", order: 1)])
        let linked = ["folder": 10, "x2": 11, "y": 12, "z": 13]
        let bindings = linked.mapValues { UsbSyncPlaylistBinding(usbID: $0, path: [], isFolder: $0 == 10) }
        let desired = UsbSyncPlan.selectedLayout(source, selection: ITunesSyncSelection(selectedIDs: ["0"]))
        let preview = try UsbSyncPlan.playlistPlan(desired: desired, library: usb, bindings: bindings, linkedPlaylistIDs: linked,
                                                   newKey: { "renamed" })
        #expect(preview.marks == ["new:renamed": .created, "12": .moved, "11": .unlinked])
        #expect(preview.deleted.map(\.name) == ["Z"])
        #expect(preview.result.outline.map(\.id) == ["10", "11", "new:renamed", "12"])
    }

    @Test("이은 목록끼리만 원본 순서로 맞추고 남은 목록은 그 자리에 둔다")
    func reorderKeepsUnlinkedSlots() throws {
        let source = layout([item("b", "B"), item("a", "A")])
        let usb = library([playlist(10, "A"), playlist(11, "남은 목록", order: 1), playlist(12, "B", order: 2)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [:], badges: [:], bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .reorder(playlist: .id("12"), index: 0)),
                               .playlist(edit: .reorder(playlist: .id("11"), index: 1))])
    }

    @Test("USB의 맨 끝 생성 규칙을 반영해 필요한 재정렬만 계획한다")
    func newPlaylistsUseUsbAppendOrder() throws {
        let source = layout([item("before", "앞 목록"), item("kept", "기존 목록"), item("after", "뒤 목록")])
        let usb = library([playlist(10, "기존 목록")])
        var keys = ["before-key", "after-key"].makeIterator()
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [:], badges: [:], bindings: [:],
                                        newKey: { keys.next()! })
        #expect(plan.edits == [.playlist(edit: .create(key: "before-key", name: "앞 목록", isFolder: false, parent: .root)),
                               .playlist(edit: .create(key: "after-key", name: "뒤 목록", isFolder: false, parent: .root)),
                               .playlist(edit: .reorder(playlist: .new("before-key"), index: 0))])
    }

    @Test("선택한 로컬 목록의 같은 경로가 중복이면 전체 계획을 거부한다")
    func duplicateLocalPathsAreRejected() {
        let source = layout([item("one", "중복 이름"), item("two", "중복 이름")])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                  library: library([]), matches: [:], badges: [:], bindings: [:],
                                  newKey: { "sync-" + UUID().uuidString.lowercased() })
        }
    }

    @Test("이름으로 이어야 하는데 USB에 같은 경로가 여럿이면 전체 계획을 거부한다")
    func duplicateUsbPathsAreRejectedWithoutBinding() {
        let source = layout([item("local-list", "중복 이름")])
        let usb = library([playlist(10, "중복 이름"), playlist(11, "중복 이름", order: 1)])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                  library: usb, matches: [:], badges: [:], bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        }
    }

    @Test("이어진 목록이 있으면 USB의 같은 이름 목록이 남아 있어도 그 목록을 쓴다")
    func linkedPlaylistWinsOverDuplicateNames() throws {
        let source = layout([item("local-list", "중복 이름")])
        let usb = library([playlist(10, "중복 이름"), playlist(11, "중복 이름", order: 1)])
        let bindings = ["local-list": UsbSyncPlaylistBinding(usbID: 11, path: ["중복 이름"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["local-list"]),
                                        library: usb, matches: [:], badges: [:], bindings: bindings,
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.playlistRefs == ["local-list": .id("11")])
        #expect(plan.edits.isEmpty)
    }

    @Test("선택하지 않은 USB 목록의 이름이 겹쳐도 남겨 두고 막지 않는다")
    func duplicateUnselectedUsbPathsAreKept() throws {
        let source = layout([item("kept", "남길 목록")])
        let usb = library([playlist(10, "남길 목록"), playlist(20, "중복 이름", order: 1), playlist(21, "중복 이름", order: 2)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["kept"]),
                                         library: usb, matches: [:], badges: [:], bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 2)
    }

    @Test("같은 경로의 폴더와 일반 목록은 자동으로 바꾸지 않는다")
    func mismatchedPlaylistTypesAreRejected() {
        let source = layout([item("folder", "같은 이름", folder: true)])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["folder"]),
                                  library: library([playlist(10, "같은 이름")]), matches: [:], badges: [:], bindings: [:],
                                  newKey: { "sync-" + UUID().uuidString.lowercased() })
        }
    }

    @Test("두 로컬 목록이 하나의 USB ID에 이어져 있어도 한 USB 목록은 한 원본에만 잇는다")
    func duplicateStoredPlaylistPairLinksOnce() throws {
        let source = layout([item("one", "USB 목록"), item("two", "목록 둘")])
        let bindings = ["one": UsbSyncPlaylistBinding(usbID: 10, path: ["USB 목록"], isFolder: false),
                        "two": UsbSyncPlaylistBinding(usbID: 10, path: ["USB 목록"], isFolder: false)]
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: library([playlist(10, "USB 목록")]), matches: [:], badges: [:], bindings: bindings,
                                        newKey: { "two-key" })
        #expect(plan.playlistRefs == ["one": .id("10"), "two": .new("two-key")])
    }

    @Test("선택한 로컬 곡의 USB 짝이 여럿이면 전체 계획을 거부한다")
    func ambiguousTrackPairIsRejected() {
        let source = layout([item("one", "목록", tracks: ["local-one"])])
        let usb = library([playlist(10, "목록", tracks: [1])])
        #expect(throws: PlaylistLayout.Blocked.self) {
            try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                  library: usb, matches: [1: "local-one", 2: "local-one"], badges: [:], bindings: [:],
                                  newKey: { "sync-" + UUID().uuidString.lowercased() })
        }
    }

    @Test("로컬에서 바뀐 필드만 갱신하고 같은 목록 내용을 다시 쓰지 않는다", arguments: [
        (Set<UsbSyncStatus.Field>([.information]), Set<UsbRefreshPart>([.info, .artwork])),
        (Set<UsbSyncStatus.Field>([.analysis]), Set<UsbRefreshPart>([.grid])),
        (Set<UsbSyncStatus.Field>([.cue]), Set<UsbRefreshPart>([.cues])),
        (Set<UsbSyncStatus.Field>([.analysis, .cue]), Set<UsbRefreshPart>([.grid, .cues])),
    ])
    func localNewerTracksAreRefreshed(fields: Set<UsbSyncStatus.Field>, parts: Set<UsbRefreshPart>) throws {
        let source = layout([item("one", "목록", tracks: ["local-one", "local-two"])])
        let usb = library([playlist(10, "목록", tracks: [1, 2])])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two"],
                                        badges: [1: .localNewer(fields), 2: .deviceModified], bindings: [:],
                                        newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.refreshTracks(usbContentIDs: [1], parts: parts)])
    }

    @Test("같은 변경 필드의 곡을 묶고 서로 다른 변경 부분은 섞지 않는다")
    func refreshGroupsKeepChangedPartsSeparate() throws {
        let source = layout([item("one", "목록", tracks: ["local-one", "local-two", "local-three"])])
        let usb = library([playlist(10, "목록", tracks: [1, 2, 3])])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two", 3: "local-three"],
                                        badges: [1: .localNewer([.cue]), 2: .localNewer([.cue]), 3: .localNewer([.analysis])],
                                        bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.count == 2)
        #expect(Set(plan.edits) == [.refreshTracks(usbContentIDs: [1, 2], parts: [.cues]),
                                  .refreshTracks(usbContentIDs: [3], parts: [.grid])])
    }

    @Test("트리·목록 내용·갱신 상태가 같으면 편집을 만들지 않는다")
    func identicalLibraryNeedsNoEdits() throws {
        let source = layout([item("folder", "폴더", folder: true),
                             item("one", "목록 하나", parent: "folder", tracks: ["local-one", "local-two"]),
                             item("two", "목록 둘", parent: "folder")])
        let usb = library([playlist(10, "폴더", folder: true),
                           playlist(11, "목록 하나", parent: 10, tracks: [1, 2]),
                           playlist(12, "목록 둘", parent: 10, order: 1)])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["0"]),
                                        library: usb, matches: [1: "local-one", 2: "local-two"],
                                        badges: [1: .upToDate, 2: .upToDate], bindings: [:], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits.isEmpty)
        #expect(plan.unlinkedPlaylistCount == 0)
        #expect(plan.trackIDs == ["local-one", "local-two"])
    }
    // MARK: - PR #235 리뷰

    /// 두 형식의 항목이 다른 USB: OneLibrary 항목만 보면 Device Library 항목에만 든 곡을 고아로 보고 모든 형식에서 지웠다.
    @Test("한 형식의 항목에만 든 곡은 뺄 곡으로 보지 않고, 형식마다 다른 이은 목록은 맞추도록 남긴다")
    func entriesOfEveryFormatKeepTracks() throws {
        let source = layout([item("one", "이은 목록", tracks: ["local-one"])])
        var linked = playlist(10, "이은 목록", tracks: [1])
        linked.entries[.deviceLibrary] = [1, 2]
        var unlinked = playlist(20, "남는 목록", order: 1, tracks: [])
        unlinked.entries[.deviceLibrary] = [3]
        let usb = library([linked, unlinked], tracks: [1, 2, 3, 4])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(selectedIDs: ["one"]),
                                        library: usb, matches: [1: "local-one"], badges: [:],
                                        bindings: ["one": UsbSyncPlaylistBinding(usbID: 10, path: ["이은 목록"], isFolder: false)],
                                        linkedPlaylistIDs: ["one": 10], newKey: { "sync-" + UUID().uuidString.lowercased() })
        // 2는 형식마다 다른 이은 목록(곡 맞추기가 막힐 수 있다)의 Device Library에, 3은 남는 목록의 Device Library에만 있다.
        #expect(plan.orphanTrackIDs == [4])
        // OneLibrary 항목이 같아도 Device Library 항목이 달라 맞추기 편집을 만든다.
        #expect(plan.edits.contains(.syncPlaylist(playlist: .id("10"), localContentIDs: ["local-one"])))
    }

    /// 선택을 모두 해제하면 모든 곡이 고아가 되어 곡 빼기가 `lastTrack`으로 막히고 묶음 전체가 쓰이지 않았다.
    @Test("뺄 곡을 빼면 USB에 곡이 하나도 남지 않을 때는 곡 빼기만 하지 않고 목록 지우기는 계획한다")
    func orphansThatWouldEmptyUsbAreKept() throws {
        let source = layout([item("one", "이은 목록", tracks: ["local-one"])])
        let usb = library([playlist(10, "이은 목록", tracks: [1, 2])], tracks: [1, 2])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(),
                                        library: usb, matches: [1: "local-one"], badges: [:],
                                        bindings: ["one": UsbSyncPlaylistBinding(usbID: 10, path: ["이은 목록"], isFolder: false)],
                                        linkedPlaylistIDs: ["one": 10], newKey: { "sync-" + UUID().uuidString.lowercased() })
        #expect(plan.edits == [.playlist(edit: .delete(playlist: .id("10")))])
        #expect(plan.orphanTrackIDs.isEmpty)
        #expect(plan.keptOrphanTrackIDs == [1, 2])
    }

    @Test("한 형식에만 있는 곡이 다 빠져 그 형식이 비게 되어도 곡 빼기만 하지 않는다")
    func orphansThatWouldEmptyOneFormatAreKept() throws {
        var only = UsbTrack(id: 3)
        only.presentIn = [.oneLibrary]
        var usb = library([playlist(10, "이은 목록", tracks: [1, 2]), playlist(20, "남는 목록", order: 1, tracks: [3])],
                          tracks: [1, 2])
        usb.tracks.append(only)
        let source = layout([item("one", "이은 목록")])
        let plan = try UsbSyncPlan.build(source: source, selection: ITunesSyncSelection(),
                                        library: usb, matches: [:], badges: [:], bindings: [:],
                                        linkedPlaylistIDs: ["one": 10], newKey: { "sync-" + UUID().uuidString.lowercased() })
        // Device Library에는 1·2뿐이라 둘을 빼면 그 형식에 곡이 남지 않는다.
        #expect(plan.orphanTrackIDs.isEmpty && plan.keptOrphanTrackIDs == [1, 2])
    }
}

/// 고아 판정(앱의 짝)과 쓰기 계획(`UsbEditPlanner.localPairs`)이 같은 규칙으로 곡을 짝짓는지
@Suite("USB 동기화 곡 짝짓기 규칙")
struct UsbSyncPairingRuleTests {
    /// 다른 라이브러리에서 가져온 곡처럼 로컬 행의 MasterDBID가 이 라이브러리 DBID와 다르다.
    /// 내보내기·쓰기 계획은 그 행의 MasterDBID로 USB 곡과 잇는다.
    @Test("로컬 행의 MasterDBID로 짝짓고 이 라이브러리 DBID로 짝짓지 않는다")
    func pairsByRowMasterDBID() {
        let local = LocalLibraryKeys(localDBID: 100,
                                     tracks: [.init(contentID: "imported", masterSongID: "10", fileNameL: "a.mp3"),
                                              .init(contentID: "native", masterSongID: "20", fileNameL: "b.mp3")],
                                     counters: [:], masterDBIDs: ["imported": 200, "native": 100])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "a.mp3", masterDbId: 200, masterContentId: 10),
                          .init(id: 2, fileName: "a.mp3", masterDbId: 100, masterContentId: 10),
                          .init(id: 3, fileName: "b.mp3", masterDbId: 100, masterContentId: 20)]
        let matches = UsbSyncBadges.evaluate(library: library, local: local).matches
        #expect(matches == [1: "imported", 3: "native"])
    }

    @Test("MasterDBID를 모르는 행은 이 라이브러리 DBID로 본다")
    func missingMasterDBIDFallsBackToLocal() {
        let local = LocalLibraryKeys(localDBID: 100, tracks: [.init(contentID: "one", masterSongID: "10", fileNameL: "a.mp3")],
                                     counters: [:])
        var library = UsbLibrary.empty
        library.tracks = [.init(id: 1, fileName: "a.mp3", masterDbId: 100, masterContentId: 10)]
        #expect(UsbSyncBadges.evaluate(library: library, local: local).matches == [1: "one"])
    }
}

