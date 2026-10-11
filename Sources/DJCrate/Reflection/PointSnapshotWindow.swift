import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

/// 시점 스냅샷 창(#224·#225): 지금 상태를 이름 붙여 남기고, 시점 스냅샷과 쓰기 전 백업을 한 목록에서 보고, 스냅샷을 고정한다.
/// 고른 스냅샷을 지금과 비교하고, 확인 창 하나를 거쳐 그 시점으로 복원한다(되돌릴 수 없는 외부 쓰기라 묻는다).
/// 쓰기 전 백업은 따로 정리되고 '쓰기 전으로 복원…'으로 되돌리므로 여기서는 보기만 한다(#223 결정).
@MainActor
final class PointSnapshotWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: PointSnapshotModel?
    /// 저장소의 대상(쓰기·복원과 같은 곳)으로 시점 스냅샷 유스케이스를 만든다(조립 지점이 실제 구현을 고른다)
    private let points: @MainActor (LibraryStore) -> PointSnapshots

    init(points: @escaping @MainActor (LibraryStore) -> PointSnapshots) {
        self.points = points
    }

    func open(store: LibraryStore, reflection: ReflectionCoordinator) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            model?.startRefresh()
            return
        }
        let model = PointSnapshotModel(store: store, reflection: reflection, points: points(store))
        let window = NSWindow(contentViewController: NSHostingController(rootView: PointSnapshotView(model: model)))
        window.title = String(ui: "시점 스냅샷")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 520))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.isWorking != true }
}

struct PointSnapshotView: View {
    @State var model: PointSnapshotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(.ui("이름(선택)"), text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startCreate() }
                    .frame(maxWidth: 320)
                Button(.ui("지금 스냅샷 남기기")) { model.startCreate() }
                    .disabled(model.isWorking || model.blockReason != nil)
                    .help(model.blockReason ?? String(ui: "rekordbox 라이브러리(DB·분석 파일·앨범아트)를 지금 시점으로 남깁니다"))
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(.ui("rekordbox가 꺼져 있을 때만 남깁니다. 수동·고정 스냅샷은 지우지 않고, 쓰기 전 백업은 따로 정리됩니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.cloneNote {
                Label { Text(verbatim: note) } icon: { Image(systemName: "externaldrive") }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(model.rows, selection: $model.selection) {
                TableColumn(.ui("시각")) { row in
                    Text(verbatim: row.date.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 130, ideal: 150)
                TableColumn(.ui("이름")) { row in
                    Text(verbatim: row.name.isEmpty ? "—" : row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.entry == nil ? .secondary : .primary)
                }
                .width(min: 140, ideal: 240)
                TableColumn(.ui("종류")) { row in Text(verbatim: row.kind) }
                    .width(min: 80, ideal: 100)
                TableColumn(.ui("크기")) { row in
                    Text(verbatim: row.bytes.map { $0.formatted(.byteCount(style: .file).locale(UIStrings.locale)) } ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
                TableColumn(.ui("고정")) { row in
                    if row.entry != nil {
                        Button {
                            model.startTogglePin(row)
                        } label: {
                            Image(systemName: row.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(row.pinned ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(row.pinned ? String(ui: "고정 풀기") : String(ui: "고정하면 자동 정리에서 지우지 않습니다"))
                        .accessibilityLabel(row.pinned ? Text(.ui("고정 풀기")) : Text(.ui("고정")))
                    }
                }
                .width(44)
            }
            if let diff = model.comparison, model.comparedID == model.selection {
                PointSnapshotComparisonView(diff: diff)
            }
            HStack {
                if let message = model.message {
                    Label { Text(verbatim: message) } icon: {
                        Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    }
                    .foregroundStyle(model.isError ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(.ui("현재와 비교")) { model.startCompare() }
                .disabled(model.selectedRow?.entry == nil || model.isWorking)
                .help(String(ui: "이 시점으로 복원하면 무엇이 바뀌는지 봅니다"))
                Button(.ui("이 시점으로 복원…")) { model.startRestore() }
                .disabled(model.selectedRow?.entry == nil || model.isWorking || model.blockReason != nil)
                .help(model.blockReason ?? String(ui: "rekordbox 라이브러리를 고른 시점으로 되돌립니다(rekordbox를 끈 뒤)"))
                Button(.ui("지우기…")) { model.startDelete() }
                .disabled(model.selectedRow?.entry == nil || model.selectedRow?.pinned == true || model.isWorking)
                .help(model.selectedRow?.pinned == true ? String(ui: "고정을 푼 뒤 지우세요") : String(ui: "고른 시점 스냅샷을 지웁니다"))
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 400)
        .task { await model.refresh() }
    }
}

/// 비교 결과: 요약 줄과 펼쳐 보기
struct PointSnapshotComparisonView: View {
    let diff: RekordboxPointSnapshotDiff

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if diff.isEmpty {
                    Text(.ui("지금 라이브러리와 다른 곳이 없습니다."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: diff.summary.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(.ui("자세히")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(diff.details(), id: \.title) { group in
                                    Text(verbatim: group.title).font(.callout.bold())
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { item in
                                        Text(verbatim: "• " + item.element).font(.callout)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(.ui("복원하면 바뀌는 것"))
        }
    }
}
