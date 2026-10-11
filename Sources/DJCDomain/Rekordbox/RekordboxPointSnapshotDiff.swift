import Foundation

/// 시점 스냅샷과 지금 라이브러리의 차이 요약(#225). 복원하면 무엇이 어떻게 바뀌는지를 곡·큐·그리드·태그·재생 목록·파일 수준으로 센다.
/// 두 DB는 임시 폴더에 복사한 사본으로 읽는다(라이브 DB·스냅샷 폴더에 읽기 곁 파일을 남기지 않게). 분석·앨범아트 파일은
/// 경로·크기·수정 시각만 견준다(클론은 수정 시각을 그대로 둔다). 내용은 출력하지 않는다.
/// `djc lab db-diff`(모든 표·칸 비교)는 규칙을 알아낼 때 쓰는 실험 도구라 옮기지 않고, 사용자가 알아볼 수준만 센다.
/// 값과 문구만 여기 두고, 두 DB를 읽어 견주는 일(`compare`)은 RekordboxKit의 확장이다(#167).
public struct RekordboxPointSnapshotDiff: Sendable, Equatable {
    /// 지금 있고 스냅샷에 없는 곡(복원하면 컬렉션에서 빠진다)
    public var tracksRemoved: [String] = []
    /// 스냅샷에만 있는 곡(복원하면 돌아온다)
    public var tracksRestored: [String] = []
    public var cuesChanged: [String] = []
    /// BPM이나 분석 파일이 다른 곡
    public var gridsChanged: [String] = []
    /// 제목·아티스트·앨범·장르·코멘트·키·평점·곡 색 등 곡 정보가 다른 곡
    public var tagsChanged: [String] = []
    /// 지금만 있는 재생 목록(복원하면 사라진다)
    public var playlistsRemoved: [String] = []
    /// 스냅샷에만 있는 재생 목록(복원하면 돌아온다)
    public var playlistsRestored: [String] = []
    /// 이름·곡·순서가 다른 재생 목록
    public var playlistsChanged: [String] = []
    /// 다른·지금만·스냅샷에만 있는 분석 파일 수
    public var analysisFiles = FileCounts()
    public var artworkFiles = FileCounts()
    /// 복원하면 다시 읽어야 할 곡(덱이 새 값을 읽게)
    public var changedTrackUUIDs: Set<String> = []
    /// 지금 DB의 클라우드 동기화 카운터(`lastUpdateCount`, 정수 칸만)
    public var currentCloudUpdateCount: Int?
    /// 그리드·분석이 바뀌는 곡(같은 곡을 두 번 세지 않게)·빠지거나 돌아오는 곡. 비교(RekordboxKit)가 채우는 중간 값
    public var gridUUIDs: Set<String> = []
    public var addedOrGoneUUIDs: Set<String> = []

    public struct FileCounts: Sendable, Equatable {
        public var changed = 0
        /// 지금만 있음(복원하면 지운다)
        public var removed = 0
        /// 스냅샷에만 있음(복원하면 되살린다)
        public var restored = 0
        public var total: Int { changed + removed + restored }

        public init(changed: Int = 0, removed: Int = 0, restored: Int = 0) {
            self.changed = changed
            self.removed = removed
            self.restored = restored
        }
    }

    public init() {}

    public var isEmpty: Bool {
        tracksRemoved.isEmpty && tracksRestored.isEmpty && cuesChanged.isEmpty && gridsChanged.isEmpty && tagsChanged.isEmpty
            && playlistsRemoved.isEmpty && playlistsRestored.isEmpty && playlistsChanged.isEmpty
            && analysisFiles.total == 0 && artworkFiles.total == 0
    }

    /// 스냅샷 뒤 클라우드 동기화가 더 진행됐는지(#229 확인 전: 막지 않고 확인 창에 알린다)
    public func cloudSyncedSince(_ entry: RekordboxPointSnapshotEntry) -> Bool {
        guard let current = currentCloudUpdateCount, current > 0 else { return false }
        return current > (entry.metadata.cloudUpdateCount ?? 0)
    }

    /// 클라우드 동기화가 스냅샷 뒤에 진행된 라이브러리에 붙이는 한 줄(#229 확인 전이라 막지 않고 알린다)
    public static var cloudSyncNote: String {
        String(ui: "이 스냅샷 뒤에 클라우드 동기화가 있었습니다. rekordbox를 켜면 동기화가 복원한 내용 일부를 다시 바꿀 수 있습니다.")
    }

    /// 요약 줄(복원하면 일어나는 일로). 바뀐 것이 없으면 빈 배열
    public var summary: [String] {
        var lines: [String] = []
        if !tracksRemoved.isEmpty { lines.append(String(ui: "컬렉션에서 빠지는 곡 \(tracksRemoved.count)")) }
        if !tracksRestored.isEmpty { lines.append(String(ui: "컬렉션에 돌아오는 곡 \(tracksRestored.count)")) }
        if !cuesChanged.isEmpty { lines.append(String(ui: "큐가 바뀌는 곡 \(cuesChanged.count)")) }
        if !gridsChanged.isEmpty { lines.append(String(ui: "그리드·분석이 바뀌는 곡 \(gridsChanged.count)")) }
        if !tagsChanged.isEmpty { lines.append(String(ui: "곡 정보가 바뀌는 곡 \(tagsChanged.count)")) }
        let playlists = playlistsRemoved.count + playlistsRestored.count + playlistsChanged.count
        if playlists > 0 { lines.append(String(ui: "바뀌는 재생 목록 \(playlists)")) }
        if analysisFiles.total > 0 { lines.append(String(ui: "바뀌는 분석 파일 \(analysisFiles.total)")) }
        if artworkFiles.total > 0 { lines.append(String(ui: "바뀌는 앨범아트 파일 \(artworkFiles.total)")) }
        return lines
    }

    /// 펼쳐 보기: 묶음마다 제목 줄과 이름(묶음마다 `limit`개까지)
    public func details(limit: Int = 30) -> [(title: String, items: [String])] {
        func group(_ title: String, _ items: [String]) -> (title: String, items: [String])? {
            guard !items.isEmpty else { return nil }
            let shown = Array(items.prefix(limit))
            return (title, items.count > limit ? shown + [String(ui: "외 \(items.count - limit)개")] : shown)
        }
        return [
            group(String(ui: "컬렉션에서 빠지는 곡"), tracksRemoved),
            group(String(ui: "컬렉션에 돌아오는 곡"), tracksRestored),
            group(String(ui: "큐가 바뀌는 곡"), cuesChanged),
            group(String(ui: "그리드·분석이 바뀌는 곡"), gridsChanged),
            group(String(ui: "곡 정보가 바뀌는 곡"), tagsChanged),
            group(String(ui: "사라지는 재생 목록"), playlistsRemoved),
            group(String(ui: "돌아오는 재생 목록"), playlistsRestored),
            group(String(ui: "바뀌는 재생 목록"), playlistsChanged),
        ].compactMap { $0 }
    }
}
