import DJCApplication
import DJCDomain
import AppKit
import SwiftUI

/// DJCrate ↔ rekordbox 연동 XML. 저장 창 없이 늘 같은 파일(조립 지점이 정한 `LibraryStore.linkedXMLFile`)에 쓴다.
/// rekordbox 환경설정 › 고급 › 데이터베이스 › rekordbox xml에 이 파일을 한 번만 지정하면,
/// 이후에는 rekordbox에서 트리 새로고침 → 재생 목록 → Import To Collection만 하면 된다.
@MainActor
enum RekordboxLink {
    /// 연동 파일의 폴더를 만들고 그 파일 자리를 돌려준다
    static func prepare(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// 처음 한 번만 rekordbox 설정 방법을 알려 주고 경로를 클립보드에 복사한다.
    static func showSetupIfNeeded(_ url: URL) {
        let key = "rekordboxLinkSetupShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        let alert = setupAlert(for: url)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    static func setupAlert(for url: URL) -> NSAlert {
        // 줄마다 번역한다. 재생 목록 이름 "DJCrate 반영"·"DJCrate 추가"는 XML에 쓰는 이름 그대로다.
        let details = [
            String(ui: "1. rekordbox › 환경설정 › 고급 › 데이터베이스 › rekordbox xml › \"가져온 라이브러리\"에 이 파일을 지정합니다(처음 한 번만)."),
            String(ui: "2. 트리에 \"rekordbox xml\"이 보이게 합니다(환경설정 › 보기 › 레이아웃에서 켤 수 있습니다)."),
            "",
            String(ui: "XML을 만든 뒤 rekordbox에서:"),
            String(ui: "• \"rekordbox xml\" 옆 새로고침 → 재생 목록 \"DJCrate 반영\"(새 곡은 \"DJCrate 추가\") → 곡 모두 선택 → 오른쪽 클릭 › Import To Collection"),
            String(ui: "• DJCrate에서 rekordbox와 동기화(⟳)를 누르면 곡마다 제대로 들어갔는지 자동으로 확인합니다."),
            "",
            String(ui: "처음 XML을 가져오기 전에 rekordbox › 파일 › 라이브러리 › 라이브러리 백업을 한 번 해 두세요."),
        ]
        let alert = AlertPrompter().makeAlert(ReflectionPrompt(
            title: String(ui: "rekordbox에 연동 파일을 한 번만 지정해 주세요"),
            text: String(ui: "DJCrate는 XML을 늘 이 파일에 만듭니다(경로를 클립보드에 복사했습니다):\n\(url.path)"),
            details: details))
        alert.addButton(withTitle: String(ui: "Finder에서 보기"))
        return alert
    }
}
