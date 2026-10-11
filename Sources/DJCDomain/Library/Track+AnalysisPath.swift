import Foundation

extension Track {
    /// 분석 파일 자리(`AnalysisDataPath`는 share 뿌리 기준 `/PIONEER/USBANLZ/…`). 경로가 없으면 nil(파일 시스템은 보지 않는다)
    public func analysisURL(in share: URL) -> URL? {
        guard let path = analysisDataPath, !path.isEmpty else { return nil }
        return share.appending(path: String(path.drop(while: { $0 == "/" })))
    }
}
