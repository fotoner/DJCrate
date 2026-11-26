@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 저장 뒤 다시 읽은 목록이 깜박이지 않는다: 순서가 같은 새 사본은 칸을 떼었다 붙이지 않고 제자리에서 다시 채우고,
/// 같은 곡의 미리 보기 파형은 새 그림이 올 때까지 옛 그림을 둔다.
@MainActor
@Suite("저장 뒤 목록 다시 그리기")
struct TrackListSaveRefreshTests {
    /// 파형 원자료: 곡마다 첫 요청은 바로 주고, 같은 곡의 다음 요청은 시험이 풀어 줄 때까지 붙든다
    final class WaveformGate: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private var heldCount = 0

        /// 붙들린 적이 있는 요청 수
        var held: Int { lock.withLock { heldCount } }

        var previews: PreviewWaveforms {
            let column = WaveformColumn(low: 1, mid: 1, high: 1)
            let waveform = AnlzPreviewWaveform(blue: Array(repeating: column, count: 400), color: Array(repeating: column, count: 400))
            return PreviewWaveforms(warm: { _, _ in }, revision: { _, _ in 0 },
                                    waveform: { [self] key, _ in
                                        await hold(key)
                                        return waveform
                                    },
                                    audioColumns: { _, _ in nil }, clear: {}, volumeFile: { _, _ in nil })
        }

        private func hold(_ key: String) async {
            guard !lock.withLock({ seen.insert(key).inserted }) else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if open { return true }
                    waiting.append(continuation)
                    heldCount += 1
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let resumed = lock.withLock {
                open = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in resumed { continuation.resume() }
        }
    }

    static func shows(_ cell: PreviewWaveformCell) -> Bool {
        (cell.accessibilityValue() as? String) == String(ui: "곡 전체 미리 보기")
    }

    @Test func 같은_곡의_새_사본은_새_파형이_올_때까지_옛_파형을_둔다() async {
        let gate = WaveformGate()
        defer { gate.release() }
        let cell = PreviewWaveformCell(cache: PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: gate.previews)))
        let analysis = URL(filePath: "/tmp/djc-preview-keep/ANLZ0000.DAT")
        cell.configure(url: analysis, revision: "사본-1:0", key: "uuid-a", duration: 180)
        cell.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        cell.layout()
        #expect(await waitForState { Self.shows(cell) }, "첫 파형을 그린다")

        // 저장 뒤 다시 읽어 사본 경로가 바뀌었다: 같은 곡이라 새 그림이 올 때까지 옛 그림을 둔다
        cell.configure(url: analysis, revision: "사본-2:0", key: "uuid-a", duration: 180)
        #expect(await waitForState { gate.held == 1 })
        #expect(Self.shows(cell), "다시 읽는 동안 파형을 비우지 않는다")

        // 다른 곡으로 다시 쓰인 칸은 옛 곡의 파형을 보이지 않는다
        cell.configure(url: URL(filePath: "/tmp/djc-preview-keep/ANLZ0001.DAT"), revision: "사본-2:0", key: "uuid-b", duration: 180)
        #expect(!Self.shows(cell))
    }

    @Test func 순서가_같은_새_사본은_칸을_떼지_않고_제자리에서_다시_채운다() async throws {
        let gate = WaveformGate()
        defer { gate.release() }
        let store = LibraryStore.test(saveTagDrafts: { _ in }, ports: { $0.previews = gate.previews })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let table = NSTableView(frame: scroll.bounds)
        for (id, width) in [("preview", 160.0), ("title", 300.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = coordinator
        table.dataSource = coordinator
        scroll.documentView = table
        coordinator.table = table
        var rows = (0..<5).map { TrackListTagEditTests.row(String($0)) }
        coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: URL(filePath: "/tmp/djc-snapshot-1"), previewRevision: 0)
        scroll.layoutSubtreeIfNeeded()
        let preview = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? PreviewWaveformCell)
        let title = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: false) as? TrackTextCell)
        #expect(await waitForState { Self.shows(preview) }, "첫 파형을 그린다")

        // 저장 뒤 다시 읽었다: 같은 곡이 같은 순서로 있고 내용만 바뀌었다
        rows[0] = TrackListTagEditTests.row("0", title: "저장한 제목")
        coordinator.update(rows: rows, edited: [], selection: [], sortOrder: [], snapshotURL: URL(filePath: "/tmp/djc-snapshot-2"), previewRevision: 0)
        #expect(table.view(atColumn: 1, row: 0, makeIfNecessary: false) as? TrackTextCell === title)
        #expect(title.text == "저장한 제목")
        #expect(await waitForState { gate.held >= 1 }, "새 사본의 파형을 다시 읽는다")
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? PreviewWaveformCell === preview)
        #expect(Self.shows(preview), "칸을 떼었다 붙이면 파형이 비었다가 다시 그려져 목록이 깜박였다")
    }
}
