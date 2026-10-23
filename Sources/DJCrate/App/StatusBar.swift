import DJCDomain
import SwiftUI

/// 창 맨 아래 상태 줄(#298). 왼쪽은 저장 상태(1-5) 자리로 비워 두고, 오른쪽에 활동 단추를 둔다.
/// 이 줄만 화면 모델을 읽는다. 읽지 않은 수가 바뀌어도 주 창 본문(`ContentView`)을 다시 계산하지 않는다.
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
