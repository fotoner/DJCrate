import DJCDomain
import Foundation
import RekordboxKit

/// 실험용 읽기만 지원한다. pyrekordbox(MIT)의 칸 배치를 참고했다(제3자 고지 참조). XOR 규칙은 `AnlzMasks`를 쓴다.
struct PhraseStructure {
    struct Entry {
        let beat: Int
        let kind: Int
    }

    let mood: Int
    let bank: Int
    let endBeat: Int
    let masked: Bool
    let entries: [Entry]

    init(data: Data) throws {
        var bytes = [UInt8](data)
        func word(_ offset: Int, _ width: Int = 2) -> Int {
            bytes[offset..<offset + width].reduce(0) { $0 * 256 + Int($1) }
        }
        let invalid = DJCError.invalidAnalysisFile("PSSI 형식을 확인할 수 없어 rekordbox 분석 사본을 다시 준비하세요")
        guard bytes.count >= 32, Array(bytes.prefix(4)) == Array("PSSI".utf8),
              word(4, 4) == 32, word(8, 4) == bytes.count, word(12, 4) == 24 else { throw invalid }
        let count = word(16)
        guard bytes.count == 32 + count * 24 else { throw invalid }
        masked = !(1...3).contains(word(18))
        if masked { bytes = [UInt8](AnlzMasks.unmaskPSSI(Data(bytes))) }
        mood = word(18); bank = Int(bytes[30]); endBeat = word(26)
        guard (1...3).contains(mood) else { throw invalid }
        var decoded: [Entry] = []
        for i in 0..<count {
            let p = 32 + i * 24, beat = word(p + 2)
            guard word(p) == i + 1, beat > (decoded.last?.beat ?? 0), beat < endBeat else { throw invalid }
            decoded.append(Entry(beat: beat, kind: word(p + 4)))
        }
        entries = decoded
    }
}
