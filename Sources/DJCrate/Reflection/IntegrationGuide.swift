import DJCDomain
import Foundation
import Observation

/// 연동 안내 창(#315)의 내용. rekordbox·Apple Music과 이어 쓰는 절차는 여기 한 곳에만 있다(STR-14·STR-23).
/// 도움말 메뉴 「연동 안내」가 언제든 열고, XML 만들기 결과 줄과 Apple Music 가져오기 창은 [가져오는 방법] 링크로 이 창의 해당 쪽을 연다.
enum IntegrationGuide {
    enum Topic: CaseIterable, Hashable, Sendable {
        case rekordbox, appleMusic

        /// 앱 이름이라 번역하지 않는다
        var title: String {
            switch self {
            case .rekordbox: "rekordbox"
            case .appleMusic: "Apple Music"
            }
        }

        /// 절차 줄. 빈 줄은 묶음 사이 간격이다. 재생 목록 이름 "DJCrate 반영"·"DJCrate 추가"는 XML에 쓰는 이름 그대로다(STR-6).
        var lines: [String] {
            switch self {
            case .rekordbox:
                [
                    String(ui: "1. rekordbox › 환경설정 › 고급 › 데이터베이스 › rekordbox xml › \"가져온 라이브러리\"에 이 파일을 지정합니다(처음 한 번만)."),
                    String(ui: "2. 트리에 \"rekordbox xml\"이 보이게 합니다(환경설정 › 보기 › 레이아웃에서 켤 수 있습니다)."),
                    "",
                    String(ui: "XML을 만든 뒤 rekordbox에서:"),
                    String(ui: "• \"rekordbox xml\" 옆 새로고침 → 재생 목록 \"DJCrate 반영\"(새 곡은 \"DJCrate 추가\") → 곡 모두 선택 → 오른쪽 클릭 › Import To Collection"),
                    String(ui: "• DJCrate에서 rekordbox와 동기화(⟳)를 누르면 곡마다 제대로 들어갔는지 자동으로 확인합니다."),
                    "",
                    String(ui: "처음 XML을 가져오기 전에 rekordbox › 파일 › 라이브러리 › 라이브러리 백업을 한 번 해 두세요."),
                ]
            case .appleMusic:
                [String(ui: "Music의 파일 › 보관함 › 보관함 내보내기에서 XML을 저장하세요. 재생 목록 내보내기에서 XML을 골라도 됩니다.")]
            }
        }
    }

    /// [Finder에서 보기]가 가리킬 곳. 연동 파일이 있으면 그 파일, 아직 만들기 전이면 있는 가장 가까운 폴더다
    static func revealTarget(for file: URL, exists: (URL) -> Bool) -> URL {
        var target = file
        while !exists(target), target.path != "/" { target = target.deletingLastPathComponent() }
        return target
    }
}

/// 연동 안내 창의 화면 모델(MVVM-1). 보는 쪽(`Topic`)과 연동 파일 자리만 든다. 복사·Finder는 창이 잇는 클로저로 한다
@MainActor
@Observable
final class IntegrationGuideModel {
    var topic: IntegrationGuide.Topic
    /// DJCrate가 XML을 늘 만드는 한 파일(조립 지점이 정한 `LibraryStore.linkedXMLFile`)
    let xmlFile: URL
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private let reveal: (URL) -> Void

    init(xmlFile: URL, topic: IntegrationGuide.Topic, copy: @escaping (String) -> Void, reveal: @escaping (URL) -> Void) {
        self.xmlFile = xmlFile
        self.topic = topic
        self.copy = copy
        self.reveal = reveal
    }

    var path: String { xmlFile.path }

    func copyPath() { copy(path) }
    func revealInFinder() { reveal(xmlFile) }
}
