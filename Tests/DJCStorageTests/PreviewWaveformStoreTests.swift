import DJCDomain
import Foundation
import RekordboxFixtures
import Synchronization
import Testing
import RekordboxKit
@testable import DJCStorage

struct PreviewWaveformStoreTests {
    @Test func persistsReducedSourcesAndReusesThemAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dat = root.appending(path: "ANLZ.DAT"), disk = root.appending(path: "previews.plist")
        try AnlzBuilder.file([AnlzBuilder.pwav(Array(repeating: 31, count: 1200))]).write(to: dat)
        let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
        try AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6,
            samples: Array(repeating: [0, 254, 127, 127, 64, 32], count: 1200).flatMap { $0 })]).write(to: ext)
        let source = PreviewWaveformStore.Source(uuid: "test", url: dat)
        let store = PreviewWaveformStore(file: disk)
        await store.warm([source])
        #expect(FileManager.default.fileExists(atPath: disk.path))
        let reads = Mutex(0)
        let again = PreviewWaveformStore(file: disk, read: { _ in reads.withLock { $0 += 1 }; return nil })
        let preview = try #require(await again.waveform(for: source))
        #expect(reads.withLock { $0 } == 0)
        #expect(preview.blueColumns.count == 400)
        #expect(preview.colorColumns?.count == 400)
        #expect(preview.heights.first == 31)
        let color = try #require(preview.colorColumns?.first)
        #expect(abs(color.mid - 64.0 / 127) <= 1.0 / 255)
        #expect(abs(color.rgb.green - 128.0 / 255) <= 1.0 / 255)
    }

    @Test func invalidatesPathSizeModificationAndNewAnalysisFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dat = root.appending(path: "first.DAT"), other = root.appending(path: "other.DAT")
        let reads = Mutex(0)
        let store = PreviewWaveformStore(file: nil, read: { url in
            reads.withLock { $0 += 1 }
            return AnlzPreviewWaveform.readAnalysis(at: url)
        })
        var source = PreviewWaveformStore.Source(uuid: "same", url: dat)
        #expect(await store.waveform(for: source) == nil)
        try AnlzBuilder.file([AnlzBuilder.pwav([5])]).write(to: dat)
        #expect(await store.waveform(for: source)?.heights == [5])
        #expect(await store.waveform(for: source)?.heights == [5])
        #expect(reads.withLock { $0 } == 2)
        let stamp = try FileManager.default.attributesOfItem(atPath: dat.path)[.modificationDate] as! Date
        try AnlzBuilder.file([AnlzBuilder.pwav([9])]).write(to: dat)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(2)], ofItemAtPath: dat.path)
        #expect(await store.waveform(for: source)?.heights == [9])
        try AnlzBuilder.file([AnlzBuilder.pwav([3, 17])]).write(to: dat)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(2)], ofItemAtPath: dat.path)
        #expect(await store.waveform(for: source)?.heights == [3, 17])
        try AnlzBuilder.file([AnlzBuilder.pwav([21])]).write(to: other)
        source = .init(uuid: "same", url: other)
        #expect(await store.waveform(for: source)?.heights == [21])
        try AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6, samples: [0, 254, 127, 127, 0, 0])])
            .write(to: other.deletingPathExtension().appendingPathExtension("EXT"))
        #expect(await store.waveform(for: source)?.colorColumns?.count == 1)
        #expect(reads.withLock { $0 } == 6)
    }

    @Test func corruptCacheIsDisposableAndWarmRemovesDeletedTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appending(path: "cache.plist"), dat = root.appending(path: "wave.DAT")
        try Data("broken".utf8).write(to: disk)
        try AnlzBuilder.file([AnlzBuilder.pwav([31])]).write(to: dat)
        let store = PreviewWaveformStore(file: disk)
        await store.warm([.init(uuid: "removed", url: dat)])
        #expect(await store.waveform(for: .init(uuid: "removed", url: dat))?.heights == [31])
        await store.warm([])
        let reads = Mutex(0)
        let again = PreviewWaveformStore(file: disk, read: { _ in reads.withLock { $0 += 1 }; return nil })
        #expect(await again.waveform(for: .init(uuid: "removed", url: dat)) == nil)
        #expect(reads.withLock { $0 } == 1)
    }
}
