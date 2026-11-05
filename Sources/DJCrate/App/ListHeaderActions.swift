import Foundation

/// 머리 줄 오른쪽 구성(#340): 그 목록의 주 동작 단추 하나, 나머지를 담은 `…` 메뉴, 목록 상태 표시 하나.
/// 화면 모델(`ListActionBarModel.actions`)이 사이드바 항목마다 값으로 계산하고, 뷰(`ListHeaderActionsView`)는 이 값만 그린다.
/// 단추 이름(고른·전체·개수)과 막힘 이유가 여기 있어 값 단계 시험으로 본다. 단추를 누르면 `Action`을 화면 모델의 `perform`에 넘긴다.
struct ListHeaderActions: Equatable {
    /// 주 동작 단추. 없는 목록도 있다
    var primary: Command?
    /// `…` 메뉴 항목. 비었으면 메뉴를 두지 않는다
    var menu: [MenuItem] = []
    /// 목록 상태 표시(읽기 전용·경고·숨김·초안·진행). 한 화면에 하나
    var status: Status?

    static let none = ListHeaderActions()

    /// 단추나 메뉴 항목이 부르는 일. 화면 모델의 `perform`이 처리한다(`findInFolder`는 시트를 가진 단추 뷰가 처리한다)
    enum Action: Equatable {
        case addStaged
        case chooseFiles, removeSelectedStaged, exportStagedXML, removeImportedStaged
        case writePending, exportPendingXML, restoreLatest, discardPlaylistDrafts
        case showHistory(String), excludePendingHistories
        case discardPlaylistDraft(String), comparePlaylist(String)
        case refreshUsbLocalChanges(String), showUsbPending(String)
        case recheckFiles, findInFolder
        case estimateGrids
        case showStreaming, openUnlinkedDrafts
    }

    struct Command: Equatable {
        var title: String
        var systemImage: String
        var action: Action
        var isEnabled = true
        /// 툴팁: 막힌 이유, 또는 라벨에 없는 결과 범위(STR-13). 없으면 툴팁을 달지 않는다
        var help: String?
        /// 눈에 띄는 모양(rekordbox에 쓰는 단추)
        var isProminent = false
        /// 폭이 모자랄 때 쓰는 줄인 이름. 줄이면서 빠진 말은 `compactHelp`가 툴팁으로 알린다(없으면 이름을 줄이지 않는다)
        var compactTitle: String?
        var compactHelp: String?
    }

    /// 재생 기록 하위 메뉴: 고르면 그 기록을 보고, 모두 빼면 쓰기 대기에서 빠진다
    struct HistoryMenu: Equatable {
        var title: String
        var systemImage: String
        var entries: [Entry]
        var excludeAll: Command

        struct Entry: Equatable, Identifiable {
            var id: String
            var name: String
        }
    }

    enum MenuItem: Equatable {
        case command(Command)
        case histories(HistoryMenu)
        case divider
    }

    struct Status: Equatable {
        enum Kind: Equatable {
            /// 읽기 전용(잠금)
            case readOnly
            /// 할 일이 있는 경고
            case warning
            /// 숨겨진 것이 있음
            case hidden
            /// 쓰기 전 초안
            case draft
            /// 진행 중
            case progress
            /// 필요한 순간에만 붙는 단서
            case hint
        }

        var kind: Kind
        /// 보이는 글. 폭이 모자라면 아이콘만 남기고 툴팁으로 알린다
        var title: String
        /// 툴팁에 글 뒤에 더하는 말(라벨에 없는 정보)
        var detail: String?
        /// 종류의 기본 아이콘 대신 쓸 아이콘
        var symbol: String?
        /// 글 옆 ⓘ 팝오버 줄(처음 한 번만 필요한 개념, STR-23)
        var info: [String] = []
        /// 상태 옆 단추(예: 숨긴 스트리밍 곡의 [보이기])
        var command: Command?

        /// 글을 접은 폭에서도 남는 아이콘 이름. 진행 표시(`progress`)만 아이콘 대신 돌아가는 표시를 쓴다
        var iconName: String? {
            if kind == .progress { return nil }
            if let symbol { return symbol }
            switch kind {
            case .readOnly: return "lock"
            case .warning: return WarningMark.symbol
            case .hidden: return "eye.slash"
            case .draft: return DraftMark.symbol
            // 단서에도 아이콘이 있어야 글을 접는 폭에서 상태가 통째로 사라지지 않는다
            case .hint, .progress: return "info.circle"
            }
        }
    }
}
