import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 덱 곡 불러오기 유스케이스. 파일·DB 없이 가짜 읽기로 시험한다.
@Suite("덱 곡 불러오기")
@MainActor
struct LoadDeckTrackTests {
    /// 가짜 읽기: 부른 읽기와 그때 메인 스레드였는지 남긴다.
    final class Probe: Sendable {
        let calls = Mutex<[String]>([])
        let onMain = Mutex<[String]>([])
        func record(_ name: String) {
            calls.withLock { $0.append(name) }
            if Thread.isMainThread { onMain.withLock { $0.append(name) } }
        }
        var names: [String] { calls.withLock { $0 } }
        var mainNames: [String] { onMain.withLock { $0 } }
    }

    static func loader(_ probe: Probe, exists: Bool = true, offset: Double = 0.026, gain: Double? = -2.5,
                       cueDraft: CueDraft? = nil, gridDraft: GridDraft? = nil,
                       grid: AnalysisGridRead = .missing, state: RekordboxAnalysisState = .ready) -> LoadDeckTrack {
        let assets = TrackAssetReader(
            audioFileExists: { _ in probe.record("exists"); return exists },
            timelineOffset: { _ in probe.record("offset"); return offset },
            gainDraft: { _ in probe.record("gain"); return gain },
            cueDraft: { _ in probe.record("cueDraft"); return cueDraft },
            newCueID: { UUID() },
            gridDraft: { _ in probe.record("gridDraft"); return gridDraft },
            rekordboxGrid: { path, root in probe.record("grid \(path ?? "-") \(root?.path ?? "-")"); return grid },
            analysisState: { path, root in probe.record("state \(path ?? "-") \(root?.path ?? "-")"); return state },
            colorWaveform: { path, _, mode in probe.record("color \(path ?? "-") \(mode)"); return nil },
            artwork: { path, root, pixels in probe.record("artwork \(path ?? "-") \(root?.path ?? "-") \(pixels)"); return nil },
            embeddedArtwork: { url in probe.record("embedded \(url.lastPathComponent)"); return nil })
        var cache = MemoryAnalysisStore().store
        cache.chroma = { _, _ in probe.record("chroma"); return nil }
        cache.loudness = { _ in probe.record("loudness"); return nil }
        return LoadDeckTrack(assets: assets, cache: cache)
    }

    static func request(audio: URL? = URL(filePath: "/music/a.wav"), cues: [Cue] = []) -> DeckTrackRequest {
        DeckTrackRequest(uuid: "track-1", audioFile: audio, analysisPath: "/PIONEER/USBANLZ/a/ANLZ0000.DAT",
                         imagePath: "/PIONEER/Artwork/a.jpg", shareRoot: URL(filePath: "/copy/share"), rekordboxCues: cues)
    }

    @Test func 음원을_열기_전에_필요한_값을_메인_스레드_밖에서_읽는다() async {
        let probe = Probe()
        let prepared = await Self.loader(probe).prepareAudio(Self.request())
        #expect(prepared.fileExists && prepared.timelineOffset == 0.026 && prepared.gainDraft == -2.5)
        #expect(Set(probe.names) == ["exists", "offset", "chroma", "loudness", "gain"])
        #expect(probe.mainNames.isEmpty, "메인 스레드에서 읽음: \(probe.mainNames)")
    }

    @Test func 파일이_없거나_스트리밍_곡이면_음원_값을_읽지_않는다() async {
        let probe = Probe()
        let missing = await Self.loader(probe, exists: false).prepareAudio(Self.request())
        #expect(!missing.fileExists && missing.timelineOffset == 0 && missing.gainDraft == nil && missing.loudness == nil)
        #expect(probe.names == ["exists"])

        let streaming = Probe()
        let stream = await Self.loader(streaming).prepareAudio(Self.request(audio: nil))
        #expect(!stream.fileExists && streaming.names.isEmpty)
    }

    @Test func 초안_그리드_그림을_한_결과로_모은다() async {
        let probe = Probe()
        let original = BeatGrid(beats: (0..<8).map { .init(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) / 2) })
        let content = await Self.loader(probe, grid: .grid(original)).content(Self.request(), duration: 5)
        #expect(content.draft == CueDraft(trackUUID: "track-1"))
        #expect(content.grid == DeckGridGate(trackUUID: "track-1", read: .grid(original), savedDraft: nil, duration: 5))
        #expect(content.artwork == nil && content.analysisState == .ready)
        // 분석 파일·그림은 요청의 share 뿌리에서 찾는다(쓰기 대상 라이브러리와 같은 곳).
        #expect(probe.names.contains("grid /PIONEER/USBANLZ/a/ANLZ0000.DAT /copy/share"))
        #expect(probe.names.contains("artwork /PIONEER/Artwork/a.jpg /copy/share 360"))
        #expect(probe.names.contains("state /PIONEER/USBANLZ/a/ANLZ0000.DAT /copy/share"))
        #expect(probe.mainNames.isEmpty, "메인 스레드에서 읽음: \(probe.mainNames)")
    }

    @Test func 쓴_뒤_다시_읽기는_게인_초안도_함께_읽는다() async {
        let probe = Probe()
        let (content, gain) = await Self.loader(probe, gain: 1.5).reloadContent(Self.request(), duration: 5)
        #expect(gain == 1.5 && content.draft.trackUUID == "track-1")
        // 소리는 그대로 두므로 음원 값은 읽지 않는다.
        #expect(!probe.names.contains("exists") && !probe.names.contains("offset"))
        #expect(probe.mainNames.isEmpty, "메인 스레드에서 읽음: \(probe.mainNames)")
    }

    @Test func 저장한_큐_초안에는_곡의_자동_큐를_채운다() async {
        let auto = Cue(id: "auto", contentID: "1", kind: 0, inMsec: 1000, name: "CUE(Auto)", colorTableIndex: nil)
        var saved = CueDraft(trackUUID: "track-1")
        saved.cues = [EditableCue(kind: .memory, time: 3)]
        let content = await Self.loader(Probe(), cueDraft: saved)
            .content(Self.request(cues: [auto]), duration: 5)
        // 채운 자동 큐는 base에도 들어가 변경으로 치지 않는다(새 큐 ID는 부를 때마다 다르다).
        #expect(content.draft.base.map(\.sourceID) == ["auto"] && content.draft.changes.count == 1)
        #expect(content.draft.cues.map(\.time) == [1, 3])
    }

    @Test func 원본이_없으면_저장한_추정_그리드_초안으로_판정한다() async {
        let estimated = GridDraft(trackUUID: "track-1", base: [], segments: [.init(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        let content = await Self.loader(Probe(), gridDraft: estimated, grid: .unreadable)
            .content(Self.request(), duration: 5)
        #expect(content.grid == DeckGridGate(trackUUID: "track-1", read: .unreadable, savedDraft: estimated, duration: 5))
        #expect(content.grid.gridDraft == estimated && content.grid.blockedReason == nil)
    }

    @Test func 분석_파일_상태는_읽기가_정한_값을_그대로_넘긴다() async {
        let content = await Self.loader(Probe(), state: .notAnalyzed(attachesAnalysis: true)).content(Self.request(), duration: 5)
        #expect(content.analysisState == .notAnalyzed(attachesAnalysis: true))
        #expect(content.analysisState.note?.title == "rekordbox 분석 전")
        #expect(RekordboxAnalysisState.ready.note == nil && RekordboxAnalysisState.waveformMissing.note != nil)
    }

    @Test func 내장_그림과_색_파형은_메인_밖에서_읽는다() async {
        let probe = Probe()
        let loader = Self.loader(probe)
        _ = await loader.embeddedArtwork(URL(filePath: "/music/a.wav"))
        _ = await loader.colorWaveform(Self.request(), mode: .rgb)
        #expect(probe.names == ["embedded a.wav", "color /PIONEER/USBANLZ/a/ANLZ0000.DAT rgb"])
        #expect(probe.mainNames.isEmpty, "메인 스레드에서 읽음: \(probe.mainNames)")
    }
}
