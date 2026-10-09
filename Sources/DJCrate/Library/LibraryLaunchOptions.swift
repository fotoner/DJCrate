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

    init(selectTrackID: String? = nil, addFiles: [URL] = [], exportStaged: URL? = nil, isDiagnosticRun: Bool = false) {
        self.selectTrackID = selectTrackID
        self.addFiles = addFiles
        self.exportStaged = exportStaged
        self.isDiagnosticRun = isDiagnosticRun
    }

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        self.init(selectTrackID: value(after: "--select"),
                  addFiles: value(after: "--add-files").map { $0.split(separator: ",").map { URL(filePath: String($0)) } } ?? [],
                  exportStaged: value(after: "--export-staged").map { URL(filePath: $0) },
                  isDiagnosticRun: DiagnosticRun.isActive(arguments: arguments))
    }
}
