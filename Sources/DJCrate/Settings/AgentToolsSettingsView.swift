import DJCApplication
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 설정 › AI 에이전트(#262): Claude Code·Codex 스킬과 djc 링크의 상태·설치·갱신·제거. 값과 동작은 `AgentToolsSettingsModel`이 든다.
struct AgentToolsSettingsView: View {
    @Bindable var model: AgentToolsSettingsModel
    @State private var pickingFolder = false

    var body: some View {
        Form {
            Section {
                if let text = model.noPayloadText {
                    Text(text).foregroundStyle(.secondary)
                } else if let version = model.versionText {
                    HStack {
                        Text(version)
                        Spacer()
                        if model.needsUpdate {
                            Button(.ui("모두 갱신")) { model.start(.updateAll) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isWorking)
                        }
                    }
                }
            } footer: {
                HStack(spacing: 4) {
                    Text(.ui("에이전트가 djc로 초안을 만듭니다."))
                    InfoPopoverButton(label: String(ui: "스킬이란?"), lines: [
                        String(ui: "DJCrate 스킬을 설치하면 Claude Code·Codex가 djc로 라이브러리를 조회하고 큐·태그 초안을 만듭니다. rekordbox에 쓰는 일은 앱에서 사람이 합니다.")])
                }
                .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.skillRows) { row in
                    AgentSkillRowView(row: row, isWorking: model.isWorking,
                                      onInstall: { model.start(.install(row.target)) },
                                      onRemove: { model.start(.remove(row.target)) },
                                      onForget: row.target.isCustom ? { model.removeCustomFolder(row.target) } : nil)
                }
                HStack {
                    Spacer()
                    Button(.ui("다른 위치…")) { pickingFolder = true }
                }
            } header: {
                Text(.ui("스킬"))
            } footer: {
                // 위치는 행이, 휴지통으로 옮기는 일은 바꾸기 직전 확인 창이 말한다. 지금 할 일이 있는 경고만 남긴다
                if let legacy = model.legacyCodexText { Text(legacy).foregroundStyle(.orange) }
            }
            if let command = model.commandRow {
                Section {
                    AgentCommandRowView(row: command, isWorking: model.isWorking,
                                        onLink: { model.start(.linkCommand) }, onUnlink: { model.start(.unlinkCommand) })
                    if let path = model.pathText {
                        VStack(alignment: .leading, spacing: 6) {
                            if path.isInPath {
                                Label(path.text, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text(path.text).foregroundStyle(.secondary)
                            }
                            if let line = path.line {
                                Text(verbatim: line)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                } header: {
                    Text(.ui("명령줄 도구 djc"))
                }
            }
            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(model.lastFailed ? .orange : .secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .task { await model.refresh() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { model.addCustomFolder(url) }
        }
    }
}

/// 스킬 자리 한 줄(값과 동작만 받는다)
struct AgentSkillRowView: View {
    let row: AgentToolsSettingsModel.SkillRow
    let isWorking: Bool
    let onInstall: () -> Void
    let onRemove: () -> Void
    let onForget: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.title).fontWeight(.semibold)
                    Text(verbatim: row.location).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(row.status).foregroundStyle(Self.tint(row.state.badge))
                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            HStack {
                if let title = row.installTitle { Button(title, action: onInstall) }
                if row.canRemove { Button(.ui("제거"), action: onRemove) }
                if let onForget { Button(.ui("목록에서 빼기"), action: onForget) }
            }
            .disabled(isWorking)
        }
    }

    static func tint(_ badge: AgentInstallBadge) -> Color {
        switch badge {
        case .installed: .green
        case .outdated, .modified: .orange
        case .notInstalled, .foreign: .secondary
        }
    }
}

/// djc 링크 한 줄(값과 동작만 받는다)
struct AgentCommandRowView: View {
    let row: AgentToolsSettingsModel.CommandRow
    let isWorking: Bool
    let onLink: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.location).fontWeight(.semibold).textSelection(.enabled)
                Text(row.status)
                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            HStack {
                if let title = row.linkTitle { Button(title, action: onLink) }
                if row.canUnlink { Button(.ui("링크 지우기"), action: onUnlink) }
            }
            .disabled(isWorking)
        }
    }
}
