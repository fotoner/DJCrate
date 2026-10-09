import DJCApplication
import DJCDomain
import Foundation
import SwiftUI

/// 곡 목록 오른쪽 클릭 메뉴가 다른 영역의 흐름을 시작하는 동작 묶음: rekordbox 쓰기·넣기·빼기 창, XML 만들기, 추가한 곡 XML, USB 초안 편집.
/// 목록은 메뉴를 그리고 대상 곡을 고를 뿐 그 흐름을 직접 부르지 않는다. 실제 묶음은 `live(store:reflection:)`이고 조립 지점(`AppComposition`)이 만든다.
@MainActor
struct TrackListActions {
    /// 고른 곡의 초안만 rekordbox에 쓴다(재생 목록 초안은 ⇧⌘E·쓰기 대기 목록에서)
    var writeDrafts: @MainActor ([TrackRow]) -> Void
    /// 고른 곡의 초안으로 XML을 만든다
    var exportDraftsXML: @MainActor ([TrackRow]) -> Void
    /// 추가한 곡을 rekordbox 컬렉션에 바로 넣는다
    var addToRekordbox: @MainActor ([TrackRow]) -> Void
    /// rekordbox 컬렉션에서 뺀다(늘 확인 창)
    var deleteFromRekordbox: @MainActor ([TrackRow]) -> Void
    /// 곡 하나·종류 하나의 막힌 초안을 복구 시트로 연다(#232)
    var recoverDraft: @MainActor (TrackRow, DraftRecoveryKind) -> Void
    /// 고른 추가한 곡으로 XML을 만든다(대상은 스토어의 선택)
    var exportStagedXML: @MainActor () -> Void
    /// 로컬 곡을 USB 컬렉션·목록에 넣는 초안
    var addToUsb: @MainActor ([TrackRow], UsbSidebarTarget) -> Void
    /// USB 곡을 그 USB에서 빼는 초안
    var removeFromUsb: @MainActor (_ rows: [TrackRow], _ volumeKey: String) -> Void
    /// USB 곡을 그 USB 목록에서 빼는 초안
    var removeFromUsbPlaylist: @MainActor (_ rows: [TrackRow], _ volumeKey: String, _ playlist: Int) -> Void
    /// 로컬에서 더 고친 USB 곡을 갱신하는 초안
    var refreshUsbTracks: @MainActor (_ rows: [TrackRow], _ volumeKey: String) -> Void
}

extension TrackListActions {
    /// 앱의 쓰기(`reflection`)·추가 목록·XML 창과 USB 편집(`LibraryStore.usbEdits`)에 잇는다.
    /// 쓰기를 붙이지 않았거나(nil) USB 편집을 붙이지 않았으면 그 동작은 아무것도 하지 않는다.
    static func live(store: LibraryStore, reflection: ReflectionCoordinator? = nil) -> TrackListActions {
        TrackListActions(
            writeDrafts: { reflection?.startWrite(rows: $0, playlists: false) },
            exportDraftsXML: { ReflectionPanels.export(store: store, rows: $0) },
            addToRekordbox: { reflection?.startAddTracks(rows: $0) },
            deleteFromRekordbox: { reflection?.startDeleteTracks(rows: $0) },
            recoverDraft: { reflection?.startRecovery(row: $0, kind: $1) },
            exportStagedXML: { StagingPanels.exportXML(store: store) },
            addToUsb: { rows, target in
                guard let edits = store.usbEdits else { return }
                Task { await edits.addTracks(rows, to: target) }
            },
            removeFromUsb: { rows, volumeKey in
                guard let edits = store.usbEdits else { return }
                Task { await edits.removeTracks(rows, volumeKey: volumeKey) }
            },
            removeFromUsbPlaylist: { rows, volumeKey, playlist in
                guard let edits = store.usbEdits else { return }
                Task { await edits.removeFromPlaylist(rows, volumeKey: volumeKey, playlist: playlist) }
            },
            refreshUsbTracks: { rows, volumeKey in
                guard let edits = store.usbEdits else { return }
                Task { await edits.refreshLocalChanges(volumeKey: volumeKey, rows: rows) }
            })
    }
}

extension EnvironmentValues {
    /// 곡 목록 메뉴의 동작 묶음. 조립 지점이 주 창에 붙인다(없으면 목록이 같은 실제 묶음을 만든다).
    @Entry var trackListActions: TrackListActions? = nil
}
