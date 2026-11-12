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
    /// 재생 목록 칸의 폴더 펼침·이름 바꾸기(조립 지점이 한 번 만든 화면 모델). 본문은 읽지 않고 재생 목록 구역·메뉴에 넘긴다
    let playlistSidebar: PlaylistSidebarModel

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        // ⌘·⇧ 클릭으로 재생 목록을 여럿 고른다(#261). 곡 목록은 마지막에 고른 항목(`store.sidebar`)을 보인다
        List(selection: Binding(get: { playlistSidebar.selection }, set: { playlistSidebar.select($0) })) {
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
                SidebarStagedRow(staging: store.staging)
                    .tag(SidebarItem.staged)
                SidebarPendingRow(store: store)
                    .tag(SidebarItem.pending)
                SidebarActivityLogRow(store: store)
                // 진행 줄은 넣고 빼야 해서 본문이 시작·끝만 읽고, 진행(done/total)은 줄이 읽는다.
                if store.staging.hasGridJob { SidebarGridJobRow(staging: store.staging) }
                if store.staging.hasXMLExportJob { SidebarXMLExportRow(staging: store.staging) }
            } header: {
                Text(verbatim: "DJCrate").sidebarSectionHeader()
            }
            if case .loaded = store.phase {
                PlaylistSection(store: store, sidebar: playlistSidebar)
                ITunesPlaylistSection(store: store)
            }
            SidebarHistorySection(history: store.history)
            if let usb = store.usb {
                UsbSidebarSection(store: store, usb: usb)
            }
            SidebarStatusSections(store: store)
        }
        .modifier(PlaylistSidebarMenu(store: store, sidebar: playlistSidebar))
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

/// 추가한 곡 줄. 줄은 저장소 대신 추가 목록 조각(`TrackStagingStore`)만 받는다(줄이 읽는 값을 부모로 올리지 않게 좁은 조각을 넘긴다).
struct SidebarStagedRow: View {
    let staging: TrackStagingStore

    var body: some View {
        Label(.ui("추가한 곡"), systemImage: "tray.and.arrow.down")
            .badge(staging.staged.count)
    }
}

/// 쓰기 대기 배지. 개수는 초안 여러 종류의 합집합이라 읽는 값이 많다. 쓰기 대기 재생 기록(#43)도 센다.
struct SidebarPendingRow: View {
    let store: LibraryStore

    var body: some View {
        Label(.ui("rekordbox 저장 대기"), systemImage: "square.and.arrow.up.on.square")
            .badge(store.pendingWriteCount)
            .help(.ui("rekordbox에 저장할 곡 편집과 USB 재생 기록을 모아 봅니다. 재생 목록 편집도 함께 저장할 수 있습니다."))
    }
}

struct SidebarActivityLogRow: View {
    let store: LibraryStore
    /// 활동 기록 시트를 든 주 창 모델(사이드바 본문에 클로저를 넣지 않으려고 환경 값으로 받는다)
    @Environment(\.libraryWindow) private var window

    var body: some View {
        Button { window?.showActivityLog() } label: {
            Label(.ui("활동 기록…"), systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.plain)
        .disabled(store.editsFrozen)
    }
}

/// 그리드 일괄 추정 진행 줄. 곡마다 진행이 오르므로 이 뷰만 다시 계산된다.
struct SidebarGridJobRow: View {
    let staging: TrackStagingStore

    var body: some View {
        if let job = staging.gridJob {
            HStack(spacing: 6) {
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).controlSize(.small)
                Text(.ui("그리드 추정 \(job.done)/\(job.total)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// 라이브러리 XML 내보내기 진행 줄. 진행이 오를 때마다 이 뷰만 다시 계산된다.
struct SidebarXMLExportRow: View {
    let staging: TrackStagingStore

    var body: some View {
        if let job = staging.xmlExportJob {
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
/// 구역과 줄은 저장소 대신 재생 기록 조각(`HistoryStore`)만 받는다(줄이 읽는 값을 부모로 올리지 않게 값 대신 좁은 조각을 넘긴다).
struct SidebarHistorySection: View {
    let history: HistoryStore
    @AppStorage(SettingKeys.sidebarHistoriesExpanded.name) private var isExpanded = SettingKeys.sidebarHistoriesExpanded.defaultValue

    var body: some View {
        Section(isExpanded: $isExpanded) {
            let tree = history.historyTree
            if tree.isEmpty {
                Text(.ui("재생 기록이 없습니다")).foregroundStyle(.secondary)
            }
            ForEach(tree.years) { year in
                SidebarHistoryYearRow(history: history, year: year)
            }
            // 연·월을 모르는 기록은 트리 아래에 바로 둔다
            ForEach(tree.undated) { item in
                SidebarHistoryRow(history: history, item: item)
                    .tag(SidebarItem.history(item.id))
            }
        } header: {
            Text(.ui("재생 기록")).sidebarSectionHeader()
        }
    }
}

/// 연 폴더. 펼침은 재생 기록 조각에 둔다(기록을 고르면 그 폴더를 펼친다). 폴더는 고르는 대상이 아니라 태그를 달지 않는다
struct SidebarHistoryYearRow: View {
    let history: HistoryStore
    let year: HistoryTree.Year

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { history.expandedHistoryFolders.contains(year.id) },
            set: { history.setHistoryFolder(year.id, expanded: $0) }
        )) {
            ForEach(year.months) { month in
                SidebarHistoryMonthRow(history: history, month: month)
            }
        } label: {
            Text(verbatim: String(year.year))
        }
    }
}

/// 월 폴더(이름은 앱 화면 언어의 월 이름)
struct SidebarHistoryMonthRow: View {
    let history: HistoryStore
    let month: HistoryTree.Month

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { history.expandedHistoryFolders.contains(month.id) },
            set: { history.setHistoryFolder(month.id, expanded: $0) }
        )) {
            ForEach(month.items) { item in
                SidebarHistoryRow(history: history, item: item)
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

/// 기록 줄. 곡 수와 보존 출처·저장 상태 표시는 이 뷰만 읽는다.
/// 출처는 줄 아이콘(USB·LINK)이, 저장 상태는 상태 아이콘이 보이고 툴팁은 상태 낱말 한 줄이다(#311)
struct SidebarHistoryRow: View {
    let history: HistoryStore
    let item: HistoryTree.Item

    var body: some View {
        let archived = history.archivedHistory(item.id)
        let mark = archived.map { HistoryStatusMark.of(history.archivedStatus($0), isLink: $0.source.isLink) }
        HStack(spacing: 4) {
            Text(verbatim: item.name)
                .lineLimit(1)
            if let archived, let mark {
                // LINK 기록(PRO DJ LINK로 내어 주는 동안 CDJ가 남긴 기록)과 USB 기기 기록을 가른다
                Image(systemName: archived.source.isLink ? "point.3.connected.trianglepath.dotted" : "externaldrive")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(archived.source.isLink ? .ui("LINK로 남긴 기록") : .ui("USB에서 가져온 기록"))
                Image(systemName: mark.symbol)
                    .imageScale(.small)
                    .foregroundStyle(mark.usesDraftColor ? UIColors.draft.color : Color.secondary)
                    .accessibilityLabel(Text(verbatim: mark.word))
            }
        }
        .badge(history.historyCount(item.id))
        .help(mark?.help ?? history.historyIndex[item.id].map(\.title) ?? item.name)
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
                Text(.ui("읽은 시점")).sidebarSectionHeader()
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
