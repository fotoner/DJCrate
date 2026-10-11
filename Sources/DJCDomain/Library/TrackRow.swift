import Foundation

/// 표 한 줄. 로드할 때 한 번 분류·파싱해 두고 화면에서는 읽기만 한다.
public struct TrackRow: Identifiable, Hashable, Sendable {
    public enum CueState: String, Sendable {
        case manual = "수동"
        case autoOnly = "자동만"
        case none = "없음"
    }

    public let track: Track
    public let cues: [Cue]
    public private(set) var commentEvaluation: CommentEvaluation?
    public let playCount: Int
    public let cueState: CueState
    public let manualCueCount: Int
    /// 직접 찍은 핫큐 수
    public let hotCueCount: Int
    /// 메모리 큐 수. rekordbox 자동 큐도 덱처럼 메모리 큐로 센다(#145).
    public let memoryCueCount: Int
    /// 메모리 큐 가운데 rekordbox 자동 큐 수
    public let autoMemoryCueCount: Int

    /// 같은 곡을 다시 재생한 행도 따로 선택하고 원래 순번을 표시한다.
    public var historyEntry: RekordboxHistory.Entry?
    public var historyTrackNumber: Int? { historyEntry?.trackNumber }
    /// iTunes 목록의 반복 곡은 행마다 고유 ID를 쓰되 편집 대상은 `track.id`로 찾는다.
    public struct PlaylistOccurrence: Hashable, Sendable {
        public let id: String
        public let number: Int

        public init(id: String, number: Int) {
            self.id = id
            self.number = number
        }
    }
    public var playlistOccurrence: PlaylistOccurrence?
    public var playlistTrackNumber: Int? { playlistOccurrence?.number }
    /// USB 곡의 로컬 대비 갱신 상태(USB 목록에서만, `UsbLibraryRows`)
    public var usbSync: UsbSyncStatus?
    /// USB 곡의 그림·분석 파일(마운트한 볼륨 안, 읽기 전용, `UsbLibraryRows`). 목록의 앨범아트·미리 보기 칸이 이 뿌리로 읽는다.
    /// 경로는 문자열만 거른 값이다. 열 때는 링크를 거르는 포트(`ArtworkFiles.volumeThumbnail`·`PreviewWaveforms.volumeFile`)로 연다.
    /// 로컬 share 기준 경로(`track.imagePath`·`analysisDataPath`)는 비워 둔다. 로컬 share로 찾는 곳(덱·반영·미리 데우기)이 다른 파일을 읽지 않게
    public var usbFiles: UsbFiles?
    public struct UsbFiles: Hashable, Sendable {
        /// 볼륨 뿌리(마운트 지점)
        public let root: URL
        /// 볼륨 뿌리 기준 아트워크 작은 그림(`PIONEER/Artwork/nnnnn/[ab]n.jpg`). 없거나 아트워크 폴더 밖이면 nil
        public let artwork: String?
        /// 볼륨 뿌리 기준 분석 파일(`PIONEER/USBANLZ/…/ANLZnnnn.DAT`). 없거나 분석 폴더 밖이면 nil
        public let analysis: String?
        /// 그 볼륨을 읽은 판. 다시 읽으면 오른다(쓰기가 같은 자리 그림을 덮어써도 썸네일을 새로 읽게)
        public let revision: Int

        public init(root: URL, artwork: String?, analysis: String?, revision: Int) {
            self.root = root
            self.artwork = artwork
            self.analysis = analysis
            self.revision = revision
        }
    }
    public var id: String { historyEntry.map { "history:\($0.id)" } ?? playlistOccurrence?.id ?? track.id }
    /// USB에서 읽은 곡의 ID 머리(`usb:<볼륨>:<ContentID>`)
    public static let usbIDPrefix = "usb:"
    /// USB에서 읽은 곡(읽기 전용: 편집·쓰기를 막는다. 덱에는 짝인 로컬 곡을 올린다, #255)
    public var isUsb: Bool { track.id.hasPrefix(Self.usbIDPrefix) }
    /// DJCrate에 추가했지만 아직 rekordbox 컬렉션에 없는 곡.
    public var isStaged: Bool { track.id.hasPrefix("djc-") }
    /// rekordbox는 Spotify 곡의 제목·아티스트를 `$A7:v1:…`로 암호화해 저장한다.
    public var isEncrypted: Bool { track.title.hasPrefix("$A7:") }
    public var title: String { isEncrypted ? String(ui: "🔒 Spotify 곡 (제목 암호화됨)") : track.title }
    public var artist: String { isEncrypted ? "" : track.artist ?? "" }
    public var comment: String { track.comment }
    public var commentClassName: String { commentEvaluation?.displayName ?? "" }
    public var importedOn: String { track.importedOn ?? "" }
    public var cueStateName: String { cueState.rawValue }
    public var bpmValue: Double { track.bpm ?? 0 }
    public var genre: String { track.genre ?? "" }
    public var lengthSeconds: Int { track.lengthSeconds }
    /// "4:02"
    public var lengthText: String { track.lengthSeconds > 0 ? String(format: "%d:%02d", track.lengthSeconds / 60, track.lengthSeconds % 60) : "" }
    public var album: String { isEncrypted ? "" : track.album ?? "" }
    public var albumArtist: String { isEncrypted ? "" : track.albumArtist ?? "" }
    public var composer: String { track.composer ?? "" }
    /// 정렬용: 연도·트랙 번호는 숫자로(없으면 0)
    public var releaseYear: Int { track.releaseYear ?? 0 }
    public var trackNumber: Int { track.trackNumber ?? 0 }
    public var keyName: String { track.key ?? "" }
    /// 정렬용: 평점 별 수(없으면 0)
    public var ratingValue: Int { track.rating }
    /// 정렬용: 곡 색 번호(rekordbox 색 순서와 같다, 없으면 0)
    public var colorSortKey: Int { track.colorID.flatMap { Int($0) } ?? 0 }
    /// 살아 있는 rekordbox 재생 목록(폴더 제외)에 들었는지. 평점·곡 색 쓰기를 확인한 범위를 가른다(`TagWriteScope`, #65).
    public var inPlaylist = false
    /// 추가한 곡의 키를 DJCrate가 추정했는지(목록에 추정으로 표시한다, #124)
    public var keyEstimated = false
    /// 태그 편집의 기준(지금 rekordbox 값). 추가한 곡의 키는 아직 rekordbox에 없으니(넣을 때 `KeyID` '0') 빈칸이다: 목록에 보이는 키
    /// (음원 태그·DJCrate 추정)는 제안일 뿐이고, 사용자가 고른 키만 곡을 넣을 때 함께 쓴다(#5).
    public var tagFields: TagFields {
        var fields = TagFields(track: track)
        if isStaged { fields.musicalKey = "" }
        return fields
    }
    /// 음원 파일을 찾지 못한 로컬 곡(#126). 라이브러리를 읽은 뒤 뒤에서 확인해 채운다(`LibraryStore.checkMissingFiles`).
    public var fileMissing = false
    /// rekordbox 그리드의 변속 흐름(BPM 순서, 변속 없으면 빈 배열)
    public let tempoChanges: [Double]
    /// rekordbox 오토게인(분석한 곡만)
    public let autoGain: RekordboxAutoGain?
    /// 목록 표시: "175→128→175"
    public var tempoChangeText: String { tempoChanges.map { String(format: "%.0f", $0) }.joined(separator: "→") }
    /// 정렬용: 변속 수
    public var tempoChangeCount: Int { max(tempoChanges.count - 1, 0) }
    /// 파일 형식(확장자). 스트리밍 곡은 "스트림".
    public var formatName: String { track.isStreaming ? String(ui: "스트림") : track.fileExtension.uppercased() }

    /// 메모리 칸(#121): 메모리 큐 수(덱 목록과 같은 수, #145). 없으면 핫큐 칸처럼 비우고,
    /// 메모리 큐가 아직 고치지 않은 rekordbox 자동 큐뿐이면 흐린 글자로 보인다.
    public enum MemoryCueLabel: Equatable {
        case count(Int)
        case autoOnly(Int)
        case empty

        public var text: String {
            switch self {
            case .count(let count), .autoOnly(let count): "\(count)"
            case .empty: ""
            }
        }
    }

    /// `draft`: DJCrate 큐 초안의 개수(반영 전이라도 초안을 따른다). 초안에도 자동 큐가 메모리 큐로 들어 있다.
    public func memoryCueLabel(draft: CueCounts?) -> MemoryCueLabel {
        let memory = draft?.memory ?? memoryCueCount, auto = draft?.autoMemory ?? autoMemoryCueCount
        if memory == 0 { return .empty }
        return memory == auto ? .autoOnly(memory) : .count(memory)
    }

    /// 검색용 소문자 키(제목·아티스트·코멘트·장르). 로딩 때 한 번만 만든다.
    public let searchKey: String

    public init(track: Track, cues: [Cue], playCount: Int, tempoChanges: [Double] = [], autoGain: RekordboxAutoGain? = nil, commentRule: (any CommentRule)? = nil) {
        self.track = track
        self.tempoChanges = tempoChanges
        self.autoGain = autoGain
        self.cues = cues.sorted { $0.inMsec < $1.inMsec }
        self.playCount = playCount
        commentEvaluation = commentRule?.evaluate(track.comment)
        let encrypted = track.title.hasPrefix("$A7:")
        searchKey = [encrypted ? "" : track.title, encrypted ? "" : (track.artist ?? ""), track.comment, track.genre ?? ""]
            .joined(separator: "\u{1F}").lowercased()
        let manual = cues.filter { !$0.isAutoGenerated }
        manualCueCount = manual.count
        hotCueCount = manual.filter { !$0.isMemoryCue }.count
        memoryCueCount = cues.filter(\.isMemoryCue).count
        autoMemoryCueCount = cues.filter { $0.isMemoryCue && $0.isAutoGenerated }.count
        cueState = cues.isEmpty ? .none : (manual.isEmpty ? .autoOnly : .manual)
    }
    public mutating func applyCommentRule(_ rule: (any CommentRule)?) {
        commentEvaluation = rule?.evaluate(track.comment)
    }
}

extension LibraryFilter {
    public func includes(_ row: TrackRow) -> Bool {
        includes(track: row.track, comment: row.commentEvaluation, hasCues: !row.cues.isEmpty,
                 playCount: row.playCount, tempoChanges: row.tempoChanges, fileMissing: row.fileMissing)
    }
}

