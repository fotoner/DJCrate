import Foundation

/// djmdCue 한 행의 모양. USB에 쓸 때 확인하지 않은 모양인지 가리는 데만 쓴다.
public struct UsbCueTraits: Codable, Hashable, Sendable {
    /// 0 메모리, 1–3·5–9 핫, 4 모름
    public var kind: Int
    public var colorTableIndex: Int?
    /// 255·nil = 색 없음
    public var color: Int?
    /// 루프가 아니면 outMsec ≤ inMsec(보통 0 또는 -1)
    public var inMsec: Int
    public var outMsec: Int
    public var activeLoop: Int
    /// 상위 16비트 = 박 분자, 하위 = 분모
    public var beatLoopSize: Int
    public var inMpegFrame: Int

    public init(kind: Int, colorTableIndex: Int? = nil, color: Int? = nil, inMsec: Int, outMsec: Int,
                activeLoop: Int = 0, beatLoopSize: Int = 0, inMpegFrame: Int = 0) {
        self.kind = kind
        self.colorTableIndex = colorTableIndex
        self.color = color
        self.inMsec = inMsec
        self.outMsec = outMsec
        self.activeLoop = activeLoop
        self.beatLoopSize = beatLoopSize
        self.inMpegFrame = inMpegFrame
    }

    var isLoop: Bool { outMsec > inMsec }
    var isHot: Bool { (1...3).contains(kind) || (5...9).contains(kind) }
}

/// 곡 큐 모양 → 필요한 확인 안 된 규칙. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)에 있던 모양만 규칙 없이 통과한다.
public enum UsbCueRules {
    /// 그 곡 큐 전체에 대해 필요한 확인 안 된 규칙
    public static func rules(fileType: Int, cues: [UsbCueTraits]) -> Set<UsbProvisionalRule> {
        var rules: Set<UsbProvisionalRule> = []
        if cues.contains(where: isVariant) { rules.insert(.cueVariant) }
        // 탐색 칸은 MP3(프레임 0), M4A, FLAC에서만 보았다.
        let seekVerified = fileType == 4 || fileType == 5 || (fileType == 1 && cues.allSatisfy { $0.inMpegFrame == 0 })
        if !cues.isEmpty && !seekVerified { rules.insert(.cueSeekFields) }
        return rules
    }

    /// 핫큐 번호: Kind < 4면 Kind, 5…9면 Kind − 1, 4는 nil(빼고 경고)
    public static func hotCueNumber(kind: Int) -> Int? {
        switch kind {
        case 1...3: kind
        case 5...9: kind - 1
        default: nil
        }
    }

    private static func isVariant(_ cue: UsbCueTraits) -> Bool {
        if cue.isHot, let index = cue.colorTableIndex, index != 0 { return true }
        if cue.kind == 0, let color = cue.color, (1...8).contains(color) { return true }
        if cue.kind == 0 && cue.isLoop { return true }
        if cue.activeLoop != 0 { return true }
        if cue.isLoop {
            if cue.beatLoopSize == 0 { return true }
            let beats = cue.beatLoopSize >> 16, denominator = cue.beatLoopSize & 0xFFFF
            if ![8, 16].contains(beats) || denominator != 1 { return true }
        }
        // 핫큐 D·F·G·H(E만 확인)
        return [5, 7, 8, 9].contains(cue.kind)
    }
}
