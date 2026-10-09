import AppKit
import DJCApplication
import DJCDomain

struct PreviewWaveformRequest: Hashable, Sendable {
    let url: URL?
    let revision: String
    let appearance: String
    var mode: WaveformColorMode = .threeBand
    var emphasized = false
    var audioURL: URL?
    var trackKey = ""
    var cues: [PreviewCueMark] = []
    var duration: Double = 0
    /// 칸의 파형 자리 크기(pt)와 화면 배율. 눈금은 이 크기로 그린다(#121).
    var size = CGSize(width: 400, height: 40)
    var scale: Double = 1

    var cacheKey: NSString {
        let positions = cues.map { "\($0.time):\($0.end ?? -1):\($0.hot)" }.joined(separator: ",")
        // 눈금이 없으면 파형 비트맵 하나를 칸에 늘려 쓰므로 크기가 달라도 같은 그림이다.
        let drawing = cues.isEmpty ? "" : "\(size.width)x\(size.height)@\(scale)"
        return [url?.absoluteString ?? "", revision, appearance, mode.rawValue, String(emphasized), audioURL?.absoluteString ?? "", trackKey,
                positions, String(duration), drawing]
            .joined(separator: "\u{1F}") as NSString
    }
}

/// 색 선택과 그리기를 한곳에 모으고, 셀에는 완성된 이미지만 넘긴다.
enum PreviewWaveformRenderer {
    /// 파형만 있으면 400×40 비트맵을 칸에 늘려 쓴다. 눈금이 있으면 칸의 실제 픽셀 크기(`size` pt × `scale`)로 다시 그린다.
    /// 400×40에 그려 칸에 줄여 넣으면 기본 칸에서 눈금이 1pt 남짓으로 작아진다(#121).
    static func image(_ waveform: AnlzPreviewWaveform?, mode: WaveformColorMode,
                      appearance: String, emphasized: Bool = false, cues: [PreviewCueMark] = [], duration: Double = 0,
                      size: CGSize = CGSize(width: 400, height: 40), scale: CGFloat = 1) -> CGImage? {
        let reduced = waveform?.downsampled(to: 400)
        let columns = mode == .blue ? reduced?.blueColumns : (reduced?.colorColumns ?? reduced?.blueColumns)
        // 선택 배경에서도 밴드·RGB 구분을 남기고 어두운 배경용 대비를 쓴다.
        let name = emphasized ? NSAppearance.Name.darkAqua : NSAppearance.Name(appearance)
        let image = columns.flatMap { WaveformBitmap.image($0, mode: mode, appearance: name, height: 40, width: 400) }
        let shapes = PreviewCueMark.shapes(cues, duration: duration, width: size.width, height: size.height)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard !shapes.isEmpty, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        if let image { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setShouldAntialias(false)
        for shape in shapes {
            // 반대 명도의 테두리(기기 픽셀 한 칸)로 어느 파형 색 위에서도 눈금 경계를 남긴다.
            context.setFillColor(UIColors.onFillVariants.resolved(for: name).cgColor)
            context.fill(shape.rect.insetBy(dx: -1 / scale, dy: -1 / scale))
            context.setFillColor(shape.color.variants.resolved(for: name).cgColor)
            context.fill(shape.rect)
        }
        return context.makeImage()
    }
}

enum PreviewWaveformSource {
    /// 분석 파일에 파랑·3밴드 파형이 없으면 음원 파형(`audioColumns`, 무거운 일)으로 채운다. 취소됐거나 곡 열쇠가 없으면 음원을 보지 않는다
    static func addingFallback(to source: AnlzPreviewWaveform?, audioURL: URL?, key: String,
                               audioColumns: (URL, String) -> [WaveformColumn]?) -> AnlzPreviewWaveform? {
        var blue = source?.blueColumns
        var bands = source?.colorColumns
        if blue == nil || bands == nil, !Task.isCancelled, let audioURL, !key.isEmpty,
           let columns = audioColumns(audioURL, key) {
            if blue == nil { blue = columns }
            if bands == nil { bands = columns }
        }
        guard let blue = blue ?? bands else { return nil }
        return AnlzPreviewWaveform(blue: blue, color: bands).downsampled(to: 400)
    }
}

/// 음원 파형 대체와 비트맵 생성은 메인 액터 밖에서 직렬 처리한다. 빈 자료도 기억한다. 원자료(분석 파일·음원 파형)는 유스케이스(`ShowPreviewWaveforms`)로 읽는다.
/// 라이브러리 저장소가 하나 들고(`LibraryStore.previewImages`) 목록 칸이 나눠 쓴다.
actor PreviewWaveformCache {
    private let previews: ShowPreviewWaveforms

    init(previews: ShowPreviewWaveforms) { self.previews = previews }
    private final class Entry {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 512
        return cache
    }()

    func image(for request: PreviewWaveformRequest) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = request.trackKey.isEmpty ? request.url?.absoluteString ?? "" : request.trackKey
        let revision = await previews.revision(key: key, analysisFile: request.url)
        let imageKey = "\(request.cacheKey)\u{1F}\(revision)" as NSString
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: imageKey) { return hit.image }
        let raw = await previews.waveform(key: key, analysisFile: request.url)
        var image: CGImage?
        // 음원 대체는 이 액터 위에서 동기로 돌려 칸이 많아도 음원을 한 번에 하나씩만 푼다
        let waveform = PreviewWaveformSource.addingFallback(to: raw, audioURL: request.audioURL, key: request.trackKey,
                                                            audioColumns: previews.audioColumns)
        if !Task.isCancelled {
            image = PreviewWaveformRenderer.image(waveform, mode: request.mode,
                                                 appearance: request.appearance, emphasized: request.emphasized,
                                                 cues: request.cues, duration: request.duration, size: request.size, scale: request.scale)
        }
        guard !Task.isCancelled else { return nil }
        cache.setObject(Entry(image), forKey: imageKey, cost: image.map { $0.bytesPerRow * $0.height } ?? 1)
        return image
    }
}

/// 재사용·모양새 전환 뒤 늦게 도착한 이미지는 버린다. 재생 틱은 읽지 않는다.
final class PreviewWaveformCell: NSTableCellView {
    private let cache: PreviewWaveformCache
    private let waveformLayer = CALayer()
    private var source: (url: URL?, revision: String, mode: WaveformColorMode, audioURL: URL?, key: String,
                         cues: [PreviewCueMark], duration: Double)?
    private(set) var request: PreviewWaveformRequest?
    private var task: Task<Void, Never>?

    init(cache: PreviewWaveformCache) {
        self.cache = cache
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(waveformLayer)
        setAccessibilityElement(true)
        setAccessibilityLabel(String(ui: "미리 보기 파형"))
        setAccessibilityValue(String(ui: "분석 자료 없음"))
        toolTip = String(ui: "곡 전체 파형 · 핫큐는 위쪽, 메모리 큐는 아래쪽 눈금 · 루프는 짧은 막대")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(url: URL?, revision: String, mode: WaveformColorMode = .threeBand, audioURL: URL? = nil, key: String = "",
                   cues: [PreviewCueMark] = [], duration: Double = 0) {
        source = (url, revision, mode, audioURL, key, cues, duration)
        refresh()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refresh() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            task?.cancel()
            request = nil
        } else {
            refresh()
        }
    }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: 3, dy: 2)
        guard waveformLayer.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformLayer.frame = frame
        CATransaction.commit()
        // 눈금은 칸 크기대로 그리므로 칸 크기가 바뀌면 다시 요청한다(#121).
        if waveformLayer.bounds.size != request?.size { refresh() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    private func refresh() {
        guard let source else { return }
        // 배치 전(크기 0)에는 그리지 않는다. 크기가 정해지면 layout에서 다시 부른다.
        let size = waveformLayer.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let appearance = effectiveAppearance.bestMatch(from: [.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua, .aqua, .darkAqua]) ?? .aqua
        var next = PreviewWaveformRequest(url: source.url, revision: source.revision,
                                          appearance: appearance.rawValue, mode: source.mode, emphasized: backgroundStyle == .emphasized,
                                          audioURL: source.audioURL, trackKey: source.key, cues: source.cues, duration: source.duration)
        next.size = size
        next.scale = Double(window?.backingScaleFactor ?? 2)
        guard request != next else { return }
        // 크기만 바뀌면(칸 너비 조절) 새 그림이 올 때까지 옛 그림을 늘려 둔다(깜박이지 않게).
        let resizedOnly = request.map { old in
            var old = old
            old.size = next.size
            old.scale = next.scale
            return old == next
        } ?? false
        request = next
        task?.cancel()
        if !resizedOnly { show(nil) }
        task = Task(priority: .utility) { [weak self, cache] in
            let image = await cache.image(for: next)
            guard !Task.isCancelled, let self, self.request == next else { return }
            self.show(image)
        }
    }

    private func show(_ image: CGImage?) {
        guard image != nil || waveformLayer.contents != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformLayer.contents = image
        CATransaction.commit()
        setAccessibilityValue(image == nil ? String(ui: "분석 자료 없음") : String(ui: "곡 전체 미리 보기"))
    }
}
