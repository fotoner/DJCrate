import DJCDomain
import Foundation

/// 곡 목록 미리 보기 파형(유스케이스): 라이브러리를 읽은 뒤 뒤에서 채우고, 목록 칸이 그림의 원자료(400칸)와 그 판을 읽고, 설정 › 저장 공간이 비운다.
/// 칸의 그림(비트맵)은 화면이 그리고 메모리에만 둔다(`PreviewWaveformCache`). 원자료는 포트(`PreviewWaveforms`)로 읽는다.
public struct ShowPreviewWaveforms: Sendable {
    let previews: PreviewWaveforms

    public init(previews: PreviewWaveforms) {
        self.previews = previews
    }

    /// 곡 목록의 미리 보기 파형을 뒤에서 채운다(스트리밍 곡은 분석 파일이 없어 뺀다)
    public func warm(_ rows: [TrackRow], shareRoot: URL) async {
        let sources = rows.filter { !$0.track.isStreaming }.map { (uuid: $0.track.uuid, analysisPath: $0.track.analysisDataPath) }
        await previews.warm(sources, shareRoot)
    }

    /// 칸 하나의 분석 파일 판(파일이 바뀌면 다른 값이다)
    public func revision(key: String, analysisFile: URL?) async -> Int { await previews.revision(key, analysisFile) }

    /// 칸 하나의 분석 파일 원자료(400칸). 없으면 nil
    public func waveform(key: String, analysisFile: URL?) async -> AnlzPreviewWaveform? { await previews.waveform(key, analysisFile) }

    /// 분석 파일에 파형이 없을 때 채울 음원 파형(400칸). 무거운 일이라 부르는 쪽이 한 번에 하나씩 부른다. 읽지 못하면 nil
    public var audioColumns: @Sendable (_ audio: URL, _ key: String) -> [WaveformColumn]? { previews.audioColumns }

    /// USB 곡의 분석 파일 자리(볼륨 안, 링크를 거치거나 열지 않는 자리면 nil). 막는 입출력이라 메인 밖에서 부른다
    public func volumeFile(root: URL, path: String) -> URL? { previews.volumeFile(root, path) }

    /// 캐시를 비운다(메모리와 파일). 다음 읽기·채우기가 분석 파일에서 다시 만든다
    public func clear() async { await previews.clear() }
}
