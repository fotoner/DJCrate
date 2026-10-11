import DJCDomain
import Foundation
import Testing

/// 편집본을 추가한 곡에 넣을 때 두는 초안(규칙). 파일 쓰기는 DJCStorageTests `EditStagingTests`, 넣는 순서는 DJCApplicationTests `StageEditTests`.
@Suite("편집본 초안 규칙")
struct StagedEditDraftsTests {
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func source(key: String? = nil, rating: Int = 0, colorID: String? = nil) -> Track {
        Track(id: "101", uuid: "src-uuid", title: "원곡", artist: "아티스트", album: "앨범", albumArtist: nil, genre: "House",
              composer: nil, releaseYear: 2024, trackNumber: 3, key: key, bpm: 120, lengthSeconds: 100,
              folderPath: "/음원/원곡.mp3", comment: "코멘트", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false,
              rating: rating, colorID: colorID)
    }

    /// 렌더한 WAV의 태그로 만든 곡(태그가 없어 파일 이름이 제목)
    func read(_ name: String = "원곡 (Edit)") -> StagedTrack {
        StagedTrack(uuid: "new", path: "/편집본/\(name).wav".decomposedStringWithCanonicalMapping, title: name, duration: 132, addedOn: "2026-10-09")
    }

    @Test func 그리드·옮긴_큐·원곡_태그와_새_제목을_초안으로_둔다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-16,1-16,17-50"))
        let carried = edit.carry([EditableCue(kind: .hot(0), time: 32.5, name: "드롭"), EditableCue(kind: .memory, time: 0.5)])
        let drafts = StagedEditDrafts(track: read(), grid: [edit.outputGrid], cues: carried.placed, source: source(), title: "원곡 (Edit)")
        // 경로는 NFC로, 그리드 BPM은 믿을 만한 값으로
        #expect(drafts.track.path == "/편집본/원곡 (Edit).wav".precomposedStringWithCanonicalMapping)
        #expect(drafts.track.bpm == 120 && drafts.track.gridConfident == true)
        #expect(drafts.grid == GridDraft(trackUUID: "new", base: [], segments: [edit.outputGrid]))
        #expect(drafts.cues.trackUUID == "new" && drafts.cues.base.isEmpty)
        #expect(drafts.cues.cues.map(\.time) == [0, 64] && drafts.cues.cues.map(\.kind) == [.memory, .hot(0)])
        // 곡 정보는 원곡에서, 제목은 편집본 표시를 붙인 새 제목(곡 넣기·XML 내보내기가 이 값을 쓴다)
        #expect(drafts.tags.trackUUID == "new" && drafts.tags.fields.title == "원곡 (Edit)" && drafts.tags.fields.artist == "아티스트")
        #expect(drafts.tags.fields.album == "앨범" && drafts.tags.fields.genre == "House" && drafts.tags.fields.year == "2024")
        #expect(drafts.tags.fields.comment == "코멘트")
    }

    @Test func 원곡의_키·평점·곡_색은_편집본의_고친_칸으로_담지_않는다() {
        // 원곡 값은 편집본에서 사용자가 고른 값이 아니다. 고친 칸이면 곡을 넣을 때 쓰이고, 평점·곡 색은 확인한 범위(#65) 밖이면 막혀
        // 다른 칸까지 못 쓴다. 추가한 곡에서 고르면 넣을 때 함께 쓴다.
        let tags = StagedEditDrafts(track: read(), grid: grid, cues: [], source: source(key: "8A", rating: 4, colorID: "2"),
                                    title: "원곡 (Edit)").tags
        #expect(tags.fields.musicalKey == tags.base.musicalKey && tags.fields.rating == tags.base.rating && tags.fields.color == tags.base.color)
        #expect(Set(tags.changedKeys).isDisjoint(with: TagFields.Key.independent), "\(tags.changedKeys)")
        #expect(tags.fields.artist == "아티스트" && tags.fields.title == "원곡 (Edit)", "다른 칸은 원곡에서 가져온다")
    }

    @Test func 그리드_없이_넣으면_그리드_초안을_두지_않는다() {
        // 원곡에 그리드가 없던 Flip: 추가한 곡에서 그리드를 추정하도록 그리드 초안·BPM을 비운다.
        let drafts = StagedEditDrafts(track: read("원곡 (Flip)"), grid: [], cues: [EditableCue(kind: .memory, time: 1)], source: source(),
                                      title: "원곡 (Flip)")
        #expect(drafts.track.gridConfident != true && drafts.track.bpm == nil && drafts.grid == nil)
        #expect(drafts.cues.cues.map(\.time) == [1] && drafts.tags.fields.title == "원곡 (Flip)")
    }

    @Test func 여러_템포_구간을_그대로_그리드_초안으로_둔다() {
        let segments = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1), GridSegment(start: 1.7, bpm: 120, firstBeatNumber: 3),
                        GridSegment(start: 2.4, bpm: 128, firstBeatNumber: 1)]
        let drafts = StagedEditDrafts(track: read(), grid: segments, cues: [], source: nil, title: "원곡 (Flip)")
        // BPM은 첫 구간
        #expect(drafts.track.bpm == 120 && drafts.track.gridConfident == true)
        #expect(drafts.grid?.base.isEmpty == true && drafts.grid?.segments == segments)
        // 원곡이 없으면 태그는 렌더한 파일 값에 새 제목만
        #expect(drafts.tags.fields.title == "원곡 (Flip)" && drafts.tags.fields.artist.isEmpty)
    }
}
