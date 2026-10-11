import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 합성 선택 파일(값은 모두 지어낸 것). 칸 모양은 2026-10-08 rekordbox 7.2.x 전후 실험에서 본 규칙을 따른다.
struct UsbSyncSelectionFileTests {
    /// 부호 없는 32비트로 읽힌 로컬 DBID. 선택 파일에는 같은 비트의 음수로 적힌다.
    static let localDBID: Int64 = 4_000_000_000
    static let fileDBID = "-294967296"

    /// rekordbox가 쓰는 모양 그대로의 합성 파일. 행이 없으면 `  <Playlists/>`다(2026-10-08 빈 USB 실험의 173바이트 파일).
    static func file(_ nodes: [String], dbid: String = fileDBID, automaticSync: String = "0") -> Data {
        let playlists = nodes.isEmpty ? ["  <Playlists/>"] : ["  <Playlists>"] + nodes.map { "    " + $0 } + ["  </Playlists>"]
        let lines = [#"<?xml version="1.0" encoding="UTF-8"?>"#, "",
                     #"<Sync DBID="\#(dbid)" AutomaticSync="\#(automaticSync)" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0">"#]
            + playlists + ["</Sync>"]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func node(_ id: String, parent: String = "0", folder: Bool = false, library: Int = 1, device: Int, timestamp: Int64 = 0,
                     check: Int = 1) -> String {
        #"<NODE Id="\#(id)" ParentId="\#(parent)" Attribute="\#(folder ? 1 : 0)" Lib_Type="\#(library)" Dev_ID="\#(device)" Timestamp="\#(timestamp)" CheckType="\#(check)"/>"#
    }

    static let xml = file([
        node("0", folder: true, device: 0, check: 2),
        node("F", folder: true, device: 1),
        node("A", parent: "F", device: 2),
    ])
    static let source: [UsbSyncSourceNode] = [
        .init(id: "itunes:F", parentID: nil, isFolder: true, timestamp: 0),
        .init(id: "itunes:A", parentID: "itunes:F", isFolder: false, timestamp: 0),
        .init(id: "itunes:B", parentID: "itunes:F", isFolder: false, timestamp: 0),
        .init(id: "itunes:C", parentID: nil, isFolder: false, timestamp: 0),
    ]
    static let usbIDs: [UsbFormat: Set<Int>] = [.deviceLibrary: [1, 2], .oneLibrary: [1, 2]]

    @Test func 명시한_폴더를_복원하며_새_하위_목록도_선택된다() throws {
        let file = try UsbSyncSelectionFile.parse(Self.xml)
        #expect(file.isCanonical)
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: file])
        let result = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID, usbPlaylistIDs: Self.usbIDs)
        #expect(result.issues.isEmpty)
        #expect(result.selection.selectedIDs == ["itunes:F", "itunes:A"])
        #expect(result.selection.expandedIDs(in: Self.source.map(\.selectionNode)).contains("itunes:B"))
        #expect(result.playlistIDs == ["itunes:F": 1, "itunes:A": 2])
        #expect(result.enabled == false)
        #expect(file.data == Self.xml)
    }

    @Test func 루트_DBID는_부호_있는_32비트로_읽고_로컬_DBID와_비트_모양으로_견준다() throws {
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(Self.xml)])
        // 로컬 DBID가 음수로 읽혀도 같은 32비트면 같은 라이브러리다.
        for local in [Self.localDBID, Int64(Int32(truncatingIfNeeded: Self.localDBID))] {
            #expect(bundle.resolution(sourceNodes: Self.source, localDBID: local, usbPlaylistIDs: Self.usbIDs).issues.isEmpty)
        }
        for local: Int64 in [42, Self.localDBID + (1 << 32), -1] {
            #expect(bundle.resolution(sourceNodes: Self.source, localDBID: local).issues == [.databaseMismatch])
        }
        #expect(UsbSyncSelectionXML.databaseID(Self.localDBID) == Self.fileDBID)
        #expect(UsbSyncSelectionXML.databaseID(42) == "42")
        #expect(UsbSyncSelectionXML.databaseID(Int64(UInt32.max) + 1) == nil)
        // 16진수·32비트 밖·빈 부호는 rekordbox 표기가 아니다.
        for dbid in ["2A", "2147483648", "-2147483649", "-", "+42", "0x10"] {
            #expect(throws: UsbSyncSelectionFile.ParseError.invalidFile) {
                try UsbSyncSelectionFile.parse(Self.file([Self.node("0", folder: true, device: 0)], dbid: dbid))
            }
        }
        #expect(try UsbSyncSelectionFile.parse(Self.file([], dbid: "-2147483648")).rootAttributes["DBID"] == "-2147483648")
    }

    @Test func 원본별_전체_선택은_그룹_선택으로_보존된다() throws {
        let text = String(decoding: Self.xml, as: UTF8.self).replacingOccurrences(of: "CheckType=\"2\"", with: "CheckType=\"1\"")
        let result = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(Data(text.utf8))])
            .resolution(sourceNodes: Self.source, localDBID: Self.localDBID, usbPlaylistIDs: Self.usbIDs)
        #expect(result.selection.selectedIDs.contains(UsbSyncSourceNode.iTunesSelectionID))
    }

    @Test func 두_형식의_선택이나_라이브러리가_다르면_합치지_않는다() throws {
        let file = try UsbSyncSelectionFile.parse(Self.xml)
        let different = try UsbSyncSelectionFile.parse(Data(String(decoding: Self.xml, as: UTF8.self)
            .replacingOccurrences(of: "Dev_ID=\"1\" Timestamp=\"0\" CheckType=\"1\"", with: "Dev_ID=\"1\" Timestamp=\"0\" CheckType=\"2\"").utf8))
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: file, .oneLibrary: different])
        #expect(bundle.semanticFingerprint == nil)
        #expect(bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID).issues.contains(.formatConflict))
        #expect(UsbSyncSelectionBundle(files: [.deviceLibrary: file])
            .resolution(sourceNodes: Self.source, localDBID: 43).issues.contains(.databaseMismatch))
    }

    @Test func 형식마다_Dev_ID가_달라도_선택은_같고_번호는_형식별로_남는다() throws {
        let deviceLibrary = try UsbSyncSelectionFile.parse(Self.xml)
        let oneLibrary = try UsbSyncSelectionFile.parse(Data(String(decoding: Self.xml, as: UTF8.self)
            .replacingOccurrences(of: "Dev_ID=\"2\"", with: "Dev_ID=\"3\"").utf8))
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: deviceLibrary, .oneLibrary: oneLibrary])
        #expect(bundle.semanticFingerprint != nil)
        let result = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID,
                                       usbPlaylistIDs: [.deviceLibrary: [1, 2], .oneLibrary: [1, 3]])
        #expect(result.issues.isEmpty)
        #expect(result.selection.selectedIDs == ["itunes:F", "itunes:A"])
        #expect(result.formatPlaylistIDs[.deviceLibrary] == ["itunes:F": 1, "itunes:A": 2])
        #expect(result.formatPlaylistIDs[.oneLibrary] == ["itunes:F": 1, "itunes:A": 3])
        // 두 형식이 다른 목록을 가리키는 원본은 한 USB 목록에 잇지 않는다.
        #expect(result.playlistIDs == ["itunes:F": 1])
        // Dev_ID는 그 형식 DB의 번호와 견준다.
        let wrong = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID,
                                      usbPlaylistIDs: [.deviceLibrary: [1, 2], .oneLibrary: [1, 2]])
        #expect(wrong.issues.contains(.deviceIDAmbiguous))
    }

    /// #233: rekordbox가 두 형식에 다른 번호를 준 같은 목록(OneLibrary 3 = Device Library 2)은 합친 모델의 대표 번호로 잇는다
    @Test func 형식_번호가_달라도_같은_USB_목록이면_대표_번호로_잇는다() throws {
        let deviceLibrary = try UsbSyncSelectionFile.parse(Self.xml)
        let oneLibrary = try UsbSyncSelectionFile.parse(Data(String(decoding: Self.xml, as: UTF8.self)
            .replacingOccurrences(of: "Dev_ID=\"2\"", with: "Dev_ID=\"3\"").utf8))
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: deviceLibrary, .oneLibrary: oneLibrary])
        var model = UsbLibrary.empty
        model.formats = UsbFormat.defaultSet
        model.playlists = [
            UsbPlaylist(id: 1, name: "합성 폴더", attribute: 1, presentIn: UsbFormat.defaultSet),
            UsbPlaylist(id: 3, name: "합성 목록", parentID: 1, presentIn: UsbFormat.defaultSet, formatIDs: [.deviceLibrary: 2]),
        ]
        #expect(UsbSyncSelectionBundle.playlistIDs(of: model) == [.deviceLibrary: [1, 2], .oneLibrary: [1, 3]])
        #expect(UsbSyncSelectionBundle.representatives(of: model) == [.deviceLibrary: [1: 1, 2: 3], .oneLibrary: [1: 1, 3: 3]])
        let result = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID,
                                       usbPlaylistIDs: UsbSyncSelectionBundle.playlistIDs(of: model),
                                       representatives: UsbSyncSelectionBundle.representatives(of: model))
        #expect(result.issues.isEmpty)
        #expect(result.formatPlaylistIDs[.deviceLibrary] == ["itunes:F": 1, "itunes:A": 2])
        #expect(result.formatPlaylistIDs[.oneLibrary] == ["itunes:F": 1, "itunes:A": 3])
        #expect(result.playlistIDs == ["itunes:F": 1, "itunes:A": 3])

        // 형식 번호가 같아도 대표 번호가 다르면(같은 번호의 다른 목록) 잇지 않는다
        model.playlists = [
            UsbPlaylist(id: 1, name: "합성 폴더", attribute: 1, presentIn: UsbFormat.defaultSet),
            UsbPlaylist(id: -2, name: "합성 장치 목록", parentID: 1, presentIn: [.deviceLibrary], formatIDs: [.deviceLibrary: 2]),
            UsbPlaylist(id: 3, name: "합성 목록", parentID: 1, presentIn: UsbFormat.defaultSet, formatIDs: [.deviceLibrary: 5]),
            UsbPlaylist(id: 2, name: "합성 다른 목록", parentID: 1, presentIn: [.oneLibrary]),
        ]
        let same = UsbSyncSelectionBundle(files: [.deviceLibrary: deviceLibrary, .oneLibrary: deviceLibrary])
        let apart = same.resolution(sourceNodes: Self.source, localDBID: Self.localDBID,
                                    representatives: UsbSyncSelectionBundle.representatives(of: model))
        #expect(apart.issues.isEmpty)
        #expect(apart.playlistIDs == ["itunes:F": 1])
    }

    @Test func DTD_중복_순환_잘못된_숫자와_로컬_동기화_형식을_거부한다() {
        let text = String(decoding: Self.xml, as: UTF8.self)
        for candidate in [
            "<!DOCTYPE Sync [<!ENTITY external SYSTEM 'file:///never-open'>]>" + text,
            text.replacingOccurrences(of: "Id=\"A\"", with: "Id=\"F\""),
            text.replacingOccurrences(of: "Id=\"F\" ParentId=\"0\"", with: "Id=\"F\" ParentId=\"F\""),
            text.replacingOccurrences(of: "Dev_ID=\"2\" Timestamp=\"0\"", with: "Dev_ID=\"2\" Timestamp=\"-1\""),
            text.replacingOccurrences(of: "Dev_ID=\"2\"", with: "Dev_ID=\"A\""),
            "<SYNC_ITUNES_PLAYLIST Version='3.0.0'><PLAYLISTS/></SYNC_ITUNES_PLAYLIST>",
        ] {
            #expect(throws: (any Error).self) { try UsbSyncSelectionFile.parse(Data(candidate.utf8)) }
        }
    }

    @Test func rekordbox_원본_Id는_16진수로_카탈로그와_맞춘다() throws {
        // Id "11"은 16진수라 원본 17번이다. 10진수 11번 원본에 잇지 않는다.
        let data = Self.file([
            Self.node("0", folder: true, library: 0, device: 0, check: 2),
            Self.node("11", folder: true, library: 0, device: 5, timestamp: 100, check: 2),
            Self.node("12", parent: "11", library: 0, device: 6, timestamp: 100),
        ])
        let source: [UsbSyncSourceNode] = [
            .init(id: "11", parentID: nil, isFolder: true), .init(id: "12", parentID: "11", isFolder: false),
            .init(id: "17", parentID: nil, isFolder: true), .init(id: "18", parentID: "17", isFolder: false),
        ]
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(data)])
        let result = bundle.resolution(sourceNodes: source, localDBID: Self.localDBID, usbPlaylistIDs: [.deviceLibrary: [5, 6]])
        #expect(result.issues.isEmpty)
        #expect(result.selection.selectedIDs == ["18"])
        #expect(result.playlistIDs == ["17": 5, "18": 6])
        let missing = bundle.resolution(sourceNodes: Array(source.prefix(2)), localDBID: Self.localDBID)
        #expect(missing.issues.contains(.sourceMissing) && missing.selection.selectedIDs.isEmpty && !missing.canWrite)
    }

    /// 2026-10-08 정상 USB 실험: 체크한 원본을 지우거나 옮겨도 rekordbox는 SYNC 전까지 선택 파일 행을 그대로 둔다.
    /// 지운 원본은 종료 때 masterPlaylists6.xml에서도 빠지고, SYNC가 그 행의 USB 목록을 지운다.
    @Test func 지운_rekordbox_원본의_행은_master에도_없을_때만_지울_USB_목록으로_돌려준다() throws {
        let data = Self.file([
            Self.node("0", folder: true, library: 0, device: 0, check: 2),
            Self.node("11", folder: true, library: 0, device: 5, timestamp: 100, check: 2),
            Self.node("12", parent: "11", library: 0, device: 6, timestamp: 100),
            Self.node("13", parent: "11", library: 0, device: 7, timestamp: 100),
        ])
        let source: [UsbSyncSourceNode] = [.init(id: "17", parentID: nil, isFolder: true), .init(id: "18", parentID: "17", isFolder: false)]
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(data), .oneLibrary: try .parse(data)])
        let ids: [UsbFormat: Set<Int>] = [.deviceLibrary: [5, 6, 7], .oneLibrary: [5, 6, 7]]
        // 원본 19(16진 13)를 로컬에서 지웠다. master에도 없다.
        let removed = bundle.resolution(sourceNodes: source, localDBID: Self.localDBID, usbPlaylistIDs: ids, masterNodeIDs: ["11", "12"])
        #expect(removed.issues.isEmpty)
        #expect(removed.selection.selectedIDs == ["18"])
        #expect(removed.playlistIDs == ["17": 5, "18": 6])
        #expect(removed.removedSourcePlaylistIDs == [7])
        // 지운 원본의 USB 목록이 이미 없으면 지울 것이 없고 막지도 않는다.
        let gone = bundle.resolution(sourceNodes: source, localDBID: Self.localDBID,
                                     usbPlaylistIDs: [.deviceLibrary: [5, 6], .oneLibrary: [5, 6]], masterNodeIDs: ["11", "12"])
        #expect(gone.issues.isEmpty && gone.removedSourcePlaylistIDs.isEmpty && gone.playlistIDs == ["17": 5, "18": 6])
        // master에 남아 있으면 로컬 사본이 오래된 것일 수 있어 지우지 않고 막는다. master를 못 읽어도 막는다.
        for master in [Set(["11", "12", "13"]), nil] {
            let stale = bundle.resolution(sourceNodes: source, localDBID: Self.localDBID, usbPlaylistIDs: ids, masterNodeIDs: master)
            #expect(stale.issues.contains(.sourceMissing) && stale.removedSourcePlaylistIDs.isEmpty && !stale.canWrite)
        }
        // iTunes 원본은 iTunes 목록을 못 읽은 것과 구분할 수 없어 늘 막는다.
        let iTunes = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(Self.xml)])
        let missing = iTunes.resolution(sourceNodes: [.init(id: "itunes:F", parentID: nil, isFolder: true)], localDBID: Self.localDBID,
                                        usbPlaylistIDs: Self.usbIDs, masterNodeIDs: [])
        #expect(missing.issues.contains(.sourceMissing))
        // 두 형식의 번호가 다르면 어느 목록인지 몰라 지울 대상에 넣지 않는다.
        let other = Self.file([
            Self.node("0", folder: true, library: 0, device: 0, check: 2),
            Self.node("11", folder: true, library: 0, device: 5, timestamp: 100, check: 2),
            Self.node("12", parent: "11", library: 0, device: 6, timestamp: 100),
            Self.node("13", parent: "11", library: 0, device: 8, timestamp: 100),
        ])
        let diverged = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(data), .oneLibrary: try .parse(other)])
        let result = diverged.resolution(sourceNodes: source, localDBID: Self.localDBID,
                                         usbPlaylistIDs: [.deviceLibrary: [5, 6, 7], .oneLibrary: [5, 6, 8]], masterNodeIDs: ["11", "12"])
        #expect(result.issues.isEmpty && result.removedSourcePlaylistIDs.isEmpty)
    }

    @Test func 옮긴_원본은_행의_부모가_달라도_체크와_연결을_유지한다() throws {
        // 폴더 17 안에 있던 18을 맨 위로 옮겼다(행은 SYNC 전까지 옛 부모를 가리킨다).
        let data = Self.file([
            Self.node("0", folder: true, library: 0, device: 0, check: 2),
            Self.node("11", folder: true, library: 0, device: 5, timestamp: 100, check: 1),
            Self.node("12", parent: "11", library: 0, device: 6, timestamp: 100),
        ])
        let source: [UsbSyncSourceNode] = [.init(id: "17", parentID: nil, isFolder: true), .init(id: "18", parentID: nil, isFolder: false)]
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(data)])
        let result = bundle.resolution(sourceNodes: source, localDBID: Self.localDBID, usbPlaylistIDs: [.deviceLibrary: [5, 6]])
        #expect(result.issues.isEmpty)
        #expect(result.selection.selectedIDs == ["17", "18"])
        #expect(result.playlistIDs == ["17": 5, "18": 6])
        // 목록이던 원본이 폴더가 되면 여전히 막는다.
        let changed = bundle.resolution(sourceNodes: [source[0], .init(id: "18", parentID: nil, isFolder: true)],
                                        localDBID: Self.localDBID, usbPlaylistIDs: [.deviceLibrary: [5, 6]])
        #expect(changed.issues.contains(.sourceStructure))
    }

    @Test func 허용한_두_파일만_읽고_부모나_파일_링크를_거부한다() throws {
        let fixture = UsbTreeFixture()
        let outside = UsbTreeFixture()
        defer { fixture.remove(); outside.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", String(decoding: Self.xml, as: UTF8.self))
        fixture.write("PIONEER/rekordbox/playlists3Plus.sync", String(decoding: Self.xml, as: UTF8.self))
        fixture.write("PIONEER/extracted/never-open", "unused")
        let fs = FaultyUsbFileSystem(root: fixture.root.url)
        let bundle = try UsbSyncSelectionBundle.read(root: fixture.root, formats: UsbFormat.defaultSet, fileSystem: fs)
        #expect(bundle.files.count == 2)
        #expect(fs.calls.allSatisfy { !$0.contains("extracted") && !$0.hasPrefix("list ") })
        outside.write("selection.xml", String(decoding: Self.xml, as: UTF8.self))
        let target = fixture.url("PIONEER/rekordbox/playlists3.sync")
        try FileManager.default.removeItem(at: target)
        fixture.symlink("PIONEER/rekordbox/playlists3.sync", to: outside.url("selection.xml").path)
        #expect(throws: (any Error).self) { try UsbSyncSelectionBundle.read(root: fixture.root, formats: [.deviceLibrary]) }
    }

    @Test func 복사_중_선택이_바뀌면_원문을_반환하지_않는다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        fixture.write("PIONEER/rekordbox/playlists3.sync", String(decoding: Self.xml, as: UTF8.self))
        let fs = FaultyUsbFileSystem(root: fixture.root.url)
        var reads = 0
        fs.onOperation = { op, url in
            if op == .read {
                reads += 1
                if reads == 2 { try? (Self.xml + Data("\n".utf8)).write(to: url) }
            }
        }
        #expect(throws: (any Error).self) {
            try UsbSyncSelectionBundle.read(root: fixture.root, formats: [.deviceLibrary], fileSystem: fs)
        }
    }

    @Test func 파일이_없으면_아직_저장한_선택과_켜짐_상태가_없다() throws {
        let fixture = UsbTreeFixture()
        defer { fixture.remove() }
        let bundle = try UsbSyncSelectionBundle.read(root: fixture.root, formats: UsbFormat.defaultSet)
        let resolution = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID)
        #expect(bundle.baseFiles.isEmpty && bundle.semanticFingerprint == nil)
        #expect(resolution.enabled == nil && resolution.selection.selectedIDs.isEmpty && resolution.issues.isEmpty)
    }

    @Test func USB_번호가_그_형식에_없으면_체크는_보이고_쓰기는_막힌다() throws {
        let text = String(decoding: Self.xml, as: UTF8.self).replacingOccurrences(of: "Dev_ID=\"2\"", with: "Dev_ID=\"10\"")
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(Data(text.utf8))])
        let result = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID, usbPlaylistIDs: Self.usbIDs)
        #expect(result.selection.selectedIDs == ["itunes:F", "itunes:A"])
        #expect(result.issues.contains(.deviceIDAmbiguous) && !result.canWrite)
        #expect(result.enabled == false)
    }

    @Test func 두_형식의_켜짐이_충돌하면_어느_값도_반환하지_않는다() throws {
        let off = try UsbSyncSelectionFile.parse(Self.xml)
        let on = try UsbSyncSelectionFile.parse(Self.file([
            Self.node("0", folder: true, device: 0, check: 2), Self.node("F", folder: true, device: 1), Self.node("A", parent: "F", device: 2),
        ], automaticSync: "1"))
        let pairs: [[UsbFormat: UsbSyncSelectionFile]] = [
            [.deviceLibrary: off, .oneLibrary: on], [.deviceLibrary: on, .oneLibrary: off],
        ]
        for files in pairs {
            let result = UsbSyncSelectionBundle(files: files).resolution(sourceNodes: Self.source, localDBID: Self.localDBID)
            #expect(result.issues.contains(.formatConflict) && result.enabled == nil)
        }
    }

    @Test func 숫자_경계와_NODE_안의_주석은_강제_해제_없이_읽는다() throws {
        for id in ["FFFFFFFFFFFFFFFF", "10000000000000"] {
            let nodes = [Self.node("0", folder: true, library: 0, device: 0),
                         #"<NODE Id="\#(id)" ParentId="0" Attribute="0" Lib_Type="0" Dev_ID="1" Timestamp="100" CheckType="1"><!--합성 메타--></NODE>"#]
            let file = try UsbSyncSelectionFile.parse(Self.file(nodes))
            #expect(file.nodes.last?.id == id)
            // 주석이 든 원문은 rekordbox 모양이 아니라 고쳐 쓰지 않는다.
            #expect(!file.isCanonical)
        }
        for id in ["10000000000000000", "１００", "G1"] {
            let nodes = [Self.node("0", folder: true, library: 0, device: 0), Self.node(id, library: 0, device: 1, timestamp: 100)]
            #expect(throws: UsbSyncSelectionFile.ParseError.invalidFile) { try UsbSyncSelectionFile.parse(Self.file(nodes)) }
        }
    }

    // MARK: - rekordbox가 SYNC 없이 다시 쓴 파일(2026-10-08 정상 USB 실험)

    /// 두 라이브러리 덩어리가 있는 원문. rekordbox가 켜진 채 원본을 바꾸면 마지막 덩어리(iTunes)의 뿌리 행이 끝에 한 번 더 붙었다.
    static let twoLibraries = [
        node("0", folder: true, library: 0, device: 0, check: 2),
        node("11", library: 0, device: 5, timestamp: 100),
        node("0", folder: true, device: 0, check: 2),
        node("F", folder: true, device: 1),
        node("A", parent: "F", device: 2),
    ]
    static let twoLibrarySource: [UsbSyncSourceNode] = source + [.init(id: "17", parentID: nil, isFolder: false, timestamp: 100)]

    @Test func 끝에_덧붙은_뿌리_행_하나는_접어_원래_선택과_같게_읽는다() throws {
        let original = try UsbSyncSelectionFile.parse(Self.file(Self.twoLibraries))
        let data = Self.file(Self.twoLibraries + [Self.twoLibraries[2]])
        let rewritten = try UsbSyncSelectionFile.parse(data)
        #expect(rewritten.trailingDuplicateRoots == 1 && original.trailingDuplicateRoots == 0)
        #expect(rewritten.nodes == original.nodes && rewritten.data == data)
        // 엄격한 모양 판정은 그대로 거짓이고, 덧붙은 행을 다시 붙인 모양만 원문과 같다.
        #expect(!rewritten.isCanonical && rewritten.isCanonicalWithTrailingDuplicateRoots)
        #expect(original.isCanonical && !original.isCanonicalWithTrailingDuplicateRoots)
        // rekordbox는 OneLibrary 파일만 다시 쓴다. 두 형식의 선택은 같은 것으로 본다.
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: original, .oneLibrary: rewritten])
        #expect(bundle.semanticFingerprint != nil
            && bundle.semanticFingerprint == UsbSyncSelectionBundle(files: [.deviceLibrary: original]).semanticFingerprint)
        let ids: [UsbFormat: Set<Int>] = [.deviceLibrary: [1, 2, 5], .oneLibrary: [1, 2, 5]]
        let result = bundle.resolution(sourceNodes: Self.twoLibrarySource, localDBID: Self.localDBID, usbPlaylistIDs: ids)
        #expect(result.issues.isEmpty)
        #expect(result.selection.selectedIDs == ["17", "itunes:F", "itunes:A"])
        #expect(result.playlistIDs == ["17": 5, "itunes:F": 1, "itunes:A": 2])
        // 끝 행 뒤에 주석이 있으면 읽기는 하지만 고쳐 쓸 모양은 아니다.
        let commented = try UsbSyncSelectionFile.parse(Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "  </Playlists>", with: "    <!--합성-->\r\n  </Playlists>").utf8))
        #expect(commented.trailingDuplicateRoots == 1 && !commented.isCanonicalWithTrailingDuplicateRoots)
    }

    @Test func 값이_다른_뿌리_행_가운데의_중복_뿌리가_아닌_중복은_여전히_거부한다() {
        let root = Self.twoLibraries[2]
        for nodes in [
            // 같은 키지만 칸 값이 다른 뿌리 행
            Self.twoLibraries + [root.replacingOccurrences(of: "CheckType=\"2\"", with: "CheckType=\"1\"")],
            Self.twoLibraries + [root.replacingOccurrences(of: "Timestamp=\"0\"", with: "Timestamp=\"1\"")],
            // 같은 뿌리 행이지만 뒤에 다른 행이 있다
            Self.twoLibraries + [root, Self.node("C", device: 3)],
            Array(Self.twoLibraries.prefix(3)) + [root] + Self.twoLibraries.suffix(2),
            // 뿌리가 아닌 행의 끝 중복
            Self.twoLibraries + [Self.twoLibraries[4]],
            Self.twoLibraries + [Self.twoLibraries[3]],
        ] {
            #expect(throws: UsbSyncSelectionFile.ParseError.invalidFile) { try UsbSyncSelectionFile.parse(Self.file(nodes)) }
        }
    }
}
