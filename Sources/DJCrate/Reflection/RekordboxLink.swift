import DJCApplication
import DJCDomain
import Foundation

/// DJCrate ↔ rekordbox 연동 XML. 저장 창 없이 늘 같은 파일(조립 지점이 정한 `LibraryStore.linkedXMLFile`)에 쓴다.
/// rekordbox 환경설정 › 고급 › 데이터베이스 › rekordbox xml에 이 파일을 한 번만 지정하면,
/// 이후에는 rekordbox에서 트리 새로고침 → 재생 목록 → Import To Collection만 하면 된다. 절차는 연동 안내 창(`IntegrationGuide`)이 보인다.
@MainActor
enum RekordboxLink {
    /// 연동 파일의 폴더를 만들고 그 파일 자리를 돌려준다
    static func prepare(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// 처음 XML을 만들었을 때 한 번만 연동 안내 창을 저절로 연다. 그 뒤에는 도움말 메뉴 「연동 안내」로 연다(#315).
    /// 창을 열 입구가 없으면(조립 지점 없이 띄운 화면) 본 것으로 치지 않는다
    static func showSetupIfNeeded(store: LibraryStore) {
        guard !store.settings.value(SettingKeys.rekordboxLinkSetupShown), let show = store.showIntegrationGuide else { return }
        store.settings.set(SettingKeys.rekordboxLinkSetupShown, true)
        show(.rekordbox)
    }
}
