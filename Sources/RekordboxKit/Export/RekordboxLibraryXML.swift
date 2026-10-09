import DJCDomain
import Foundation

/// 라이브러리 전체를 rekordbox XML(`DJ_PLAYLISTS`)로 내보낸다(#72). 스냅샷(읽기용 사본)과 분석 파일을 읽기만 하고,
/// 지정한 출력 파일 하나에만 쓴다. rekordbox 라이브러리에는 쓰지 않는다.
///
/// 기존 `RekordboxXML`(새 곡)·`Reflection`(큐·그리드 반영)은 rekordbox로 되가져오는 일부 내용용이라 그대로 두고,
/// 이 경로는 다른 도구가 읽는 전체 내보내기다. 직렬화 도우미(`escape`·`location`·`kind`)만 나눠 쓴다.
///
/// 시각은 rekordbox 시간축(초)이다. DB의 큐(ms)와 분석 파일의 박(ms)이 이미 그 시간축이라 인코더 지연을 더하거나 빼지 않는다
/// (기존 XML 경로와 같은 규칙).
///
/// 넣지 않는 것(rekordbox가 XML에 어떻게 넣는지 확인하지 못했거나 이 형식에 칸이 없다):
/// 인텔리전트 재생 목록·My Tag·핫큐 색(Red·Green·Blue)·앨범 아티스트·Grouping·Mix·DateModified·LastPlayed·스트리밍 곡·
/// 쓰지 않은 초안. Rating·Colour는 곡 행에 칸이 생기면(#65) `Entry.extraAttributes`로 연결한다.
public enum RekordboxLibraryXML {
    /// TRACK에 덧붙일 속성 한 칸
    public struct Attribute: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    /// `Track`에 없는 곡 행 칸(내보내기에서만 읽는다)
    public struct Extras: Sendable, Equatable {
        public var fileSize: Int?
        public var discNumber: Int?
        public var sampleRate: Int?
        /// `djmdContent.DJPlayCount`
        public var playCount = 0
        public var remixer: String?
        public var label: String?
        /// `StockDate`(YYYY-MM-DD). 비면 곡 행을 만든 날(`Track.importedOn`)로 대신한다.
        public var dateAdded: String?
        public init() {}
    }

    /// XML TRACK 하나
    public struct Entry: Sendable {
        /// XML `TrackID`. `ContentID`가 정수면 그 값을 쓴다.
        public var trackKey: Int
        public var track: Track
        public var extras: Extras
        public var marks: [Reflection.Mark]
        public var tempos: [GridSegment]
        /// 이 내보내기가 아직 모르는 칸(#65의 Rating·Colour)을 Location 뒤에 그대로 붙인다.
        public var extraAttributes: [Attribute] = []

        public init(trackKey: Int, track: Track, extras: Extras, marks: [Reflection.Mark], tempos: [GridSegment],
                    extraAttributes: [Attribute] = []) {
            self.trackKey = trackKey; self.track = track; self.extras = extras; self.marks = marks; self.tempos = tempos
            self.extraAttributes = extraAttributes
        }
    }

    /// PLAYLISTS의 NODE 하나. `children`이 nil이면 재생 목록, 있으면 폴더다.
    public struct ListNode: Sendable, Equatable {
        public var name: String
        public var children: [ListNode]?
        /// 재생 목록의 `TrackID`(곡 순서, 같은 곡이 여러 번 있을 수 있다)
        public var keys: [Int]
        /// rekordbox 목록 ID(가져오기 비교가 초안을 만들 때 쓴다, 파일에는 쓰지 않는다)
        public var id: String?
        public init(name: String, children: [ListNode]? = nil, keys: [Int] = [], id: String? = nil) {
            self.name = name; self.children = children; self.keys = keys; self.id = id
        }
    }

    public typealias Omitted = LibraryXMLSummary.Omitted
    public typealias Summary = LibraryXMLSummary

    public struct Collection: Sendable {
        public var entries: [Entry]
        public var lists: [ListNode]
        public var productVersion: String
        public var omitted: Omitted

        public init(entries: [Entry], lists: [ListNode], productVersion: String = "0.1", omitted: Omitted = Omitted()) {
            self.entries = entries; self.lists = lists; self.productVersion = productVersion; self.omitted = omitted
        }

        public var summary: Summary {
            var summary = Summary()
            summary.tracks = entries.count
            summary.marks = entries.reduce(0) { $0 + $1.marks.count }
            summary.tracksWithGrid = entries.filter { !$0.tempos.isEmpty }.count
            summary.tracksWithoutGrid = entries.count - summary.tracksWithGrid
            func count(_ nodes: [ListNode]) {
                for node in nodes {
                    if let children = node.children { summary.folders += 1; count(children) } else {
                        summary.playlists += 1; summary.playlistEntries += node.keys.count
                    }
                }
            }
            count(lists)
            summary.omitted = omitted
            return summary
        }
    }

    public typealias Progress = LibraryXMLProgress

    // MARK: - 읽기

    /// 스냅샷과 분석 파일을 읽어 내보낼 컬렉션을 만든다(쓰지 않는다). 무거운 일이라 메인 스레드 밖에서 부르고,
    /// 부르는 작업을 취소하면 `CancellationError`로 멈춘다.
    /// - Parameter shareRoot: 분석 파일 뿌리(`…/share`). 분석 파일이 없는 곡은 TEMPO 없이 내보낸다. nil이면 모든 곡을 TEMPO 없이.
    /// - Parameter gridPaths: 주면 경로(NFC·소문자, `XMLTrackMatching.key`)가 이 안에 있는 곡만 분석 파일을 읽는다(가져오기 비교는 XML에 TEMPO가 있는 곡만 본다).
    public static func load(snapshot: URL, shareRoot: URL?, productVersion: String = "0.1", gridPaths: Set<String>? = nil,
                            progress: (@Sendable (Progress) -> Void)? = nil) throws -> Collection {
        progress?(Progress(phase: .readingLibrary, done: 0, total: 0))
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let extras = try loadExtras(snapshot: snapshot)
        try Task.checkCancellation()

        var omitted = Omitted()
        // 스트리밍 곡은 파일 경로가 없어 rekordbox가 XML에 어떻게 쓰는지 확인하지 못했다.
        let local = library.tracks.filter { track in
            if track.isStreaming { omitted.streamingTracks += 1; return false }
            return true
        }.sorted { lhs, rhs in
            switch (Int(lhs.id), Int(rhs.id)) {
            case let (a?, b?): a == b ? lhs.id < rhs.id : a < b
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.id < rhs.id
            }
        }
        let keys = trackKeys(for: local.map(\.id))

        var entries: [Entry] = []
        entries.reserveCapacity(local.count)
        for (index, track) in local.enumerated() {
            if index % 25 == 0 {
                try Task.checkCancellation()
                progress?(Progress(phase: .readingGrids, done: index, total: local.count))
            }
            let rawCues = library.cues(for: track)
            let marks = Reflection.marks(from: rawCues)
            omitted.unknownCues += rawCues.count - marks.count
            let tempos = shareRoot.flatMap { gridPaths.map { !$0.contains(XMLTrackMatching.key(track.folderPath).lowercased()) } == true ? nil : RekordboxShare.analysisURL(track.analysisDataPath, root: $0) }
                .flatMap { try? BeatGrid.load(anlz: $0) }
                .map(tempoSegments(from:)) ?? []
            // #65: 별점·곡 색(Rating·Colour)은 곡 행에 칸이 생기면 여기서 `extraAttributes`로 연결한다.
            entries.append(Entry(trackKey: keys[track.id] ?? 0, track: track, extras: extras[track.id] ?? Extras(),
                                 marks: marks, tempos: tempos))
        }
        progress?(Progress(phase: .readingGrids, done: local.count, total: local.count))

        let lists = listTree(library.playlists, keys: keys, omitted: &omitted)
        return Collection(entries: entries, lists: lists, productVersion: productVersion, omitted: omitted)
    }

    /// 곡 행에서 `Track`에 없는 칸. 공용 곡 읽기(`RekordboxLibrary.load`)는 건드리지 않고 이 내보내기에서만 한 번 더 읽는다.
    static func loadExtras(snapshot: URL) throws -> [String: Extras] {
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var result: [String: Extras] = [:]
        try db.query("""
            SELECT c.ID, c.FileSize, c.DiscNo, c.SampleRate, c.DJPlayCount, rm.Name, lb.Name, c.StockDate
            FROM djmdContent c
            LEFT JOIN djmdArtist rm ON rm.ID = c.RemixerID
            LEFT JOIN djmdLabel lb ON lb.ID = c.LabelID
            WHERE c.rb_local_deleted = 0
            """) { row in
            guard let id = row.string(0) else { return }
            var extras = Extras()
            extras.fileSize = row.int(1).flatMap { $0 > 0 ? $0 : nil }
            extras.discNumber = row.int(2).flatMap { $0 > 0 ? $0 : nil }
            extras.sampleRate = row.int(3).flatMap { $0 > 0 ? $0 : nil }
            extras.playCount = max(row.int(4) ?? 0, 0)
            extras.remixer = row.string(5).flatMap { $0.isEmpty ? nil : $0 }
            extras.label = row.string(6).flatMap { $0.isEmpty ? nil : $0 }
            extras.dateAdded = row.string(7).flatMap { $0.isEmpty ? nil : String($0.prefix(10)) }
            result[id] = extras
        }
        return result
    }

    /// `ContentID`가 정수 표기 그대로면 `TrackID`로 쓰고(rekordbox가 내보낸 XML과 곡을 짝지을 수 있게), 아니면 겹치지 않는 번호를 새로 준다.
    static func trackKeys(for ids: [String]) -> [String: Int] {
        var keys: [String: Int] = [:]
        var used = Set<Int>()
        for id in ids {
            if let number = Int(id), String(number) == id, number >= 0, used.insert(number).inserted { keys[id] = number }
        }
        var next = (used.max() ?? 0) + 1
        for id in ids where keys[id] == nil {
            keys[id] = next
            next += 1
        }
        return keys
    }

    /// 분석 파일의 박 → 템포 구간. 구간 나눔은 그리드 초안과 같고(`GridDraft.segments`), BPM은 다시 구한 값이 아니라
    /// rekordbox가 구간 첫 박에 적은 값을 그대로 쓴다(화면에 보이는 값과 같게).
    static func tempoSegments(from grid: BeatGrid) -> [GridSegment] {
        GridDraft.segments(from: grid).compactMap { segment in
            let index = grid.firstIndex(atOrAfter: segment.start - 1e-9)
            let stored = grid.beats.indices.contains(index) ? grid.beats[index].bpm : segment.bpm
            let bpm = stored > 0 ? stored : segment.bpm
            return bpm > 0 ? GridSegment(start: segment.start, bpm: bpm, firstBeatNumber: segment.firstBeatNumber) : nil
        }
    }

    /// 재생 목록·폴더 트리. 인텔리전트 목록은 넣지 않고, 컬렉션에 없는 곡 항목은 뺀다.
    /// ROOT에서 닿지 않는 목록(없는 폴더를 가리키거나 서로를 가리키는 폴더)은 rekordbox 트리에 없으므로 빼고 `orphanedPlaylists`에 센다.
    static func listTree(_ playlists: [RekordboxPlaylist], keys: [String: Int], omitted: inout Omitted) -> [ListNode] {
        let byParent = Dictionary(grouping: playlists, by: \.parentID)
        var reached = Set<String>()
        func build(_ parent: String) -> [ListNode] {
            (byParent[parent] ?? []).sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }.compactMap { playlist in
                guard reached.insert(playlist.id).inserted else { return nil }
                if playlist.isSmart { omitted.intelligentPlaylists += 1; return nil }
                if playlist.isFolder { return ListNode(name: playlist.name, children: build(playlist.id), id: playlist.id) }
                let present = playlist.trackIDs.compactMap { keys[$0] }
                omitted.playlistEntries += playlist.trackIDs.count - present.count
                return ListNode(name: playlist.name, keys: present, id: playlist.id)
            }
        }
        let tree = build("root")
        omitted.orphanedPlaylists += Set(playlists.map(\.id)).subtracting(reached).count
        return tree
    }
}
