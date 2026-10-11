import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 선택 파일을 rekordbox와 같은 바이트로 만드는지 본다. 기대 바이트는 시험 안에서 칸 규칙대로 직접 적는다(값은 합성).
/// 규칙: 2026-10-08 rekordbox 7.2.x 동기화 관리자 전후 실험(docs/usb-internals.md #233).
struct UsbSyncSelectionXMLTests {
    static let contract = UsbSyncXMLWriteContract.confirmed
    static let localDBID = UsbSyncSelectionFileTests.localDBID
    static let dbid = UsbSyncSelectionFileTests.fileDBID

    /// rekordbox 폴더 100(16진 64) 안에 101(65)·102(66), 맨 위 200(C8). iTunes 폴더 F 안에 A·B, 맨 위 C.
    static let source: [UsbSyncSourceNode] = [
        .init(id: "100", parentID: nil, isFolder: true, timestamp: 1_700_000_000_100),
        .init(id: "101", parentID: "100", isFolder: false, timestamp: 1_700_000_000_101),
        .init(id: "102", parentID: "100", isFolder: false, timestamp: 1_700_000_000_102),
        .init(id: "200", parentID: nil, isFolder: false, timestamp: 1_700_000_000_200),
        .init(id: "itunes:F", parentID: nil, isFolder: true, timestamp: 0),
        .init(id: "itunes:A", parentID: "itunes:F", isFolder: false, timestamp: 0),
        .init(id: "itunes:B", parentID: "itunes:F", isFolder: false, timestamp: 0),
        .init(id: "itunes:C", parentID: nil, isFolder: false, timestamp: 0),
    ]
    static let refs: [String: PlaylistRef] = [
        "100": .id("11"), "101": .id("12"), "102": .new("b"), "200": .id("14"),
        "itunes:F": .id("21"), "itunes:A": .id("22"), "itunes:B": .new("ib"), "itunes:C": .id("24"),
    ]

    /// 실험 전 USB처럼 iTunes 폴더 F만 체크된 원문
    static let base = UsbSyncSelectionFileTests.file([
        UsbSyncSelectionFileTests.node("0", folder: true, device: 0, check: 2),
        UsbSyncSelectionFileTests.node("F", folder: true, device: 21),
        UsbSyncSelectionFileTests.node("A", parent: "F", device: 22),
        UsbSyncSelectionFileTests.node("B", parent: "F", device: 23),
    ])

    func draft(_ selection: Set<String>, source: [UsbSyncSourceNode] = Self.source, base: Data? = Self.base,
               enabled: Bool = true) -> UsbSyncSelectionDraft {
        .init(localDBID: Self.localDBID, sourceNodes: source, selection: .init(selectedIDs: selection), enabled: enabled,
              playlistRefs: Self.refs, baseFiles: base.map { [.deviceLibrary: $0, .oneLibrary: $0] } ?? [:])
    }

    func render(_ draft: UsbSyncSelectionDraft, format: UsbFormat = .deviceLibrary,
                ids: [String: Int] = ["b": 13, "ib": 23]) throws -> Data {
        try UsbSyncSelectionXML.render(draft: draft, format: format, playlistIDs: ids, contract: Self.contract)
    }

    /// 칸 순서·들여쓰기·CRLF(마지막 줄 포함)를 그대로 적은 기대값
    static func expected(automaticSync: String = "1", _ nodes: [String]) -> Data {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n"
        text += "<Sync DBID=\"\(dbid)\" AutomaticSync=\"\(automaticSync)\" AllPlaylists=\"0\" IncludeCue=\"1\" ForcedSync=\"0\" Timestamp=\"0\">\r\n"
        if nodes.isEmpty {
            text += "  <Playlists/>\r\n"
        } else {
            text += "  <Playlists>\r\n"
            for node in nodes { text += "    \(node)\r\n" }
            text += "  </Playlists>\r\n"
        }
        text += "</Sync>\r\n"
        return Data(text.utf8)
    }

    @Test func 체크한_목록과_부분_폴더만_rekordbox와_같은_바이트로_쓴다() throws {
        let output = try render(draft(["101", "itunes:F", "itunes:C"]))
        #expect(output == Self.expected([
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="64" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="11" Timestamp="1700000000100" CheckType="2"/>"#,
            #"<NODE Id="65" ParentId="64" Attribute="0" Lib_Type="0" Dev_ID="12" Timestamp="1700000000101" CheckType="1"/>"#,
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="1" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="F" ParentId="0" Attribute="1" Lib_Type="1" Dev_ID="21" Timestamp="0" CheckType="1"/>"#,
            #"<NODE Id="A" ParentId="F" Attribute="0" Lib_Type="1" Dev_ID="22" Timestamp="0" CheckType="1"/>"#,
            #"<NODE Id="B" ParentId="F" Attribute="0" Lib_Type="1" Dev_ID="23" Timestamp="0" CheckType="1"/>"#,
            #"<NODE Id="C" ParentId="0" Attribute="0" Lib_Type="1" Dev_ID="24" Timestamp="0" CheckType="1"/>"#,
        ]))
        try UsbSyncSelectionXML.verify(data: output, draft: draft(["101", "itunes:F", "itunes:C"]), format: .deviceLibrary,
                                       playlistIDs: ["b": 13, "ib": 23], contract: Self.contract)
        #expect(try UsbSyncSelectionFile.parse(output).isCanonical)
    }

    @Test func 해제한_목록의_행과_체크가_없는_라이브러리의_뿌리_행은_쓰지_않는다() throws {
        // 폴더의 하위를 모두 고르면 폴더도 체크(1)로, 하나만 빼면 그 행이 빠지고 폴더는 부분(2)이다.
        #expect(try render(draft(["101", "102"])) == Self.expected([
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="64" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="11" Timestamp="1700000000100" CheckType="2"/>"#,
            #"<NODE Id="65" ParentId="64" Attribute="0" Lib_Type="0" Dev_ID="12" Timestamp="1700000000101" CheckType="1"/>"#,
            #"<NODE Id="66" ParentId="64" Attribute="0" Lib_Type="0" Dev_ID="13" Timestamp="1700000000102" CheckType="1"/>"#,
        ]))
        // 폴더를 고르면 체크(1), 원본 전체를 고르지 않은 라이브러리 뿌리는 부분(2)이다.
        #expect(try render(draft(["100", "200"])) == Self.expected([
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="64" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="11" Timestamp="1700000000100" CheckType="1"/>"#,
            #"<NODE Id="65" ParentId="64" Attribute="0" Lib_Type="0" Dev_ID="12" Timestamp="1700000000101" CheckType="1"/>"#,
            #"<NODE Id="66" ParentId="64" Attribute="0" Lib_Type="0" Dev_ID="13" Timestamp="1700000000102" CheckType="1"/>"#,
            #"<NODE Id="C8" ParentId="0" Attribute="0" Lib_Type="0" Dev_ID="14" Timestamp="1700000000200" CheckType="1"/>"#,
        ]))
        // 모두 해제하면 뿌리 행도 빠져 빈 목록이 된다. 행이 없는 파일은 `<Playlists/>` 한 줄이다(빈 USB 실험의 173바이트 파일).
        #expect(try render(draft([])) == Self.expected([]))
    }

    @Test func 형식마다_그_DB의_Dev_ID를_쓰고_나머지_바이트는_같다() throws {
        let request = draft(["101"])
        let deviceLibrary = try render(request, format: .deviceLibrary, ids: ["101": 12])
        let oneLibrary = try render(request, format: .oneLibrary, ids: ["101": 37])
        #expect(deviceLibrary != oneLibrary)
        #expect(String(decoding: oneLibrary, as: UTF8.self)
            == String(decoding: deviceLibrary, as: UTF8.self).replacingOccurrences(of: "Dev_ID=\"12\"", with: "Dev_ID=\"37\""))
        let bundle = UsbSyncSelectionBundle(files: [.deviceLibrary: try .parse(deviceLibrary), .oneLibrary: try .parse(oneLibrary)])
        let resolved = bundle.resolution(sourceNodes: Self.source, localDBID: Self.localDBID,
                                         usbPlaylistIDs: [.deviceLibrary: [11, 12], .oneLibrary: [11, 37]])
        #expect(resolved.issues.isEmpty && resolved.selection.selectedIDs == ["101"])
        #expect(resolved.formatPlaylistIDs[.deviceLibrary]?["101"] == 12 && resolved.formatPlaylistIDs[.oneLibrary]?["101"] == 37)
        #expect(throws: UsbSyncSelectionXML.RenderError.verificationFailed) {
            try UsbSyncSelectionXML.verify(data: oneLibrary, draft: request, format: .deviceLibrary, playlistIDs: ["101": 12],
                                           contract: Self.contract)
        }
    }

    @Test func 켜짐만_바꾸면_AutomaticSync_말고는_원문과_같다() throws {
        let original = Self.base
        for (enabled, value) in [(true, "1"), (false, "0")] {
            let request = UsbSyncSelectionDraft.enabledOnly(localDBID: Self.localDBID, enabled: enabled,
                                                            baseFiles: [.deviceLibrary: original])
            let output = try render(request, ids: [:])
            #expect(String(decoding: output, as: UTF8.self)
                == String(decoding: original, as: UTF8.self).replacingOccurrences(of: "AutomaticSync=\"0\"", with: "AutomaticSync=\"\(value)\""))
            try UsbSyncSelectionXML.verify(data: output, draft: request, format: .deviceLibrary, playlistIDs: [:], contract: Self.contract)
        }
        // 원문이 없는 USB에서 끄기만 하면 만들 파일이 없다(쓰기 계획이 건너뛴다).
        let off = UsbSyncSelectionDraft.enabledOnly(localDBID: Self.localDBID, enabled: false, baseFiles: [:])
        #expect(throws: UsbSyncSelectionXML.RenderError.invalidSource) { try render(off, ids: [:]) }
        #expect(UsbSyncSelectionStage.writesNothing(off, formats: UsbFormat.defaultSet))
        #expect(!UsbSyncSelectionStage.writesNothing(.enabledOnly(localDBID: Self.localDBID, enabled: true, baseFiles: [:]),
                                                     formats: UsbFormat.defaultSet))
    }

    @Test func 원문이_rekordbox_모양이_아니면_고쳐_쓰지_않는다() throws {
        let text = String(decoding: Self.base, as: UTF8.self)
        for candidate in [
            text.replacingOccurrences(of: "\r\n", with: "\n"),
            text.replacingOccurrences(of: "  <Playlists>", with: "  <!--메모-->\r\n  <Playlists>"),
            text.replacingOccurrences(of: "Timestamp=\"0\">", with: "Timestamp=\"0\" Custom=\"keep\">"),
            text.replacingOccurrences(of: "<Sync DBID=\"\(Self.dbid)\" AutomaticSync=\"0\"", with: "<Sync AutomaticSync=\"0\" DBID=\"\(Self.dbid)\""),
            text.replacingOccurrences(of: "  <Playlists>", with: "  <PRODUCT Name=\"synthetic\"/>\r\n  <Playlists>"),
            text.replacingOccurrences(of: "DBID=\"\(Self.dbid)\"", with: "DBID=\"42\""),
        ] {
            #expect(throws: UsbSyncSelectionXML.RenderError.contractMismatch) {
                try render(draft(["101"], base: Data(candidate.utf8)))
            }
        }
        // 모르는 원본 종류의 행은 옮기는 방법을 모르므로 선택을 새로 쓰지 않는다. 켜짐만 바꾸는 쓰기는 행을 그대로 둔다.
        let unknown = UsbSyncSelectionFileTests.file([UsbSyncSelectionFileTests.node("0", folder: true, library: 7, device: 0, check: 0)])
        #expect(throws: UsbSyncSelectionXML.RenderError.contractMismatch) { try render(draft(["101"], base: unknown)) }
        let flipped = try render(.enabledOnly(localDBID: Self.localDBID, enabled: true, baseFiles: [.deviceLibrary: unknown]), ids: [:])
        #expect(try UsbSyncSelectionFile.parse(flipped).nodes == UsbSyncSelectionFile.parse(unknown).nodes)
    }

    @Test func masterPlaylists6에_없는_목록은_체크해_쓰지_않는다() throws {
        let source = Self.source.map { node in
            node.id == "102" ? UsbSyncSourceNode(id: node.id, parentID: node.parentID, isFolder: node.isFolder) : node
        }
        #expect(throws: UsbSyncSelectionXML.RenderError.missingSourceNode) { try render(draft(["102"], source: source)) }
        // 쓰지 않는 행(해제한 목록)은 막지 않는다.
        _ = try render(draft(["101"], source: source))
    }

    @Test func 원본이나_최종_USB_번호가_없으면_거부한다() {
        #expect(throws: (any Error).self) { try render(draft(["itunes:missing"])) }
        #expect(throws: UsbSyncSelectionXML.RenderError.missingPlaylist) { try render(draft(["102"]), ids: [:]) }
        // 서로 다른 원본이 같은 USB 목록을 가리키면 거부한다(Lib0·Lib1은 같은 번호 공간).
        #expect(throws: UsbSyncSelectionXML.RenderError.invalidSource) {
            try render(draft(["200", "itunes:C"]), ids: ["200": 30, "itunes:C": 30])
        }
        #expect(throws: UsbSyncSelectionXML.RenderError.contractMismatch) {
            try UsbSyncSelectionXML.render(draft: draft(["101"]), format: .deviceLibrary, playlistIDs: [:],
                                           contract: UsbSyncXMLWriteContract(revision: 0))
        }
    }

    /// 2026-10-08 빈 USB 실험(첫 SYNC): rekordbox가 새로 만든 두 파일의 루트는
    /// `AutomaticSync="1" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0"`, 행은 기존 규칙과 같았다.
    @Test func 원문이_없으면_새_파일_루트_값으로_만든다() throws {
        let output = try render(draft(["itunes:C"], base: nil))
        #expect(output == Self.expected([
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="1" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="C" ParentId="0" Attribute="0" Lib_Type="1" Dev_ID="24" Timestamp="0" CheckType="1"/>"#,
        ]))
        try UsbSyncSelectionXML.verify(data: output, draft: draft(["itunes:C"], base: nil), format: .deviceLibrary,
                                       playlistIDs: ["b": 13, "ib": 23], contract: Self.contract)
        // 끈 채 첫 SYNC를 할 수는 없지만(rekordbox는 SYNC 버튼이 비활성) 칸은 체크 값을 따른다.
        #expect(try render(draft(["itunes:C"], base: nil, enabled: false)) == Self.expected(automaticSync: "0", [
            #"<NODE Id="0" ParentId="0" Attribute="1" Lib_Type="1" Dev_ID="0" Timestamp="0" CheckType="2"/>"#,
            #"<NODE Id="C" ParentId="0" Attribute="0" Lib_Type="1" Dev_ID="24" Timestamp="0" CheckType="1"/>"#,
        ]))
        // 형식마다 파일이 모두 있거나 모두 없을 때만 쓴다. 한쪽만 있으면 막는다.
        #expect(UsbSyncSelectionStage.gateBlock(baseFiles: [:], formats: [.deviceLibrary]) == nil)
        #expect(UsbSyncSelectionStage.gateBlock(baseFiles: [:], formats: UsbFormat.defaultSet) == nil)
        #expect(UsbSyncSelectionStage.gateBlock(baseFiles: [.deviceLibrary: Self.base], formats: [.deviceLibrary]) == nil)
        for present in UsbFormat.allCases {
            #expect(UsbSyncSelectionStage.gateBlock(baseFiles: [present: Self.base], formats: UsbFormat.defaultSet)?.code
                == "syncSelectionPartialFiles")
        }
        #expect(UsbSyncSelectionStage.gateBlock(baseFiles: [.deviceLibrary: Self.base, .oneLibrary: Self.base],
                                                formats: UsbFormat.defaultSet) == nil)
        #expect(UsbSyncXMLWriteContract.production == .confirmed)
    }

    /// 2026-10-08 빈 USB 실험: "장치와 플레이리스트 동기화"를 켜면 SYNC 전에 두 파일이 173바이트로 생겼다.
    /// 그 길이가 정확히 맞는 모양은 행 없는 `<Playlists/>`뿐이다(DBID 11자, CRLF).
    @Test func 파일이_없는_USB에서_켜면_행_없는_173바이트_파일을_만든다() throws {
        let local: Int64 = 2_200_000_000
        let dbid = try #require(UsbSyncSelectionXML.databaseID(local))
        #expect(dbid == "-2094967296")
        let request = UsbSyncSelectionDraft.enabledOnly(localDBID: local, enabled: true, baseFiles: [:])
        let expected = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n"
            + "<Sync DBID=\"-2094967296\" AutomaticSync=\"1\" AllPlaylists=\"0\" IncludeCue=\"1\" ForcedSync=\"0\" Timestamp=\"0\">\r\n"
            + "  <Playlists/>\r\n</Sync>\r\n"
        for format in UsbFormat.allCases {
            let output = try UsbSyncSelectionXML.render(draft: request, format: format, playlistIDs: [:], contract: Self.contract)
            #expect(output == Data(expected.utf8))
            #expect(output.count == 173)
            try UsbSyncSelectionXML.verify(data: output, draft: request, format: format, playlistIDs: [:], contract: Self.contract)
            // rekordbox가 만든 이 모양도 고쳐 쓸 수 있는 원문이다. 이어서 끄면 AutomaticSync만 바뀐다.
            let parsed = try UsbSyncSelectionFile.parse(output)
            #expect(parsed.isCanonical && parsed.nodes.isEmpty)
            let off = try UsbSyncSelectionXML.render(draft: .enabledOnly(localDBID: local, enabled: false, baseFiles: [format: output]),
                                                     format: format, playlistIDs: [:], contract: Self.contract)
            #expect(String(decoding: off, as: UTF8.self)
                == expected.replacingOccurrences(of: "AutomaticSync=\"1\"", with: "AutomaticSync=\"0\""))
        }
    }

    // MARK: - rekordbox가 SYNC 없이 다시 쓴 원문(2026-10-08 정상 USB 실험)

    /// `base` 끝에 마지막 덩어리의 뿌리 행이 한 번 더 붙은 원문
    static let rewrittenBase = UsbSyncSelectionFileTests.file([
        UsbSyncSelectionFileTests.node("0", folder: true, device: 0, check: 2),
        UsbSyncSelectionFileTests.node("F", folder: true, device: 21),
        UsbSyncSelectionFileTests.node("A", parent: "F", device: 22),
        UsbSyncSelectionFileTests.node("B", parent: "F", device: 23),
        UsbSyncSelectionFileTests.node("0", folder: true, device: 0, check: 2),
    ])

    @Test func 끝_뿌리_행이_덧붙은_원문도_다음_SYNC처럼_그_행_없이_새로_쓴다() throws {
        let selection: Set<String> = ["101", "itunes:F", "itunes:C"]
        let output = try render(draft(selection, base: Self.rewrittenBase))
        #expect(output == (try render(draft(selection))))
        #expect(try UsbSyncSelectionFile.parse(output).isCanonical)
        try UsbSyncSelectionXML.verify(data: output, draft: draft(selection, base: Self.rewrittenBase), format: .deviceLibrary,
                                       playlistIDs: ["b": 13, "ib": 23], contract: Self.contract)
        // 선택을 그대로 두고 쓰면 덧붙은 행만 빠진 원문이 된다.
        #expect(try render(draft(["itunes:F"], base: Self.rewrittenBase)) == (try render(draft(["itunes:F"]))))
        #expect(UsbSyncSelectionStage.draftBlock(draft(selection, base: Self.rewrittenBase)) == nil)
    }

    @Test func 끝_뿌리_행이_덧붙은_원문에서_켜짐만_바꾸는_쓰기는_rekordbox_SYNC를_먼저_요구한다() throws {
        for enabled in [true, false] {
            let request = UsbSyncSelectionDraft.enabledOnly(localDBID: Self.localDBID, enabled: enabled,
                                                            baseFiles: [.deviceLibrary: Self.base, .oneLibrary: Self.rewrittenBase])
            #expect(throws: UsbSyncSelectionXML.RenderError.pendingRekordboxSync) { try render(request, format: .oneLibrary, ids: [:]) }
            #expect(UsbSyncSelectionStage.draftBlock(request)?.code == "syncSelectionPendingRekordboxSync")
            let canonical = UsbSyncSelectionDraft.enabledOnly(localDBID: Self.localDBID, enabled: enabled,
                                                              baseFiles: [.deviceLibrary: Self.base, .oneLibrary: Self.base])
            #expect(UsbSyncSelectionStage.draftBlock(canonical) == nil)
        }
    }
}
