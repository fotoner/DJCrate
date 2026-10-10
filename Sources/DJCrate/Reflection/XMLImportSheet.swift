import DJCApplication
import DJCDomain
import SwiftUI

/// rekordbox XML 가져오기(#72)의 차이 미리 보기. 종류별 탭에서 고른 차이만 초안으로 만든다(rekordbox에는 쓰지 않는다).
struct XMLImportSheet: View {
    @Bindable var model: XMLImportModel
    let preview: XMLImportPreview
    @Environment(\.dismiss) private var dismiss

    typealias Tab = XMLImportModel.Tab

    private var diff: XMLLibraryDiff.Result { preview.diff }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.ui("rekordbox XML 가져오기")).font(.title2.bold())
            Text(verbatim: preview.fileName).foregroundStyle(.secondary)
            if let result = model.result { resultView(result) } else { previewView }
        }
        .padding(24)
        .frame(width: 680, height: 540)
        // 닫으면 계획 중인 초안 만들기를 멈춘다(저장을 시작한 초안은 끝까지 쓴다).
        .onDisappear { model.cancel() }
    }

    // MARK: 미리 보기

    @ViewBuilder private var previewView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: String(ui: "XML 곡 \(diff.matching.xmlTracks) · 맞춘 곡 \(diff.matching.matched) · 라이브러리에 없는 곡 \(diff.matching.unmatched) · 여러 곡에 맞는 곡 \(diff.matching.ambiguous)"))
            if !preview.library.hasGrids {
                Text(.ui("분석 파일 폴더를 찾지 못해 그리드는 비교하지 않았습니다."))
            }
            if diff.counts.xmlWithoutCues + diff.counts.xmlUnreadableCues > 0 {
                Text(verbatim: String(ui: "큐를 비교하지 않은 곡: XML에 큐 없음 \(diff.counts.xmlWithoutCues) · 읽지 못한 큐 있음 \(diff.counts.xmlUnreadableCues)"))
            }
            let skipped = preview.xml.skipped.sorted { $0.key < $1.key }.map { "\($0.key.label) \($0.value)" }
            if !skipped.isEmpty {
                Text(verbatim: String(ui: "읽지 않고 건너뛴 것: \(skipped.joined(separator: " · "))"))
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Picker(.ui("차이 종류"), selection: $model.tab) {
            ForEach(Tab.allCases, id: \.self) { tab in Text(verbatim: label(tab)).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        list.frame(maxWidth: .infinity, maxHeight: .infinity)

        Text(.ui("고른 차이만 초안으로 만듭니다. rekordbox에는 쓰지 않으며, 이미 초안이 있는 곡·목록은 덮지 않습니다."))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            if model.tab != .unmatched {
                Button(.ui("이 탭 모두 고르기")) { model.setAll(true) }
                Button(.ui("이 탭 모두 빼기")) { model.setAll(false) }
            }
            Spacer()
            if model.isMakingDrafts { ProgressView().controlSize(.small) }
            Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(.ui("초안으로 만들기")) { model.startDrafts() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canMakeDrafts)
        }
    }

    @ViewBuilder private var list: some View {
        switch model.tab {
        case .cue, .grid, .tag:
            let kind = model.tab.kind!
            let rows = model.tracks(for: kind)
            if rows.isEmpty { empty } else {
                List(rows, id: \.libraryKey) { track in
                    Toggle(isOn: Binding(get: { model.isChosen(kind: kind, key: track.libraryKey) },
                                         set: { model.setChosen($0, kind: kind, key: track.libraryKey) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: track.title.isEmpty ? track.path : track.title)
                            Text(verbatim: Self.detail(track, kind: kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(Text(verbatim: track.path))
                    .accessibilityLabel(Text(verbatim: track.title))
                }
            }
        case .playlist:
            if diff.playlists.isEmpty { empty } else {
                List(diff.playlists, id: \.path) { change in
                    Toggle(isOn: Binding(get: { model.isChosen(list: change.path) }, set: { model.setChosen($0, list: change.path) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: change.path.joined(separator: " / "))
                            Text(verbatim: Self.detail(change)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .unmatched:
            let rows = model.unmatched
            if rows.isEmpty { empty } else {
                List(rows, id: \.key) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.title)
                        Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var empty: some View {
        Text(.ui("이 종류의 차이가 없습니다.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 결과

    @ViewBuilder private func resultView(_ result: XMLImportDraftResult) -> some View {
        if let failure = result.failure {
            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(UIColors.warning.color)
        } else {
            Text(verbatim: String(ui: "초안을 만들었습니다: 큐 \(result.cues) · 그리드 \(result.grids) · 태그 \(result.tags) · 재생 목록 \(result.playlists)"))
                .font(.headline)
        }
        let notes = result.skipped.map { ($0, true) } + result.losses.map { ($0, false) }
        if notes.isEmpty {
            Spacer()
        } else {
            Text(verbatim: String(ui: "기존 초안이 있어 건너뛴 것 \(result.skipped.count) · 초안에 담지 못한 차이 \(result.losses.count)"))
                .font(.callout).foregroundStyle(.secondary)
            List(Array(notes.enumerated()), id: \.offset) { _, entry in
                let (note, skipped) = entry
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.subject.isEmpty ? note.kind.label : "\(note.kind.label) · \(note.subject)")
                        Text(verbatim: note.reason).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: skipped ? "arrow.uturn.right" : "minus.circle")
                }
            }
            .frame(maxHeight: .infinity)
        }
        Text(.ui("rekordbox에는 아직 쓰지 않았습니다. DJCrate의 rekordbox에 쓰기에서 미리 보고 쓰세요"))
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 값

    private func label(_ tab: Tab) -> String {
        switch tab {
        case .cue: String(ui: "큐 \(diff.counts.cueTracks)")
        case .grid: String(ui: "그리드 \(diff.counts.gridTracks)")
        case .tag: String(ui: "태그 \(diff.counts.tagTracks)")
        case .playlist: String(ui: "재생 목록 \(diff.playlists.count)")
        case .unmatched: String(ui: "못 맞춘 곡 \(diff.matching.unmatched + diff.matching.ambiguous)")
        }
    }

    static func detail(_ track: XMLLibraryDiff.TrackDiff, kind: XMLImportDrafts.Kind) -> String {
        switch kind {
        case .cue:
            guard let cues = track.cues else { return "" }
            // 무엇을 더하고 빼고 고치는지 종류·슬롯·위치로 적는다
            let lines = cues.added.map { "+ " + XMLLibraryDiff.describe($0) }
                + cues.modified.map { "~ " + XMLLibraryDiff.describe($0.library) + " → " + XMLLibraryDiff.describe($0.xml) }
                + cues.removed.map { "− " + XMLLibraryDiff.describe($0) }
            return lines.joined(separator: "\n")
        case .grid:
            guard let grid = track.grid else { return "" }
            func bpm(_ segments: [GridSegment]) -> String {
                segments.first.map { $0.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never)) } ?? "—"
            }
            return String(ui: "BPM \(bpm(grid.library)) → \(bpm(grid.xml)) · 구간 \(grid.library.count) → \(grid.xml.count)")
        case .tag:
            return track.tags.map { String(ui: "\($0.key.label): \($0.library) → \($0.xml)") }.joined(separator: " · ")
        case .playlist:
            return ""
        }
    }

    static func detail(_ change: XMLLibraryDiff.PlaylistChange) -> String {
        switch change.kind {
        case .missing:
            change.unmatchedEntries > 0
                ? String(ui: "없는 목록 · 곡 \(change.xmlEntries.count) · 못 맞춘 곡 \(change.unmatchedEntries)(넣지 않음)")
                : String(ui: "없는 목록 · 곡 \(change.xmlEntries.count)")
        case .changed:
            change.unmatchedEntries > 0
                ? String(ui: "곡이 다른 목록 · XML \(change.xmlEntries.count)곡 · 라이브러리 \(change.libraryEntries.count)곡 · 못 맞춘 곡 \(change.unmatchedEntries)(바꾸지 않음)")
                : String(ui: "곡이 다른 목록 · XML \(change.xmlEntries.count)곡 · 라이브러리 \(change.libraryEntries.count)곡")
        }
    }
}
