@testable import DJCrate
import AppKit
import DJCDomain
import Testing

/// 태그 시트 평점·곡 색 열 폭(#65): 곡 목록 평점 칸은 별 다섯 칸이 안 들어가 "★★★…"로 잘려 3·4·5가 같아 보였다(RatingColumnFitTests).
/// 시트의 평점 열(기본 폭 70, 글자 자리 62pt)도 큰 글자 배율에서 같은 일이 생기는지, 어떤 열 폭·글자 배율에서도
/// 평점 1~5가 서로 다르게 잘리지 않고 읽히는지(별이 안 들어가면 "5★"처럼 숫자로), 곡 색 이름이 잘려도 다른 색으로 읽히지 않는지 본다.
@Suite("태그 시트 평점·곡 색 열 폭")
@MainActor
struct SheetRatingFitTests {
    /// 글자 배율 1.0·1.3·1.5(설정 › 글자 크기의 단계 가운데 큰 쪽)
    nonisolated static let scales = [1.0, 1.3, 1.5]

    static let stars = TrackRating.choices.map(TrackRating.stars)
    static let compact = TrackRating.choices.map(TrackRating.compact)
    static let colorNames = TrackColor.rekordboxDefaults.map(\.name)

    /// 평점 1~5·곡 색 1~8(곡 8개)을 실제 시트 표(열 정의·최소 폭·늘어나지 않음)에 올린 모습
    @MainActor
    final class Harness {
        let coordinator: SheetCoordinator
        let table = SheetTableView()
        let window: NSWindow
        let rows: [TrackRow]

        init(scale: Double = 1, ratingWidth: CGFloat? = nil, colorWidth: CGFloat? = nil) {
            _ = NSApplication.shared
            let store = LibraryStore.test(saveTagDrafts: { _ in })
            coordinator = SheetCoordinator(store: store)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            table.coordinator = coordinator
            coordinator.table = table
            table.delegate = coordinator
            table.dataSource = coordinator
            table.rowHeight = 22
            table.intercellSpacing = .zero
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.allowsColumnResizing = true
            for spec in SheetColumn.all {
                let column = NSTableColumn(identifier: .init(spec.id))
                column.width = spec.width
                column.minWidth = spec.minWidth
                table.addTableColumn(column)
            }
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            window.contentView = scroll
            rows = (1...8).map { RatingColorEditingTests.row(String($0), rating: $0 <= 5 ? $0 : 0, color: String($0)) }
            coordinator.updateTextScale(scale)
            coordinator.update(rows: rows, revision: 0)
            if let ratingWidth { rating.width = ratingWidth }
            if let colorWidth { color.width = colorWidth }
            relayout()
        }

        var rating: NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == "rating" }! }
        var color: NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == "color" }! }

        func close() { window.close() }

        func relayout() {
            table.tile()
            table.layoutSubtreeIfNeeded()
            for row in rows.indices {
                for id in ["rating", "color"] { cell(row: row, column: id)?.layoutSubtreeIfNeeded() }
            }
        }

        func cell(row: Int, column: String) -> SheetCell? {
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return nil }
            return table.view(atColumn: index, row: row, makeIfNecessary: true) as? SheetCell
        }

        /// 평점 1~5 곡 칸이 지금 보이는 글자
        var ratingTexts: [String] { (0..<5).map { cell(row: $0, column: "rating")?.label.stringValue ?? "?" } }

        /// 곡 색 1~8 곡 칸이 지금 보이는 글자
        var colorTexts: [String] { rows.indices.map { cell(row: $0, column: "color")?.label.stringValue ?? "?" } }

        /// 칸 글자가 칸 자리에 다 들어가는지(들어가지 않으면 NSTextField가 끝을 "…"로 줄인다).
        func fits(row: Int, column: String) -> Bool {
            guard let cell = cell(row: row, column: column), let size = cell.label.cell?.cellSize else { return false }
            return size.width <= cell.label.frame.width + 0.01
        }

        /// 칸 글자 자리 폭(칸 폭에서 양옆 4pt씩 뺀 것)에 글자가 줄어들어 보이는 모습.
        /// 끝을 "…"로 줄이는 NSTextField와 같게, 글자 자리에 "…"까지 들어가는 가장 긴 앞부분이다.
        func visible(_ text: String, in column: String) -> String {
            guard let cell = cell(row: 0, column: column) else { return text }
            let slot = cell.label.frame.width - 4
            func width(_ string: String) -> CGFloat { ceil((string as NSString).size(withAttributes: [.font: cell.font]).width) }
            if width(text) <= slot { return text }
            var shown = text
            while !shown.isEmpty, width(shown + "…") > slot { shown.removeLast() }
            return shown + "…"
        }
    }

    // MARK: 어떤 폭에서도

    /// 열 폭을 최소 폭부터 기본 폭을 한참 넘을 때까지 한 칸씩 바꿔 가며, 다섯 평점이 늘 서로 다르게 읽히고 잘리지 않는지 본다.
    /// 글자 배율마다의 규칙은 `FittingTextTests`가 창 없이 보고, 여기서는 가장 큰 배율로 열이 규칙에 맞는 자리를 넘기는지 본다.
    @Test func 열_폭이_어떻든_평점_다섯_값이_서로_다르게_읽힌다() {
        let scale = 1.5
        let h = Harness(scale: scale)
        defer { h.close() }
        var shownStars = 0, shownCompact = 0
        var broken: [String] = []
        for width in stride(from: h.rating.minWidth, through: 220, by: 1) {
            h.rating.width = width
            h.relayout()
            let texts = h.ratingTexts
            let distinct = Set(texts).count == 5
            let known = zip(texts, zip(Self.stars, Self.compact)).allSatisfy { $0 == $1.0 || $0 == $1.1 }
            let whole = (0..<5).allSatisfy { h.fits(row: $0, column: "rating") }
            if !(distinct && known && whole) { broken.append("폭 \(Int(width)): \(texts)") }
            if texts == Self.stars { shownStars += 1 } else { shownCompact += 1 }
        }
        #expect(broken.isEmpty, "배율 \(scale) 폭을 줄이면 별이 잘리거나 값이 같아진다(\(broken.count)개 폭): \(broken.prefix(3)) … \(broken.suffix(1))")
        // 좁을 때는 숫자, 넉넉하면 별(두 모양 모두 쓰인다)
        #expect(shownStars > 0 && shownCompact > 0, "배율 \(scale): 별 \(shownStars)개 폭, 숫자 \(shownCompact)개 폭")
    }

    @Test func 열을_넓히면_별로_돌아오고_다시_좁히면_숫자가_된다() {
        let h = Harness(scale: 1.5, ratingWidth: 50)
        defer { h.close() }
        #expect(h.ratingTexts == Self.compact)
        h.rating.width = 120
        h.relayout()
        #expect(h.ratingTexts == Self.stars)
        h.rating.width = 50
        h.relayout()
        #expect(h.ratingTexts == Self.compact)
    }

    // MARK: 평점 없는 곡·읽기·초안

    @Test func 평점이_없는_곡은_폭과_상관없이_비어_있다() {
        let h = Harness(scale: 1.5, ratingWidth: 50)
        defer { h.close() }
        #expect((5..<8).allSatisfy { h.cell(row: $0, column: "rating")?.label.stringValue == "" })
    }

    /// 숫자 표기여도 VoiceOver는 별 개수를 읽고, 초안 표식·복사·툴팁은 별 다섯 칸 글자 그대로다.
    @Test func 숫자_표기여도_VoiceOver는_별_개수를_읽고_복사는_별_그대로다() throws {
        let h = Harness(scale: 1.5, ratingWidth: 50)
        defer { h.close() }
        let cell = try #require(h.cell(row: 2, column: "rating"))
        #expect(cell.label.stringValue == "3★")
        #expect(cell.label.cell?.accessibilityValue() as? String == "별 3개")
        let column = try #require(h.table.tableColumns.firstIndex { $0.identifier.rawValue == "rating" })
        #expect(h.coordinator.text(row: 2, column: column) == "★★★☆☆")
        // 초안: 값이 바뀌어도(5개) 값이 같은 모양으로 읽힌다
        h.coordinator.store.setTag(.rating, "5", rows: [h.rows[2]])
        h.coordinator.update(rows: h.rows, revision: h.coordinator.store.tagRevision)
        h.relayout()
        let edited = try #require(h.cell(row: 2, column: "rating"))
        #expect(edited.label.stringValue == "5★" && edited.showsDraftMark)
        #expect(edited.label.cell?.accessibilityValue() as? String == "별 5개, 초안")
    }

    // MARK: 곡 색 열

    /// 시트의 곡 색 열은 색 점 없이 이름만 보인다. 이름이 잘려도 여덟 색이 서로 다르게 읽혀야 한다.
    @Test(arguments: scales)
    func 곡_색_이름은_기본_폭에서_잘리지_않고_여덟_색이_서로_다르다(_ scale: Double) {
        let h = Harness(scale: scale)
        defer { h.close() }
        let shown = h.colorTexts.enumerated().map { h.visible($0.element, in: "color") }
        #expect(Set(shown).count == 8, "배율 \(scale): \(shown)")
        #expect(shown == Self.colorNames, "배율 \(scale) 기본 폭 \(h.color.width)에서 이름이 잘린다: \(shown)")
    }

    /// 열을 좁혀도 앞부분만으로 여덟 색이 갈린다("P…"만 남아 Pink·Purple이 같아 보이지 않게).
    @Test(arguments: scales)
    func 곡_색_열을_좁혀도_여덟_색이_서로_다르게_읽힌다(_ scale: Double) {
        let h = Harness(scale: scale)
        defer { h.close() }
        var broken: [String] = []
        for width in stride(from: h.color.minWidth, through: 220, by: 1) {
            h.color.width = width
            h.relayout()
            let shown = h.colorTexts.map { h.visible($0, in: "color") }
            if Set(shown).count != 8 { broken.append("폭 \(Int(width)): \(shown)") }
        }
        #expect(broken.isEmpty, "배율 \(scale) 곡 색이 같은 글자로 줄어든다(\(broken.count)개 폭): \(broken.prefix(2)) … \(broken.suffix(1))")
    }
}
