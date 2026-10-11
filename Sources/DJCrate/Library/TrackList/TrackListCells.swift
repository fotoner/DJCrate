import DJCDomain
import AppKit
import SwiftUI

/// 썸네일은 백그라운드에서 디코딩해 받아 온다. 셀이 다른 곡으로 재사용되면 늦게 온 결과는 버린다.
final class ThumbnailCell: NSTableCellView {
    private let thumbnails: Thumbnails
    private let thumb = NSImageView()
    private var showingPlaceholder = true
    private var key: String?
    private var task: Task<Void, Never>?
    private static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: String(ui: "앨범아트 없음"))
        return image?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
    }()

    init(thumbnails: Thumbnails) {
        self.thumbnails = thumbnails
        super.init(frame: .zero)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.masksToBounds = true
        thumb.contentTintColor = .tertiaryLabelColor
        thumb.setAccessibilityLabel(String(ui: "앨범아트"))
        addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 22),
            thumb.heightAnchor.constraint(equalToConstant: 22),
            thumb.centerXAnchor.constraint(equalTo: centerXAnchor),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: TrackRow, shareRoot: URL) {
        // 그림을 쓴 곡은 번호가 붙은 새 열쇠라 같은 ContentID여도 다시 읽는다(#66). USB 곡은 볼륨을 다시 읽은 판을 붙인다
        let id = row.isUsb ? "\(row.track.id)#usb\(row.usbFiles?.revision ?? 0)" : ArtworkRevisions.key(row.track.id)
        guard key != id else { return }
        key = id
        task?.cancel()
        show(nil)
        // USB 곡(보존 기록 곡 포함)은 로컬 share를 보지 않는다(로컬의 다른 그림을 가리킨다). 볼륨 안 그림이 있을 때만 읽는다
        if row.isUsb {
            guard let files = row.usbFiles, files.artwork != nil else { task = nil; return }
            task = Task { [weak self, thumbnails] in
                let box = await thumbnails.usbImage(files, key: id)
                self?.finish(box, key: id)
            }
            return
        }
        let path = row.track.imagePath
        task = Task { [weak self, thumbnails] in
            let box = await thumbnails.image(imagePath: path, root: shareRoot, key: id)
            self?.finish(box, key: id)
        }
    }

    /// 늦게 온 그림(그새 다른 곡으로 다시 쓰인 칸)은 버린다
    private func finish(_ box: Thumbnails.Box?, key id: String) {
        guard !Task.isCancelled, key == id else { return }
        show(box.map { NSImage(cgImage: $0.image, size: NSSize(width: 22, height: 22)) })
    }

    private func show(_ image: NSImage?) {
        thumb.image = image ?? Self.placeholder
        thumb.imageScaling = image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        showingPlaceholder = image == nil
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.backgroundColor = showingPlaceholder ? NSColor.quaternarySystemFill.cgColor : nil
        }
    }
}

final class EditedMarkCell: NSTableCellView {
    private let mark = NSImageView()
    private static let image = NSImage(systemSymbolName: DraftMark.symbol, accessibilityDescription: String(ui: "초안 있음"))

    init() {
        super.init(frame: .zero)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.contentTintColor = UIColors.draft.nsColor
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            mark.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : UIColors.draft.nsColor
        }
    }

    func configure(edited: Bool) {
        mark.image = edited ? Self.image : nil
        toolTip = edited ? String(ui: "DJCrate 초안이 있습니다 (rekordbox·파일에 쓰기 전)") : nil
    }
}

extension CommentEvaluation.Tone {
    var tint: Color { Color(nsColor: nsTint) }

    var nsTint: NSColor {
        switch self {
        case .matched: UIColors.hot.nsColor
        case .empty: UIColors.warning.nsColor
        case .info: UIColors.info.nsColor
        case .residue: UIColors.memory.nsColor
        case .secondary: .secondaryLabelColor
        }
    }
}
