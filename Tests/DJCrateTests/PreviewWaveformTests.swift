import AppKit
import Foundation
import RekordboxFixtures
import Testing
import RekordboxKit
import DJCDomain
import DJCAdapters
import DJCApplication
import DJCStorage
import DJCTestKit
import Synchronization
@testable import DJCrate

struct PreviewWaveformTests {
    /// 분석 파일에 파형이 없으면 음원 전체를 풀어 채운다. 무거운 동기 일이라 협력 풀 밖에서 돈다(코어가 적으면 풀이 바닥난다)
    @Test func 음원_파형_대체는_협력_풀_밖에서_푼다() async throws {
        let calls = Mutex(0)
        let previews = PreviewWaveforms(warm: { _, _ in }, revision: { _, _ in 0 }, waveform: { _, _ in nil }, audioColumns: { _, _ in
            expectBlockingOffPool()
            calls.withLock { $0 += 1 }
            return [WaveformColumn(low: 1, mid: 0.5, high: 0.2)]
        }, clear: {}, volumeFile: { _, _ in nil })
        let cache = PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: previews))
        var request = PreviewWaveformRequest(url: nil, revision: "r", appearance: NSAppearance.Name.aqua.rawValue)
        request.audioURL = URL(filePath: "/missing/audio.wav")
        request.trackKey = "key"
        _ = await cache.image(for: request)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func modeChangesInvalidateCachedImagesAndUsePWV4() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preview.DAT")
        try AnlzBuilder.file([AnlzBuilder.pwav([31])]).write(to: url)
        try AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6, samples: [0, 255, 127, 127, 0, 0])])
            .write(to: url.deletingPathExtension().appendingPathExtension("EXT"))
        let cache = PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: .live(store: PreviewWaveformStore(file: nil))))
        var request = PreviewWaveformRequest(url: url, revision: "same", appearance: NSAppearance.Name.darkAqua.rawValue)
        request.mode = .blue
        let blue = try #require(await cache.image(for: request))
        request.mode = .rgb
        let rgb = try #require(await cache.image(for: request))
        #expect(blue !== rgb)
        let color = try #require(NSBitmapImageRep(cgImage: rgb).colorAt(x: 200, y: 20))
        #expect(color.redComponent > color.blueComponent)
        request.mode = .threeBand
        let bands = try #require(await cache.image(for: request))
        #expect(rgb !== bands)
        #expect(await cache.image(for: request) === bands)
    }

    @Test func rendersPeaksAndSilenceInEveryAppearance() throws {
        let preview = try #require(try AnlzPreviewWaveform(file: AnlzFile(data:
            AnlzBuilder.file([AnlzBuilder.pwav([0, 31])]))))
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let image = try #require(PreviewWaveformRenderer.image(preview, mode: .blue, appearance: name.rawValue))
            #expect(image.width == 400)
            #expect(image.height == 40)
            let bitmap = NSBitmapImageRep(cgImage: image)
            #expect(bitmap.colorAt(x: 0, y: 20)?.alphaComponent == 0)
            #expect(bitmap.colorAt(x: 300, y: 20)?.alphaComponent == 1)
            let expected = UIColors.info.variants.resolved(for: name).usingColorSpace(.sRGB)!
            let pixels = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(pixels))
            let offset = 20 * image.bytesPerRow + 300 * 4
            #expect(abs(Double(bytes[offset + 2]) / 255 - expected.blueComponent) < 0.01)
            #expect(abs(Double(bytes[offset]) / 255 - expected.redComponent) < 0.01)
        }
    }

    @Test func cachesImagesAndSeparatesSnapshotRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preview.DAT")
        let cache = PreviewWaveformCache(previews: ShowPreviewWaveforms(previews: .live(store: PreviewWaveformStore(file: nil))))
        let first = PreviewWaveformRequest(url: url, revision: "first", appearance: NSAppearance.Name.aqua.rawValue)
        #expect(await cache.image(for: first) == nil)
        #expect(await cache.image(for: first) == nil)
        try AnlzBuilder.file([AnlzBuilder.pwav([31, 0, 15])]).write(to: url)
        // 같은 스냅샷이어도 분석 파일이 생기면 빈 비트맵 캐시를 버린다.
        #expect(await cache.image(for: first) != nil)
        let second = PreviewWaveformRequest(url: url, revision: "second", appearance: NSAppearance.Name.aqua.rawValue)
        let image = try #require(await cache.image(for: second))
        #expect(await cache.image(for: second) === image)
        let missing = PreviewWaveformRequest(url: nil, revision: "second", appearance: NSAppearance.Name.aqua.rawValue)
        #expect(await cache.image(for: missing) == nil)
    }
}
