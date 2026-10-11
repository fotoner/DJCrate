@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import RekordboxKit
import Testing

/// 곡 목록 다듬기(#121): 스트리밍 곡 표시, 메모리 칸 빈칸, 미리 보기 큐 눈금 크기
@Suite("곡 목록 다듬기")
@MainActor
struct TrackListPolishTests {
    static func cue(_ kind: Int, _ msec: Int, name: String = "") -> Cue {
        Cue(id: "\(kind)-\(msec)", contentID: "1", kind: kind, inMsec: msec, name: name, colorTableIndex: nil)
    }

    static func row(_ id: String, cues: [Cue], streaming: Bool = false) -> TrackRow {
        let base = TrackListTagEditTests.row(id, streaming: streaming)
        return TrackRow(track: base.track, cues: cues, playCount: 0)
    }

    static func counts(_ cues: [EditableCue]) -> CueCounts {
        var draft = CueDraft(trackUUID: "draft")
        draft.cues = cues
        return CueCounts(draft)
    }

    // MARK: - 메모리 칸

    /// #145: 자동 큐도 덱과 같이 메모리 큐로 센다. 메모리 큐가 아직 고치지 않은 자동 큐뿐이면 수를 흐린 글자로 보인다.
    @Test func 메모리_칸은_자동_큐도_메모리_큐로_센다() {
        let auto = Self.cue(0, 350, name: "1.1Bars")
        #expect(Self.row("1", cues: []).memoryCueLabel(draft: nil) == .empty)
        #expect(Self.row("2", cues: [Self.cue(1, 1000)]).memoryCueLabel(draft: nil) == .empty)
        #expect(Self.row("3", cues: [auto]).memoryCueLabel(draft: nil) == .autoOnly(1))
        #expect(Self.row("4", cues: [auto, Self.cue(0, 2000), Self.cue(0, 3000)]).memoryCueLabel(draft: nil) == .count(3))
        #expect(Self.row("5", cues: [auto, Self.cue(1, 1000)]).memoryCueLabel(draft: nil) == .autoOnly(1))
        #expect(Self.row("6", cues: [auto, Self.cue(0, 2000)]).memoryCueCount == 2, "정렬도 같은 수로")
    }

    @Test func 초안이_있으면_초안의_큐_수를_같은_규칙으로_보인다() throws {
        let autoCue = Self.cue(0, 350, name: "CUE(Auto)")
        let auto = Self.row("1", cues: [autoCue])
        let plain = Self.row("2", cues: [Self.cue(0, 1000)])
        let editable = try #require(EditableCue(autoCue))
        var edited = editable
        edited.name = ""   // 고친 자동 큐는 일반 큐
        #expect(auto.memoryCueLabel(draft: Self.counts([editable])) == .autoOnly(1))
        #expect(auto.memoryCueLabel(draft: Self.counts([edited])) == .count(1))
        #expect(auto.memoryCueLabel(draft: Self.counts([editable, EditableCue(kind: .memory, time: 5)])) == .count(2))
        // 초안에서 자동 큐까지 지우면 비운다.
        #expect(auto.memoryCueLabel(draft: Self.counts([])) == .empty)
        #expect(plain.memoryCueLabel(draft: Self.counts([])) == .empty)
        #expect(plain.memoryCueLabel(draft: Self.counts([EditableCue(kind: .hot(0), time: 1)])) == .empty)
        #expect(plain.memoryCueLabel(draft: Self.counts([EditableCue(kind: .memory, time: 1), EditableCue(kind: .memory, time: 2)])) == .count(2))
    }

    @Test func 메모리_칸_글자() {
        #expect(TrackRow.MemoryCueLabel.empty.text.isEmpty)
        #expect(TrackRow.MemoryCueLabel.count(3).text == "3")
        #expect(TrackRow.MemoryCueLabel.autoOnly(2).text == "2")
        let help = TrackColumn.all.first { $0.id == "memoryCues" }?.help ?? ""
        #expect(!help.contains(String(ui: "없음")))
        #expect(help.contains(String(ui: "자동")))
    }

    @Test func 목록의_메모리_칸에_없음이_보이지_않는다() throws {
        let (coordinator, table) = Self.table(columns: ["memoryCues"],
                                              rows: [Self.row("1", cues: []), Self.row("2", cues: [Self.cue(0, 350, name: "1.1Bars")]),
                                                     Self.row("3", cues: [Self.cue(0, 350, name: "1.1Bars"), Self.cue(0, 900)])])
        let column = try #require(table.tableColumns.first)
        let empty = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? TrackTextCell)
        #expect(empty.text.isEmpty)
        let auto = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? TrackTextCell)
        #expect(auto.text == "1" && auto.label.textColor == .tertiaryLabelColor)
        let mixed = try #require(coordinator.tableView(table, viewFor: column, row: 2) as? TrackTextCell)
        #expect(mixed.text == "2" && mixed.label.textColor == UIColors.memory.nsColor)
    }

    // MARK: - 스트리밍 곡

    @Test func 스트리밍_곡은_제목_앞_아이콘과_흐린_글자로_구분한다() throws {
        let (coordinator, table) = Self.table(columns: ["title"],
                                              rows: [Self.row("1", cues: []), Self.row("2", cues: [], streaming: true)])
        let column = try #require(table.tableColumns.first)
        let local = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? TrackTextCell)
        #expect(local.leadingSymbol == nil)
        #expect(local.label.textColor == .labelColor)
        let streaming = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? TrackTextCell)
        #expect(streaming.leadingSymbol == LibraryFilter.streaming.systemImage)
        #expect(streaming.label.textColor == .secondaryLabelColor)
        #expect(streaming.text == "곡 2")
    }

    @Test func 다른_칸에_다시_쓰인_글자_칸은_아이콘을_지운다() {
        let cell = TrackTextCell()
        cell.set("스트리밍 곡", color: .secondaryLabelColor, symbol: LibraryFilter.streaming.systemImage)
        #expect(cell.leadingSymbol == LibraryFilter.streaming.systemImage)
        cell.set("120", color: .secondaryLabelColor, digits: true)
        #expect(cell.leadingSymbol == nil)
    }

    @Test func 스트리밍_아이콘은_제목_바로_앞에_붙는다() {
        func laidOut(_ configure: (TrackTextCell) -> Void) -> TrackTextCell {
            let cell = TrackTextCell()
            cell.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
            configure(cell)
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        let plain = laidOut { $0.set("로컬 곡", color: .labelColor) }.label.frame.minX
        let cell = laidOut { $0.set("스트리밍 곡", color: .secondaryLabelColor, symbol: LibraryFilter.streaming.systemImage) }
        // 아이콘(약 11pt)과 간격 3pt 뒤에서 제목이 시작한다(아이콘 칸이 늘어나 제목을 밀지 않는다).
        #expect(cell.label.frame.minX > plain + 8 && cell.label.frame.minX < plain + 24)
        cell.set("로컬 곡", color: .labelColor)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.label.frame.minX == plain)
    }

    // MARK: - 미리 보기 큐 눈금

    /// 기본 칸 160×24pt에서 여백(3·2pt)을 뺀 파형 자리
    static let cellSize = CGSize(width: 154, height: 20)

    @Test func 기본_칸에서도_눈금은_최소_크기를_지킨다() {
        let marks = [PreviewCueMark(EditableCue(kind: .hot(0), time: 25)),
                     PreviewCueMark(EditableCue(kind: .memory, time: 75, loop: .init(end: 75.1))),
                     PreviewCueMark(EditableCue(kind: .hot(1), time: 100))]
        let shapes = PreviewCueMark.shapes(marks, duration: 100, width: Self.cellSize.width, height: Self.cellSize.height)
        #expect(shapes.count == 4)
        let ticks = shapes.filter { $0.color != .loop }
        #expect(ticks.allSatisfy { $0.rect.width >= 2 && $0.rect.height >= 6 })
        let loop = shapes.first { $0.color == .loop }
        #expect(loop != nil)
        #expect((loop?.rect.width ?? 0) >= 3 && (loop?.rect.height ?? 0) >= 2)
        #expect(shapes.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 154 && $0.rect.minY >= 0 && $0.rect.maxY <= 20 })
        // 핫큐는 위, 메모리 큐는 아래
        #expect(ticks[0].rect.minY <= 2 && ticks[1].rect.maxY >= 18)
        // 글자 배율을 줄여 줄이 낮아져도 눈금을 그린다.
        #expect(!PreviewCueMark.shapes(marks, duration: 100, width: 154, height: 14).isEmpty)
    }

    @Test func 눈금은_칸의_실제_픽셀_크기로_그린다() throws {
        let preview = AnlzPreviewWaveform(blue: [WaveformColumn(low: 1, mid: 1, high: 1)],
                                          color: [WaveformColumn(low: 1, mid: 1, high: 1)])
        let marks = [PreviewCueMark(EditableCue(kind: .hot(0), time: 25)),
                     PreviewCueMark(EditableCue(kind: .memory, time: 75))]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let image = try #require(PreviewWaveformRenderer.image(preview, mode: .threeBand, appearance: appearance.rawValue,
                                                                  cues: marks, duration: 100, size: Self.cellSize, scale: 2))
            #expect(image.width == 308 && image.height == 40)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let hot = UIColors.hot.variants.resolved(for: appearance).usingColorSpace(.sRGB)!
            // 핫큐(25% = 38.5pt)는 위쪽에 2pt(4px) 이상 폭으로 보인다.
            let hotColumns = (0..<308).filter { x in
                guard let color = bitmap.colorAt(x: x, y: 6) else { return false }
                return abs(color.greenComponent - hot.greenComponent) < 0.02 && abs(color.redComponent - hot.redComponent) < 0.02
            }
            #expect(hotColumns.count >= 4)
            #expect(hotColumns.allSatisfy { (74...82).contains($0) })
            let memory = UIColors.memory.variants.resolved(for: appearance).usingColorSpace(.sRGB)!
            let memoryPixel = try #require(bitmap.colorAt(x: 232, y: 34))
            #expect(abs(memoryPixel.redComponent - memory.redComponent) < 0.02)
        }
    }

    @Test func 눈금이_있으면_칸_크기마다_따로_캐시한다() {
        var plain = PreviewWaveformRequest(url: nil, revision: "one", appearance: NSAppearance.Name.aqua.rawValue)
        var resized = plain
        resized.size = CGSize(width: 300, height: 20)
        // 눈금이 없으면 파형 비트맵 하나를 늘려 쓴다.
        #expect(plain.cacheKey == resized.cacheKey)
        plain.cues = [PreviewCueMark(EditableCue(kind: .hot(0), time: 2))]
        resized.cues = plain.cues
        #expect(plain.cacheKey != resized.cacheKey)
    }

    @Test func 칸이_배치된_뒤_그_크기로_그린다() {
        let cell = PreviewWaveformCell(cache: PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: .none)))
        cell.configure(url: nil, revision: "one", cues: [PreviewCueMark(EditableCue(kind: .hot(0), time: 2))], duration: 100)
        // 크기가 정해지기 전에는 그리지 않는다(잘못된 크기로 한 번 더 그리지 않게).
        #expect(cell.request == nil)
        cell.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        cell.layout()
        #expect(cell.request?.size == Self.cellSize)
    }

    // MARK: -

    static func table(columns: [String], rows: [TrackRow]) -> (TrackListCoordinator, NSTableView) {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        for id in columns { table.addTableColumn(NSTableColumn(identifier: .init(id))) }
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        return (coordinator, table)
    }
}
