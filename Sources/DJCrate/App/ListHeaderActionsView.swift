import DJCDomain
import SwiftUI

/// 머리 줄 오른쪽(보기 전환 왼쪽): 그 목록의 상태 표시 하나 · 주 단추 하나 · `…` 메뉴(#340).
/// 구성(`ListHeaderActions`)은 화면 모델(`ListActionBarModel.actions`)이 값으로 계산하고, 이 뷰는 그 값만 그린다.
/// 선택·개수·막힘은 이 잎의 본문만 읽는다: 고른 곡이 바뀌어 단추 이름이 달라져도 `ContentView`·`LibraryDetail`·`ListHeaderBar`는 다시 계산하지 않는다.
/// 폭이 모자라면 상태 표시가 글을 접고 아이콘만 남고(툴팁이 이름을 알린다), 그래도 모자라면 쓰기 대기·USB의 주 단추 이름이 덧붙은 말을 덜어낸다.
/// 어느 차례로 줄이는지는 `ListHeaderLayout`이 정한다.
struct ListHeaderActionsView: View {
    let model: ListActionBarModel
    /// 연결되지 않은 초안 시트를 띄우는 주 창 모델
    let window: LibraryWindowModel
    @Environment(\.reflection) private var reflection
    #if DEBUG
    @Environment(\.listHeaderActionsOverride) private var override
    private let debugOverride = ListHeaderActionsDebugOverride.shared
    #endif

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        #if DEBUG
        let actions = override ?? debugOverride.value ?? model.actions
        #else
        let actions = model.actions
        #endif
        let perform: (ListHeaderActions.Action) -> Void = { model.perform($0, reflection: reflection, window: window) }
        // 세 자리는 머리 줄 배치(`ListHeaderLayout`)가 직접 놓는다: 이 뷰의 본문은 자리 뷰만 내보낸다
        Group {
            if let status = actions.status { ListHeaderStatusView(status: status, perform: perform).modifier(ListHeaderLayout.role(.status)) }
            if let primary = actions.primary { primaryButton(primary, perform: perform).modifier(ListHeaderLayout.role(.primary)) }
            if !actions.menu.isEmpty { ListHeaderMoreMenu(items: actions.menu, perform: perform).modifier(ListHeaderLayout.role(.menu)) }
        }
    }

    @ViewBuilder private func primaryButton(_ command: ListHeaderActions.Command, perform: @escaping (ListHeaderActions.Action) -> Void) -> some View {
        Group {
            if command.action == .findInFolder {
                // 폴더를 고르고 비교 시트를 띄우는 단추라 시트를 든 뷰가 직접 처리한다
                RelocateEntryButton(store: model.store, title: command.title, isEnabled: command.isEnabled, help: command.help)
            } else {
                ListHeaderCommandButton(command: command, perform: perform)
            }
        }
        .controlSize(.small)
        .selfTestFrame("listHeader.primary", clearsOnDisappear: true)
    }
}

/// 글자만 있는 단추. 쓰는 단추만 눈에 띄는 모양이다. 툴팁은 막힌 이유나 결과 범위가 있을 때만 단다.
/// 줄인 이름(`compactTitle`)이 있으면 폭이 모자랄 때 그 이름으로 바꾸고, 빠진 말을 툴팁이 알린다
private struct ListHeaderCommandButton: View {
    let command: ListHeaderActions.Command
    let perform: (ListHeaderActions.Action) -> Void

    var body: some View {
        if let compact = command.compactTitle {
            ViewThatFits(in: .horizontal) {
                button(title: command.title, help: command.help)
                button(title: compact, help: command.compactHelp ?? command.help)
            }
        } else {
            button(title: command.title, help: command.help)
        }
    }

    @ViewBuilder private func button(title: String, help: String?) -> some View {
        let base = Button { perform(command.action) } label: { Text(verbatim: title).lineLimit(1) }
            .fixedSize()
            .disabled(!command.isEnabled)
            .help(help ?? "")
        if command.isProminent { base.buttonStyle(.borderedProminent) } else { base.buttonStyle(.bordered) }
    }
}

/// 상태 표시: 아이콘 + 글(+ ⓘ + 단추). 폭이 모자라면 글을 접고 아이콘만 남기며, 그때 툴팁이 이름을 알린다(STR-19).
struct ListHeaderStatusView: View {
    @Environment(\.textScale) private var textScale
    let status: ListHeaderActions.Status
    let perform: (ListHeaderActions.Action) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(showsTitle: true)
            content(showsTitle: false)
        }
        .controlSize(.small)
        .selfTestFrame("listHeader.status", clearsOnDisappear: true)
    }

    private func content(showsTitle: Bool) -> some View {
        HStack(spacing: 6) {
            icon(named: !showsTitle)
            if showsTitle { Text(verbatim: status.title).lineLimit(1) }
            if !status.info.isEmpty { InfoPopoverButton(label: status.title, lines: status.info) }
            if let command = status.command {
                Button(command.title) { perform(command.action) }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(!command.isEnabled)
            }
        }
        .font(.scaled(.callout, textScale))
        .foregroundStyle(tint)
        .fixedSize()
        .help(showsTitle ? (status.detail ?? "") : [status.title, status.detail].compactMap { $0 }.joined(separator: ": "))
    }

    /// 글을 접은 모양(`named`)에서는 아이콘이 이름을 알린다. 옆 단추(ⓘ·[보이기])는 따로 눌러야 해서 묶지 않는다
    @ViewBuilder private func icon(named: Bool) -> some View {
        if status.kind == .progress {
            ProgressView().controlSize(.small).accessibilityLabel(named ? status.title : "")
        } else if let symbol = status.iconName {
            Image(systemName: symbol).accessibilityLabel(named ? status.title : "")
        }
    }

    private var tint: Color {
        switch status.kind {
        case .warning: UIColors.warning.color
        case .draft: UIColors.draft.color
        case .readOnly, .hidden, .progress, .hint: .secondary
        }
    }
}

/// `…` 메뉴: 주 단추 밖의 동작. 항목 이름이 곧 설명이라 툴팁은 막힌 이유나 결과 범위가 있는 항목에만 있다
struct ListHeaderMoreMenu: View {
    let items: [ListHeaderActions.MenuItem]
    let perform: (ListHeaderActions.Action) -> Void

    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case let .command(command):
                    Button { perform(command.action) } label: { Label(command.title, systemImage: command.systemImage) }
                        .disabled(!command.isEnabled)
                        .help(command.help ?? "")
                case let .histories(menu):
                    Menu {
                        ForEach(menu.entries) { entry in
                            Button(entry.name) { perform(.showHistory(entry.id)) }
                        }
                        Divider()
                        Button(menu.excludeAll.title) { perform(menu.excludeAll.action) }
                            .disabled(!menu.excludeAll.isEnabled)
                    } label: {
                        Label(menu.title, systemImage: menu.systemImage)
                    }
                case .divider:
                    Divider()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(ui: "더 보기"))
        .accessibilityLabel(String(ui: "더 보기"))
        .controlSize(.small)
        .selfTestFrame("listHeader.menu", clearsOnDisappear: true)
    }
}

#if DEBUG
import Observation

extension EnvironmentValues {
    /// 화면 시험이 모드별 구성을 값으로 넣어 폭을 잰다(저장소 상태를 만들기 어려운 가장 긴 이름·상태도 시험하려고). 배포 앱에는 없다
    @Entry var listHeaderActionsOverride: ListHeaderActions? = nil
}

/// 자가 테스트가 실제 앱 창에서 모드별 구성(가장 긴 이름)을 값으로 넣어 폭을 잰다(`--search-layout-selftest`). 배포 앱에는 없다
@MainActor @Observable
final class ListHeaderActionsDebugOverride {
    static let shared = ListHeaderActionsDebugOverride()
    var value: ListHeaderActions?
}
#endif
