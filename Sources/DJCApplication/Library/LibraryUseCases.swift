import DJCDomain
import Foundation

/// 라이브러리 화면의 피동 포트 묶음. 실제 구현(`LibraryPorts.live`)은 DJCAdapters가 주고 조립 지점이 고른다.
public struct LibraryPorts: Sendable {
    /// rekordbox 라이브러리 읽기(스냅샷 사본·분석 파일)
    public var source: LibrarySource
    /// Music 보관함·iTunes 동기화 선택·목록 사본
    public var music: MusicLibrarySource
    /// 초안 폴더의 초안 저장소(덱·반영과 같은 저장 큐)
    public var drafts: DraftStore
    /// Music 결과 채택 순서(한 프로세스에 하나)
    public var musicOrder: ITunesRefreshCoordinator
    /// 곡 목록 미리 보기 파형 캐시
    public var previews: PreviewWaveforms
    /// rekordbox XML 파일(가져오기·내보내기·반영 XML)
    public var xml: XMLFiles
    /// XML 가져오기가 만든 초안 파일(곡별 파일을 바로 쓴다)
    public var draftFiles: DraftFiles
    /// 반영 XML 묶음 저장(가져온 뒤 확인)
    public var batches: ReflectionBatchStore
    /// 추가 목록 파일(`staged.json`). 넣기·빼기·추정 결과를 모두 이 한 길로 쓴다
    public var staging: StagingStore
    /// 음원·그림 파일(있는지·태그)
    public var files: TrackFiles
    /// 추가한 곡의 그리드·키 추정
    public var analysis: StagingAnalysis
    /// 막힌 초안 복구가 비교할 지금 rekordbox 값(임시 사본으로 읽기)
    public var recovery: RecoveryReader
    /// 재생 목록 연결 기록
    public var playlistImports: PlaylistImportsStore
    /// 쓰기 전 백업 폴더(되돌릴 백업이 있는지)
    public var backups: RekordboxBackups
    /// 앨범아트 그림(확인·사본 이름)
    public var artwork: ArtworkFiles
    /// 파일 없는 곡의 새 위치 찾기(사본 DB 파일 크기·폴더 훑기·볼륨)
    public var relocate: RelocateSource
    /// 라이브러리 질의(CLI 읽기 명령)
    public var query: LibraryQuerySource
    /// Music 보관함 XML·음원
    public var appleMusic: AppleMusicFiles
    /// 라이브 rekordbox share(사본을 명시하지 않은 CLI 읽기가 그리드를 읽는 곳)
    public var liveShare: URL
    /// rekordbox 환경설정에 한 번 지정하는 연동 XML 파일("XML 만들기"가 늘 이 파일을 덮어쓴다)
    public var linkedXML: URL
    /// 목록을 읽은 사본의 지문과 USB 동기화 작업 사본
    public var usbSnapshots: UsbSyncSnapshots
    /// 라이브 DB에서 읽기용 스냅샷 사본 뜨기(반영 세션도 같은 것을 쓴다)
    public var snapshots: SnapshotTaker
    /// 읽은 사본의 USB 짝짓기 키(보존한 기기 재생 기록의 짝·쓴 표시 검증, #43)
    public var localKeys: LocalLibraryKeysSource
    /// 같은 음원 곡 합치기 초안 만들기(사본에서 읽는다)
    public var prepareMerge: @Sendable (_ keeping: String, _ removing: [String], _ snapshot: URL) throws -> DuplicateMergeDraft
    /// 시계(반영 묶음 시각 등)·오늘 날짜(`yyyy-MM-dd`)와 새 열쇠(재생 목록 초안)
    public var now: @Sendable () -> Date
    public var today: @Sendable () -> String
    public var newKey: @Sendable () -> String

    public init(source: LibrarySource, music: MusicLibrarySource, drafts: DraftStore, musicOrder: ITunesRefreshCoordinator,
                previews: PreviewWaveforms, xml: XMLFiles, draftFiles: DraftFiles, batches: ReflectionBatchStore,
                staging: StagingStore, files: TrackFiles, analysis: StagingAnalysis, recovery: RecoveryReader,
                playlistImports: PlaylistImportsStore, backups: RekordboxBackups, artwork: ArtworkFiles, relocate: RelocateSource,
                query: LibraryQuerySource, appleMusic: AppleMusicFiles, liveShare: URL, linkedXML: URL, usbSnapshots: UsbSyncSnapshots,
                snapshots: SnapshotTaker, localKeys: LocalLibraryKeysSource,
                prepareMerge: @escaping @Sendable (_ keeping: String, _ removing: [String], _ snapshot: URL) throws -> DuplicateMergeDraft,
                now: @escaping @Sendable () -> Date, today: @escaping @Sendable () -> String, newKey: @escaping @Sendable () -> String) {
        self.source = source
        self.music = music
        self.drafts = drafts
        self.musicOrder = musicOrder
        self.previews = previews
        self.xml = xml
        self.draftFiles = draftFiles
        self.batches = batches
        self.staging = staging
        self.files = files
        self.analysis = analysis
        self.recovery = recovery
        self.playlistImports = playlistImports
        self.backups = backups
        self.artwork = artwork
        self.relocate = relocate
        self.query = query
        self.appleMusic = appleMusic
        self.liveShare = liveShare
        self.linkedXML = linkedXML
        self.usbSnapshots = usbSnapshots
        self.snapshots = snapshots
        self.localKeys = localKeys
        self.prepareMerge = prepareMerge
        self.now = now
        self.today = today
        self.newKey = newKey
    }
}

/// 라이브러리 화면이 부르는 유스케이스 묶음. 조립 지점이 포트로 한 번 만들어 화면 모델(`LibraryStore`)·CLI 명령에 넘긴다.
/// 포트 묶음은 공개하지 않는다: 화면 모델·명령은 유스케이스(와 아래 읽기 메서드)만 부른다. 반영 세션은 같은 초안 저장 큐·스냅샷을
/// `ReflectionPorts(sharing:…)`로 받는다.
public struct LibraryUseCases: Sendable {
    let ports: LibraryPorts
    /// 라이브러리 읽기(스냅샷·변경 감지·Music)
    public let load: LoadLibrary
    /// 초안 지켜보기(초안 색인·바깥 변경)
    public let watch: WatchDrafts
    /// rekordbox XML 가져오기(차이 → 초안)
    public let importXML: ImportXML
    /// rekordbox XML 내보내기(라이브러리·추가한 곡·반영 XML)
    public let exportXML: ExportXML
    /// 추가한 곡(넣기·가져온 뒤 확인·그리드·키 추정)
    public let stage: StageTracks
    /// 막힌 초안 복구(#232)
    public let recover: RecoverDrafts
    /// 재생 목록 초안 편집·연결
    public let playlists: EditPlaylists
    /// 앨범아트 초안
    public let artwork: EditArtwork
    /// 같은 음원 곡 합치기
    public let merge: MergeDuplicates
    /// 파일 없는 곡의 새 위치 찾기(#62)
    public let relocate: RelocateTracks
    /// 라이브러리 질의(CLI `search`·`track`·`report`·`path`·`compat` …)
    public let queries: QueryLibrary
    /// 곡별 큐·태그 초안 파일 바로 고치기(CLI `draft`)
    public let draftEdits: EditDraftFiles
    /// Music XML에서 곡 가져오기
    public let appleMusic: ImportAppleMusic
    /// 곡 목록 미리 보기 파형(채우기·칸 원자료·비우기)
    public let previews: ShowPreviewWaveforms
    /// USB 큐·그리드를 이 라이브러리 초안으로 넣기
    public let usbCueGrid: ImportUsbCueGridDrafts

    public init(ports: LibraryPorts) {
        self.ports = ports
        load = LoadLibrary(source: ports.source, music: ports.music, drafts: ports.drafts, order: ports.musicOrder,
                           snapshots: ports.snapshots, usbSnapshots: ports.usbSnapshots, localKeys: ports.localKeys)
        watch = WatchDrafts(drafts: ports.drafts)
        importXML = ImportXML(files: ports.xml, source: ports.source, drafts: ports.drafts, draftFiles: ports.draftFiles,
                              newKey: ports.newKey)
        exportXML = ExportXML(files: ports.xml, source: ports.source, drafts: ports.drafts, batches: ports.batches, now: ports.now)
        stage = StageTracks(files: ports.files, analysis: ports.analysis, drafts: ports.drafts, source: ports.source, today: ports.today,
                            staging: ports.staging, imports: ports.playlistImports, newKey: ports.newKey)
        recover = RecoverDrafts(reader: ports.recovery, drafts: ports.drafts)
        playlists = EditPlaylists(imports: ports.playlistImports, drafts: ports.drafts)
        artwork = EditArtwork(artwork: ports.artwork, files: ports.files, drafts: ports.drafts)
        merge = MergeDuplicates(prepare: ports.prepareMerge, drafts: ports.drafts)
        relocate = RelocateTracks(source: ports.relocate)
        queries = QueryLibrary(source: ports.source, query: ports.query, liveShare: ports.liveShare)
        draftEdits = EditDraftFiles(files: ports.draftFiles)
        appleMusic = ImportAppleMusic(files: ports.appleMusic)
        previews = ShowPreviewWaveforms(previews: ports.previews)
        usbCueGrid = ImportUsbCueGridDrafts(drafts: ports.drafts, files: ports.draftFiles, newKey: ports.newKey)
    }

    // MARK: - 표시용 읽기

    /// rekordbox 환경설정에 한 번 지정하는 연동 XML 파일("XML 만들기"가 늘 이 파일을 덮어쓴다)
    public var linkedXML: URL { ports.linkedXML }

    /// 백업 폴더의 쓰기 전 백업(최근 것부터)
    public func writeBackups(in folder: URL) -> [RekordboxWriteBackup] { ports.backups.list(folder) }

    /// 되돌릴 rekordbox 쓰기 백업이 있는지
    public func hasWriteBackup(in folder: URL) -> Bool { writeBackups(in: folder).contains(where: \.isWrite) }

    /// 음원 파일이 없는 곡(#126). 곡마다 파일 시스템을 보는 일이라 메인 밖에서 한다
    public func missingFiles(_ tracks: [Track]) async -> MissingFiles {
        let exists = ports.files.exists
        return (try? await LoadLibrary.background(qos: .utility) { MissingFiles.scan(tracks, exists: exists) }) ?? MissingFiles()
    }

    /// 진단 줄을 남긴다(라이브러리 읽기 시간 등)
    public func log(_ line: String) { ports.source.log(line) }
}
