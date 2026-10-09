@testable import DJCrate
import AppKit
import AVFoundation
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Synchronization
import Testing

/// 소리를 내지 않는 편집 창 재생기. 들린 시간(`elapsed`)은 시험이 정한다.
@MainActor
final class FakeEditAudio: EditAudio {
    var isReady = true
    var sampleRate = 44_100.0
    var isPlaying = false
    /// 재생 감시(40ms 틱)가 `elapsed`를 읽은 횟수. "틱이 한 번 돈 뒤"를 시간 대신 이 값으로 기다린다
    private(set) var elapsedReads = 0
    private var heard = 0.0
    var elapsed: Double {
        get { elapsedReads += 1; return heard }
        set { heard = newValue }
    }
    var plays: [(items: [EditPlaybackItem], frame: Int64)] = []
    var volume: Float?
    var closed = false

    func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void) { done(isReady) }

    func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool {
        // 실제 재생기처럼 원곡을 풀기 전에는 소리를 내지 못한다(계약 시험 `AudioEngineContractTests`).
        guard isReady else { return false }
        plays.append((items, frame))
        self.volume = volume
        isPlaying = true
        elapsed = 0
        return true
    }

    func stop() { isPlaying = false }
    func close() { closed = true }
}

/// 편집 창 모델을 덱 없이 만든다: 창을 열 때 덱에서 읽어 둘 값(`EditSource`)을 바로 준다.
/// 음원 파일은 실제로 렌더하는 시험만 만든다(`audioFile`). 렌더한 편집본·초안은 `home` 아래에 둔다.
@MainActor
final class EditHarness {
    let player = FakeEditAudio()
    let home: URL
    let source: URL
    let editSource: EditSource
    /// 창이 덱을 멈춘 횟수(창에서 재생할 때마다)와 덱 음량
    var deckPauses = 0
    var deckVolume = 0.9

    /// 120 BPM, 첫 다운비트 0.5초, 20.5초 = 0마디 + 10마디
    init(seconds: Double = 20.5, grid: [GridSegment] = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
         cues: [EditableCue] = [], audioFile: Bool = false) throws {
        home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        source = audioFile ? try AudioFixture.wav(seconds: seconds, in: home, name: "원곡.wav") : home.appending(path: "원곡.wav")
        let track = Track(id: "7", uuid: "edit-src", title: "시험 곡", artist: "아티스트", album: nil, albumArtist: nil, genre: "House",
                          composer: nil, releaseYear: 2025, trackNumber: nil, key: "8A", bpm: 120, lengthSeconds: Int(seconds),
                          folderPath: source.path, comment: "코멘트", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false)
        var draft = CueDraft(trackUUID: track.uuid)
        for cue in cues { draft.place(cue) }
        let state = EditSourceState(isStreaming: false, audioFileExists: true, playbackUnavailableReason: nil, segments: grid,
                                    gridUnavailableReason: nil, gridSourceNotice: nil, gridEditBlockedReason: nil)
        editSource = EditSource(row: TrackRow(track: track, cues: [], playCount: 0), cues: draft.cues, timelineOffset: 0,
                                duration: seconds, waveform: nil, currentTime: 0, state: state)
    }

    var deck: EditDeckControl {
        EditDeckControl(volume: { [unowned self] in deckVolume }, pause: { [unowned self] in deckPauses += 1 })
    }

    var writer: RenderEdit { .live(home: home) }

    func loaded() -> TrackEditModel {
        TrackEditModel(source: editSource, audio: player, deck: deck, writer: writer)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

/// 파일 없이 넣기만 남기는 가짜 편집본 쓰기의 기록(넣을 초안)
final class StagingProbe: Sendable {
    let drafts = Mutex<[StagedEditDrafts]>([])
    var grids: [[GridSegment]] { drafts.withLock { $0.map { $0.grid?.segments ?? [] } } }
}

extension RenderEdit {
    /// 실제 파일 접근. 편집본은 `home` 아래 edits, 추가한 곡·초안은 `home`에 둔다(추가 목록은 파일을 바로 읽고 쓴다).
    static func live(home: URL) -> RenderEdit {
        RenderEdit(files: .live(output: { home.appending(path: "edits") }), stager: .files(home: home))
    }

    /// 렌더·파일 없이 넣을 초안만 남긴다.
    static func fake(_ probe: StagingProbe) -> RenderEdit {
        let list = Mutex<[StagedTrack]>([])
        return RenderEdit(
            files: EditFiles(outputDirectory: { URL(filePath: "/편집본") }, fileExists: { _ in false }, createDirectory: { _ in },
                             removeFile: { _ in }, render: { _, _, _ in }),
            stager: StageEdit(
                staging: StagingStore(tracks: { list.withLock { $0 } }, save: { tracks in list.withLock { $0 = tracks } }),
                files: EditStagingFiles(
                    readTrack: { url, addedOn in
                        StagedTrack(uuid: UUID().uuidString.lowercased(), path: url.path, title: url.lastPathComponent, duration: 1,
                                    addedOn: addedOn)
                    },
                    writeDrafts: { drafts in
                        probe.drafts.withLock { $0.append(drafts) }
                        return {}
                    }),
                now: { Date(timeIntervalSince1970: 1_791_000_000) }))
    }
}

/// 조건이 맞을 때까지(최대 5초) 기다린다.
@MainActor
func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    if !condition() { throw FixtureError("5초 안에 끝나지 않음") }
}

func frames(_ url: URL) throws -> Int64 { try AVAudioFile(forReading: url).length }

@MainActor
@Suite("곡 편집 창 모델")
struct TrackEditModelTests {
    @Test func 고른_구간은_고른_클립_뒤에_넣고_Esc는_클립_구간_순서로_놓는다() async throws {
        // 끌어 고르기·곡 머리 규칙은 Domain `EditPointerTests`·`EditTimelineTests`. 여기서는 모델이 넣을 자리와 안내를 고르는 것만 본다.
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        #expect(model.blockedReason == nil && model.layout?.count == 10 && model.isAudioReady)
        #expect(model.title == "시험 곡 (Edit)")
        model.select(from: 0.2, to: 4.4)
        #expect(model.selection == BarRange(0, 2) && model.focus == .source)
        model.finishSelection()
        #expect(model.position(.source) == 0)
        model.addSelection()
        #expect(model.entries.map(\.range) == [BarRange(0, 2)] && model.selectedClip == model.entries[0].id)
        // 고른 클립 뒤에 넣는다(고른 클립이 가운데면 그 뒤에 끼운다)
        model.select(from: 12.5, to: 16.5)
        model.addSelection()
        model.selectedClip = model.entries[0].id
        model.select(from: 4.6, to: 8.6)
        model.addSelection()
        #expect(model.entries.map(\.range) == [BarRange(0, 2), BarRange(3, 4), BarRange(7, 8)] && model.selectedIndex == 1)
        // 넣을 수 없는 구간은 안내만 한다
        model.selectedClip = nil
        model.select(from: 0, to: 0.2)
        model.addSelection()
        #expect(model.entries.count == 3 && model.message?.kind == .warning)
        #expect(model.planError == nil && model.canRender)
        // Esc: 고른 클립 → 고른 구간 순서로 놓는다
        model.selectedClip = model.entries[1].id
        #expect(model.clearSelection() && model.selectedClip == nil && model.selection != nil)
        #expect(model.clearSelection() && model.selection == nil && !model.clearSelection())
    }

    @Test func 창_재생기로_원곡을_재생하고_멈추고_시킹한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        // 덱을 멈추고 창에서 재생한다(두 소리가 겹치지 않게). 음량은 덱을 따른다.
        h.deckVolume = 0.5
        model.seek(.source, to: 4.5)
        model.play(.source)
        #expect(model.playing == .source && h.deckPauses == 1 && h.player.volume == 0.5)
        // 원곡 그대로 한 칸(인코더 지연 없음), 재생선 프레임부터
        #expect(h.player.plays.last?.items == [EditPlaybackItem(outputFrame: 0, frameCount: 904_050, sourceFrame: 0)])
        #expect(h.player.plays.last?.frame == 198_450)
        h.player.elapsed = 1
        #expect(model.position(.source) == 5.5)
        model.pause()
        #expect(model.playing == nil && !h.player.isPlaying && model.position(.source) == 5.5)
        // 스페이스바는 마지막으로 누른 줄을 재생선부터
        model.togglePlay()
        #expect(model.playing == .source && h.player.plays.last?.frame == 242_550)
        // 재생 중 시킹은 그 자리에서 잇는다
        model.seek(.source, to: 10)
        #expect(model.playing == .source && h.player.plays.count == 3 && h.player.plays.last?.frame == 441_000)
        // 재생선을 끄는 동안은 멈췄다가 손을 떼면 그 자리에서 잇는다
        model.scrub(.source, to: 12)
        #expect(model.playing == nil && model.position(.source) == 12)
        model.endScrub()
        #expect(model.playing == .source && h.player.plays.last?.frame == 529_200)
        // ←→는 마디 줄로(1마디 2초, 첫 다운비트 0.5초)
        model.step(bars: 1)
        #expect(model.position(.source) == 12.5 && h.player.plays.last?.frame == 551_250)
        model.pause()
        model.step(bars: -4)
        #expect(model.position(.source) == 4.5)
        model.jump(toEnd: true)
        #expect(model.position(.source) == 20.5)
        // 끝에서 재생하면 처음부터
        model.play(.source)
        #expect(h.player.plays.last?.frame == 0)
        model.close()
        #expect(h.player.closed && model.playing == nil)
    }

    @Test func 결과를_어디서든_렌더하지_않고_재생한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        #expect(!model.canPlay(.output))
        model.entries = [BarRange(1, 2), BarRange(1, 2)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        let edit = try #require(model.edit)
        model.seek(.output, to: 3)
        model.play(.output)
        // 렌더러와 같은 예약표(조각·이음새 섞기)를 결과 3초 프레임부터
        #expect(h.player.plays.last?.items == TrackEdit.playbackItems(edit.frames(sampleRate: 44_100, sourceOffset: 0)))
        #expect(h.player.plays.last?.frame == 132_300 && model.focus == .output)
        // 끝까지 들으면 멈추고 재생선은 끝에
        h.player.elapsed = 6
        try await until { model.playing == nil }
        #expect(model.position(.output) == 8 && !h.player.isPlaying)
        // 결과를 고치면 재생을 멈춘다(바뀐 결과를 다시 재생)
        model.play(.output)
        #expect(h.player.plays.last?.frame == 0)
        model.entries.append(TrackEditModel.Entry(id: UUID(), range: BarRange(9, 10)))
        #expect(model.playing == nil && !h.player.isPlaying)
    }

    @Test func 이음새_앞뒤_2마디를_듣고_멈춘다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        model.entries = [BarRange(1, 4), BarRange(1, 4)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        model.auditionSeam(1)
        // 이음새 8초: 4초부터 12초까지
        #expect(model.playing == .output && model.auditioning == 1 && h.player.plays.last?.frame == 176_400)
        h.player.elapsed = 8.5
        try await until { model.playing == nil }
        #expect(model.position(.output) == 12 && model.auditioning == nil)
        // 조각이 2마디보다 짧으면 그 조각 안에서
        model.entries = [BarRange(1, 1), BarRange(5, 5)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        model.auditionSeam(1)
        #expect(h.player.plays.last?.frame == 0)
        h.player.elapsed = 5
        try await until { model.playing == nil }
        #expect(model.position(.output) == 4)
        // 덱을 재생하면 창의 재생은 멈춘다(뷰가 pause를 부른다)
        model.auditionSeam(9)
        #expect(model.playing == nil)
    }

    @Test func 자르고_복제하고_옮기고_지우고_실행_취소한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        let undo = UndoManager()
        model.undoManager = undo
        model.entries = [TrackEditModel.Entry(id: UUID(), range: BarRange(1, 8))]
        #expect(!model.canUndo)

        // 재생선 5.2초 → 가장 가까운 마디 줄(6초, 4마디)에서 자르고 오른쪽을 고른다
        model.seek(.output, to: 5.2)
        model.splitAtPlayhead()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 1)
        #expect(model.position(.output) == 6 && model.canUndo && undo.undoActionName == "자르기")
        // 클립 끝이 더 가까우면 자르지 않고 알린다
        model.seek(.output, to: 5.9)
        model.splitAtPlayhead()
        #expect(model.entries.count == 2 && model.message?.kind == .warning)

        model.duplicateSelected()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8), BarRange(4, 8)] && model.selectedIndex == 2)
        let copy = try #require(model.selectedClip)
        // 끌어서 맨 앞으로(놓을 자리 = 앞 클립 수)
        model.moveClip(copy, toOffset: 0)
        #expect(model.entries.map(\.range) == [BarRange(4, 8), BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 0)
        model.removeSelected()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 0)
        // 앞뒤 단추·마디 칸
        model.move(model.entries[0].id, by: 1)
        #expect(model.entries.map(\.range) == [BarRange(4, 8), BarRange(1, 3)])
        model.setLast(model.entries[0].id, 99)
        #expect(model.entries[0].range == BarRange(4, 10))

        // 실행 취소 6번(마디·앞뒤·지우기·옮기기·복제·자르기) → 처음, 실행 복귀 → 자른 모양
        for _ in 0..<6 { undo.undo() }
        #expect(model.entries.map(\.range) == [BarRange(1, 8)] && !model.canUndo && model.canRedo)
        undo.redo()
        #expect(model.entries.map(\.range) == [BarRange(1, 3), BarRange(4, 8)] && model.selectedIndex == 1)
        // 창을 닫으면 이 창의 실행 취소를 비운다
        model.close()
        #expect(!undo.canUndo && !undo.canRedo)
    }

    @Test func 규칙에_맞지_않는_목록도_타임라인에_그려_고칠_수_있다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        model.entries = [BarRange(1, 2), BarRange(0, 2)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        #expect(model.edit == nil && model.planError?.contains("0마디") == true && !model.canRender && !model.canPlay(.output))
        #expect(model.clipLayout.count == 2)
        model.moveClip(model.entries[1].id, toOffset: 0)
        #expect(model.planError == nil && model.edit != nil)
    }

    @Test func 줄마다_확대하고_가로로_스크롤한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        let length = model.duration
        // 보이는 재생선(10초)을 그 자리에 두고 4배. 결과 줄은 그대로
        model.seek(.source, to: 10)
        model.zoom(.source, by: 4)
        let zoomed = model.viewport(.source).visible(length: length)
        #expect(abs(model.viewport(.source).scale(length: length) - 4) < 1e-9 && zoomed.contains(10))
        #expect(abs(model.viewport(.source).x(of: 10, width: 400, length: length) - 10 / 20.5 * 400) < 1e-6)
        #expect(model.viewport(.output) == EditViewport())
        // 가장 가깝게는 2마디(4초)
        model.zoom(.source, by: 100)
        let closest = model.viewport(.source).visible(length: length)
        #expect(abs(closest.upperBound - closest.lowerBound - 4) < 1e-9)
        model.scroll(.source, by: 100)
        #expect(model.viewport(.source).visible(length: length) == 16.5...20.5)
        // 재생선을 보이지 않는 자리로 옮기면(←→·Home 등) 따라 넘긴다
        model.seek(.source, to: 2)
        #expect(model.viewport(.source).visible(length: length) == 0...4)
        model.focus = .source
        model.step(bars: 2)
        #expect(model.position(.source) == 4.5 && model.viewport(.source).visible(length: length).contains(4.5))
        // 키: = 확대, − 축소, 0 전체(⌘가 붙은 키는 보기 › 글자 크기 메뉴에 맡긴다)
        #expect(TrackEditCommand(keyCode: 24, modifiers: []) == .zoom(in: true) && TrackEditCommand(keyCode: 24, modifiers: .shift) == .zoom(in: true))
        #expect(TrackEditCommand(keyCode: 69, modifiers: []) == .zoom(in: true) && TrackEditCommand(keyCode: 27, modifiers: []) == .zoom(in: false))
        #expect(TrackEditCommand(keyCode: 78, modifiers: []) == .zoom(in: false) && TrackEditCommand(keyCode: 29, modifiers: []) == .fit)
        #expect(TrackEditCommand(keyCode: 24, modifiers: .command) == nil && TrackEditCommand(keyCode: 27, modifiers: .command) == nil)
        #expect(TrackEditCommand(keyCode: 29, modifiers: .command) == nil)
        #expect(TrackEditCommand.zoom(in: false).perform(on: model))
        #expect(abs(model.viewport(.source).scale(length: length) - 20.5 / 8) < 1e-9)
        #expect(TrackEditCommand.fit.perform(on: model) && model.viewport(.source) == EditViewport())
        // 결과가 없으면 결과 줄은 확대할 것이 없다
        model.focus = .output
        #expect(!TrackEditCommand.zoom(in: true).perform(on: model) && model.viewport(.output) == EditViewport())
    }

    @Test func 재생선이_보이는_자리를_넘으면_다음_쪽으로_넘긴다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        let length = model.duration
        model.seek(.source, to: 0)
        model.zoom(.source, by: 100)
        #expect(model.viewport(.source).visible(length: length) == 0...4)
        model.play(.source)
        h.player.elapsed = 4.5
        // 오른쪽 끝을 넘으면 재생선을 왼쪽 10% 자리에
        try await until { model.viewport(.source).visible(length: length).lowerBound > 4 }
        #expect(abs(model.viewport(.source).visible(length: length).lowerBound - 4.1) < 0.05)
        // 재생 중에 다른 곳을 보고 있으면 끌어오지 않는다
        model.scroll(.source, to: 12)
        h.player.elapsed = 5
        // 재생 감시가 새 위치(5초)를 읽고 그 틱을 마칠 때까지(틱마다 끝 확인과 재생선 위치로 두 번 읽는다)
        let reads = h.player.elapsedReads
        #expect(await waitForState { h.player.elapsedReads >= reads + 2 })
        #expect(model.viewport(.source).visible(length: length) == 12...16 && model.playing == .source)
        model.pause()
    }

    @Test func 편집_창_단축키는_키_위치로_정한다() async throws {
        #expect(TrackEditCommand(keyCode: 49, modifiers: []) == .togglePlay)
        #expect(TrackEditCommand(keyCode: 124, modifiers: [.numericPad, .function]) == .step(1))
        #expect(TrackEditCommand(keyCode: 123, modifiers: .shift) == .step(-4))
        #expect(TrackEditCommand(keyCode: 11, modifiers: .command) == .split && TrackEditCommand(keyCode: 11, modifiers: []) == nil)
        #expect(TrackEditCommand(keyCode: 2, modifiers: .command) == .duplicateClip)
        #expect(TrackEditCommand(keyCode: 51, modifiers: []) == .removeClip && TrackEditCommand(keyCode: 36, modifiers: []) == .addSelection)
        // ⌘Z는 편집 메뉴(창의 실행 취소)에 맡긴다
        #expect(TrackEditCommand(keyCode: 6, modifiers: .command) == nil)

        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        // 고른 것이 없으면 키를 넘긴다(다른 곳에서 경고음·기본 동작)
        #expect(!TrackEditCommand.removeClip.perform(on: model) && !TrackEditCommand.addSelection.perform(on: model))
        #expect(!TrackEditCommand.split.perform(on: model) && !TrackEditCommand.clearSelection.perform(on: model))
        #expect(TrackEditCommand.togglePlay.perform(on: model) && model.playing == .source)
    }

    @Test func 편집할_수_없는_곡은_이유를_보여_주고_고르기·재생·렌더를_막는다() async throws {
        let tempo = try EditHarness(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1),
                                           GridSegment(start: 10.5, bpm: 124, firstBeatNumber: 1)])
        defer { tempo.remove() }
        let changing = tempo.loaded()
        #expect(changing.blockedReason?.contains("템포 구간 2개") == true && changing.layout == nil)
        changing.select(from: 4.6, to: 8.6)
        changing.addSelection()
        #expect(changing.entries.isEmpty && !changing.canRender && !changing.canPlay(.source))
        // 막힌 곡은 원곡을 메모리에 풀지 않는다.
        #expect(!changing.isAudioReady)
    }

    @Test func 누르기·끌기_동작을_차례로_한다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        let undo = UndoManager()
        model.undoManager = undo
        model.entries = [BarRange(1, 2), BarRange(5, 6)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        let ids = model.entries.map(\.id)
        #expect(model.pointerContext.hasEdit && model.pointerContext.clips.count == 2 && model.pointerContext.entries == model.entries)
        model.apply([.select(from: 4.6, to: 8.6), .finishSelection])
        #expect(model.selection == BarRange(3, 4) && model.position(.source) == 4.5 && model.pointerContext.selectionContains(5))
        let insertion = EditInsertion(offset: 1, range: BarRange(3, 4))
        model.apply([.preview(insertion)])
        #expect(model.insertPreview == insertion)
        model.apply([.insert(insertion), .preview(nil)])
        #expect(model.entries.map(\.range) == [BarRange(1, 2), BarRange(3, 4), BarRange(5, 6)] && model.insertPreview == nil)
        #expect(undo.undoActionName == "구간 넣기")
        model.apply([.moveClip(ids[1], toOffset: 0), .trim(ids[0], to: BarRange(1, 3))])
        #expect(model.entries.map(\.range) == [BarRange(5, 6), BarRange(1, 3), BarRange(3, 4)] && model.selectedClip == ids[0])
        model.apply([.selectClip(nil), .seek(.output, to: 3), .focus(.source)])
        #expect(model.selectedClip == nil && model.position(.output) == 3 && model.focus == .source)
        // 눈금 끌기: 재생 중이면 멈췄다가 손을 떼면 그 자리에서 잇는다
        model.play(.source)
        model.apply([.scrub(.source, to: 12)])
        #expect(model.playing == nil && model.position(.source) == 12)
        model.apply([.endScrub])
        #expect(model.playing == .source && h.player.plays.last?.frame == 529_200)
        model.close()
    }

    @Test func 덱에서_편집할_원곡을_읽어_두고_덱_재생을_멈춘다() async throws {
        let h = try DeckHarness(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        try await h.loaded()
        h.deck.seek(4)
        let source = try #require(h.deck.editSource(audioFileExists: true))
        #expect(source.row.id == h.deck.row?.id && source.duration == h.deck.duration && source.currentTime == h.deck.currentTime)
        #expect(source.state.segments == h.deck.gridDraft?.segments && source.state.playbackUnavailableReason == nil)
        #expect(source.cues == h.deck.draft?.cues && source.url.path == h.deck.row?.track.folderPath)
        #expect(source.state.trackEditOpening(duration: source.duration).blockedReason == nil)
        // 파일이 없다고 보면 덱의 재생 불가 이유(파일을 다시 본다)는 읽지 않는다.
        #expect(h.deck.editSource(audioFileExists: false)?.state.trackEditOpening(duration: 180) == .blocked(EditSourceState.missingFileReason))
        h.deck.togglePlay()
        #expect(h.deck.isPlaying)
        h.deck.editControl.pause()
        #expect(!h.deck.isPlaying && h.deck.editControl.volume() == h.deck.volume)
        h.deck.editControl.pause()
        #expect(!h.deck.isPlaying, "멈춘 덱은 다시 켜지 않는다")
    }

    // 덱 → `EditSource`가 그리드 막힘 이유를 제자리로 옮기는지(규칙은 Domain `EditSourceStateTests`).

    @Test func 그리드_없는_덱은_덱이_알린_이유로_곡_편집_창을_열지_않는다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let reason = try #require(h.deck.gridUnavailableReason ?? h.deck.gridSourceNotice, "덱이 그리드가 없는 이유를 알린다")
        let source = try #require(h.deck.editSource(audioFileExists: true))
        #expect(source.state.segments.isEmpty)
        #expect(source.state.trackEditOpening(duration: source.duration) == .blocked(reason))
    }

    @Test func 그리드_편집이_막힌_덱은_Flip에_그리드를_옮기지_않고_알린다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.gridEditBlockedReason = "합성 재생성 오차"
        let source = try #require(h.deck.editSource(audioFileExists: true))
        #expect(source.state.gridEditBlockedReason == "합성 재생성 오차" && source.state.flipBlockedReason == nil)
        var recording = FlipRecording()
        recording.record(PlayedRun(spans: [PlayedSpan(start: 0, end: 8.5), PlayedSpan(start: 4.5, end: 12)], continuing: false))
        let moved = source.state.flipGrid(try FlipEdit(recording, sourceDuration: 20.5))
        #expect(moved.grid.isEmpty && moved.notice == EditSourceState.flipGridBlockedNotice)
    }

    @Test func 렌더해서_추가한_곡에_넣는다() async throws {
        let h = try EditHarness(cues: [EditableCue(kind: .memory, time: 0.5), EditableCue(kind: .hot(0), time: 2.5, name: "A"),
                                       EditableCue(kind: .hot(1), time: 12.5, name: "빠짐")], audioFile: true)
        defer { h.remove() }
        let model = h.loaded()
        model.entries = [BarRange(0, 4), BarRange(1, 4)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        #expect(model.carry?.placed.count == 2 && model.carry?.dropped.count == 1)
        model.title = "시험 곡 (Extended)"
        var reported: [StagedTrack] = []
        model.onStaged = { reported.append($0) }
        model.render()
        #expect(model.renderProgress != nil)
        try await until { model.staged != nil }
        #expect(model.renderProgress == nil && model.message?.kind == .success)

        // 결과 파일은 DJCrate 데이터 폴더의 edits 아래, 원본 길이 그대로(0.5 + 16초)
        let staged = try #require(model.staged)
        let output = h.home.appending(path: "edits/시험 곡 (Extended).wav")
        #expect(staged.path == output.path.precomposedStringWithCanonicalMapping && reported == [staged])
        #expect(try frames(output) == Int64((16.5 * 44_100).rounded()))
        #expect(StagedTrackFile.load(url: h.home.appending(path: "staged.json")).map(\.uuid) == [staged.uuid])
        // 변환한 그리드·옮긴 큐·원곡 태그 초안
        let grid = try #require(GridDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "grid-drafts")))
        #expect(grid.segments == [try #require(model.edit).outputGrid])
        let cues = try #require(CueDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "cue-drafts")))
        #expect(cues.cues.map(\.time) == [0.5, 2.5] && cues.cues.map(\.kind) == [.memory, .hot(0)])
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: h.home.appending(path: "tag-drafts")))
        #expect(tags.fields.title == "시험 곡 (Extended)" && tags.fields.artist == "아티스트" && tags.fields.genre == "House")
        // 원본은 그대로
        #expect(try frames(h.source) == Int64(20.5 * 44_100))

        // 같은 제목으로 또 렌더하면 파일 이름에 번호를 붙인다
        model.render()
        try await until { model.staged?.uuid != staged.uuid && model.renderProgress == nil }
        #expect(model.staged?.path.hasSuffix("edits/시험 곡 (Extended) 2.wav") == true)
    }

    @Test func 렌더를_취소하면_파일을_남기지_않는다() async throws {
        let h = try EditHarness()
        defer { h.remove() }
        let model = h.loaded()
        model.entries = [BarRange(1, 10), BarRange(1, 10)].map { TrackEditModel.Entry(id: UUID(), range: $0) }
        model.render()
        model.cancelRender()
        try await until { model.renderProgress == nil }
        #expect(model.staged == nil && model.message?.kind == .warning)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.home.appending(path: "edits").path)) ?? []
        #expect(left.isEmpty && !FileManager.default.fileExists(atPath: h.home.appending(path: "staged.json").path))
    }
}
