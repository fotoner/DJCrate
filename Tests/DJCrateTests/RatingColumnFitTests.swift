@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import Testing

/// 곡 목록 평점 칸 폭(#65): 기본 폭 66에서 별 다섯 칸이 "★★★…"로 잘려 평점 3·4·5가 같은 모양으로 보였다.
/// 어떤 칸 폭·글자 배율에서도 평점 1~5가 서로 다르게, 잘리지 않고 읽혀야 한다(별이 안 들어가면 "5★"처럼 숫자로).
/// 실제 목록과 같은 모양(`.inset` 표)에서 칸을 그려 본다.
@Suite("평점 칸 폭")
@MainActor
struct RatingColumnFitTests {
    /// 글자 배율 1.0·1.3·1.5(설정 › 글자 크기의 단계 가운데 큰 쪽)
    nonisolated static let scales = [1.0, 1.3, 1.5]

    static var ratingSpec: TrackColumn { TrackColumn.all.first { $0.id == "rating" }! }
    static var colorSpec: TrackColumn { TrackColumn.all.first { $0.id == "color" }! }

    /// 평점 1~5 다섯 곡(곡 색은 번호 2~8 가운데 다섯)을 `.inset` 표에 올린 목록
    @MainActor
    final class Harness {
        let coordinator: TrackListCoordinator
        let table = TrackListTableView()
        let window: NSWindow
        let rows: [TrackRow]

        init(scale: Double = 1, ratingWidth: CGFloat? = nil, colorWidth: CGFloat? = nil) {
            _ = NSApplication.shared
            let store = LibraryStore.test(saveTagDrafts: { _ in })
            coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
            coordinator.isMouseDown = { false }
            table.identifier = KeyRouter.trackListID
            table.coordinator = coordinator
            table.dataSource = coordinator
            table.delegate = coordinator
            table.style = .inset
            table.rowHeight = 24
            table.columnAutoresizingStyle = .noColumnAutoresizing
            // 앱과 같은 칸 정의(폭·최소 폭·늘어나지 않음)로 만든다.
            for spec in [TrackColumn.all.first { $0.id == "title" }!, Self.spec("rating"), Self.spec("color")] {
                let column = NSTableColumn(identifier: .init(spec.id))
                column.width = spec.width
                column.minWidth = spec.minWidth
                column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
                table.addTableColumn(column)
            }
            let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 900, height: 300))
            scroll.documentView = table
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scroll)
            coordinator.table = table
            rows = (1...5).map { RatingColorEditingTests.row(String($0), rating: $0, color: String($0 + 1)) }
            coordinator.updateTextScale(scale)
            coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
            if let ratingWidth { rating.width = ratingWidth }
            if let colorWidth { color.width = colorWidth }
            relayout()
        }

        static func spec(_ id: String) -> TrackColumn { TrackColumn.all.first { $0.id == id }! }

        var rating: NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == "rating" }! }
        var color: NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == "color" }! }

        func close() { window.close() }

        func relayout() {
            table.tile()
            table.layoutSubtreeIfNeeded()
            for row in 0..<table.numberOfRows {
                for id in ["rating", "color"] { cell(row: row, column: id)?.layoutSubtreeIfNeeded() }
            }
        }

        func cell(row: Int, column: String) -> TrackTextCell? {
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return nil }
            return table.view(atColumn: index, row: row, makeIfNecessary: true) as? TrackTextCell
        }

        /// 평점 1~5 곡 칸이 지금 보이는 글자
        var ratingTexts: [String] { rows.indices.map { cell(row: $0, column: "rating")?.text ?? "?" } }

        /// 칸 글자가 칸 자리에 다 들어가는지(들어가지 않으면 NSTextField가 끝을 "…"로 줄인다).
        /// 글자 칸 프레임은 글자 자리보다 양옆 2pt씩 넓고, 글자 칸이 바라는 폭(`cellSize`)에는 그 여백이 들어 있다.
        func fits(row: Int, column: String) -> Bool {
            guard let cell = cell(row: row, column: column), let size = cell.label.cell?.cellSize else { return false }
            return size.width <= cell.label.frame.width + 0.01
        }
    }

    static let stars = TrackRating.choices.map(TrackRating.stars)
    static let compact = TrackRating.choices.map(TrackRating.compact)

    // MARK: 기본 폭

    @Test func 기본_폭에서_별_다섯_칸이_그대로_보인다() {
        let h = Harness(ratingWidth: Self.ratingSpec.width)
        defer { h.close() }
        #expect(h.ratingTexts == Self.stars)
        #expect(h.rows.indices.allSatisfy { h.fits(row: $0, column: "rating") })
    }

    // MARK: 어떤 폭·글자 배율에서도

    /// 칸 폭을 최소 폭부터 기본 폭을 한참 넘을 때까지 한 칸씩 바꿔 가며, 다섯 평점이 늘 서로 다르게 읽히고 잘리지 않는지 본다.
    /// 글자 배율마다의 규칙은 `FittingTextTests`가 창 없이 보고, 여기서는 가장 큰 배율로 칸이 규칙에 맞는 자리를 넘기는지 본다.
    @Test func 칸_폭이_어떻든_평점_다섯_값이_서로_다르게_읽힌다() {
        let scale = 1.5
        let h = Harness(scale: scale)
        defer { h.close() }
        var shownStars = 0, shownCompact = 0
        for width in stride(from: h.rating.minWidth, through: 220, by: 1) {
            h.rating.width = width
            h.relayout()
            let texts = h.ratingTexts
            let note = "폭 \(width) 배율 \(scale): \(texts)"
            #expect(Set(texts).count == 5, "\(note) 다섯 값이 서로 달라야 한다")
            #expect(zip(texts, zip(Self.stars, Self.compact)).allSatisfy { $0 == $1.0 || $0 == $1.1 }, "\(note) 별 다섯 칸이거나 숫자 표기여야 한다")
            #expect(h.rows.indices.allSatisfy { h.fits(row: $0, column: "rating") }, "\(note) 잘리면 안 된다")
            if texts == Self.stars { shownStars += 1 } else { shownCompact += 1 }
        }
        // 좁을 때는 숫자, 넉넉하면 별(두 모양 모두 쓰인다)
        #expect(shownStars > 0 && shownCompact > 0)
    }

    // MARK: 옛 기본 폭(66)으로 저장된 사용자

    @Test func 옛_기본_폭_66은_숫자_표기로_보여_별_수를_잘못_읽지_않는다() {
        let h = Harness(ratingWidth: TrackColumn.legacyRatingWidth)
        defer { h.close() }
        #expect(h.rating.width == 66)
        #expect(h.ratingTexts == Self.compact)
        #expect(h.rows.indices.allSatisfy { h.fits(row: $0, column: "rating") })
    }

    @Test func 칸을_넓히면_별로_돌아오고_다시_좁히면_숫자가_된다() {
        let h = Harness(ratingWidth: TrackColumn.legacyRatingWidth)
        defer { h.close() }
        #expect(h.ratingTexts == Self.compact)
        h.rating.width = Self.ratingSpec.width
        h.relayout()
        #expect(h.ratingTexts == Self.stars)
        h.rating.width = TrackColumn.legacyRatingWidth
        h.relayout()
        #expect(h.ratingTexts == Self.compact)
    }

    @Test func 폭이_옛_기본값_그대로일_때만_한_번_기본_폭으로_옮긴다() {
        let new = Self.ratingSpec.width
        #expect(TrackColumn.legacyRatingWidth == 66 && new > 66)
        #expect(TrackColumn.migratedRatingWidth(saved: 66) == new)
        // 사용자가 직접 줄이거나 넓힌 폭은 건드리지 않는다
        for saved: CGFloat in [40, 48, 65.5, 66.5, 70, new, 84, 120] {
            #expect(TrackColumn.migratedRatingWidth(saved: saved) == nil, "\(saved)")
        }
    }

    @Test func 옛_기본_폭은_한_번만_넓히고_그_뒤에_줄인_폭은_덮어쓰지_않는다() throws {
        let name = TestDefaults.suiteName("ratingWidth")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("rating"))
        column.minWidth = TrackColumn.ratingMinWidth
        column.width = TrackColumn.legacyRatingWidth
        table.addTableColumn(column)
        // 시작: 저장된 66 그대로 → 새 기본 폭으로
        TrackColumn.migrateRatingWidth(in: table, defaults: defaults)
        #expect(column.width == TrackColumn.ratingWidth && defaults.bool(forKey: TrackColumn.ratingWidthMigratedKey))
        // 사용자가 일부러 66으로 줄인다 → 다음 실행에서도 그대로
        column.width = TrackColumn.legacyRatingWidth
        TrackColumn.migrateRatingWidth(in: table, defaults: defaults)
        #expect(column.width == 66)
    }

    @Test func 사용자가_바꾼_폭은_옮기지_않고_표시만_남긴다() throws {
        let name = TestDefaults.suiteName("ratingWidth")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("rating"))
        column.minWidth = TrackColumn.ratingMinWidth
        column.width = 52
        table.addTableColumn(column)
        TrackColumn.migrateRatingWidth(in: table, defaults: defaults)
        #expect(column.width == 52 && defaults.bool(forKey: TrackColumn.ratingWidthMigratedKey))
        // 성능 측정(칸 배치를 저장하지 않음)에서는 표시를 남기지 않는다
        let other = TestDefaults.suiteName("ratingWidth")
        let perf = TestDefaults.open(other)
        defer { perf.removePersistentDomain(forName: other) }
        column.width = TrackColumn.legacyRatingWidth
        TrackColumn.migrateRatingWidth(in: table, defaults: perf, remember: false)
        #expect(column.width == TrackColumn.ratingWidth && !perf.bool(forKey: TrackColumn.ratingWidthMigratedKey))
        // 평점 칸이 없는 표(USB 목록 등 칸이 다른 표)는 그냥 지나간다
        let bare = NSTableView()
        TrackColumn.migrateRatingWidth(in: bare, defaults: defaults)
    }

    // MARK: 평점 없는 곡·초안

    @Test func 평점이_없는_곡은_폭과_상관없이_비어_있다() {
        let h = Harness(ratingWidth: TrackColumn.legacyRatingWidth)
        defer { h.close() }
        let none = RatingColorEditingTests.row("9", rating: 0)
        h.coordinator.update(rows: [none], edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        h.relayout()
        #expect(h.cell(row: 0, column: "rating")?.text == "")
    }

    @Test func 숫자_표기여도_VoiceOver는_별_개수를_읽고_초안_표식은_그대로다() throws {
        let h = Harness(ratingWidth: TrackColumn.legacyRatingWidth)
        defer { h.close() }
        let row = h.rows[2]
        let cell = try #require(h.cell(row: 2, column: "rating"))
        #expect(cell.text == "3★" && cell.label.accessibilityValue() as? String == "별 3개")
        h.coordinator.store.tags.setTag(.rating, "5", rows: [row])
        h.coordinator.updateTagRevision(h.coordinator.store.tagRevision)
        h.relayout()
        #expect(cell.text == "5★" && cell.showsDraftMark && cell.label.accessibilityValue() as? String == "별 5개, 초안")
    }

    // MARK: 곡 색 칸

    /// 곡 색은 색 점이 먼저 알리고 이름은 곁들인다. 이름이 잘려도 점·VoiceOver 값은 그대로라 다른 색으로 읽히지 않는다.
    @Test(arguments: scales)
    func 곡_색_칸은_이름이_잘려도_색_점이_남는다(_ scale: Double) throws {
        let h = Harness(scale: scale, colorWidth: Self.colorSpec.width)
        defer { h.close() }
        for row in h.rows.indices {
            let cell = try #require(h.cell(row: row, column: "color"))
            #expect(cell.swatchShown, "\(row)행 배율 \(scale)")
            #expect(cell.label.accessibilityValue() as? String == cell.text)
        }
    }
}
