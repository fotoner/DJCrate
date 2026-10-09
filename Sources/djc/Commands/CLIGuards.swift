import DJCApplication
import DJCDomain
import Foundation

/// CLI 명령이 공통으로 쓰는 거부 규칙. 동의는 플래그가 곧 동의이고(대화형 질문 없음), 거부는 오류로 던져 종료 코드를 0이 아니게 한다.
enum CLIGuards {
    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// 경로 비교용: 심볼릭 링크를 풀어 표준화한 경로(양쪽에 같은 함수를 쓴다)
    static func normalized(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// 실험 명령이 쓰는 DB가 라이브 DB이면 거부한다(`live`는 시험에서 가짜 자리를 줄 때만 바꾼다)
    static func refuseLiveDatabase(_ database: URL, live: URL = CLIComposition.live.location.database) throws {
        if normalized(database) == normalized(live) {
            throw Refusal(String(ui: "라이브 rekordbox DB에는 쓰지 않습니다. djc snapshot으로 만든 사본을 주세요"))
        }
    }

    /// 분석 파일 폴더(share)가 라이브 rekordbox 폴더이거나 실제 Pioneer 폴더 안이면 거부한다
    static func refuseLiveShare(_ share: URL, live: URL = CLIComposition.liveShare,
                                pioneer: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer")) throws {
        let analysis = normalized(share.appending(path: "PIONEER/USBANLZ"))
        if normalized(share) == normalized(live) || analysis.hasPrefix(normalized(pioneer)) {
            throw Refusal(String(ui: "라이브 rekordbox 분석 폴더에는 쓰지 않습니다. 사본 share를 주세요"))
        }
    }

    /// 파일을 만드는 명령의 덮어쓰기 규칙: 이미 있으면 `--overwrite`가 있어야 한다
    static func refuseExistingOutput(_ out: URL, overwrite: Bool) throws {
        if !overwrite, FileManager.default.fileExists(atPath: out.path) {
            throw Refusal(String(ui: "같은 이름의 파일이 이미 있습니다. 덮어쓰려면 --overwrite를 주거나 다른 이름을 고르세요"))
        }
    }
}
