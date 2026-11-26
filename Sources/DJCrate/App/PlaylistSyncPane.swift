import AppKit
import DJCDomain
import SwiftUI

/// iTunes·USB 동기화가 같은 트리와 부분 선택 표시를 쓴다.
protocol PlaylistSyncNode: Identifiable {
    var name: String { get }
    var isFolder: Bool { get }
    var children: [Self]? { get }
    var syncIssue: String? { get }
}

extension PlaylistSyncNode {
    var syncIssue: String? { nil }
}

extension PlaylistOutlineNode: PlaylistSyncNode {
    var syncIssue: String? { blockedReason }
}
extension ITunesSyncOutline.Node: PlaylistSyncNode {}

struct PlaylistSyncSelectionControls<Node: PlaylistSyncNode> {
    let state: (Node) -> ITunesSyncSelection.State
    let toggle: (Node) -> Void
    let identifier: (Node) -> String
}

/// 목록 줄에 마우스를 올리면 나오는 글. 뜻이 있는 것부터 하나만 고른다.
enum PlaylistSyncRowHelp {
    /// 막힘 이유, 비활성 이유, 흐린 줄의 뜻 순서이고 모두 없으면 이름(길어서 잘릴 때 전체를 본다)
    static func text(issue: String?, lockedReason: String?, hint: String?, name: String) -> String {
        issue ?? lockedReason ?? hint ?? name
    }
}

struct PlaylistSyncPane<Node: PlaylistSyncNode, Header: View>: View {
    let tree: [Node]
    let isLoading: Bool
    let emptyMessage: String
    let selection: PlaylistSyncSelectionControls<Node>?
    /// 동기화에 이어지지 않은 USB 목록처럼 흐리게 보일 칸
    let dimmed: (Node) -> Bool
    /// 칸 옆에 작게 붙일 표시(동기화 후 미리 보기의 "새로 만듦"·"옮김"·"지움")
    let note: (Node) -> String?
    /// 흐린 칸에 마우스를 올리면 나오는 뜻
    let hint: (Node) -> String?
    /// 선택을 바꿀 수 없게 잠근 이유(없으면 잠기지 않았거나 잠깐 막힌 것). 잠기면 칸과 체크에 이 이유가 툴팁으로 뜬다
    let lockedReason: String?
    @ViewBuilder let header: () -> Header

    init(tree: [Node], isLoading: Bool = false, emptyMessage: String,
         selection: PlaylistSyncSelectionControls<Node>? = nil, dimmed: @escaping (Node) -> Bool = { _ in false },
         note: @escaping (Node) -> String? = { _ in nil }, hint: @escaping (Node) -> String? = { _ in nil },
         lockedReason: String? = nil,
         @ViewBuilder header: @escaping () -> Header) {
        self.tree = tree
        self.isLoading = isLoading
        self.emptyMessage = emptyMessage
        self.selection = selection
        self.dimmed = dimmed
        self.note = note
        self.hint = hint
        self.lockedReason = lockedReason
        self.header = header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header().frame(minHeight: 24)
            List {
                OutlineGroup(tree, children: \.children) { node in
                    HStack {
                        Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                            .lineLimit(1)
                            .help(PlaylistSyncRowHelp.text(issue: node.syncIssue, lockedReason: lockedReason, hint: hint(node), name: node.name))
                            .foregroundStyle(dimmed(node) || lockedReason != nil ? .secondary : .primary)
                        if let note = note(node) {
                            Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
                        }
                        if let issue = node.syncIssue {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange).help(issue).accessibilityLabel(issue)
                        }
                        if let selection {
                            Spacer(minLength: 8)
                            PlaylistSyncCheckbox(name: node.name, state: selection.state(node),
                                                 identifier: selection.identifier(node)) { selection.toggle(node) }
                                .frame(width: 18, height: 18)
                                .help(lockedReason ?? "")
                        }
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if tree.isEmpty {
                    Text(emptyMessage).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                }
            }
        }
    }
}

/// AppKit 체크박스의 부분 선택 표시와 키보드·접근성을 그대로 쓴다.
struct PlaylistSyncCheckbox: NSViewRepresentable {
    let name: String
    let state: ITunesSyncSelection.State
    let identifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.state = switch state { case .off: .off; case .mixed: .mixed; case .on: .on }
        button.setAccessibilityLabel(name)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
