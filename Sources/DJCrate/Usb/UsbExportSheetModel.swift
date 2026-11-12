import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 내보내기 시트에서 고르는 것(순수 값): 형식·원본(목록 트리·고른 곡)·미리 보기. 고르는 것이 바뀌면 앞의 미리 보기를 버린다
struct UsbExportSelection: Equatable {
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

    /// 미리 보기 계산이 달라지는 입력(형식·원본). 요약만 바뀐 것은 다시 계산하지 않는다
    struct PreviewInputs: Equatable {
        var formats: Set<UsbFormat>
        var playlistIDs: Set<String>
        var includesSelectedTracks: Bool
    }

    var previewInputs: PreviewInputs {
        PreviewInputs(formats: formats, playlistIDs: playlistIDs, includesSelectedTracks: includesSelectedTracks)
    }

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

/// "USB로 내보내기…" 시트의 화면 모델: 고른 것(`UsbExportSelection`)을 들고, 미리 보기와 [USB에 쓰기]를 쓰기 흐름(`UsbWriteCoordinator`)으로 부른다.
/// 형식·원본이 바뀌면 미리 보기를 저절로 다시 계산한다(#314): 앞의 계산은 버리고, 미리 보기는 USB 잠금이 하나라 앞 계산이 끝난 뒤 마지막 선택만 계산한다.
/// [USB에 쓰기]는 시트가 볼륨 줄과 미리 보기를 보인 뒤의 쓰기 동의라, 시트를 닫은 뒤 확인 창 없이 쓴다(#212). 순서·판정은 쓰기 흐름에 있다.
@MainActor @Observable
final class UsbExportSheetModel {
    /// 라이브러리 화면이 주는 것(부를 때마다 지금 값). 앱은 `LibraryStore`(`init(store:usb:request:)`), 시험은 가짜
    struct Ports {
        /// 앱이 연 로컬 스냅샷 사본
        var snapshot: @MainActor () -> URL?
        /// 로컬 rekordbox share(읽기만)
        var share: @MainActor () -> URL
        /// 스냅샷의 rekordbox 목록 트리(재시도가 아닐 때의 원본)
        var playlists: @MainActor () -> PlaylistLayout
        /// 동기화 원본(재시도 원본이 그대로인지 견준다)
        var syncSource: @MainActor () -> UsbSyncSource
        var catalogRevision: @MainActor () -> Int
        var readEpoch: @MainActor () -> Int
        /// 동기화 원본(선택 당시 원본·revision·스냅샷)이 지금도 같은지
        var sourceIsCurrent: @MainActor (UsbExportSyncSourceContext, _ database: URL?, _ share: URL?) -> Bool
        var coordinator: @MainActor () -> UsbWriteCoordinator?
    }

    let request: UsbExportSheetRequest
    var selection: UsbExportSelection {
        didSet {
            // 막힌 뒤에는 저절로 다시 계산하지 않는다. 계산마다 끝나지 않은 쓰기 회복 창·오류 창이 다시 뜨므로 [다시 시도]로만 계산한다
            guard selection.previewInputs != oldValue.previewInputs, !previewStopped else { return }
            restartPreview()
        }
    }
    /// 미리 보기를 계산하는 중(진행 표시)
    private(set) var isPreviewing = false
    /// 계산이 막히거나 실패해 요약이 없다(rekordbox 켜짐·다른 쓰기 중·오류). 선택을 바꾸지 않고 [다시 시도]할 수 있다
    private(set) var previewStopped = false
    /// 시트를 닫은 뒤 동기화 창을 연다(‘USB 동기화…’)
    private(set) var opensSyncAfterDismissal = false
    /// 미리 보기를 막은 USB 안내(rekordbox 켜짐·쓰는 중). 창 토스트는 시트 뒤에 가리고 저절로 닫히므로(#296)
    /// 시트에서 닫거나 다음 안내가 올 때까지 여기에 둔다(#230)
    private(set) var notice: AppToast?
    /// 가장 최근에 시작한 미리 보기 계산(앞 계산이 끝나길 기다린 뒤 돈다). 시험이 끝을 기다릴 때 쓴다
    @ObservationIgnored private(set) var previewTask: Task<Void, Never>?
    /// 계산마다 올린다. 끝난 계산이 지금 것인지 가린다
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private let usb: UsbStore
    @ObservationIgnored private let ports: Ports

    /// - selectedTrackIDs: 곡 목록에서 고른 로컬 곡. 동기화 재시도면 그 작업의 곡을 쓰므로 부르지 않는다
    init(request: UsbExportSheetRequest, usb: UsbStore, selectedTrackIDs: @autoclosure () -> [String], ports: Ports) {
        self.request = request
        self.usb = usb
        self.ports = ports
        let tracks = request.job.flatMap { $0.syncSelection == nil ? nil : $0.selection.trackIDs } ?? selectedTrackIDs()
        // 연 때의 볼륨으로 그린다(볼륨이 빠지면 UsbStore가 시트를 닫는다)
        var selection = UsbExportSelection(volume: request.volume, selectedTrackIDs: tracks)
        // 다시 미리 보기면 그때 고른 것을 되살린다
        if let job = request.job {
            selection.restore(job, summary: request.summary, layout: job.playlistLayout ?? ports.playlists())
        }
        self.selection = selection
    }

    convenience init(store: LibraryStore, usb: UsbStore, request: UsbExportSheetRequest) {
        let ports = Ports(snapshot: { store.snapshotURL }, share: { store.shareRoot }, playlists: { store.playlists.rekordboxPlaylists },
                          syncSource: { UsbSyncSource.make(rekordbox: store.playlists.rekordboxPlaylists, iTunes: store.music.library) },
                          catalogRevision: { store.previewRevision }, readEpoch: { store.snapshotReadEpoch },
                          sourceIsCurrent: { store.usbSyncSourceIsCurrent($0, database: $1, share: $2) },
                          coordinator: { store.usbCoordinator })
        self.init(request: request, usb: usb,
                  selectedTrackIDs: store.selectedRows.filter { !$0.isStaged && !$0.track.isStreaming }.map(\.track.id), ports: ports)
    }

    /// 원본 목록 트리(재시도면 그때 고른 트리)
    var layout: PlaylistLayout { request.job?.playlistLayout ?? ports.playlists() }
    var rows: [UsbExportSelection.Row] { UsbExportSelection.rows(layout) }

    /// 동기화 재시도면 그 원본과 볼륨이 지금도 같은지(아니면 미리 보기·쓰기를 막는다)
    var sourceIsCurrent: Bool {
        guard selection.hasFixedSource, let retry = selection.retryJob else { return true }
        guard let context = retry.syncSourceContext else { return false }
        return ports.sourceIsCurrent(context, retry.database, retry.share)
            && usb.volume(request.volumeKey)?.matchesSyncWriteVolume(retry.volume) == true
    }

    /// 미리 보기를 계산할 수 있는지(원본이 그대로이고 고른 것이 있다)
    var canPreview: Bool { sourceIsCurrent && selection.canPreview(layout: layout) }
    var canExport: Bool { !isPreviewing && sourceIsCurrent && selection.canWrite }
    /// ‘USB 동기화…’를 누를 수 있는지(쓰는 중에는 동기화 창을 열지 않는다)
    var canOpenSync: Bool { !isPreviewing && usb.activeWrite == nil }

    // MARK: - 의도

    /// 창 알림이 바뀔 때(뷰의 `onChange`). USB 안내만 받아 두고, 창 알림이 닫혀도 지우지 않는다
    func toastChanged(_ toast: AppToast?) {
        if let toast, toast.isNotice, toast.isUsb { notice = toast }
    }

    /// 안내 [닫기]. 닫은 안내의 id를 돌려준다(창 토스트가 아직 떠 있으면 함께 닫는다)
    func closeNotice() -> AppToast.ID? {
        defer { notice = nil }
        return notice?.id
    }

    /// 시트가 열릴 때: 미리 본 요약이 없는 선택(다시 미리 보기로 돌아온 시트)이면 계산한다
    func appeared() {
        guard selection.summary == nil, previewTask == nil else { return }
        restartPreview()
    }

    /// 막힌 미리 보기를 같은 선택으로 다시 계산한다(원인을 푼 뒤)
    func retryPreview() { restartPreview() }

    /// [USB에 쓰기]: 시트를 먼저 닫고 미리 본 요약으로 쓴다(시트의 동의). 쓸 것이 없으면(미리 보기 전) nil
    @discardableResult
    func writeTapped(dismiss: () -> Void) -> Task<Void, Never>? {
        guard let job = job(), let summary = selection.summary, let coordinator = ports.coordinator() else { return nil }
        dismiss()
        return Task { await coordinator.export(job, reusing: summary, consented: true) }
    }

    /// ‘USB 동기화…’: 시트를 닫은 뒤 동기화 창을 연다(`disappeared`)
    func syncTapped(dismiss: () -> Void) {
        opensSyncAfterDismissal = true
        dismiss()
    }

    /// 시트가 닫힐 때: 재시도 원본 사본을 놓고, 동기화 재시도면 지난 쓰기·시트 요청을 지운다(옛 원본으로 다시 열지 않게)
    func disappeared() {
        cancelPreview()
        selection.releaseRetrySnapshot()
        if request.job?.syncSourceContext != nil {
            usb.lastExports[request.volumeKey] = nil
            if usb.exportSheet?.id == request.id { usb.exportSheet = nil }
        }
        if opensSyncAfterDismissal { usb.presentSync(request.volumeKey) }
    }

    private func job() -> UsbExportJob? {
        guard let snapshot = ports.snapshot(), sourceIsCurrent else { return nil }
        let volume = usb.volume(request.volumeKey) ?? selection.volume
        return selection.job(database: snapshot, share: ports.share(), volume: volume, layout: layout, syncSource: ports.syncSource(),
                             catalogRevision: ports.catalogRevision(), readEpoch: ports.readEpoch())
    }

    /// 형식·원본이 바뀌었다: 앞 계산을 버리고(요약은 선택 값이 이미 비웠다) 고른 것이 있으면 다시 계산한다
    private func restartPreview() {
        cancelPreview()
        guard canPreview else { return }
        let previous = previewTask, generation = previewGeneration
        isPreviewing = true
        previewTask = Task { [weak self] in
            // 미리 보기는 볼륨 잠금을 하나만 쓴다. 앞 계산이 끝나길 기다리면 사이에 바뀐 선택은 취소돼 건너뛴다
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await preview(generation: generation)
        }
    }

    /// 계산 중인 미리 보기를 버린다(이미 도는 계산의 결과는 쓰지 않는다). 새 계산이 이어 서지 않으면 진행 표시를 끈다
    private func cancelPreview() {
        previewGeneration += 1
        previewTask?.cancel()
        isPreviewing = false
        previewStopped = false
    }

    private func preview(generation: Int) async {
        guard let job = job(), let coordinator = ports.coordinator() else {
            if generation == previewGeneration { isPreviewing = false }
            return
        }
        let summary = await coordinator.preview(job)
        // 기다리는 동안 고른 것이 바뀌었거나 시트가 닫혔으면 버린다
        guard generation == previewGeneration else { return }
        // 선택은 그대로인데 볼륨·읽은 사본 정보가 바뀌어 같은 계산이 아니다: 그 요약은 쓰지 않고 새 정보로 다시 계산한다
        guard self.job() == job else { return restartPreview() }
        selection.summary = summary
        previewStopped = summary == nil
        isPreviewing = false
    }
}
