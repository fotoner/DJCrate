import DJCDomain
import Foundation

/// USB 동기화 원본(rekordbox 목록 + iTunes 목록)을 합친 값. iTunes ID는 rekordbox 편집 대상에 넣지 않는다.
/// 앱은 라이브러리 화면의 rekordbox 목록과 읽은 iTunes 목록으로 만든다(`make`, 앱 쪽 확장).
public struct UsbSyncSource: Sendable, Equatable {
    public static let rekordboxSelectionID = UsbSyncSourceNode.rekordboxSelectionID
    public static let iTunesSelectionID = UsbSyncSourceNode.iTunesSelectionID

    /// iTunes 목록 읽기 상태(`ITunesLibrarySnapshot.Status`와 같은 이름)
    public enum ITunesStatus: String, Sendable, Equatable {
        case ready, stale, notCaptured, unavailable, loading
    }

    public var layout: PlaylistLayout
    public var rekordbox: PlaylistLayout
    public var iTunes: PlaylistLayout
    /// 목록 옆에 보일 알림(잇지 못한 곡이 있는 iTunes 목록). 동기화를 막지 않는다
    public var notices: [String: String]
    /// iTunes 목록 ID → 잇지 못한 곡의 곡 단위 막힘(목록 순서, 대상은 음원 경로의 해시). rekordbox처럼 이 곡만 빼고 동기화하고 넣지 못한 곡으로 알린다
    public var unlinked: [String: [UsbBlock]] = [:]
    /// 행이 없어도 읽기 실패와 정상적인 빈 원본을 구분한다.
    public var iTunesStatus: ITunesStatus

    public init(layout: PlaylistLayout, rekordbox: PlaylistLayout, iTunes: PlaylistLayout, notices: [String: String],
                unlinked: [String: [UsbBlock]] = [:], iTunesStatus: ITunesStatus) {
        self.layout = layout
        self.rekordbox = rekordbox
        self.iTunes = iTunes
        self.notices = notices
        self.unlinked = unlinked
        self.iTunesStatus = iTunesStatus
    }

    /// 선택 전용 머리는 USB의 실제 폴더가 아니다. 원본 파일에는 실제 목록 ID만 전달한다.
    public var nativeNodes: [UsbSyncSourceNode] {
        Self.nativeNodes(layout)
    }

    /// - master: rekordbox 폴더의 masterPlaylists6.xml. 같은 Id·ParentId·Attribute·Lib_Type의 NODE가 있는 목록만
    ///   Timestamp를 싣는다(USB 선택 파일에 그대로 옮긴다). 맞지 않는 목록은 체크해 쓸 때 막힌다.
    public static func nativeNodes(_ layout: PlaylistLayout, master: [MasterPlaylistNode] = []) -> [UsbSyncSourceNode] {
        let byKey = Dictionary(master.map { ("\($0.libType):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        func encoded(_ id: String) -> (library: Int, id: String)? {
            if id == PlaylistLayout.root { return nil }
            if id.hasPrefix("itunes:") {
                return UInt64(id.dropFirst("itunes:".count), radix: 16).map { (1, String($0, radix: 16, uppercase: true)) }
            }
            return MasterPlaylistNode.hex(id).map { (0, $0) }
        }
        return layout.outline.map { item in
            var timestamp: Int64?
            if let key = encoded(item.id), let node = byKey["\(key.library):\(key.id)"],
               node.parentID == (encoded(item.parentID).map(\.id) ?? "0"), node.attribute == (item.isFolder ? 1 : 0) {
                timestamp = node.timestamp
            }
            return UsbSyncSourceNode(id: item.id, parentID: item.parentID == PlaylistLayout.root ? nil : item.parentID,
                                     isFolder: item.isFolder, timestamp: timestamp)
        }
    }

    /// 체크하거나 부분 체크로 쓸 목록 중 masterPlaylists6.xml에서 찾지 못한 것이 있는지
    public static func lacksMasterNode(_ nodes: [UsbSyncSourceNode], selection: ITunesSyncSelection) -> Bool {
        let selectionNodes: [ITunesSyncSelection.Node] = [
            .init(id: rekordboxSelectionID, parentID: "0", isFolder: true), .init(id: iTunesSelectionID, parentID: "0", isFolder: true),
        ] + nodes.map { node in
            .init(id: node.id, parentID: node.parentID ?? (node.id.hasPrefix("itunes:") ? iTunesSelectionID : rekordboxSelectionID),
                  isFolder: node.isFolder)
        }
        let expanded = selection.expandedIDs(in: selectionNodes)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var written = Set<String>()
        for id in expanded where byID[id] != nil {
            var next: String? = id
            while let current = next, let node = byID[current], written.insert(current).inserted { next = node.parentID }
        }
        return written.contains { byID[$0]?.timestamp == nil }
    }

    /// 선택한 iTunes 목록의 잇지 못한 곡을 곡 단위 막힘으로. 같은 음원은 여러 목록에 있어도 한 번만 센다.
    /// 막힘 대상은 경로를 남기지 않게 음원 경로의 해시로 적혀 있다(`unlinked`)
    public func skippedITunesTracks(selection: ITunesSyncSelection) -> [UsbBlock] {
        var seen = Set<UsbBlock.Scope>(), blocks: [UsbBlock] = []
        for item in UsbSyncPlan.selectedLayout(layout, selection: selection).outline where item.holdsTracks {
            for block in unlinked[item.id] ?? [] where seen.insert(block.scope).inserted {
                blocks.append(block)
            }
        }
        return blocks
    }

    /// 로컬 곡을 USB에 넣을 수 없는 까닭(앱이 아는 것만. 음원 없음·분석 파일 없음은 USB 쓰기 계획이 곡마다 알린다)
    public enum LocalSkip: Sendable {
        case missing, staged, usb, streaming

        public var block: (code: String, message: String) {
            switch self {
            case .missing:
                ("syncSourceTrackMissing", String(ui: "로컬 라이브러리에서 찾지 못한 곡이라 USB에 넣지 않았습니다. 라이브러리를 새로고침한 뒤 다시 동기화하세요"))
            case .staged:
                ("syncTrackStaged", String(ui: "아직 rekordbox 컬렉션에 넣지 않은 곡이라 USB에 넣지 않았습니다. rekordbox에 쓴 뒤 다시 동기화하세요"))
            case .usb:
                ("syncTrackOnUsbOnly", String(ui: "USB에만 있는 곡이라 다시 넣지 않았습니다. 로컬 컬렉션의 곡으로 목록을 고친 뒤 다시 동기화하세요"))
            case .streaming:
                ("streamingTrack", String(ui: "스트리밍 곡이라 USB에 넣지 않았습니다. 로컬 음원으로 바꾼 뒤 다시 동기화하세요"))
            }
        }
    }

    /// 선택한 목록 중 USB에 넣을 수 없는 로컬 곡 → 곡 단위 막힘. 동기화는 이 곡을 목록에서 빼고 나머지를 쓴다
    public static func skippedLocalTracks(_ selected: PlaylistLayout, kind: (String) -> LocalSkip?) -> [String: UsbBlock] {
        var result: [String: UsbBlock] = [:]
        for id in selected.outline.filter(\.holdsTracks).flatMap(\.trackIDs) where result[id] == nil {
            guard let skip = kind(id) else { continue }
            let block = skip.block
            result[id] = UsbBlock(code: block.code, scope: .track(id), message: block.message)
        }
        return result
    }

    /// 그룹 머리나 사라진 iTunes ID도 선택의 출처이므로 빈 미러로 바꾸지 않는다.
    public func blockReason(selection: ITunesSyncSelection) -> String? {
        let expanded = selection.expandedIDs(in: Self.nodes(layout))
        let selectsITunes = expanded.contains(Self.iTunesSelectionID) || expanded.contains { $0.hasPrefix("itunes:") }
        if selectsITunes, iTunesStatus != .ready, iTunesStatus != .stale {
            return String(ui: "선택한 iTunes 원본을 아직 읽지 못했습니다. iTunes 목록을 새로고침한 뒤 동기화하세요")
        }
        let available = Set(Self.nodes(layout).map(\.id)).union(["0"])
        guard selection.selectedIDs.isSubset(of: available) else {
            return String(ui: "USB에서 선택했던 원본 목록을 찾지 못했습니다. iTunes와 rekordbox 목록을 다시 읽거나 rekordbox에서 USB 동기화 선택을 확인하세요")
        }
        // 잇지 못한 곡이 있는 목록은 막지 않는다. 그 곡만 빼고 넣지 못한 곡으로 알린다(rekordbox와 같다, `skippedITunesTracks`)
        return nil
    }

    /// 원본별 전체 선택도 새 하위 목록을 따라가게 한다(`UsbSyncPlan.nodes`)
    public static func nodes(_ layout: PlaylistLayout) -> [ITunesSyncSelection.Node] {
        UsbSyncPlan.nodes(layout)
    }
}

extension UsbSyncPlan {
    /// 읽기 실패를 정상적인 빈 선택으로 계획하기 전에 막는다.
    /// - Parameter newKey: 새로 만들 목록의 초안 키(앱은 `sync-<UUID>`)
    public static func build(source: UsbSyncSource, selection: ITunesSyncSelection, library: UsbLibrary,
                             matches: [Int: String], badges: [Int: UsbSyncStatus], bindings: [String: UsbSyncPlaylistBinding],
                             linkedPlaylistIDs: [String: Int] = [:], removedPlaylistIDs: Set<Int> = [], excluding: Set<String> = [],
                             newKey: () -> String) throws -> UsbSyncPlan {
        if let reason = source.blockReason(selection: selection) { throw PlaylistLayout.Blocked(reason) }
        return try build(source: source.layout, selection: selection, library: library, matches: matches,
                         badges: badges, bindings: bindings, linkedPlaylistIDs: linkedPlaylistIDs,
                         removedPlaylistIDs: removedPlaylistIDs, excluding: excluding, newKey: newKey)
    }
}
