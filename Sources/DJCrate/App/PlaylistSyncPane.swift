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

struct PlaylistSyncPane<Node: PlaylistSyncNode, Header: View>: View {
    let tree: [Node]
    let isLoading: Bool
    let emptyMessage: String
    let selection: PlaylistSyncSelectionControls<Node>?
    /// 동기화에 이어지지 않은 USB 목록처럼 흐리게 보일 칸
    let dimmed: (Node) -> Bool
    /// 칸 옆에 작게 붙일 설명(동기화 후 미리 보기의 "새로 만듦"·"옮김")
    let note: (Node) -> String?
    @ViewBuilder let header: () -> Header

    init(tree: [Node], isLoading: Bool = false, emptyMessage: String,
         selection: PlaylistSyncSelectionControls<Node>? = nil, dimmed: @escaping (Node) -> Bool = { _ in false },
         note: @escaping (Node) -> String? = { _ in nil },
         @ViewBuilder header: @escaping () -> Header) {
        self.tree = tree
        self.isLoading = isLoading
        self.emptyMessage = emptyMessage
        self.selection = selection
        self.dimmed = dimmed
        self.note = note
        self.header = header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header().frame(minHeight: 24)
            List {
                OutlineGroup(tree, children: \.children) { node in
                    HStack {
                        Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                            .lineLimit(1).help(node.syncIssue ?? node.name)
                            .foregroundStyle(dimmed(node) ? .secondary : .primary)
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
