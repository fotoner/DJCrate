import DJCDomain
import Testing

@Suite("코멘트 프리셋")
struct CommentPresetTests {
    @Test func 기본은_꺼짐이고_규칙_밖_필터만_숨긴다() {
        #expect(SettingKeys.commentPreset.defaultValue == "none")
        #expect(SettingKeys.commentPreset.value(from: "unknown") == "none")
        #expect(CommentPreset.none.rule == nil)
        #expect(LibraryFilter.visible(commentPreset: .none).contains(.emptyComment))
        #expect(!LibraryFilter.visible(commentPreset: .none).contains(.offConvention))
        #expect(LibraryFilter.visible(commentPreset: .anisong) == LibraryFilter.allCases)
    }

    @Test func 빈_코멘트_필터는_규칙_없이_정리한_코멘트로_고른다() {
        func includes(_ comment: String) -> Bool {
            let track = Track(id: "1", uuid: "uuid-1", title: "곡 1", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                              releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/a.mp3",
                              comment: comment, importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
            return LibraryFilter.emptyComment.includes(track: track, comment: nil, hasCues: true, playCount: 0, tempoChanges: [],
                                                       fileMissing: false)
        }
        #expect(!LibraryFilter.emptyComment.requiresCommentRule)
        #expect(LibraryFilter.offConvention.requiresCommentRule)
        for blank in ["", "  ", "\u{3000}\n", "\u{1}"] { #expect(includes(blank)) }
        #expect(!includes(" 메모 "))
    }

    @Test func 애니송은_기존_분류와_표시를_유지한다() throws {
        let rule = try #require(CommentPreset.anisong.rule)
        let result = rule.evaluate(" TVA  시험(약칭) 2기 OP 1 TVSIZE ")
        #expect(result.classification == "convention")
        #expect(result.displayName == "규칙")
        #expect(result.isMatch)
        #expect(result.prefix == "TVA")
        #expect(result.usages == ["OP"])
        #expect(result.summary == "TVA · 시험 · 2기 · 약칭 약칭 · OP 1 · TVSIZE")
        #expect(rule.evaluate("").isEmpty)
        #expect(rule.evaluate("JASRAC / Lantis").classification == "residue")
        #expect(!rule.evaluate("자유 메모").isMatch)
    }
}
