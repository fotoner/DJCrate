import DJCDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 파일 선택·저장 창.
@MainActor
enum StagingPanels {
    static func chooseFiles(store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = String(ui: "추가")
        panel.message = String(ui: "음원 파일이나 폴더를 고르세요. rekordbox에 있는 파일은 건너뜁니다.")
        guard panel.runModal() == .OK else { return }
        store.staging.startAddingFiles(panel.urls)
    }

    static func exportXML(store: LibraryStore) {
        let selected = store.selection.filter { $0.hasPrefix("djc-") }
        do {
            let url = try RekordboxLink.prepare(store.linkedXMLFile)
            let result = try store.staging.exportStaged(to: url, only: selected.isEmpty ? nil : selected)
            // 키 초안이 있어 뺀 곡만 있으면 아무것도 쓰지 않았다: 이유를 알리고 연동 안내는 띄우지 않는다.
            guard result.count > 0 || result.skipped.isEmpty else {
                store.showToast(.notice(text: result.skipped.joined(separator: "\n"), kind: .failure))
                return
            }
            store.showToast(resultMessage(count: result.count, withoutGrid: result.withoutGrid, skipped: result.skipped))
            RekordboxLink.showSetupIfNeeded(store: store)
        } catch {
            store.showToast(.notice(text: String(ui: "내보내지 못했습니다. 저장 위치와 권한을 확인하세요: \(error.localizedDescription)"), kind: .failure))
        }
    }

    /// 추가한 곡의 XML을 만든 뒤의 알림: 결과 한 줄과 [가져오는 방법]. 그리드 없이 넣은 곡·뺀 곡의 이유는 있을 때만 붙는다(#315)
    static func resultMessage(count: Int, withoutGrid: Int, skipped: [String]) -> AppToast {
        var lines: [String] = []
        if withoutGrid > 0 { lines.append(String(ui: "\(withoutGrid)곡은 그리드 없이(rekordbox가 분석)")) }
        lines += skipped
        var toast = AppToast.notice(String(ui: "\(count)곡을 연동 XML에 썼습니다"), lines.joined(separator: "\n"),
                                    kind: withoutGrid > 0 || !skipped.isEmpty ? .warning : .success)
        toast.action = .openIntegrationGuide(.rekordbox)
        return toast
    }
}
