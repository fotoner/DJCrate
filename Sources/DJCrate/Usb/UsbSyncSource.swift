import CryptoKit
import DJCApplication
import DJCDomain
import Foundation

/// 라이브러리 화면의 rekordbox 목록과 읽은 iTunes 목록(DJCStorage `SyncedITunesLibrary`)으로 USB 동기화 원본을 만든다.
extension UsbSyncSource {
    static func make(rekordbox raw: PlaylistLayout, iTunes library: SyncedITunesLibrary) -> Self {
        let rekordbox = UsbSyncPlan.source(raw)
        var entries: [(item: PlaylistLayout.Item, seq: Int)] = []
        var notices: [String: String] = [:]
        var unlinked: [String: [UsbBlock]] = [:]
        func append(_ nodes: [SyncedITunesLibrary.Node], parent: String) {
            for (position, node) in nodes.enumerated() {
                // 폴더의 곡 모음은 중복을 뺀 값이라 USB 목록의 순서로 쓰지 않는다.
                let tracks: [PlaylistEntry] = node.isFolder ? [] : zip(node.trackNumbers, node.trackIDs).map {
                    PlaylistEntry(trackNo: $0.0, contentID: $0.1)
                }
                let item = PlaylistLayout.Item(id: node.id, name: node.name, parentID: parent,
                                               isFolder: node.isFolder, entries: tracks)
                entries.append((item: item, seq: position))
                if let children = node.children {
                    append(children, parent: node.id)
                } else if !node.unlinked.isEmpty {
                    // rekordbox도 동기화할 수 없는 곡은 내보내기 기록에 남기고 나머지를 동기화했다(2026-10-08 실제 동기화)
                    unlinked[node.id] = node.unlinked.enumerated().map { position, entry in
                        let target = entry.key.map { "itunes:" + Self.digest($0) } ?? "itunes:\(node.id)#\(position + 1)"
                        return UsbBlock(code: "iTunes." + entry.reason.rawValue, scope: .track(target), message: entry.reason.message)
                    }
                    notices[node.id] = String(ui: "rekordbox 컬렉션에 잇지 못한 \(node.unlinked.count)곡은 USB에 넣지 않습니다. 컬렉션 등록과 음원 경로를 확인하세요")
                }
            }
        }
        if library.status == .ready || library.status == .stale {
            append(library.tree, parent: PlaylistLayout.root)
        }
        let iTunes = PlaylistLayout(entries)
        let rootOffset = rekordbox.childIDs(of: PlaylistLayout.root).count
        let combined = [rekordbox, iTunes].enumerated().flatMap { sourceIndex, source in
            source.outline.map { item in
                let position = source.childIDs(of: item.parentID).firstIndex(of: item.id) ?? 0
                let offset = item.parentID == PlaylistLayout.root && sourceIndex == 1 ? rootOffset : 0
                return (item: item, seq: position + offset)
            }
        }
        return Self(layout: PlaylistLayout(combined), rekordbox: rekordbox, iTunes: iTunes, notices: notices, unlinked: unlinked,
                    iTunesStatus: ITunesStatus(library.status))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

extension UsbSyncSource.ITunesStatus {
    init(_ status: ITunesLibrarySnapshot.Status) {
        switch status {
        case .ready: self = .ready
        case .stale: self = .stale
        case .notCaptured: self = .notCaptured
        case .unavailable: self = .unavailable
        case .loading: self = .loading
        }
    }
}
