import Foundation

/// 개발용 실행 인자. 조립 지점이 실행 인자를 한 번 풀어 저장소에 넘긴다(화면 모델이 프로세스 인자를 다시 읽지 않게).
struct LibraryLaunchOptions: Equatable {
    /// `--select <ContentID>`: 처음 읽은 뒤 이 곡을 골라 덱에 올린다
    var selectTrackID: String?
    /// `--add-files <경로,…>`: 처음 읽은 뒤 이 파일들을 추가한다(`DJC_HOME`과 함께 쓴다)
    var addFiles: [URL] = []
    /// `--export-staged <파일>`: 추가한 곡의 그리드 추정이 끝나면 내보낼 파일
    var exportStaged: URL?
    /// 자가 테스트·성능 측정·화면 캡처로 띄운 실행(`DiagnosticRun`): 뒤에서 도는 디스크 일(자동 시점 스냅샷)을 돌리지 않는다
    var isDiagnosticRun = false
    /// `--first-run-read`: 진단 실행에서도 읽을 사본이 없으면 첫 실행처럼 바로 읽는다(첫 실행·읽기 실패 화면 캡처용, #299)
    var forcesFirstRunRead = false
    /// `DJC_HOME`만 주고 `DJC_REKORDBOX_DIR`은 주지 않은 실행: 사용자 데이터만 임시 폴더로 옮겼을 뿐 라이브러리와 읽기 사본 폴더는 실제 것이다
    /// (`DJC_HOME`은 읽기 사본 폴더를 옮기지 않는다). 이런 개발 실행이 실제 라이브러리를 자동으로 복사하지 않게 한다(SAFE-9·SAFE-11).
    var keepsRealLibraryOutOfDataHome = false

    init(selectTrackID: String? = nil, addFiles: [URL] = [], exportStaged: URL? = nil, isDiagnosticRun: Bool = false,
         forcesFirstRunRead: Bool = false, keepsRealLibraryOutOfDataHome: Bool = false) {
        self.selectTrackID = selectTrackID
        self.addFiles = addFiles
        self.exportStaged = exportStaged
        self.isDiagnosticRun = isDiagnosticRun
        self.forcesFirstRunRead = forcesFirstRunRead
        self.keepsRealLibraryOutOfDataHome = keepsRealLibraryOutOfDataHome
    }

    /// 읽을 사본이 없을 때 단추 없이 바로 읽는지. 진단 실행은 지금까지처럼 읽지 않는다(그 상태에 기대는 캡처 장면이 있다)
    var readsOnFirstRun: Bool { (!isDiagnosticRun || forcesFirstRunRead) && !keepsRealLibraryOutOfDataHome }

    init(arguments: [String], environment: [String: String] = [:]) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        self.init(selectTrackID: value(after: "--select"),
                  addFiles: value(after: "--add-files").map { $0.split(separator: ",").map { URL(filePath: String($0)) } } ?? [],
                  exportStaged: value(after: "--export-staged").map { URL(filePath: $0) },
                  isDiagnosticRun: DiagnosticRun.isActive(arguments: arguments),
                  forcesFirstRunRead: arguments.contains("--first-run-read"),
                  keepsRealLibraryOutOfDataHome: environment["DJC_HOME"] != nil && environment["DJC_REKORDBOX_DIR"]?.isEmpty != false)
    }
}
