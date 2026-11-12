import DJCDomain
import Foundation

/// 곡 목록이 비었을 때 가운데 안내(#340). 뷰(`EmptyLibraryOverlay`)는 이 값을 그리기만 한다.
/// 한 화면에서 같은 이유는 한 곳에서만 말한다(STR-21): 곡이 없으면 이 안내가, 곡이 있으면 머리 줄(`ListHeaderActions`)이 말한다.
/// 그래서 계산한 목록의 주의("rekordbox 화면과 다를 수 있다")와 쓰기 대기의 재생 기록 건수는 여기서 되풀이하지 않는다.
enum EmptyListNotice: Equatable {
    case noResults(NoResultsGuide)
    case message(Message)

    struct Message: Equatable {
        var title: String
        var description: String?
        var systemImage: String
        var action: Action?

        init(title: String, description: String? = nil, systemImage: String, action: Action? = nil) {
            self.title = title
            self.description = description
            self.systemImage = systemImage
            self.action = action
        }
    }

    /// 안내 아래 단추 하나(빈 화면의 첫 행동, STR-24)
    struct Action: Equatable {
        enum Kind: Equatable {
            case addFiles
            case showStreaming
        }

        var title: String
        var kind: Kind

        @MainActor func perform(store: LibraryStore) {
            switch kind {
            case .addFiles: StagingPanels.chooseFiles(store: store)
            case .showStreaming: store.showHiddenStreaming()
            }
        }
    }

    @MainActor static func resolve(store: LibraryStore) -> EmptyListNotice {
        // 스마트 목록 계산 실패가 먼저, 다음은 검색어, 필터만 켜졌으면 그 뒤에 안내한다(#299: 시스템 검색 화면 대신 앱 문구)
        let guide = NoResultsGuide(search: store.search, isFiltered: store.isAttributeFiltered,
                                   hasUnwrittenEdits: store.isAttributeFiltered && store.pendingWriteCount > 0)
        let smart = store.playlists.selectedSmartPlaylistResult
        return resolve(guide: guide, smartSummary: smart?.unsupportedSummary, hasSmartResult: smart != nil,
                       streamingHidden: store.streamingHiddenInView, sidebar: store.sidebar,
                       pendingHistories: store.history.pendingHistories.count, isUsbSelection: store.isUsbSelection)
    }

    static func resolve(guide: NoResultsGuide?, smartSummary: String?, hasSmartResult: Bool, streamingHidden: Int, sidebar: SidebarItem,
                        pendingHistories: Int, isUsbSelection: Bool) -> EmptyListNotice {
        // 계산하지 못한 목록은 검색어와 상관없이 곡이 없고 머리 줄도 말하지 않는다. 검색 안내보다 먼저 그 사실을 말한다
        if let smartSummary {
            return .message(Message(title: String(ui: "조건을 계산하지 못했습니다"),
                                    description: String(ui: "\(smartSummary). rekordbox에서 이 목록을 확인하세요."), systemImage: WarningMark.symbol))
        }
        if let guide, guide.offersClearSearch { return .noResults(guide) }
        if let guide { return .noResults(guide) }
        if hasSmartResult, streamingHidden == 0 {
            // 계산한 결과라는 주의는 머리 줄의 읽기 전용 표시(ⓘ)가 말한다
            return .message(Message(title: String(ui: "조건에 맞는 곡이 없습니다"), systemImage: "music.note.list"))
        }
        if sidebar == .pending, pendingHistories > 0 {
            // 쓰기 대기 재생 기록(#43)은 곡 줄이 아니라 위 쓰기 단추에서 함께 쓴다. 건수는 그 단추 이름이 말한다
            return .message(Message(title: String(ui: "저장할 곡 편집이 없습니다"), description: String(ui: "위 저장 단추로 재생 기록을 rekordbox에 넣습니다."),
                                    systemImage: "clock.arrow.circlepath"))
        }
        if sidebar == .pending {
            return .message(Message(title: String(ui: "저장할 편집이 없습니다"), description: String(ui: "곡의 큐·그리드·게인을 고치면 여기에 모입니다."),
                                    systemImage: "checkmark.circle"))
        }
        if isUsbSelection {
            return .message(Message(title: String(ui: "표시할 USB 곡이 없습니다"), description: String(ui: "USB를 다시 읽거나 다른 재생 목록을 고르세요."),
                                    systemImage: "externaldrive"))
        }
        if sidebar == .staged {
            return .message(Message(title: String(ui: "추가한 곡이 없습니다"), description: String(ui: "음원 파일을 끌어다 놓으세요."), systemImage: "music.note",
                                    action: Action(title: String(ui: "곡 추가…"), kind: .addFiles)))
        }
        if streamingHidden > 0 {
            // "설정에서 끄세요"라고 글로 안내하지 않고 그 자리에서 푼다
            return .message(Message(title: String(ui: "이 목록은 스트리밍 곡뿐입니다"), systemImage: "eye.slash",
                                    action: Action(title: String(ui: "스트리밍 곡 보이기"), kind: .showStreaming)))
        }
        return .message(Message(title: String(ui: "표시할 곡이 없습니다"), description: String(ui: "다른 목록을 고르거나 rekordbox와 동기화하세요."),
                                systemImage: "music.note.list"))
    }
}
