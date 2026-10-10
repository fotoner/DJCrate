import DJCApplication
@testable import DJCrate
import AppKit
import DJCAnalysis
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import SwiftUI
import Testing

/// 덱 제안 줄: 덱에 올린 곡의 게인·그리드·키 제안을 한 줄에 모은다. [적용]만 초안을 만들고(실행 취소 가능),
/// [무시]한 제안은 "무시한 제안 다시 보기" 하나로 되살린다. 키 제안은 태그 인스펙터가 아니라 여기에만 있다.
@Suite("덱 제안 줄", .serialized)
@MainActor
struct DeckSuggestionBarTests {
    @MainActor
    final class Harness {
        let deck: DeckModel
        let store: LibraryStore
        let deckSettings: SettingsStore
        let storeSettings: SettingsStore
        let undo = UndoManager()
        private let suites: [String]

        init() {
            let deckSuite = TestDefaults.suiteName("suggestion-bar.deck"), storeSuite = TestDefaults.suiteName("suggestion-bar.store")
            suites = [deckSuite, storeSuite]
            deckSettings = SettingsStore(defaults: TestDefaults.open(deckSuite), persist: true)
            storeSettings = SettingsStore(defaults: TestDefaults.open(storeSuite), persist: true)
            deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts(), settings: deckSettings), runsAnalysis: false)
            store = LibraryStore.test(settings: storeSettings, saveTagDrafts: { _ in })
            undo.groupsByEvent = false
            deck.undoManager = undo
            store.undoManager = undo
        }

        deinit {
            for suite in suites { TestDefaults.open(suite).removePersistentDomain(forName: suite) }
        }

        var bar: DeckSuggestions { DeckSuggestions(deck: deck, store: store) }

        func load(_ row: TrackRow) async throws {
            deck.load(row)
            for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
            if deck.draft == nil { throw FixtureError("덱이 곡을 다 읽지 못함") }
        }
    }

    static func row(_ id: String, key: String? = nil, staged: Bool = false, streaming: Bool = false,
                    autoGain: RekordboxAutoGain? = nil) -> TrackRow {
        TrackRow(track: Track(id: staged ? "djc-\(id)" : id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 30,
                              folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0, autoGain: autoGain)
    }

    /// A단조 화음 30초의 크로마(덱이 디코딩하며 구하는 것과 같다)
    /// 같은 합성 음원(30초 WAV 쓰기와 크로마 분석)을 시험마다 다시 만들지 않는다.
    private static let aMinorResult = Result { try makeAMinorChroma() }
    static func aMinorChroma() throws -> KeyAnalyzer.Chroma { try aMinorResult.get() }

    private static func makeAMinorChroma() throws -> KeyAnalyzer.Chroma {
        let directory = FileManager.default.temporaryDirectory.appending(path: "djc-suggestion-bar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try KeyAnalyzer.chroma(fileAt: ChordFixture.wav(ChordFixture.aMinor, seconds: 30, in: directory, name: "a-minor.wav"))
    }

    static func gridEstimate(bpm: Double = 120) throws -> GridEstimator.Estimate {
        let period = 60 / bpm
        let beats = (0..<40).map { Double($0) * period }
        var estimate = try #require(GridEstimator.estimate(beats: beats, bars: [0, period * 4, period * 8, period * 12], duration: 20))
        estimate.segments[0].bpm = bpm
        return estimate
    }

    // MARK: 키 제안(태그 초안)

    @Test func 추가한_곡의_음원_태그_키는_적용해야만_태그_초안이_되고_실행_취소된다() async throws {
        let h = Harness()
        let row = Self.row("staged", key: "8B", staged: true)
        try await h.load(row)
        let key = try #require(h.bar.list.shown.first { $0.kind == .key })
        #expect(key.value == "8B (음원 태그)")
        #expect(h.store.tagDrafts.isEmpty, "보이기만 하고 저절로 채우지 않는다")
        h.bar.apply(.key)
        let draft = try #require(h.store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.musicalKey] && draft.fields.musicalKey == "8B")
        #expect(!h.bar.list.shown.contains { $0.kind == .key }, "적용한 뒤에는 제안이 사라진다")
        #expect(h.undo.canUndo)
        h.undo.undo()
        #expect(h.store.tagDrafts.isEmpty)
        #expect(h.bar.list.shown.first { $0.kind == .key }?.value == "8B (음원 태그)", "실행 취소하면 제안이 돌아온다")
        h.undo.redo()
        #expect(h.store.tagDrafts[row.track.uuid]?.fields.musicalKey == "8B")
    }

    @Test func 키가_빈_라이브러리_곡은_덱이_보이는_조성을_제안하고_곡을_바꾸면_앞_곡_추정이_남지_않는다() async throws {
        let h = Harness()
        let first = Self.row("first"), second = Self.row("second"), keyed = Self.row("keyed", key: "5A")
        try await h.load(first)
        #expect(!h.bar.list.shown.contains { $0.kind == .key }, "크로마가 오기 전에는 추정이 없다")
        h.deck.keyChroma = try Self.aMinorChroma()
        h.deck.refreshKeySegments()
        let key = try #require(h.bar.list.shown.first { $0.kind == .key })
        #expect(key.value == "8A")
        #expect(h.deck.key(at: 1) == "8A", "헤더의 조성과 같은 값이다")
        // 다음 곡: 크로마가 오기 전 첫 화면에 앞 곡의 추정이 비치지 않는다
        try await h.load(second)
        #expect(h.deck.estimatedKey(for: second.track.uuid) == nil && h.deck.estimatedKey(for: first.track.uuid) == nil)
        #expect(!h.bar.list.shown.contains { $0.kind == .key })
        // rekordbox 키가 있는 곡은 추정하지 않는다
        try await h.load(keyed)
        h.deck.keyChroma = try Self.aMinorChroma()
        h.deck.refreshKeySegments()
        #expect(h.deck.estimatedKey(for: keyed.track.uuid) == nil && !h.bar.list.shown.contains { $0.kind == .key })
    }

    @Test func 키를_못_고치는_곡은_키_제안이_없고_쓰는_동안에는_단추를_막는다() async throws {
        let h = Harness()
        try await h.load(Self.row("streaming", key: nil, streaming: true))
        h.deck.keyChroma = try Self.aMinorChroma()
        h.deck.refreshKeySegments()
        #expect(!h.bar.list.shown.contains { $0.kind == .key }, "스트리밍 곡")
        let row = Self.row("locked", key: "8B", staged: true)
        try await h.load(row)
        #expect(!h.bar.isLocked)
        h.deck.isWriteLocked = true
        #expect(h.bar.isLocked && h.bar.list.shown.contains { $0.kind == .key }, "쓰는 동안 줄은 그대로 두고 단추만 막는다")
        h.bar.apply(.key)
        #expect(h.store.tagDrafts.isEmpty)
        h.deck.isWriteLocked = false
        h.store.isWritingRekordbox = true
        #expect(h.bar.isLocked)
    }

    @Test func 동기화로_rekordbox_키가_생긴_곡은_덱의_옛_행으로_제안하지_않는다() async throws {
        let h = Harness()
        let stale = Self.row("synced")
        try await h.load(stale)
        h.deck.keyChroma = try Self.aMinorChroma()
        h.deck.refreshKeySegments()
        #expect(h.bar.list.shown.contains { $0.kind == .key })
        h.store.rowsByUUID[stale.track.uuid] = Self.row("synced", key: "5A")
        #expect(!h.bar.list.shown.contains { $0.kind == .key }, "목록의 새 행(키 5A)을 기준으로 본다")
    }

    // MARK: 게인·그리드

    @Test func 게인_제안_적용은_게인_초안이고_실행_취소된다() async throws {
        let h = Harness()
        try await h.load(Self.row("gain", key: "5A", autoGain: RekordboxAutoGain(gain: 1, peak: 0.9)))
        h.deck.loudness = Loudness(integrated: -6, peak: -3, clippedRuns: 0)
        let gain = try #require(h.bar.list.shown.first { $0.kind == .gain })
        #expect(gain.value == "-4.0 dB (rekordbox +0.0)")
        h.bar.apply(.gain)
        #expect(h.deck.gainDraft == -4)
        #expect(!h.bar.list.shown.contains { $0.kind == .gain })
        h.undo.undo()
        #expect(h.deck.gainDraft == nil && h.bar.list.shown.contains { $0.kind == .gain })
    }

    @Test func 그리드_제안_적용은_그리드_초안이고_실행_취소된다() async throws {
        let h = Harness()
        try await h.load(Self.row("grid", key: "5A"))
        #expect(h.bar.gridStatus == .estimating, "그리드가 없고 추정 전")
        h.deck.gridSuggestion = try Self.gridEstimate()
        h.deck.refreshSuggestionNote()
        let grid = try #require(h.bar.list.shown.first { $0.kind == .grid })
        #expect(grid.value.hasSuffix("rekordbox 그리드 없음") && h.bar.gridStatus == nil)
        h.bar.apply(.grid)
        #expect(h.deck.gridDraft != nil)
        #expect(!h.bar.list.shown.contains { $0.kind == .grid } && h.bar.gridStatus == .matches, "적용하면 추정과 같다")
        h.undo.undo()
        #expect(h.deck.gridDraft == nil && h.bar.list.shown.contains { $0.kind == .grid })
    }

    @Test func 분석에_실패한_그리드_없는_곡은_실패를_알린다() async throws {
        let h = Harness()
        try await h.load(Self.row("failed", key: "5A"))
        h.deck.analysisError = "실패"
        #expect(h.bar.gridStatus == .failed && h.bar.list.isEmpty)
    }

    // MARK: 무시·다시 보기

    @Test func 세_제안을_무시하면_줄에서_빠지고_다시_보기_하나로_모두_되살린다() async throws {
        let h = Harness()
        let row = Self.row("all", autoGain: RekordboxAutoGain(gain: 1, peak: 0.9))
        try await h.load(row)
        h.deck.loudness = Loudness(integrated: -6, peak: -3, clippedRuns: 0)
        h.deck.gridSuggestion = try Self.gridEstimate()
        h.deck.refreshSuggestionNote()
        h.deck.keyChroma = try Self.aMinorChroma()
        h.deck.refreshKeySegments()
        #expect(h.bar.list.shown.map(\.kind) == [.gain, .grid, .key])
        #expect(!h.bar.list.canRestore)
        h.bar.dismiss(.gain)
        h.bar.dismiss(.grid)
        h.bar.dismiss(.key)
        #expect(h.bar.list.shown.isEmpty && h.bar.list.dismissed == [.gain, .grid, .key] && h.bar.list.canRestore)
        #expect(h.store.tagDrafts.isEmpty && h.deck.gainDraft == nil && h.deck.gridDraft == nil, "무시는 초안을 만들지 않는다")
        // 저장 이름과 뜻은 그대로다(곡 UUID 모음)
        #expect(h.deckSettings.strings(SettingKeys.dismissedGainSuggestions) == [row.track.uuid])
        #expect(h.deckSettings.strings(SettingKeys.dismissedGridSuggestions) == [row.track.uuid])
        #expect(h.storeSettings.strings(SettingKeys.dismissedKeySuggestions) == [row.track.uuid])
        h.bar.restoreDismissed()
        #expect(h.bar.list.shown.map(\.kind) == [.gain, .grid, .key] && !h.bar.list.canRestore)
        #expect(h.deckSettings.strings(SettingKeys.dismissedGainSuggestions).isEmpty)
        #expect(h.deckSettings.strings(SettingKeys.dismissedGridSuggestions).isEmpty)
        #expect(h.storeSettings.strings(SettingKeys.dismissedKeySuggestions).isEmpty)
    }

    @Test func 다른_곡의_무시는_건드리지_않는다() async throws {
        let h = Harness()
        let other = Self.row("other")
        h.deckSettings.setStrings(SettingKeys.dismissedGridSuggestions, [other.track.uuid])
        h.storeSettings.setStrings(SettingKeys.dismissedKeySuggestions, [other.track.uuid])
        let reopened = LibraryStore.test(settings: h.storeSettings, saveTagDrafts: { _ in })
        let row = Self.row("mine", key: "8B", staged: true)
        try await h.load(row)
        let bar = DeckSuggestions(deck: h.deck, store: reopened)
        bar.dismiss(.key)
        bar.restoreDismissed()
        #expect(h.storeSettings.strings(SettingKeys.dismissedKeySuggestions) == [other.track.uuid])
        #expect(h.deckSettings.strings(SettingKeys.dismissedGridSuggestions) == [other.track.uuid])
    }
}

/// 덱 제안 줄의 배치: 넓으면 한 줄, 좁거나 글자 배율이 크면 제안이 한 줄씩 내려가고 문구가 줄을 바꿔 칸 밖으로 넘치지 않는다.
@MainActor
@Suite("덱 제안 줄 배치")
struct DeckSuggestionBarLayoutTests {
    struct Words {
        var gain: (String, String)
        var grid: (String, String)
        var key: (String, String)
        var titles: DeckSuggestionBarContent.Titles
    }

    static let korean = Words(
        gain: ("게인", "+1.7 dB (rekordbox -4.0)"), grid: ("그리드", "133.97 BPM · 위상 -1ms · 변속 128→130 · rekordbox 그리드 없음"),
        key: ("키", "12B (음원 태그)"), titles: .init())
    static let english = Words(
        gain: ("Gain", "+1.7 dB (rekordbox -4.0)"), grid: ("Grid", "133.97 BPM · phase -1 ms · tempo changes 128→130 · no rekordbox grid"),
        key: ("Key", "12B (audio tag)"),
        titles: .init(apply: "Apply", dismiss: "Ignore", check: "Check Needed", restore: "Show Ignored Suggestions", reanalyze: "Reanalyze"))
    static let japanese = Words(
        gain: ("ゲイン", "+1.7 dB（rekordbox -4.0）"), grid: ("グリッド", "133.97 BPM · 位相 -1ms · テンポ変化 128→130 · rekordboxのグリッドなし"),
        key: ("キー", "12B（音源タグ）"),
        titles: .init(apply: "適用", dismiss: "無視", check: "要確認", restore: "無視した候補を再表示", reanalyze: "再解析"))

    static func list(_ words: Words, dismissed: Set<DeckSuggestion.Kind> = []) -> DeckSuggestionList {
        func item(_ kind: DeckSuggestion.Kind, _ pair: (String, String), check: Bool = false) -> DeckSuggestion {
            DeckSuggestion(kind: kind, title: pair.0, value: pair.1, needsCheck: check, applyHelp: "", dismissHelp: "", detail: nil)
        }
        return DeckSuggestionList([item(.gain, words.gain), item(.grid, words.grid, check: true), item(.key, words.key)], dismissed: dismissed)
    }

    private struct Host: View {
        var list: DeckSuggestionList
        var status: DeckSuggestions.GridStatus? = nil
        var titles = DeckSuggestionBarContent.Titles()
        var scale = 1.0
        var body: some View {
            DeckSuggestionBarContent(list: list, gridStatus: status, isLocked: false, titles: titles)
                .environment(\.textScale, scale)
        }
    }

    private func size(_ host: Host, width: Double) -> CGSize {
        NSHostingController(rootView: host).sizeThatFits(in: CGSize(width: width, height: 2000))
    }

    /// 덱 가운데 열 폭(DeckView 배치): 본문 폭에서 덱 여백·큐 목록·양옆 레일을 뺀 값
    static func column(detailWidth: Double, scale: Double) -> Double {
        let cueList = TextScale.length(DeckWidthClass(width: detailWidth).cueListWidth, scale: 1 + (scale - 1) / 2)
        return detailWidth - 2 * Spacing.edge - (cueList + 16)
            - (TextScale.length(66, scale: scale) + 8) - (TextScale.length(58, scale: scale) + 8)
    }

    /// 최소 창(1100pt, DJCrateApp)에서 인스펙터를 기본 폭(340pt, ContentView)으로 열면 사이드바가 접혀 본문이 760pt다.
    static let minimumWindowDetail = 1100.0 - 340
    /// 덱 본문 최소 폭(620pt)의 가운데 열(1배 186pt). 이 폭은 덱의 템포 줄(슬라이더 120pt 포함)보다도 좁고, 배율을 키우면
    /// 슬라이더조차 들어가지 않는다(1.5배 61pt). 제안 줄은 1배에서는 여기에도 들어가게 하고, 큰 배율은 최소 창 폭으로 본다.
    static let narrowestColumn = column(detailWidth: DeckLayout.minimumDetailWidth, scale: 1)

    static func widths(scale: Double) -> [Double] {
        scale == 1 ? [column(detailWidth: minimumWindowDetail, scale: scale), narrowestColumn]
            : [column(detailWidth: minimumWindowDetail, scale: scale)]
    }

    @Test func 넓으면_세_제안과_다시_보기와_재분석이_한_줄이다() {
        let single = size(Host(list: Self.list(Self.korean)), width: 1400)
        #expect(single.height < 34, "한 줄 높이: \(single.height)")
        let restore = size(Host(list: Self.list(Self.korean, dismissed: [.gain])), width: 1400)
        #expect(restore.height < 34)
    }

    @Test(arguments: TextScale.steps)
    func 최소_창의_덱에서도_세_언어_모두_칸_밖으로_넘치지_않는다(scale: Double) {
        for width in Self.widths(scale: scale) {
            for words in [Self.korean, Self.english, Self.japanese] {
                for dismissed: Set<DeckSuggestion.Kind> in [[], [.key]] {
                    let fitted = size(Host(list: Self.list(words, dismissed: dismissed), titles: words.titles, scale: scale), width: width)
                    #expect(fitted.width <= width + 0.5, "배율 \(scale) \(words.gain.0): 폭 \(fitted.width) > \(width)")
                }
            }
            for status in [DeckSuggestions.GridStatus.estimating, .failed, .matches] {
                let fitted = size(Host(list: DeckSuggestionList([], dismissed: []), status: status, scale: scale), width: width)
                #expect(fitted.width <= width + 0.5, "배율 \(scale) \(status): 폭 \(fitted.width) > \(width)")
            }
        }
    }

    /// 한 줄에 다 들어가지 않을 뿐인 폭(1440pt 창의 덱 가운데 열)에서는 칩을 통째로 다음 줄로 넘긴다.
    /// 칩마다 단추를 아래로 내리면(한 칩이 두 줄) 덱이 쓸데없이 길어진다.
    @Test func 조금_모자라면_칩을_통째로_다음_줄로_넘긴다() {
        let width = Self.column(detailWidth: 1192, scale: 1)
        let line = size(Host(list: Self.list(Self.korean)), width: 2400).height
        let flowing = size(Host(list: Self.list(Self.korean, dismissed: [.key])), width: width)
        #expect(flowing.width <= width + 0.5)
        #expect(flowing.height > line && flowing.height < line * 2.6, "두 줄 남짓이어야 한다: 한 줄 \(line), 지금 \(flowing.height)")
    }

    @Test func 좁으면_제안이_한_줄씩_내려가_높이가_늘어난다() {
        let width = Self.column(detailWidth: Self.minimumWindowDetail, scale: 1.5)
        let wide = size(Host(list: Self.list(Self.korean), scale: 1.5), width: 2400)
        let narrow = size(Host(list: Self.list(Self.korean), scale: 1.5), width: width)
        #expect(narrow.height > wide.height * 2, "넓음 \(wide.height), 좁음 \(narrow.height)")
    }
}

/// 태그 인스펙터의 키 칸은 고르기만 남는다: 키 제안은 덱 제안 줄로 옮겼다.
@MainActor
@Suite("태그 인스펙터 키 칸")
struct MusicalKeyFieldSuggestionTests {
    private func size(_ field: MusicalKeyField) -> CGSize {
        NSHostingController(rootView: field).sizeThatFits(in: CGSize(width: 300, height: 1000))
    }

    @Test func 추가한_곡의_음원_태그_키도_인스펙터에는_제안으로_나오지_않는다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        // 예전에는 추가한 곡의 키(음원 태그)가 곧바로 "DJCrate 제안" 줄로 나왔다.
        let staged = DeckSuggestionBarTests.row("inspector-staged", key: "8B", staged: true)
        let keyed = DeckSuggestionBarTests.row("inspector-keyed", key: "5A")
        #expect(size(MusicalKeyField(store: store, rows: [staged])).height == size(MusicalKeyField(store: store, rows: [keyed])).height,
                "제안 줄이 없으면 두 곡의 키 칸 높이가 같다")
        #expect(store.tagDrafts.isEmpty)
    }
}
