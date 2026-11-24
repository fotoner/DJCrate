import AppKit
import Foundation

/// 뷰가 직접 읽고 쓰는 화면 설정(`@AppStorage`·`ObservedSetting`)의 저장소. 보통은 사용자 환경설정(`UserDefaults.standard`)이다.
/// 자동 저장 자가 테스트 실행(`--auto-reflect-selftest`, 두 빌드 모두)은 임시 폴더의 영역에 쓴다: 메뉴(⌘2 등)나 화면이 설정을 바꿔도
/// 사용자 환경설정이 자가 테스트 전후로 같다(R18). SwiftUI 분할 보기의 칸 크기 자동 저장도 이 실행에서는 끈다
enum ViewPreferences {
    /// `@AppStorage(…, store:)`에 넘긴다. nil이면 사용자 환경설정이다(`UserDefaults`는 스레드에 안전하다)
    nonisolated(unsafe) static let store: UserDefaults? = DiagnosticRun.isAutoReflectSelfTest() ? isolated() : nil

    /// `ObservedSetting`처럼 저장소를 직접 받는 곳이 쓴다
    static var defaults: UserDefaults { store ?? .standard }

    /// 임시 폴더 안 경로를 영역 이름으로 쓰면 그 경로의 plist에 남는다(`~/Library/Preferences`에 남기지 않는다)
    private static func isolated() -> UserDefaults? {
        let name = "djc-view-preferences-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        return UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: name).path)
    }

    /// 창 안 분할 보기의 칸 크기 자동 저장을 끈다(자동 저장 자가 테스트 실행만). SwiftUI가 분할 보기에 붙이는 이름을 바꿀 수 없어
    /// 창에 붙는 첫 순간과 그 뒤 몇 번 더 본다
    @MainActor
    static func stopSplitViewAutosave(in window: NSWindow?) {
        guard store != nil, let content = window?.contentView else { return }
        func clear(_ view: NSView) {
            if let split = view as? NSSplitView, split.autosaveName != nil { split.autosaveName = nil }
            view.subviews.forEach(clear)
        }
        clear(content)
    }
}
