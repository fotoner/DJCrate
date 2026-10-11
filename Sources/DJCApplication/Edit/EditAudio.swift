import DJCDomain
import Foundation

/// 편집 창 전용 재생기(덱과 따로). 실제는 DJCAdapters의 `EditAudioPlayer`를 조립 지점이 넣고, 시험에서는 가짜로 바꾼다.
@MainActor
public protocol EditAudio: AnyObject {
    /// 원곡을 메모리에 풀어 재생할 수 있다
    var isReady: Bool { get }
    var sampleRate: Double { get }
    var isPlaying: Bool { get }
    /// 재생을 시작한 뒤 들린 시간(초, 출력 지연을 뺌)
    var elapsed: Double { get }
    /// 원곡을 메모리에 푼다. 끝나면(실패하면 false) `done`을 부른다.
    func prepare(url: URL, done: @escaping @MainActor (Bool) -> Void)
    /// 예약표를 `frame`부터 재생한다. 소리를 낼 수 없으면 false.
    func play(_ items: [EditPlaybackItem], from frame: Int64, volume: Float) -> Bool
    func stop()
    /// 창을 닫을 때: 멈추고 메모리를 놓는다.
    func close()
}
