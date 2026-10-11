import Foundation

/// 편집 결과를 파일로 렌더하지 않고 원본(메모리에 푼 PCM)에서 바로 재생하는 예약 한 칸.
///
/// 렌더러(`EditRenderer`)가 쓰는 프레임과 같다: 조각 본문은 원본을 그대로, 이음새 앞 섞는 구간은 앞 조각 끝을 줄이고
/// 뒤 조각 바로 앞 원본을 키운다. 원본 프레임이 음수·길이 밖이면 무음이다.
public struct EditPlaybackItem: Sendable, Equatable {
    public struct Fade: Sendable, Equatable {
        /// 키우는 쪽(뒤 조각 바로 앞 원본) 첫 프레임
        public var sourceFrame: Int64
        /// 이 칸의 첫 프레임이 섞는 구간의 몇 번째인지(중간부터 재생하면 0보다 크다)
        public var position: Int64
        public var length: Int64

        public init(sourceFrame: Int64, position: Int64, length: Int64) {
            self.sourceFrame = sourceFrame
            self.position = position
            self.length = length
        }
    }

    /// 출력 프레임(재생 시작 프레임을 빼면 재생 노드 샘플)
    public var outputFrame: Int64
    public var frameCount: Int64
    /// 원본 첫 프레임. 섞는 칸이면 줄이는 쪽(앞 조각 끝)
    public var sourceFrame: Int64
    public var fade: Fade?

    public init(outputFrame: Int64, frameCount: Int64, sourceFrame: Int64, fade: Fade? = nil) {
        self.outputFrame = outputFrame
        self.frameCount = frameCount
        self.sourceFrame = sourceFrame
        self.fade = fade
    }
}

public extension TrackEdit {
    /// 섞는 구간 `k`번째 프레임에서 키우는 쪽 세기(줄이는 쪽은 1 − 이 값). 렌더러와 재생이 함께 쓴다.
    static func crossfadeGain(_ k: Int64, of length: Int64) -> Float {
        length > 0 ? (Float(k) + 0.5) / Float(length) : 1
    }

    /// 출력 0프레임부터 끝까지의 예약표. 조각 본문 → 이음새 섞기 → 다음 조각 본문 … 순서로 빈틈없이 이어진다.
    static func playbackItems(_ spans: [EditFrameSpan]) -> [EditPlaybackItem] {
        var items: [EditPlaybackItem] = []
        for (index, span) in spans.enumerated() {
            if index > 0, span.crossfadeFrames > 0 {
                let before = spans[index - 1], fade = span.crossfadeFrames
                items.append(EditPlaybackItem(outputFrame: span.outputFrame - fade, frameCount: fade,
                                              sourceFrame: before.sourceFrame + before.frameCount - fade,
                                              fade: .init(sourceFrame: span.sourceFrame - fade, position: 0, length: fade)))
            }
            let hold = index + 1 < spans.count ? spans[index + 1].crossfadeFrames : 0
            if span.frameCount - hold > 0 {
                items.append(EditPlaybackItem(outputFrame: span.outputFrame, frameCount: span.frameCount - hold, sourceFrame: span.sourceFrame))
            }
        }
        return items
    }
}

public extension Array where Element == EditPlaybackItem {
    /// `frame`부터 재생할 칸: 앞은 버리고 걸친 칸은 앞을 잘라 낸다.
    func starting(at frame: Int64) -> [EditPlaybackItem] {
        compactMap { item in
            guard item.outputFrame + item.frameCount > frame else { return nil }
            let skip = Swift.max(0, frame - item.outputFrame)
            var trimmed = item
            trimmed.outputFrame += skip
            trimmed.frameCount -= skip
            trimmed.sourceFrame += skip
            trimmed.fade?.sourceFrame += skip
            trimmed.fade?.position += skip
            return trimmed
        }
    }
}
