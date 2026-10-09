import DJCDomain
import Foundation
import RekordboxKit

/// 색 모드와 무관한 미리 보기 원자료. 디스크 읽기·검증·저장은 모두 이 액터에서 한다.
public actor PreviewWaveformStore {
    public static let shared = PreviewWaveformStore()

    public struct Source: Sendable {
        public let uuid: String
        public let url: URL?
        public init(uuid: String, url: URL?) { self.uuid = uuid; self.url = url }
    }

    private struct FileStamp: Codable, Hashable {
        let size: UInt64
        let modified: Date
        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? UInt64, let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size; self.modified = modified
        }
    }

    private struct Stamp: Codable, Hashable {
        let path: String?
        let dat, ext: FileStamp?
        init(_ url: URL?) {
            path = url?.standardizedFileURL.path
            dat = url.flatMap(FileStamp.init)
            ext = url.flatMap { FileStamp($0.deletingPathExtension().appendingPathExtension("EXT")) }
        }
    }

    /// 칸마다 높이·3밴드·흰 정도·RGB를 각 1바이트로 보관한다(곡당 최대 6.4KB).
    private struct Packed: Codable {
        let blue: Data
        let color: Data?

        init(_ waveform: AnlzPreviewWaveform) {
            func pack(_ columns: [WaveformColumn]) -> Data {
                Data(columns.flatMap { c in
                    [c.height, c.low, c.mid, c.high, c.whiteness, c.rgb.red, c.rgb.green, c.rgb.blue].map {
                        UInt8(($0.isFinite ? min(1, max(0, $0)) * 255 : 0).rounded())
                    }
                })
            }
            let reduced = waveform.downsampled(to: 400)
            blue = pack(reduced.blueColumns); color = reduced.colorColumns.map(pack)
        }

        func unpack() -> AnlzPreviewWaveform? {
            func columns(_ data: Data) -> [WaveformColumn]? {
                guard data.count <= 400 * 8, data.count.isMultiple(of: 8) else { return nil }
                let bytes = [UInt8](data)
                return stride(from: 0, to: bytes.count, by: 8).map { index in
                    func value(_ offset: Int) -> Double { Double(bytes[index + offset]) / 255 }
                    var column = WaveformColumn(low: value(1), mid: value(2), high: value(3))
                    column.height = value(0); column.whiteness = value(4)
                    column.rgb = WaveformRGB(red: value(5), green: value(6), blue: value(7))
                    return column
                }
            }
            guard let blue = columns(blue), !blue.isEmpty else { return nil }
            let colors = color.flatMap(columns)
            guard color == nil || colors != nil else { return nil }
            return AnlzPreviewWaveform(blue: blue, color: colors)
        }
    }

    private struct Entry: Codable {
        let stamp: Stamp
        let waveform: Packed?
    }
    private struct Cache: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private let file: URL?
    private let read: @Sendable (URL?) -> AnlzPreviewWaveform?
    private var cache = Cache()
    private var loaded = false
    private var dirty = false

    public init(file: URL? = DJCPaths.previewWaveforms,
                read: @escaping @Sendable (URL?) -> AnlzPreviewWaveform? = AnlzPreviewWaveform.readAnalysis) {
        self.file = file; self.read = read
    }

    public func waveform(for source: Source) -> AnlzPreviewWaveform? {
        loadIfNeeded()
        let stamp = Stamp(source.url)
        if let entry = cache.entries[source.uuid], entry.stamp == stamp {
            if entry.waveform == nil { return nil }
            if let value = entry.waveform?.unpack() { return value }
        }
        let value = read(source.url)?.downsampled(to: 400)
        cache.entries[source.uuid] = Entry(stamp: stamp, waveform: value.map(Packed.init))
        dirty = true
        return value
    }

    /// 메모리 비트맵도 파일 변경을 따라 무효화한다. 해시는 프로세스 안에서만 쓴다.
    public func revision(for source: Source) -> Int { Stamp(source.url).hashValue }

    /// 전체 목록을 조용히 채우되 셀의 요청이 사이에 들어올 수 있도록 칸마다 양보한다.
    /// 음원은 읽지 않고 ANLZ만 읽는다. 새 로드가 시작되면 이전 작업은 취소한다.
    public func warm(_ sources: [Source]) async {
        loadIfNeeded()
        for source in sources {
            if Task.isCancelled { save(); return }
            if cache.entries[source.uuid]?.stamp != Stamp(source.url) { _ = waveform(for: source) }
            await Task.yield()
        }
        guard !Task.isCancelled else { save(); return }
        let retained = Set(sources.map(\.uuid))
        let oldCount = cache.entries.count
        cache.entries = cache.entries.filter { retained.contains($0.key) }
        if oldCount != cache.entries.count { dirty = true }
        save()
    }

    /// 캐시 비우기(설정 › 저장 공간): 메모리와 파일을 함께 비운다. 저장과 같은 액터라 옛 내용을 다시 쓰지 않는다.
    /// 다음 `waveform(for:)`·`warm`이 분석 파일에서 다시 읽어 파일을 새로 만든다.
    public func clear() {
        cache = Cache()
        loaded = true
        dirty = false
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? PropertyListDecoder().decode(Cache.self, from: data), stored.version == 1 { cache = stored }
    }

    private func save() {
        guard dirty, let file else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(cache).write(to: file, options: .atomic)
            dirty = false
        } catch { /* 캐시는 다시 만들 수 있으므로 읽기·스크롤은 계속한다. */ }
    }
}
