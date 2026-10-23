import AppKit
import DJCDomain
import SwiftUI

/// 활동 기록 시트(#296): 왼쪽은 최근 것부터의 알림 목록, 오른쪽은 고른 항목의 자세한 내용(쓰기 결과면 백업 위치).
struct ActivityLogView: View {
    @Bindable var model: ActivityLogModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.ui("활동 기록")).font(.title2.bold())
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.entries.isEmpty {
                Text(.ui("아직 활동 기록이 없습니다."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(model.entries, selection: $model.selection) { entry in
                        ActivityLogRow(entry: entry)
                    }
                    .frame(width: 280)
                    Divider()
                    ScrollView {
                        if let entry = model.selected { ActivityEntryDetail(entry: entry) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            HStack { Spacer(); Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 820, height: 540)
    }
}

/// 목록 한 줄: 종류 아이콘 + 제목 + 시각(같은 알림이 잇달아 떴으면 횟수). 활동 팝오버(#298)도 같은 줄을 쓴다
struct ActivityLogRow: View {
    /// 아이콘 칸 폭. 아이콘마다 폭이 달라 실패 줄 제목이 2~3pt 밀렸다(#298). 칸을 고정해 제목 줄을 맞춘다
    static let iconWidth: CGFloat = 18
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind.icon).foregroundStyle(entry.kind.tint)
                .frame(width: Self.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.listTime)
                    if entry.count > 1 { Text(verbatim: "×\(entry.count)").monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 고른 항목의 자세한 내용. 쓰기 결과면 백업 위치와 Finder 열기를 함께 보인다.
struct ActivityEntryDetail: View {
    let entry: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(entry.title, systemImage: entry.kind.icon).font(.headline).foregroundStyle(entry.kind.tint)
            Text(entry.detailTime).foregroundStyle(.secondary)
            if entry.count > 1 {
                Text(.ui("같은 알림이 잇달아 \(entry.count)번 떴습니다. 시각은 마지막으로 뜬 때입니다."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let detail = entry.detail { Text(detail).frame(maxWidth: .infinity, alignment: .leading) }
            if let result = entry.result {
                Text(.ui("백업 위치")).font(.headline)
                if result.backups.isEmpty { Text(.ui("이 결과에 연결된 백업이 없습니다.")).foregroundStyle(.secondary) }
                ForEach(result.backups, id: \.self) { url in
                    Text(url.path).font(.callout.monospaced())
                    Button(.ui("Finder에서 백업 보기")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                }
                if !result.backups.isEmpty { Text(.ui("정리되거나 이동한 백업은 열 수 없습니다.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
