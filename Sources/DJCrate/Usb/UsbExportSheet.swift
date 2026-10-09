import DJCApplication
import DJCDomain
import SwiftUI

/// 내보내기 시트에서 고르는 것(순수): 형식·원본(목록 트리·고른 곡)·미리 보기. 고르는 것이 바뀌면 앞의 미리 보기를 버린다
struct UsbExportSheetModel: Equatable {
    /// 원본 목록 트리 한 줄
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var depth: Int
        var isFolder: Bool
        /// 인텔리전트 재생 목록(규칙을 확인하지 않아 내보내지 않는다)
        var isSmart: Bool
        var trackCount: Int
    }

    let volume: UsbVolumeInfo
    private(set) var formats: Set<UsbFormat> = UsbFormat.defaultSet
    private(set) var playlistIDs: Set<String> = []
    /// 곡 목록에서 고른 로컬 곡(ContentID, 목록 순서)
    let selectedTrackIDs: [String]
    var includesSelectedTracks = false {
        didSet {
            if hasFixedSource { includesSelectedTracks = oldValue; return }
            if includesSelectedTracks != oldValue { summary = nil }
        }
    }
    var summary: UsbExportSummary?
    private(set) var retryJob: UsbExportJob?

    mutating func releaseRetrySnapshot() { retryJob = nil; summary = nil }
    var hasFixedSource: Bool { retryJob?.syncSelection != nil }

    init(volume: UsbVolumeInfo, selectedTrackIDs: [String]) {
        self.volume = volume
        self.selectedTrackIDs = selectedTrackIDs
    }

    var isTestVolume: Bool { volume.isDiskImage }

    /// 형식을 켜고 끈다. 마지막 하나는 끌 수 없다
    mutating func setFormat(_ format: UsbFormat, on: Bool) {
        var next = formats
        if on { next.insert(format) } else { next.remove(format) }
        guard !next.isEmpty, next != formats else { return }
        formats = next
        summary = nil
    }

    mutating func setPlaylist(_ id: String, selected: Bool) {
        guard !hasFixedSource else { return }
        let changed = selected ? playlistIDs.insert(id).inserted : playlistIDs.remove(id) != nil
        if changed { summary = nil }
    }

    func isSelected(_ id: String) -> Bool { playlistIDs.contains(id) }

    /// 고른 폴더 안에 있어 폴더가 함께 넘기는 목록
    func isCovered(_ id: String, layout: PlaylistLayout) -> Bool {
        layout.ancestors(of: id).contains { $0.id != id && playlistIDs.contains($0.id) }
    }

    /// 세션에 넘길 선택(트리 순서, 고른 폴더 안의 목록은 폴더가 품는다). 고른 것이 없으면 nil
    func selection(layout: PlaylistLayout) -> UsbSelection? {
        if hasFixedSource { return retryJob?.selection }
        let playlists = layout.outline.map(\.id).filter { playlistIDs.contains($0) && !isCovered($0, layout: layout) }
        let tracks = includesSelectedTracks ? selectedTrackIDs : []
        switch (playlists.isEmpty, tracks.isEmpty) {
        case (true, true): return nil
        case (false, true): return .playlists(playlists)
        case (true, false): return .tracks(tracks)
        case (false, false): return .both(playlists: playlists, tracks: tracks)
        }
    }

    /// native 요청의 전체 원본은 부분 선택 트리만으로 복구할 수 없으므로 재시도 원본을 고정한다.
    mutating func restore(_ job: UsbExportJob, summary: UsbExportSummary?, layout: PlaylistLayout) {
        retryJob = nil
        formats = job.formats.isEmpty ? UsbFormat.defaultSet : job.formats
        playlistIDs = Set(job.selection.playlistIDs)
        includesSelectedTracks = !job.selection.trackIDs.isEmpty && job.selection.trackIDs == selectedTrackIDs
        var retry = job
        retry.snapshotLease = job.snapshotLease ?? job.syncSourceContext?.snapshot?.lease
        retryJob = retry
        self.summary = selection(layout: layout) == job.selection && formats == job.formats ? summary : nil
    }

    /// 시트에서 세션으로 넘길 작업을 한 곳에서 만든다. 동기화 재시도는 원문·원본 사본도 유지한다.
    func job(database: URL, share: URL, volume: UsbVolumeInfo, layout: PlaylistLayout,
             syncSource: UsbSyncSource? = nil, catalogRevision: Int? = nil, readEpoch: Int = 0) -> UsbExportJob? {
        if hasFixedSource, var retry = retryJob {
            guard let context = retry.syncSourceContext,
                  database == (context.snapshot?.provenance.sourceURL ?? retry.database),
                  share == retry.share, volume.matchesSyncWriteVolume(retry.volume), syncSource == context.source,
                  catalogRevision == context.catalogRevision, readEpoch == context.readEpoch else { return nil }
            retry.formats = formats
            return retry
        }
        guard let selection = selection(layout: layout) else { return nil }
        return UsbExportJob(database: database, share: share, volume: volume, selection: selection,
                            formats: formats, snapshotTime: retryJob?.snapshotTime, playlistLayout: retryJob?.playlistLayout)
    }

    func canPreview(layout: PlaylistLayout) -> Bool { selection(layout: layout) != nil }

    /// 미리 보기를 본 뒤 그대로 쓸 수 있는지
    var canWrite: Bool { summary?.canWrite == true }

    /// 스냅샷의 목록 트리 → 줄(초안으로 만든 새 목록은 스냅샷에 없어 뺀다)
    static func rows(_ layout: PlaylistLayout) -> [Row] {
        func walk(_ parent: String, depth: Int) -> [Row] {
            layout.children(of: parent).filter { !$0.isNew }.flatMap { item in
                [Row(id: item.id, name: item.name, depth: depth, isFolder: item.isFolder, isSmart: item.isSmart,
                     trackCount: item.isFolder ? 0 : item.entries.count)]
                    + (item.isFolder ? walk(item.id, depth: depth + 1) : [])
            }
        }
        return walk(PlaylistLayout.root, depth: 0)
    }
}

/// "USB로 내보내기…" 시트: 대상 볼륨 · 형식 · 원본(목록 트리·고른 곡) · 미리 보기(곡·목록 수, 공간, 막힘 이유별 수).
/// 시트에 볼륨 줄(실물이면 "실물 USB입니다")과 미리 보기를 보이고, [USB에 쓰기]를 쓰기 동의로 본다. 시트를 닫은 뒤 코디네이터가 확인 창 없이 쓴다(#212)
struct UsbExportSheet: View {
    let store: LibraryStore
    let usb: UsbStore
    let request: UsbExportSheetRequest
    @State private var model: UsbExportSheetModel
    @State private var isPreviewing = false
    @State private var opensSyncAfterDismissal = false
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, usb: UsbStore, request: UsbExportSheetRequest) {
        self.store = store
        self.usb = usb
        self.request = request
        let tracks = request.job.flatMap { $0.syncSelection == nil ? nil : $0.selection.trackIDs }
            ?? store.selectedRows.filter { !$0.isStaged && !$0.track.isStreaming }.map(\.track.id)
        // 연 때의 볼륨으로 그린다(볼륨이 빠지면 UsbStore가 시트를 닫는다)
        var model = UsbExportSheetModel(volume: request.volume, selectedTrackIDs: tracks)
        // 다시 미리 보기면 그때 고른 것을 되살린다
        if let job = request.job {
            model.restore(job, summary: request.summary, layout: job.playlistLayout ?? store.rekordboxPlaylists)
        }
        _model = State(initialValue: model)
    }

    private var layout: PlaylistLayout { request.job?.playlistLayout ?? store.rekordboxPlaylists }
    private var sourceIsCurrent: Bool {
        guard model.hasFixedSource, let retry = model.retryJob else { return true }
        guard let context = retry.syncSourceContext else { return false }
        return store.usbSyncSourceIsCurrent(context, database: retry.database, share: retry.share)
            && usb.volume(request.volumeKey)?.matchesSyncWriteVolume(retry.volume) == true
    }

    var canPreview: Bool { !isPreviewing && sourceIsCurrent && model.canPreview(layout: layout) }
    var canExport: Bool { !isPreviewing && sourceIsCurrent && model.canWrite }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            formatsSection
            sourceSection
            previewSection
            // 미리 보기를 막은 안내(rekordbox 켜짐·쓰는 중)는 창 대신 토스트로 알린다. 토스트는 시트 뒤에 가리므로 여기에도 보인다(#230)
            if let toast = store.toast, toast.isNotice, toast.isUsb {
                AppMessageView(message: AppMessage(kind: toast.kind, text: [toast.title, toast.detail].compactMap { $0 }.joined(separator: " — ")),
                               onClose: { store.toast = nil })
            }
            HStack {
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("미리 보기")) { Task { await preview() } }
                    .disabled(!canPreview)
                Button(.ui("USB에 쓰기")) { write() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .onDisappear {
            model.releaseRetrySnapshot()
            if request.job?.syncSourceContext != nil {
                usb.lastExports[request.volumeKey] = nil
                if usb.exportSheet?.id == request.id { usb.exportSheet = nil }
            }
            if opensSyncAfterDismissal { usb.presentSync(request.volumeKey) }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("USB로 내보내기")).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Label {
                    Text(verbatim: model.volume.name)
                } icon: {
                    Image(systemName: "externaldrive")
                }
                if model.isTestVolume {
                    Text(.ui("시험 볼륨"))
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .foregroundStyle(.secondary)
            // 쓰기 확인 창 대신 여기서 어느 볼륨에 쓰는지 보인다(실물 USB 쓰기 동의, #212)
            if !model.isTestVolume {
                ForEach(UsbWriteFlow.volumeLines(model.volume, isTestVolume: false), id: \.self) { line in
                    Text(verbatim: line).font(.callout)
                }
            }
        }
    }

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("형식")).font(.headline)
            HStack(spacing: 16) {
                ForEach(UsbFormat.allCases, id: \.self) { format in
                    Toggle(isOn: Binding(get: { model.formats.contains(format) }, set: { model.setFormat(format, on: $0) })) {
                        Text(verbatim: format.displayName)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("원본")).font(.headline)
            if model.hasFixedSource {
                Text(.ui("동기화 재시도의 원본 선택은 고정되어 있습니다. 선택을 바꾸거나 원본이 갱신되었으면 USB 동기화 창에서 다시 준비하세요"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(.ui("USB 동기화…")) {
                    opensSyncAfterDismissal = true
                    dismiss()
                }
                .disabled(isPreviewing || usb.activeWrite != nil)
            }
            List {
                ForEach(UsbExportSheetModel.rows(layout)) { row in
                    let covered = model.isCovered(row.id, layout: layout)
                    Toggle(isOn: Binding(get: { covered || model.isSelected(row.id) }, set: { model.setPlaylist(row.id, selected: $0) })) {
                        Label {
                            Text(verbatim: row.name).lineLimit(1)
                        } icon: {
                            Image(systemName: row.isFolder ? "folder" : row.isSmart ? "gearshape" : "music.note.list")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .disabled(model.hasFixedSource || covered || row.isSmart)
                    .help(row.isSmart ? String(ui: "인텔리전트 재생 목록은 내보내지 않습니다") : row.name)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
            Toggle(isOn: $model.includesSelectedTracks) {
                Text(.ui("곡 목록에서 고른 곡 \(model.selectedTrackIDs.count)개도 넣기"))
            }
            .toggleStyle(.checkbox)
            .disabled(model.hasFixedSource || model.selectedTrackIDs.isEmpty)
        }
    }

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("미리 보기")).font(.headline)
            if isPreviewing {
                ProgressView().controlSize(.small)
            } else if let summary = model.summary {
                Text(.ui("곡 \(summary.trackCount)개 · 재생 목록 \(summary.playlistCount)개 · 빼고 쓰는 곡 \(summary.blockedTrackCount)개"))
                Text(verbatim: summary.spaceText)
                    .foregroundStyle(summary.isShortOfSpace ? UIColors.warning.color : Color.secondary)
                ForEach(summary.stopping, id: \.self) { message in
                    Label { Text(verbatim: message) } icon: { Image(systemName: WarningMark.symbol) }
                        .foregroundStyle(UIColors.warning.color)
                }
                ForEach(UsbWriteFlow.blockLines(summary), id: \.self) { line in
                    Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(.ui("형식과 원본을 고른 뒤 미리 보기를 누르세요")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func job() -> UsbExportJob? {
        guard let snapshot = store.snapshotURL, sourceIsCurrent else { return nil }
        let volume = usb.volume(request.volumeKey) ?? model.volume
        return model.job(database: snapshot, share: store.shareRoot,
                         volume: volume, layout: layout,
                         syncSource: UsbSyncSource.make(rekordbox: store.rekordboxPlaylists, iTunes: store.iTunesLibrary),
                         catalogRevision: store.previewRevision, readEpoch: store.snapshotReadEpoch)
    }

    private func preview() async {
        guard let job = job(), let coordinator = store.usbCoordinator else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        let summary = await coordinator.preview(job)
        // 기다리는 동안 고른 것이 바뀌었으면 버린다
        if self.job() == job { model.summary = summary }
    }

    private func write() {
        guard let job = job(), let summary = model.summary, let coordinator = store.usbCoordinator else { return }
        dismiss()
        Task { await coordinator.export(job, reusing: summary, consented: true) }
    }
}

/// USB에 쓰는 동안 창 전체를 덮는다: 단계·파일 수·바이트, DB 교체 전까지만 취소
struct UsbWritingOverlay: View {
    @Environment(\.textScale) private var textScale
    let model: UsbWriteProgressModel
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 10) {
                if let fraction = model.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.regular)
                }
                Text(verbatim: model.title).font(.scaled(.body, textScale).weight(.semibold))
                if let phase = model.phase {
                    Text(verbatim: [phase, model.items, model.bytes].compactMap { $0 }.joined(separator: " · "))
                        .font(.scaled(.caption, textScale).monospacedDigit())
                }
                Text(.ui("끝날 때까지 USB를 뽑지 마세요"))
                    .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                if model.showsCancel {
                    Button(.ui("취소"), action: onCancel).keyboardShortcut(.cancelAction)
                }
            }
            .frame(minWidth: 280)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
