import DJCDomain
import SwiftUI

/// 창 맨 아래 상태 줄(#298). 왼쪽은 비워 두고, 오른쪽에 rekordbox 쓰기 상태(#324)와 활동 단추를 둔다. 쓰기 상태 칩은 활동 종 바로 왼쪽이다.
/// 이 줄만 화면 모델을 읽는다. 읽지 않은 수와 쓰기 상태가 바뀌어도 주 창 본문(`ContentView`)을 다시 계산하지 않는다.
/// 쓰기 상태는 구역(`WriteStatusSection`)이 따로 읽어, 쓰기 상태가 바뀔 때 이 줄의 활동 단추까지 다시 계산하지 않는다.
struct StatusBar: View {
    /// 줄 높이(위 구분선 포함). 창 알림은 이만큼 올려 띄운다
    static let height: CGFloat = 25
    @Bindable var model: StatusBarModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let write = model.write { WriteStatusSection(model: write) }
                ActivityButton(unread: model.unreadCount, kind: model.unreadKind, action: { model.togglePopover() })
                    .popover(isPresented: $model.isPresented, arrowEdge: .top) { ActivityPopover(model: model) }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .background(.bar)
        .selfTestFrame(model.frameKey)
    }
}

/// 활동 단추: 종 아이콘. 읽지 않은 알림이 있으면 가장 무거운 종류 색의 점과 수를 붙인다
struct ActivityButton: View {
    let unread: Int
    let kind: AppToast.Kind?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "bell")
                if unread > 0, let kind {
                    Circle().fill(kind.tint).frame(width: 7, height: 7)
                    Text(unread, format: .number).monospacedDigit()
                }
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(.ui("최근 알림을 봅니다"))
        .accessibilityLabel(unread > 0 ? String(ui: "활동 기록, 읽지 않은 알림 \(unread)건") : String(ui: "활동 기록"))
        .selfTestFrame("statusBarActivity")
    }
}

/// 활동 팝오버(#298): 최근 알림을 활동 기록 창과 같은 줄로 보인다. 줄을 누르면 그 자리에서 자세한 내용을 펼친다.
/// 팝오버의 화면 모델은 상태 줄과 같은 것이다(열고 닫기·펼친 항목·읽음 기준을 함께 든다).
struct ActivityPopover: View {
    let model: StatusBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(.ui("최근 알림")).font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if model.recent.isEmpty {
                Text(.ui("아직 활동 기록이 없습니다."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.recent) { entry in
                            ActivityPopoverRow(entry: entry, isFresh: model.fresh.contains(entry.id), isExpanded: model.expanded == entry.id,
                                               toggle: { model.toggleExpanded(entry.id) }, showInLog: { model.showAll(selecting: entry.id) })
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(.ui("모두 보기…")) { model.showAll() }
            }
            .padding(10)
        }
        .frame(width: 380)
        .selfTestFrame("activityPopover")
    }
}

/// 팝오버 한 줄: 활동 기록 창과 같은 줄 + (읽지 않았던 점) + 펼침 표시. 펼치면 자세한 내용과 활동 기록 창 입구를 보인다
struct ActivityPopoverRow: View {
    let entry: ActivityEntry
    let isFresh: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let showInLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    ActivityLogRow(entry: entry)
                    Spacer(minLength: 0)
                    if isFresh {
                        Circle().fill(entry.kind.tint).frame(width: 7, height: 7)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isFresh ? String(ui: "읽지 않음") : "")
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.detailTime).font(.caption).foregroundStyle(.secondary)
                    if let detail = entry.detail {
                        // 긴 쓰기 결과는 앞부분만 보이고 전체는 활동 기록 창에서 본다
                        Text(detail).font(.callout).lineLimit(8).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(.ui("활동 기록에서 보기…"), action: showInLog).controlSize(.small)
                }
                .padding(.leading, ActivityLogRow.iconWidth + 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// rekordbox 쓰기 상태 구역(#324): 보조 글(마지막 쓰기) + 상태 칩 + 쓰기 대기가 있을 때 [쓰기] 단추. 칩을 누르면 상태 팝오버가 열린다.
/// rekordbox가 켜져 있는지·꺼졌는지(#326)는 칩 글자에 이유로 붙고, 꺼진 것을 확인하면 [쓰기]가 [지금 쓰기]로 강조된다(같은 명령).
/// 쓸 수 없는 라이브러리(#327)는 칩이 「rekordbox에 쓸 수 없음」이고 이유를 칩 툴팁과 팝오버 맨 위에 보인다. 그때는 [쓰기]를 보이지 않는다.
/// 이 구역만 쓰기 상태를 읽는다. 값과 클로저만 잎 뷰에 넘긴다.
struct WriteStatusSection: View {
    @Bindable var model: ReflectionStatusModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        HStack(spacing: 8) {
            if let caption = model.lastWriteText {
                // 폭이 모자라면 잘라 보이는 대신 통째로 숨긴다
                ViewThatFits(in: .horizontal) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            WriteStatusChip(chip: model.chip, help: model.chip.blockReason, action: { model.isPresented.toggle() })
                .popover(isPresented: $model.isPresented, arrowEdge: .top) {
                    WriteStatusPopover(title: model.chip.title, lines: model.popoverLines, items: model.items, perform: { model.perform($0) })
                }
            if model.showsWriteButton {
                WriteStatusButton(title: model.writeButtonTitle, isEmphasized: model.emphasizesWrite, isEnabled: model.canWrite,
                                  disabledReason: model.writeDisabledReason, action: { model.perform(.reflect) })
            }
        }
    }
}

/// 칩 옆 쓰기 단추: [쓰기], rekordbox가 꺼진 것을 확인하면 강조한 [지금 쓰기]. 둘 다 같은 명령과 같은 막힘 조건이다(메뉴 막대와 같다)
struct WriteStatusButton: View {
    let title: String
    let isEmphasized: Bool
    let isEnabled: Bool
    let disabledReason: String?
    let action: () -> Void

    var body: some View {
        Group {
            if isEmphasized {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
            }
        }
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(isEnabled ? "" : disabledReason ?? "")
        .selfTestFrame("statusBarWriteButton")
    }
}

/// 쓰기 상태 칩: 모양과 글자로 상태를 알린다(쓰기 대기는 초안 표식과 같은 연필, 쓸 수 없음은 경고 삼각형, 쓰는 중은 진행 표시)
struct WriteStatusChip: View {
    let chip: ReflectionChip
    /// 툴팁(쓸 수 없는 이유). 없으면 달지 않는다
    let help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                switch chip {
                case .clean: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                case .pending: Image(systemName: DraftMark.symbol).foregroundStyle(UIColors.draft.color)
                case .blocked: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppToast.Kind.warning.tint)
                case .writing: ProgressView().controlSize(.mini)
                }
                Text(chip.title).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? "")
        .accessibilityLabel(chip.title)
        .accessibilityHint(help ?? "")
        .selfTestFrame("statusBarWriteChip")
    }
}

/// 쓰기 상태 팝오버: 상태 한 줄과 보조 글, 그 아래 메뉴 막대와 같은 명령 넷. 막힌 명령은 흐리게 두고 이유를 툴팁으로 알린다.
struct WriteStatusPopover: View {
    let title: String
    /// 상태 아래 보조 글(쓸 수 없는 이유·할 일·재생 목록 편집 건수·마지막 쓰기)
    let lines: [String]
    let items: [ReflectionStatusModel.Item]
    let perform: (LibraryMenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                // 쓸 수 없는 이유는 할 일까지 한 문장이라 길다. 잘라 보이지 않고 줄을 바꾼다
                ForEach(lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in WriteStatusPopoverRow(item: item, perform: { perform(item.action) }) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .selfTestFrame("writeStatusPopover")
    }
}

/// 팝오버 한 줄: 명령 이름과 단축키 안내
struct WriteStatusPopoverRow: View {
    let item: ReflectionStatusModel.Item
    let perform: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 16) {
                Text(item.title)
                Spacer(minLength: 0)
                if let hint = item.shortcutHint { Text(hint).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering && item.isEnabled ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .onHover { isHovering = $0 }
        .help(item.disabledReason ?? "")
    }
}
