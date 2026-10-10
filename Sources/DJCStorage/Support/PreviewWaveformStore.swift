import DJCDomain
import Foundation
import RekordboxKit

/// 색 모드와 무관한 미리 보기 원자료. 디스크 읽기·검증·저장은 모두 이 액터에서 한다.
public actor PreviewWaveformStore {
    public static let shared = PreviewWaveformStore()

    /// 곡마다 파일 상태를 읽는 막는 입출력이라 협력 풀이 아닌 제 직렬 큐에서 돈다(코어가 적으면 풀이 바닥난다).
    /// GCD로 넘기는 대신 실행기를 바꿔, 미리 데우기가 보는 작업 취소와 칸 사이 양보는 그대로다.
    private let queue = DispatchSerialQueue(label: "DJCrate.PreviewWaveformStore")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public struct Source: Sendable {
        public let uuid: String
        public let url: URL?
        public init(uuid: String, url: URL?) { self.uuid = uuid; self.url = url }
    }

    /// 분석 파일의 크기·수정 시각(시험이 어느 스레드에서 읽는지 본다)
    typealias StatFile = @Sendable (URL) -> (size: UInt64, modified: Date)?
    static let statFile: StatFile = { url in
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64, let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    private struct FileStamp: Codable, Hashable {
        let size: UInt64
        let modified: Date
        init?(_ url: URL, stat: StatFile) {
            guard let (size, modified) = stat(url) else { return nil }
            self.size = size; self.modified = modified
        }
    }

    private struct Stamp: Codable, Hashable {
        let path: String?
        let dat, ext: FileStamp?
        init(_ url: URL?, stat: StatFile) {
            path = url?.standardizedFileURL.path
            dat = url.flatMap { FileStamp($0, stat: stat) }
            ext = url.flatMap { FileStamp($0.deletingPathExtension().appendingPathExtension("EXT"), stat: stat) }
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
    private let stat: StatFile
    private var cache = Cache()
    private var loaded = false
    private var dirty = false

    public init(file: URL? = DJCPaths.previewWaveforms,
                read: @escaping @Sendable (URL?) -> AnlzPreviewWaveform? = AnlzPreviewWaveform.readAnalysis) {
        self.init(file: file, read: read, stat: Self.statFile)
    }

    init(file: URL?, read: @escaping @Sendable (URL?) -> AnlzPreviewWaveform?, stat: @escaping StatFile) {
        self.file = file; self.read = read; self.stat = stat
    }

    public func waveform(for source: Source) -> AnlzPreviewWaveform? {
        loadIfNeeded()
        let stamp = Stamp(source.url, stat: stat)
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
    public func revision(for source: Source) -> Int { Stamp(source.url, stat: stat).hashValue }

    /// 전체 목록을 조용히 채우되 셀의 요청이 사이에 들어올 수 있도록 칸마다 양보한다.
    /// 음원은 읽지 않고 ANLZ만 읽는다. 새 로드가 시작되면 이전 작업은 취소한다.
    public func warm(_ sources: [Source]) async {
        loadIfNeeded()
        for source in sources {
            if Task.isCancelled { save(); return }
            if cache.entries[source.uuid]?.stamp != Stamp(source.url, stat: stat) { _ = waveform(for: source) }
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
