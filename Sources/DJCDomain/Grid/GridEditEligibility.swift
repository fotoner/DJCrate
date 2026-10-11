import CryptoKit
import Foundation

public enum GridEditEligibility {
    /// PQTZ와 재생성 박은 ms 정수이므로 빼기 전에 같은 단위로 맞춘다.
    public static func reconstructionErrorMilliseconds(original: BeatGrid, rebuilt: BeatGrid) -> Double {
        original.beats.map { abs((rebuilt.snap($0.time) * 1000).rounded() - ($0.time * 1000).rounded()) }.max() ?? 0
    }

    /// 원본을 템포 구간으로 바꿨다가 다시 만든 박과의 최대 차이(ms). 2를 넘는 원본은 구간 편집으로 다룰 수 없다.
    public static func reconstructionErrorMilliseconds(of original: BeatGrid, duration: Double) -> Double {
        guard let last = original.beats.last else { return 0 }
        let rebuilt = GridDraft(trackUUID: "", grid: original).grid(duration: max(duration + 1, last.time + 0.01))
        return reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt)
    }
}

public extension GridDraft {
    /// 현재 원본에서 지원되는 단일 구간으로 명시 대체할 때만 승인한다.
    func approvingReplacement(of original: BeatGrid, duration: Double) -> GridDraft? {
        guard let source = Self.sourceFingerprint(original), supportsReplacement(of: original, duration: duration) else { return nil }
        var approved = self
        approved.replacementSource = source
        return approved
    }

    func isVerifiedReplacement(of original: BeatGrid, duration: Double) -> Bool {
        guard let replacementSource, let source = Self.sourceFingerprint(original),
              replacementSource == source else { return false }
        return supportsReplacement(of: original, duration: duration)
    }

    private func supportsReplacement(of original: BeatGrid, duration: Double) -> Bool {
        guard !trackUUID.isEmpty, base == Self.segments(from: original),
              segments.count == 1, let segment = segments.first,
              duration.isFinite, duration > 0, duration < Double(UInt32.max) / 1000 else { return false }
        guard segment.start.isFinite, abs(segment.start) < Double(UInt32.max) / 1000, segment.start < duration,
              (20...655.35).contains(segment.bpm), (1...4).contains(segment.firstBeatNumber) else { return false }
        var withoutApproval = self
        withoutApproval.replacementSource = nil
        if withoutApproval.hasChanges { return true }
        let fresh = GridDraft(trackUUID: trackUUID, grid: original)
        let rebuilt = fresh.grid(duration: max(duration + 1, original.beats.last!.time + 0.01))
        return GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: rebuilt) > 2
    }

    private static func sourceFingerprint(_ grid: BeatGrid) -> String? {
        guard !grid.beats.isEmpty, grid.beats.allSatisfy({
            $0.time.isFinite && $0.time >= 0 && $0.time <= Double(UInt32.max) / 1000
                && (20...655.35).contains($0.bpm) && (1...4).contains($0.number)
        }), zip(grid.beats, grid.beats.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return nil }
        // 구간화는 interior 박의 차이를 잃으므로 전체 박의 번호·BPM·시각을 확인한다.
        var data = Data()
        for beat in grid.beats {
            for value in [UInt64(beat.number), beat.bpm.bitPattern, beat.time.bitPattern] {
                var bigEndian = value.bigEndian
                withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
