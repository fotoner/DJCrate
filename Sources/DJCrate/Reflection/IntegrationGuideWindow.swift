import AppKit
import DJCDomain
import SwiftUI

/// 연동 안내 창(#315). 도움말 메뉴·결과 줄·Apple Music 가져오기 창이 같은 창을 연다.
/// 앱에 창 하나만 만들고 늘 그 창을 쓴다. 닫았거나 최소화한 창도 새로 만들지 않고 다시 보이며, 보는 쪽(`topic`)만 바꾼다.
@MainActor
final class IntegrationGuideWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var model: IntegrationGuideModel?
    /// 창을 화면에 올린다. 시험은 창을 띄우지 않게 바꿔 넣는다
    private let show: (NSWindow) -> Void

    init(show: @escaping (NSWindow) -> Void = { window in
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }) {
        self.show = show
    }

    func open(file: URL, topic: IntegrationGuide.Topic) {
        if let window, let model {
            model.topic = topic
            show(window)
            return
        }
        let model = IntegrationGuideModel(xmlFile: file, topic: topic, copy: { path in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }, reveal: { file in
            let target = IntegrationGuide.revealTarget(for: file) { FileManager.default.fileExists(atPath: $0.path) }
            if target == file { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { NSWorkspace.shared.open(target) }
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: IntegrationGuideView(model: model)))
        window.title = String(ui: "연동 안내")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 640, height: 400))
        window.contentMinSize = NSSize(width: 520, height: 300)
        window.center()
        self.window = window
        self.model = model
        show(window)
    }
}

private struct IntegrationGuideView: View {
    @Bindable var model: IntegrationGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(selection: $model.topic) {
                ForEach(IntegrationGuide.Topic.allCases, id: \.self) { topic in
                    Text(verbatim: topic.title).tag(topic)
                }
            } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(.ui("연동 안내"))
            if model.topic == .rekordbox {
                HStack(spacing: 8) {
                    Text(verbatim: model.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(.ui("경로 복사")) { model.copyPath() }
                    Button(.ui("Finder에서 보기")) { model.revealInFinder() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.topic.lines.enumerated()), id: \.offset) { _, line in
                        if line.isEmpty { Color.clear.frame(height: 4) } else { Text(line).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }
}
