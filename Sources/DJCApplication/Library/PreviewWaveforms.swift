import DJCDomain
import Foundation

/// 곡 목록 미리 보기 파형 캐시(포트). 실제 구현은 DJCAdapters(`PreviewWaveforms.live`, 분석 파일에서 읽어 캐시에 둔다).
/// 칸의 그림(비트맵)은 화면이 그리고 메모리에만 둔다. 이 포트는 그림의 원자료(400칸)와 그 판만 준다.
public struct PreviewWaveforms: Sendable {
    /// 곡(UUID·분석 파일 경로)의 미리 보기 파형을 뒤에서 채운다
    public var warm: @Sendable (_ tracks: [(uuid: String, analysisPath: String?)], _ shareRoot: URL) async -> Void
    /// 칸 하나의 분석 파일 판(파일 크기·시각에서 만든 값, 이 프로세스 안에서만 견준다). 파일이 바뀌면 다른 값이다
    public var revision: @Sendable (_ key: String, _ analysisFile: URL?) async -> Int
    /// 칸 하나의 분석 파일 원자료(400칸). 없으면 nil
    public var waveform: @Sendable (_ key: String, _ analysisFile: URL?) async -> AnlzPreviewWaveform?
    /// 분석 파일에 파형이 없을 때 채울 음원 파형(400칸, 디스크 캐시 열쇠 = 곡 UUID). 음원을 풀어 분석하는 무거운 일이라
    /// 부르는 쪽(목록 그림 캐시 액터)이 한 번에 하나씩 부른다. 읽지 못하면 nil
    public var audioColumns: @Sendable (_ audio: URL, _ key: String) -> [WaveformColumn]?
    /// 캐시를 비운다(설정 › 저장 공간): 메모리와 파일을 함께. 다음 읽기·채우기가 분석 파일에서 다시 만든다
    public var clear: @Sendable () async -> Void
    /// USB 곡의 분석 파일 자리: 마운트한 볼륨(`root`) 안 .DAT(볼륨 뿌리 기준 경로)와 옆 .EXT가 링크를 거치지 않고
    /// 열지 않는 자리(`UsbLayout.neverRead`)도 아니면 .DAT 자리. 아니면 nil(열지 않는다). 막는 입출력이라 메인 밖에서 부른다
    public var volumeFile: @Sendable (_ root: URL, _ path: String) -> URL?

    public init(warm: @escaping @Sendable (_ tracks: [(uuid: String, analysisPath: String?)], _ shareRoot: URL) async -> Void,
                revision: @escaping @Sendable (_ key: String, _ analysisFile: URL?) async -> Int,
                waveform: @escaping @Sendable (_ key: String, _ analysisFile: URL?) async -> AnlzPreviewWaveform?,
                audioColumns: @escaping @Sendable (_ audio: URL, _ key: String) -> [WaveformColumn]?,
                clear: @escaping @Sendable () async -> Void,
                volumeFile: @escaping @Sendable (_ root: URL, _ path: String) -> URL?) {
        self.warm = warm
        self.revision = revision
        self.waveform = waveform
        self.audioColumns = audioColumns
        self.clear = clear
        self.volumeFile = volumeFile
    }

    /// 채우지도 읽지도 않는다(시험)
    public static let none = PreviewWaveforms(warm: { _, _ in }, revision: { _, _ in 0 }, waveform: { _, _ in nil }, audioColumns: { _, _ in nil },
                                              clear: {}, volumeFile: { _, _ in nil })
}
