import DJCDomain
import Testing

@Suite("큐 목록 보기")
struct CueListFilterTests {
    let cues = [
        EditableCue(kind: .memory, time: 3, name: "메모리"),
        EditableCue(kind: .hot(7), time: 4, name: "핫큐 H"),
        EditableCue(kind: .memory, time: 5, loop: .init(end: 7, active: true, beats: 4)),
        EditableCue(kind: .hot(0), time: 6, loop: .init(end: 8, beats: 4)),
    ]

    @Test func 전체는_통합_보기의_순서와_편집_정보를_그대로_유지한다() {
        #expect(cues.filter(CueListFilter.all.includes) == cues)
        #expect(CueListFilter.allCases == [.all, .hot, .memory])
    }

    @Test func 종류별_보기는_루프를_포함하고_기존_순서를_유지한다() {
        #expect(cues.filter(CueListFilter.hot.includes) == [cues[1], cues[3]])
        #expect(cues.filter(CueListFilter.memory.includes) == [cues[0], cues[2]])
        #expect([EditableCue]().filter(CueListFilter.hot.includes).isEmpty)
    }

    @Test func 저장된_탭이_없거나_잘못되면_전체로_돌아간다() {
        #expect(SettingKeys.cueListFilter.defaultValue == "all")
        #expect(SettingKeys.cueListFilter.value(from: nil) == "all")
        #expect(SettingKeys.cueListFilter.value(from: "invalid") == "all")
        for filter in CueListFilter.allCases {
            #expect(SettingKeys.cueListFilter.value(from: filter.rawValue) == filter.rawValue)
        }
        #expect(SettingKeys.all.contains(SettingKeys.cueListFilter.name))
    }
}
