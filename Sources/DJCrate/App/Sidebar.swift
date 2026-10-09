import DJCApplication
import DJCDomain
import AppKit
import SwiftUI

/// 사이드바 본문은 목록 구조(어떤 줄·구역이 있나)만 읽는다. 배지·진행 값·펼침 설정은 줄·구역 뷰가 각자 읽는다(#141).
/// 본문이 다시 계산되면 List가 재생 목록 수백 개를 모두 다시 비교해(약 50~120ms) 덱에 곡을 올릴 때마다 화면이 멈칫했다.
/// 그래서 이 뷰는 `@AppStorage`도 들지 않는다. 그런 값을 든 뷰는 부모(ContentView)가 다시 계산될 때마다 바뀐 것으로 보여
/// 본문이 새로 계산된다.
struct Sidebar: View {
    @Bindable var store: LibraryStore

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        List(selection: $store.sidebar) {
            Section {
                ForEach(LibraryFilter.visible(commentPreset: store.commentPreset, hidingStreaming: store.hideStreaming)) { filter in
                    SidebarFilterRow(store: store, filter: filter)
                        .tag(SidebarItem.filter(filter))
                }
                SidebarDuplicatesRow(store: store)
                    .tag(SidebarItem.duplicates)
            } header: {
                Text(.ui("라이브러리")).sidebarSectionHeader()
            }
            Section {
                SidebarStagedRow(store: store)
                    .tag(SidebarItem.staged)
                SidebarPendingRow(store: store)
                    .tag(SidebarItem.pending)
                SidebarLastWriteResultRow(store: store)
                // 진행 줄은 넣고 빼야 해서 본문이 시작·끝만 읽고, 진행(done/total)은 줄이 읽는다.
                if store.hasGridJob { SidebarGridJobRow(store: store) }
                if store.hasXMLExportJob { SidebarXMLExportRow(store: store) }
            } header: {
                Text(verbatim: "DJCrate").sidebarSectionHeader()
            }
            if case .loaded = store.phase {
                PlaylistSection(store: store)
                ITunesPlaylistSection(store: store)
            }
            SidebarHistorySection(store: store)
            if let usb = store.usb {
                UsbSidebarSection(store: store, usb: usb)
            }
            SidebarStatusSections(store: store)
        }
        .modifier(PlaylistSidebarMenu(store: store))
    }
}

/// 라이브러리 필터 줄. 개수는 이 뷰의 본문만 읽는다.
struct SidebarFilterRow: View {
    let store: LibraryStore
    let filter: LibraryFilter

    var body: some View {
        Label(filter.title, systemImage: filter.systemImage)
            .badge(store.count(filter))
    }
}

struct SidebarDuplicatesRow: View {
    let store: LibraryStore

    var body: some View {
        Label(.ui("중복 후보"), systemImage: "square.on.square")
            .badge(store.duplicateGroups.count)
            .help(.ui("제목·아티스트가 같고 길이 차이가 2초 이내인 후보 묶음"))
    }
}

struct SidebarStagedRow: View {
    let store: LibraryStore

    var body: some View {
        Label(.ui("추가한 곡"), systemImage: "tray.and.arrow.down")
            .badge(store.staged.count)
    }
}

/// 쓰기 대기 배지. 개수는 초안 여러 종류의 합집합이라 읽는 값이 많다. 쓰기 대기 재생 기록(#43)도 센다.
struct SidebarPendingRow: View {
    let store: LibraryStore

    var body: some View {
        Label(.ui("rekordbox 쓰기 대기"), systemImage: "square.and.arrow.up.on.square")
            .badge(store.pendingWriteCount)
            .help(.ui("rekordbox에 쓸 곡 초안과 USB 재생 기록을 모아 봅니다. 재생 목록 초안도 함께 쓸 수 있습니다."))
    }
}

struct SidebarLastWriteResultRow: View {
    let store: LibraryStore

    var body: some View {
        Button { store.showingWriteResult = true } label: {
            Label(.ui("마지막 쓰기 결과…"), systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.plain)
        .disabled(store.isWritingRekordbox)
    }
}

/// 그리드 일괄 추정 진행 줄. 곡마다 진행이 오르므로 이 뷰만 다시 계산된다.
struct SidebarGridJobRow: View {
    let store: LibraryStore

    var body: some View {
        if let job = store.gridJob {
            HStack(spacing: 6) {
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).controlSize(.small)
                Text(.ui("그리드 추정 \(job.done)/\(job.total)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// 라이브러리 XML 내보내기 진행 줄. 진행이 오를 때마다 이 뷰만 다시 계산된다.
struct SidebarXMLExportRow: View {
    let store: LibraryStore

    var body: some View {
        if let job = store.xmlExportJob {
            // 사이드바 폭에서 문구가 잘리지 않게 막대를 문구 아래에 둔다.
            VStack(alignment: .leading, spacing: 3) {
                Text(.ui("라이브러리 XML 내보내는 중")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if job.isPreparing { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                else { ProgressView(value: job.fraction).controlSize(.small) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// 재생 기록 구역: rekordbox Histories처럼 연 › 월 › 기록(모두 오래된 것부터). rekordbox 기록과 USB에서 보존한 기록을 섞는다(#43).
/// 본문은 트리 구조(`historyTree`)만 읽고, 곡 수·USB 표시는 줄 뷰가 읽는다(#141). 구역 펼침 설정은 여기서 읽는다.
struct SidebarHistorySection: View {
    let store: LibraryStore
    @AppStorage(SettingKeys.sidebarHistoriesExpanded.name) private var isExpanded = SettingKeys.sidebarHistoriesExpanded.defaultValue

    var body: some View {
        Section(isExpanded: $isExpanded) {
            let tree = store.historyTree
            if tree.isEmpty {
                Text(.ui("재생 기록이 없습니다")).foregroundStyle(.secondary)
            }
            ForEach(tree.years) { year in
                SidebarHistoryYearRow(store: store, year: year)
            }
            // 연·월을 모르는 기록은 트리 아래에 바로 둔다
            ForEach(tree.undated) { item in
                SidebarHistoryRow(store: store, item: item)
                    .tag(SidebarItem.history(item.id))
            }
        } header: {
            Text(.ui("재생 기록")).sidebarSectionHeader()
        }
    }
}

/// 연 폴더. 펼침은 스토어에 둔다(기록을 고르면 그 폴더를 펼친다). 폴더는 고르는 대상이 아니라 태그를 달지 않는다
struct SidebarHistoryYearRow: View {
    let store: LibraryStore
    let year: HistoryTree.Year

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { store.expandedHistoryFolders.contains(year.id) },
            set: { store.setHistoryFolder(year.id, expanded: $0) }
        )) {
            ForEach(year.months) { month in
                SidebarHistoryMonthRow(store: store, month: month)
            }
        } label: {
            Text(verbatim: String(year.year))
        }
    }
}

/// 월 폴더(이름은 앱 화면 언어의 월 이름)
struct SidebarHistoryMonthRow: View {
    let store: LibraryStore
    let month: HistoryTree.Month

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { store.expandedHistoryFolders.contains(month.id) },
            set: { store.setHistoryFolder(month.id, expanded: $0) }
        )) {
            ForEach(month.items) { item in
                SidebarHistoryRow(store: store, item: item)
                    .tag(SidebarItem.history(item.id))
            }
        } label: {
            Text(verbatim: Self.name(of: month.month))
        }
    }

    /// 화면 언어(`UIStrings.locale`)의 월 이름(한국어 "8월", 영어 "August", 일본어 "8月")
    static func name(of month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = UIStrings.locale
        let symbols = calendar.standaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
    }
}

/// 기록 줄. 곡 수와 USB 보존·쓰기 대기 표시는 이 뷰만 읽는다
struct SidebarHistoryRow: View {
    let store: LibraryStore
    let item: HistoryTree.Item

    var body: some View {
        let archived = store.archivedHistory(item.id)
        let pending = archived != nil && store.pendingHistoryIDs.contains(item.id)
        HStack(spacing: 4) {
            Text(verbatim: item.name)
                .lineLimit(1)
            if archived != nil {
                Image(systemName: "externaldrive")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(.ui("USB에서 가져온 기록"))
            }
            // 아직 rekordbox에 쓰지 않은 초안과 같은 표식(쓰기 대기)
            if pending {
                Image(systemName: DraftMark.symbol)
                    .imageScale(.small)
                    .foregroundStyle(UIColors.draft.color)
                    .accessibilityLabel(.ui("rekordbox 쓰기 대기"))
            }
        }
        .badge(store.historyCount(item.id))
        .help(archived.map { archivedHelp($0, pending: pending) } ?? store.historyIndex[item.id].map { store.historyTitle($0) } ?? item.name)
    }

    /// 보존 기록의 도움말: 어디서 가져왔는지와 rekordbox 쓰기 상태
    private func archivedHelp(_ archived: ArchivedHistory, pending: Bool) -> String {
        let volume = archived.source.volumeName
        if pending {
            return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. rekordbox 쓰기 대기에 있어 rekordbox에 쓰기(⇧⌘E) 때 rekordbox 재생 기록에 넣습니다")
        }
        if archived.excludedFromRekordbox {
            return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. rekordbox 쓰기 대기에서 뺐습니다")
        }
        if let id = archived.rekordboxHistoryID, store.historyIndex[id] != nil {
            return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. rekordbox에 썼습니다")
        }
        if HistoryWriteQueue.hasRepeatedTracks(archived) {
            return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. 같은 곡이 두 번 이상 들어 DJCrate는 rekordbox에 쓰지 않으니 rekordbox에서 USB를 연결해 직접 가져오세요")
        }
        if archived.matchedContentIDs.isEmpty {
            return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. 컬렉션에 있는 곡이 없어 rekordbox에는 쓰지 않습니다")
        }
        return String(ui: "USB ‘\(volume)’에서 가져와 DJCrate에 보존한 기록입니다. rekordbox에는 없습니다")
    }
}

/// 현황·스냅샷 구역(설정의 '현황·스냅샷 보이기'). 켜짐·펼침 설정은 여기서 읽는다.
struct SidebarStatusSections: View {
    let store: LibraryStore
    @AppStorage(SettingKeys.sidebarSummaryExpanded.name) private var summaryExpanded = SettingKeys.sidebarSummaryExpanded.defaultValue
    @AppStorage(SettingKeys.sidebarShowsStatus.name) private var showsStatus = SettingKeys.sidebarShowsStatus.defaultValue

    var body: some View {
        if showsStatus, let report = store.report {
            Section(isExpanded: $summaryExpanded) {
                LabeledContent(.ui("실제 컬렉션"), value: report.liveTracks.formatted())
                LabeledContent(.ui("삭제 행(제외)"), value: report.deletedRows.formatted())
                if store.commentRuleEnabled {
                    LabeledContent(.ui("규칙 코멘트"), value: report.matchingComments.formatted())
                }
                LabeledContent(.ui("수동 큐 곡"), value: report.tracksWithManualCues.formatted())
            } header: {
                Text(.ui("현황")).sidebarSectionHeader()
            }
            .font(.callout)
        }
        if showsStatus, let url = store.snapshotURL {
            Section {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text(.ui("스냅샷")).sidebarSectionHeader()
            }
        }
    }
}

extension View {
    /// 사이드바 섹션 제목(#120). 시스템 기본보다 크고 진하게, 위를 더 띄워 섹션끼리 나뉘어 보이게 한다.
    /// 제목 줄의 버튼도 같은 크기·색을 따른다.
    func sidebarSectionHeader() -> some View {
        font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
    }
}

/// 목록 위 작업 줄: 추가한 곡(추가·빼기·XML 내보내기), BPM 없는 곡(일괄 추정).
struct ListActionBar: View {
    let store: LibraryStore
    @Environment(\.reflection) private var reflection

    var body: some View {
        switch store.sidebar {
        case .staged:
            bar {
                let selectedStaged = ReflectionTargets.add(store.selectedRows)
                let addTargets = selectedStaged.isEmpty ? store.stagedRows : selectedStaged
                Button { reflection?.startAddTracks(rows: addTargets) } label: {
                    Label(store.isWritingRekordbox ? LocalizedStringResource.ui("rekordbox에 쓰는 중…") : .ui("rekordbox에 바로 넣기 (\(addTargets.count)곡)"),
                          systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(addTargets.isEmpty || store.isWritingRekordbox || store.writesBlockedBySheet)
                .help(store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
                      : String(ui: "고른 곡(없으면 추가 목록 전체)을 확인한 뒤 rekordbox 컬렉션에 넣습니다."))
                Button { StagingPanels.chooseFiles(store: store) } label: { Label(.ui("곡 추가…"), systemImage: "plus") }
                Button { store.removeStaged(store.selection) } label: { Label(.ui("추가 목록에서 제거"), systemImage: "minus") }
                    .disabled(!store.selection.contains { $0.hasPrefix("djc-") })
                    .help(.ui("추가 목록에서만 뺍니다. 파일은 지우지 않습니다."))
                Button { StagingPanels.exportXML(store: store) } label: { Label(.ui("XML 만들기"), systemImage: "doc.text") }
                    .disabled(store.staged.isEmpty)
                    .help(.ui("추가한 곡을 rekordbox에서 가져올 XML로 만듭니다."))
                if store.staged.contains(where: { $0.importCheck != nil && $0.importCheck?.result != .pending }) {
                    Button { store.removeImportedStaged() } label: { Label(.ui("가져온 곡 정리"), systemImage: "checkmark.circle") }
                        .help(.ui("rekordbox에 들어간 것이 확인된 곡을 추가 목록에서 뺍니다(파일·초안은 그대로)."))
                }
            }
        case .pending:
            bar {
                let targets = store.selection.isEmpty ? store.displayRows : store.selectedRows
                let playlistEdits = store.playlistDraft.steps.count
                let histories = store.pendingHistories.count
                Button { reflection?.startWrite(rows: targets) } label: {
                    Label(Self.pendingWriteTitle(tracks: targets.count, playlistEdits: playlistEdits, histories: histories),
                          systemImage: "square.and.arrow.up.on.square")
                }
                .disabled((targets.isEmpty && playlistEdits == 0 && histories == 0) || store.isWritingRekordbox || store.writesBlockedBySheet)
                .help(store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
                      : String(ui: "고른 곡(없으면 목록 전체)과 재생 목록 초안·USB 재생 기록을 rekordbox에 씁니다."))
                if histories > 0 {
                    // 쓰기 대기 재생 기록(#43)은 곡 줄이 아니라 이 메뉴에서 보고(고르면 그 기록으로) 뺀다
                    Menu {
                        ForEach(store.pendingHistories) { history in
                            Button(history.name) { store.sidebar = .history(history.id) }
                        }
                        Divider()
                        Button(.ui("모두 rekordbox 쓰기 대기에서 빼기")) {
                            store.setHistoriesExcluded(store.pendingHistories.map(\.id), excluded: true)
                        }
                        .disabled(store.isWritingRekordbox)
                    } label: {
                        Label(.ui("재생 기록 \(histories)건"), systemImage: "clock.arrow.circlepath")
                    }
                    .fixedSize()
                    .help(.ui("쓰기 대기에 오른 USB 재생 기록입니다. 고르면 그 기록을 보고, 빼면 실행 취소로 되돌립니다."))
                }
                if playlistEdits > 0 {
                    Button { PlaylistPanels.discardAll(store: store) } label: {
                        Label(.ui("재생 목록 초안 버리기"), systemImage: "trash")
                    }
                    .disabled(store.isWritingRekordbox)
                    .help(.ui("rekordbox에 아직 쓰지 않은 재생 목록 편집을 모두 버립니다(⌘Z로 되돌림)."))
                }
                Button { ReflectionPanels.export(store: store, rows: targets) } label: {
                    Label(.ui("XML 만들기"), systemImage: "doc.text")
                }
                .disabled(targets.isEmpty)
                .help(.ui("큐·그리드 초안을 rekordbox에서 가져올 XML로 만듭니다."))
                Button { reflection?.startRestoreLatest() } label: {
                    Label(.ui("쓰기 전으로 복원…"), systemImage: "arrow.uturn.backward")
                }
                .disabled(store.isWritingRekordbox || !store.hasWriteBackup || store.writesBlockedBySheet)
                .help(store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
                      : store.hasWriteBackup
                      ? String(ui: "라이브러리 전체를 마지막 쓰기 전 백업으로 복원합니다.")
                      : String(ui: "복원할 백업이 없습니다. rekordbox에 쓰면 쓰기 전 백업이 생깁니다."))
                if store.isWritingRekordbox {
                    ProgressView().controlSize(.small)
                    Text(.ui("rekordbox 라이브러리 확인·쓰는 중…")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.ui("rekordbox가 꺼져 있을 때만 씁니다 · 쓰기 전에 전체 백업")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .itunesPlaylist(id):
            bar {
                Label(.ui("목록 구성과 순서는 Music에서 바꿉니다 · 큐·태그는 여기서 편집할 수 있습니다"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                if let node = store.iTunesLibrary.index[id], node.unavailableTrackCount > 0 {
                    Text(.ui("연결하지 못한 \(node.unavailableTrackCount)곡은 rekordbox 컬렉션 등록과 파일 위치를 확인하세요"))
                        .font(.caption).foregroundStyle(UIColors.warning.color)
                }
            }
        case let .playlist(id):
            // 실험실에서 보는 인텔리전트 목록: 읽기 전용이고 곡은 DJCrate가 조건으로 계산한 것(#68)
            if let result = store.selectedSmartPlaylistResult { smartPlaylistNote(result) }
            // 숨긴 스트리밍 곡 때문에 끌어 옮길 수 없는 목록은 이유를 알린다(`canReorderDisplayedTracks`).
            // 줄이 하나도 안 남았으면 목록 가운데 안내(`EmptyLibraryOverlay`)가 같은 말을 한다.
            let hiddenNote = store.streamingHiddenInView > 0 && store.editablePlaylistID == id && !store.displayRows.isEmpty
            if let node = store.playlistIndex[id], node.isDraft || node.blockedReason != nil {
                bar {
                    if let reason = node.blockedReason {
                        Label(.ui("이 목록의 초안 일부를 쓸 수 없습니다: \(reason)"), systemImage: WarningMark.symbol)
                            .foregroundStyle(UIColors.warning.color)
                            .lineLimit(2)
                    } else {
                        Label(.ui("아직 쓰지 않은 목록 초안입니다 · rekordbox에 쓰기(⇧⌘E)로 저장합니다"), systemImage: DraftMark.symbol)
                            .foregroundStyle(UIColors.draft.color)
                    }
                    if node.blockedReason != nil {
                        Button(.ui("현재 목록 비교…")) { reflection?.startPlaylistRecovery(playlist: id) }
                            .fixedSize()
                            .disabled(store.isWritingRekordbox || store.isRecoveringDraft || store.writeTask != nil)
                    } else {
                        Button(.ui("이 목록의 초안 버리기")) { store.discardPlaylistDraft(id) }
                            .disabled(store.isWritingRekordbox)
                    }
                    if hiddenNote { hiddenStreamingNote }
                }
            } else if hiddenNote {
                bar { hiddenStreamingNote }
            } else {
                EmptyView()
            }
        case .usb(.pending):
            // 쓰기 대기 목록은 자기 머리에 단추를 둔다
            EmptyView()
        case let .usb(target):
            bar {
                if let actions = store.usbEdits, actions.usb.acceptsEdits(target.volumeKey) {
                    let key = target.volumeKey
                    let updatable = actions.updatableTracks(volumeKey: key).count
                    // 막힐 반영이면(실물 USB 등) 누를 수 없게 하고 이유를 도움말로
                    let reason = updatable == 0 ? nil : actions.refreshBlockReason(volumeKey: key)
                    Button { Task { await actions.refreshLocalChanges(volumeKey: key) } } label: {
                        Label(.ui("로컬 변경을 USB에 반영 (\(updatable)곡)"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(updatable == 0 || reason != nil)
                    .help(reason ?? String(ui: "로컬에서 더 고친 곡(갱신 가능)을 USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."))
                    Button { store.sidebar = .usb(.pending(volumeKey: key)) } label: {
                        Label(.ui("USB 쓰기 대기 (\(actions.usb.draftCounts[key] ?? 0)건)"), systemImage: "square.and.arrow.up.on.square")
                    }
                    Text(.ui("USB 편집은 초안으로 쌓고 ‘USB에 쓰기…’로 반영합니다")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(.ui("USB의 곡·재생 목록은 읽기만 합니다"), systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.usb?.infos[target.volumeKey].map({ $0.consistency.playlistMismatches > 0 }) == true {
                    Label(.ui("두 형식의 재생 목록 내용이 다릅니다"), systemImage: WarningMark.symbol)
                        .font(.caption).foregroundStyle(UIColors.warning.color)
                }
            }
        case .filter(.missingFile):
            bar {
                // 빠진 외장 디스크는 곡마다가 아니라 디스크째 알린다(#126).
                let volumes = store.missingFiles.unmountedVolumes
                if !volumes.isEmpty {
                    let names = volumes.map { String(ui: "\($0.name)(\($0.trackCount)곡)") }.joined(separator: ", ")
                    Label(.ui("연결되지 않은 외장 디스크: \(names) · 연결하면 다시 확인합니다"), systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(UIColors.warning.color)
                        .lineLimit(1)
                        .help(names)
                }
                Button { store.checkMissingFiles() } label: { Label(.ui("다시 확인"), systemImage: "arrow.clockwise") }
                    .disabled(store.isCheckingFiles)
                    .help(.ui("음원 파일이 있는지 다시 확인합니다. rekordbox에는 쓰지 않습니다."))
                RelocateEntryButton(store: store)
                if store.isCheckingFiles {
                    ProgressView().controlSize(.small)
                    Text(.ui("파일을 확인하는 중…")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.ui("옮긴 음원은 rekordbox의 Relocate로 다시 연결하세요")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .filter(.noBPM):
            bar {
                Button { store.estimateGridsForDisplayedRows() } label: {
                    Label(.ui("이 목록 그리드 추정 (\(store.displayRows.count)곡)"), systemImage: "metronome")
                }
                .disabled(store.displayRows.isEmpty || store.gridJob != nil)
                .help(.ui("rekordbox가 분석하지 않은 곡의 BPM·박 위치를 추정해 그리드 초안으로 저장합니다(rekordbox는 바뀌지 않습니다)."))
                Text(.ui("초안만 만듭니다 · 덱에서 확인·수정")).font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func smartPlaylistNote(_ result: SmartPlaylistResult) -> some View {
        bar {
            if let summary = result.unsupportedSummary {
                Label(.ui("DJCrate가 이 목록의 조건을 계산하지 못해 곡을 보이지 않습니다 · rekordbox에서 확인하세요"), systemImage: WarningMark.symbol)
                    .foregroundStyle(UIColors.warning.color)
                    .lineLimit(1)
                Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Label(.ui("DJCrate가 조건으로 계산한 읽기 전용 목록입니다 · rekordbox 화면과 곡이 다를 수 있습니다"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 쓰기 대기 바의 쓰기 단추 제목: 곡 수와 함께 쓸 재생 목록 편집·재생 기록 수
    static func pendingWriteTitle(tracks: Int, playlistEdits: Int, histories: Int) -> LocalizedStringResource {
        switch (playlistEdits > 0, histories > 0) {
        case (true, true): .ui("rekordbox에 쓰기 (\(tracks)곡 · 재생 목록 \(playlistEdits)건 · 재생 기록 \(histories)건)")
        case (true, false): .ui("rekordbox에 쓰기 (\(tracks)곡 · 재생 목록 \(playlistEdits)건)")
        case (false, true): .ui("rekordbox에 쓰기 (\(tracks)곡 · 재생 기록 \(histories)건)")
        case (false, false): .ui("rekordbox에 쓰기 (\(tracks)곡)")
        }
    }

    private var hiddenStreamingNote: some View {
        Label(.ui("스트리밍 \(store.streamingHiddenInView)곡을 숨기는 중 · 순서를 바꾸려면 설정에서 숨기기를 끄세요"), systemImage: "eye.slash")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 6)
    }
}
