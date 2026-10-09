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
        panel.message = String(ui: "DJCrate에 추가할 음원 파일이나 폴더를 고르세요. 이미 rekordbox에 있는 파일은 건너뜁니다.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.addFiles(urls) }
    }

    static func exportXML(store: LibraryStore) {
        let selected = store.selection.filter { $0.hasPrefix("djc-") }
        do {
            let url = try RekordboxLink.prepare(store.linkedXMLFile)
            let result = try store.exportStaged(to: url, only: selected.isEmpty ? nil : selected)
            // 키 초안이 있어 뺀 곡만 있으면 아무것도 쓰지 않았다: 이유를 알리고 연동 안내는 띄우지 않는다.
            guard result.count > 0 || result.skipped.isEmpty else {
                store.stagingMessage = AppMessage(kind: .failure, text: result.skipped.joined(separator: "\n"))
                return
            }
            // 재생 목록 이름 "DJCrate 추가"는 XML에 쓰는 이름 그대로다(번역하지 않음).
            var text = String(ui: "\(result.count)곡을 연동 XML에 썼습니다 · rekordbox: rekordbox xml 새로고침 › \"DJCrate 추가\" › Import To Collection")
            if result.withoutGrid > 0 { text += " · " + String(ui: "\(result.withoutGrid)곡은 그리드 없이(rekordbox가 분석)") }
            if !result.skipped.isEmpty { text += "\n" + result.skipped.joined(separator: "\n") }
            store.stagingMessage = AppMessage(kind: result.withoutGrid > 0 || !result.skipped.isEmpty ? .warning : .success, text: text)
            RekordboxLink.showSetupIfNeeded(store.linkedXMLFile)
        } catch {
            store.stagingMessage = AppMessage(kind: .failure, text: String(ui: "내보내지 못했습니다. 저장 위치와 권한을 확인하세요: \(error.localizedDescription)"))
        }
    }
}
