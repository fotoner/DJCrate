import Foundation

/// 렌더한 편집본(곡 편집·Flip)을 "추가한 곡"에 넣을 때 함께 두는 초안(규칙).
///
/// 그리드는 추정하지 않고 편집으로 변환한 그리드를(비면 두지 않는다: 원곡에 그리드가 없던 Flip은 추가한 곡에서 추정한다),
/// 큐는 출력 위치로 옮긴 큐를 초안으로 둔다. 곡 정보는 원곡 값을 태그 초안으로 둔다(렌더한 WAV에는 태그가 없다).
/// 출력은 PCM이라 인코더 지연이 없어 초안의 rekordbox 시간축 = 출력 파일 시간축이다.
public struct StagedEditDrafts: Sendable {
    /// 추가 목록에 넣을 곡(경로는 NFC, 그리드가 있으면 그 BPM을 믿을 만한 값으로)
    public var track: StagedTrack
    public var grid: GridDraft?
    public var cues: CueDraft
    public var tags: TagDraft

    /// - Parameters:
    ///   - read: 렌더한 파일의 태그로 만든 곡(새 UUID)
    ///   - grid: 출력 그리드(템포 구간). 비어 있으면 그리드 초안을 두지 않는다
    ///   - source: 원곡(곡 정보를 태그 초안으로 옮긴다)
    public init(track read: StagedTrack, grid: [GridSegment], cues: [EditableCue], source: Track?, title: String) {
        var track = read
        track.path = read.path.precomposedStringWithCanonicalMapping
        if let first = grid.first {
            track.bpm = first.bpm
            track.gridConfident = true
        }
        var cueDraft = CueDraft(trackUUID: track.uuid)
        for cue in cues { cueDraft.place(cue) }
        var tags = TagDraft(track: track.track)
        if let source {
            tags.fields = TagFields(track: source)
            // 원곡의 키·평점·곡 색은 이 편집본에서 사용자가 고른 값이 아니니 고친 칸으로 담지 않는다(#5: 사용자가 고른 키만 쓴다, 담으면 곡을 넣을 때
            // 쓰인다. 평점·곡 색은 #65). 추가한 곡에서 고르면 넣을 때 함께 쓴다.
            for key in TagFields.Key.independent { tags.fields[key] = tags.base[key] }
        }
        tags.fields.title = title
        self.track = track
        self.grid = grid.isEmpty ? nil : GridDraft(trackUUID: track.uuid, base: [], segments: grid)
        self.cues = cueDraft
        self.tags = tags
    }
}
