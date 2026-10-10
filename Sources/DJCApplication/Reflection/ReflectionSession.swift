import DJCDomain
import Foundation

/// 반영 세션(유스케이스): rekordbox 라이브러리에 쓰는 흐름 전부를 정한다.
/// - 쓰기: rekordbox 꺼짐 확인 → 대상 고르기 → 사본으로 미리 보기 → (막힘·제외·손실이 있을 때만) 확인 → 쓸 수 있는 것만 쓰기 → 쓴 뒤 처리 → 결과
/// - 곡 넣기·빼기, 쓰기 전으로 복원(남길 초안·되살리기), 시점 스냅샷 복원, iTunes 동기화 쓰기, 재생 목록 편집 쓰기(CLI)
///
/// 화면은 흐름(`write`·`addTracks`·`deleteTracks`·`restore`)을 부르고 결과(`ReflectionOutcome`)를 보이기만 한다.
/// CLI와 자가 테스트는 같은 세션의 단계(`writeDrafts`·`restoreBackup`·`addTracks(_:to:dryRun:)` …)를 부른다.
/// 쓴 뒤 처리·되살리기는 옵션이다: 앱은 켜고, CLI는 끈다(사용자 결정 대기, `Options.cli`).
/// 쓰는 동안은 잠가서(`WriteLock`) 덱이 재생을 멈추고 조작을 막는다.
@MainActor
public struct ReflectionSession {
    public struct Options: Sendable {
        /// 쓴·넣은·뺀 뒤 처리(쓴 초안 정리·추가 목록 정리·백업에 사본 남기기·다시 읽기)
        public var followsUp: Bool
        /// 복원 때 지금 초안 가운데 남길 것을 정하고, 복원 뒤 백업의 초안을 되살린다
        public var revivesDrafts: Bool
        /// 분석 전 곡(분석 파일 없음)의 그리드 초안에 분석 파일을 만들어 붙이는지(`RekordboxWriter.attachesAnalysis`)
        public var attachesAnalysis: Bool
        /// 분석까지 붙여 넣는 곡에 음원의 앨범아트로 아트워크 파일도 만드는지(`RekordboxTrackWriter.writesArtwork`)
        public var writesArtwork: Bool

        public init(followsUp: Bool, revivesDrafts: Bool, attachesAnalysis: Bool, writesArtwork: Bool) {
            self.followsUp = followsUp
            self.revivesDrafts = revivesDrafts
            self.attachesAnalysis = attachesAnalysis
            self.writesArtwork = writesArtwork
        }

        /// 앱: 쓴 뒤 처리와 되살리기를 한다
        public static func app(attachesAnalysis: Bool, writesArtwork: Bool) -> Self {
            Self(followsUp: true, revivesDrafts: true, attachesAnalysis: attachesAnalysis, writesArtwork: writesArtwork)
        }

        /// CLI: 쓴 초안을 지우지 않고 복원 때 초안을 되살리지 않는다(앱과 다름, 사용자 결정 대기)
        public static func cli(attachesAnalysis: Bool, writesArtwork: Bool) -> Self {
            Self(followsUp: false, revivesDrafts: false, attachesAnalysis: attachesAnalysis, writesArtwork: writesArtwork)
        }
    }

    /// 라이브러리 위치(쓰기·복원 대상·백업 폴더·스냅샷을 뜰 수 있는지·iTunes 동기화 대상)
    public var location: LibraryLocation
    public var ports: ReflectionPorts
    public var options: Options

    public init(location: LibraryLocation, ports: ReflectionPorts, options: Options) {
        self.location = location
        self.ports = ports
        self.options = options
    }

    /// 화면 흐름의 쓰기·복원 대상(#182: 대상은 조립 지점이 정한 위치 한 곳이다)
    public var target: RekordboxWriteTarget {
        RekordboxWriteTarget(database: location.database, shareRoot: location.shareRoot, backups: location.backupDirectory)
    }

    /// 이 위치의 백업 폴더에 남은 쓰기 전 백업(최근 것부터, 최근 쓰기 복원·토스트의 복원 단추가 고른다)
    public func writeBackups() -> [RekordboxWriteBackup] { ports.backups.list(location.backupDirectory) }

    // MARK: - 대상

    /// 고른 곡 가운데 쓸 곡(반영 대기 초안이 있는 rekordbox 곡, 저장 대기 입력 포함). 메뉴도 같은 규칙을 쓴다.
    public func writeTargets(_ rows: [TrackRow]) -> [TrackRow] {
        ReflectionTargets.write(rows, pending: ReflectionTargets.pending(marked: ports.library.state().pendingUUIDs,
                                                                          unsaved: ports.drafts.unsavedUUIDs()))
    }

    /// 고른 곡 가운데 쓰기에서 빠지는 초안의 줄(`blockedOnly`면 막힌 것만)
    public func exclusions(for rows: [TrackRow], blockedOnly: Bool) -> [String] {
        DraftExclusions.reasons(for: rows, state: ports.library.state(), drafts: ports.drafts, blockedOnly: blockedOnly)
    }

    // MARK: - 공통

    func lock(_ locked: Bool) { ports.lock.set(locked, true) }
    func stage(_ stage: WriteStage?) { ports.lock.stage(stage) }
    func apply(_ change: ReflectionLibraryChange) { ports.library.apply(change) }

    /// 쓴 뒤·복원 뒤 재생 목록 초안·연결 기록 저장
    var playlistEdits: EditPlaylists { EditPlaylists(imports: ports.playlistImports, drafts: ports.drafts) }

    /// 태그 초안을 통째로 바꿔 저장하고(변경이 없는 초안은 파일째 지운다) 화면이 메모리를 맞추게 한다
    func replaceTagDrafts(_ tags: [TagDraft]) {
        ports.drafts.saveTags(tags)
        apply(.tagDrafts(tags))
    }

    /// 합치기 초안을 이것으로 바꿔 저장하고 화면이 메모리를 맞추게 한다. 쓰기·복원은 이미 끝났으니 저장 실패는 화면이 경고로만 알린다
    /// (실패로 바꾸면 되돌리기 안내까지 잃는다).
    func replaceMergeDrafts(_ merges: [DuplicateMergeDraft]) {
        do {
            try ports.drafts.saveMergeDrafts(merges)
            apply(.mergeDrafts(merges, failure: nil, moved: location.movesDamagedDrafts ? ports.drafts.takeMovedFiles() : []))
        } catch {
            apply(.mergeDrafts(merges, failure: error, moved: []))
        }
    }

    @discardableResult
    func publish(_ outcome: ReflectionOutcome) -> ReflectionOutcome {
        ports.results.publish(outcome)
        return outcome
    }

    /// 저장이 끝나지 않았거나 실패한 초안이 있으면 막는다(디스크의 옛 초안을 쓰지 않게, #170)
    func requireDraftSaves(for uuids: Set<String>) throws { try ports.drafts.requireSaved(uuids) }

    /// 재생 목록 초안 저장이 끝나지 않았으면 다시 저장해 보고, 그래도 안 되면 막는다(#174)
    func requirePlaylistDraftSaved() throws {
        guard ports.library.savePlaylistDraft() else { throw DJCError.writeRefused(Self.playlistSaveFailureText) }
    }

    /// 쓰기·복원 뒤 초안 저장에 실패한 곡이 있으면 그 경고
    func draftSaveWarning(for uuids: Set<String>, restoring: Bool) -> String? { ports.drafts.saveWarning(for: uuids, restoring: restoring) }

    /// 쓰기·복원 결과와 나눠 알릴 경고를 정리해 화면에 남긴다(목록 위 경고 줄에도, 다시 읽기 실패 이유는 그 뒤에 잇는다, #175)
    func finishFollowUp(_ notes: [String?], reloaded: Bool, restoring: Bool) -> [String] {
        let reloadError = reloaded ? nil : ports.library.state().lastError
        let followUp = notes.compactMap { $0 } + (reloaded ? [] : [Self.reloadFailureText(restoring: restoring)])
        apply(.followUp(followUp))
        let line = (followUp + [reloadError].compactMap { $0 }).joined(separator: " ")
        if !line.isEmpty { apply(.libraryError(line)) }
        return followUp
    }

    /// 사본을 떠서 그 사본에서 관문을 시험한다(미리 보기 1/2 → 사본 → 2/2 → 관문). 백업은 이 위치의 백업 폴더(사용자 백업을 밀어내지 않게)
    func onSnapshotCopy<Report: Sendable>(_ body: @escaping @Sendable (RekordboxWriteTarget) throws -> Report) async throws -> Report {
        stage(WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true))
        // 사본 뜨기와 관문 시험은 DB를 통째로 다루는 동기 입출력이라 협력 풀 밖에서 한다
        let take = ports.snapshots.take, backups = location.backupDirectory
        let copy = try await BlockingWork.run { try take(false) }
        stage(WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true))
        return try await BlockingWork.run { try body(RekordboxWriteTarget(database: copy, shareRoot: nil, backups: backups)) }
    }
}

// MARK: - 문구

extension ReflectionSession {
    public static var playlistSaveFailureText: String {
        String(ui: "재생 목록 초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 쓰기를 다시 시도하세요.")
    }

    public static var snapshotRefusedMessage: String {
        String(ui: "명시한 사본(--db)으로 연 창에서는 스냅샷을 뜨지 않습니다. --db 없이 다시 여세요")
    }

    public static func reloadFailureText(restoring: Bool) -> String {
        restoring ? String(ui: "rekordbox는 복원했지만 라이브러리를 다시 읽지 못했으니 ‘rekordbox와 동기화’(⌘R)로 다시 읽은 뒤 편집을 이어 가세요.")
            : String(ui: "rekordbox에는 썼지만 라이브러리를 다시 읽지 못했으니 ‘rekordbox와 동기화’(⌘R)로 다시 읽은 뒤 편집을 이어 가세요.")
    }

    public static func keptDraftsText(_ count: Int) -> String {
        String(ui: "쓴 뒤 새로 만든 초안이 있는 \(count)곡은 지금 초안을 남겼고, 백업의 초안은 ‘마지막 쓰기 결과…’의 백업 폴더에 남아 있습니다.")
    }

    public static func artworkRestoreFailureText(_ count: Int) -> String {
        String(ui: "rekordbox는 복원했지만 앨범아트 초안 \(count)곡을 되살리지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 그 곡의 앨범아트를 다시 고르세요.")
    }

    /// 넣기 끝에 백업 폴더에 추가 목록을 남기지 못했을 때(#202). 넣기 자체는 끝났다.
    public static var stagedBackupFailureText: String {
        String(ui: "rekordbox에는 넣었지만 추가 목록을 백업에 저장하지 못해 ‘쓰기 전으로 복원…’으로 되돌려도 곡이 추가 목록으로 돌아오지 않으니, 되돌렸다면 음원을 다시 추가하세요.")
    }

    /// 넣기 끝에 추가한 곡의 초안 사본을 백업 폴더에 남기지 못한 곡이 있을 때(#202). 그 초안은 되돌릴 때 이어질 유일한 사본이라 지우지 않는다.
    public static func stagedDraftsBackupFailureText(_ count: Int) -> String {
        String(ui: "추가한 곡 \(count)곡의 초안을 백업에 저장하지 못해 연결되지 않은 초안으로 남겼으니, 되돌려 곡이 추가 목록으로 돌아올 때 이어지도록 ‘연결되지 않은 초안 보기…’에서 버리지 마세요.")
    }

    /// 되돌린 새 곡에 남아 있던 초안을 지우지 않고 남긴 곡이 있을 때(#197·#202)
    public static func keptNewTrackDraftsText(_ count: Int, kinds: [AddedTrackDrafts.Kind]) -> String? {
        guard count > 0 else { return nil }
        let labels = kinds.map(\.label).joined(separator: "·")
        return String(ui: "넣은 곡에 남아 있던 \(labels) 초안 \(count)곡은 지우지 않고 연결되지 않은 초안으로 남겼습니다. 필요 없으면 ‘연결되지 않은 초안 보기…’에서 버리세요.")
    }
}
