import AppKit
import DJCDomain
import Foundation
import UniformTypeIdentifiers

/// 라이브러리 XML 내보내기 저장 창. 연동 파일을 늘 같은 자리에 만드는 "XML 만들기"(`RekordboxLink`)와 달리 저장 위치를 고른다.
@MainActor
enum LibraryXMLPanels {
    static func export(store: LibraryStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = defaultFileName()
        // 연동 XML이 있는 Documents/DJCrate가 아니라 Documents에서 시작한다.
        panel.directoryURL = URL.documentsDirectory
        panel.canCreateDirectories = true
        panel.title = String(ui: "라이브러리 XML 내보내기")
        panel.message = String(ui: "라이브러리 전체(곡·큐·그리드·재생 목록)를 rekordbox XML 파일로 내보냅니다. rekordbox 라이브러리는 바뀌지 않으며, 쓰지 않은 초안은 넣지 않습니다.")
        panel.prompt = String(ui: "내보내기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.staging.exportLibraryXML(to: url)
    }

    /// rekordbox XML 가져오기 열기 창. 읽은 뒤 차이 미리 보기 시트가 열린다(rekordbox에는 쓰지 않는다).
    static func importXML(into model: XMLImportModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL.documentsDirectory
        panel.title = String(ui: "rekordbox XML 가져오기")
        panel.message = String(ui: "다른 도구나 rekordbox가 만든 rekordbox XML을 골라 지금 라이브러리와의 차이를 봅니다. 고른 차이만 초안으로 만들고 rekordbox에는 쓰지 않습니다.")
        panel.prompt = String(ui: "열기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.start(from: url)
    }

    /// 파일 이름은 번역하지 않는다.
    static func defaultFileName(now: Date = .now) -> String {
        "DJCrate-library-\(now.formatted(.iso8601.year().month().day())).xml"
    }
}
