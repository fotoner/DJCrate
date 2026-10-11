import Foundation

/// 저장된 탐색 위치가 현재 음원과 다른 이유. 쓰기 허용 여부나 계산 규칙은 바꾸지 않는다.
public enum SeekDiagnostics {
    public static func pvbr(stored: Data, current: Data, frames: SeekInfo.Mp3Frames) -> String {
        guard stored.count == 1620, current.count == 1620,
              stored.prefix(16) == current.prefix(16) else { return "PVBR 형식이 달라 비교할 수 없습니다" }
        let old = stored.suffix(4).reduce(0) { $0 << 8 | Int($1) }
        let new = current.suffix(4).reduce(0) { $0 << 8 | Int($1) }
        if old == 0, new > 0, stored.dropFirst(16).allSatisfy({ $0 == 0 }) {
            return "저장 PVBR 전체 샘플 미기록(0); 현재 음원에는 완전한 프레임이 있습니다. rekordbox에서 재분석해 확인하세요"
        }
        if frames.hasInfoFrame, stored.dropLast(4) == current.dropLast(4),
           old == frames.offsets.count * frames.samplesPerFrame,
           new == (frames.offsets.count - 1) * frames.samplesPerFrame {
            return "저장값은 정보 프레임 포함, 현재 규칙은 제외(한 프레임 차이); 생성 당시 규칙은 미확인입니다. 재분석 전후 비교가 필요합니다"
        }
        return "PVBR 원인 미확인(저장 샘플 \(old), 현재 \(new)); rekordbox에서 재분석 전후를 비교하세요"
    }

    public static func pvb2(stored: Data, current: Data) -> String {
        guard stored.count == 8032, current.count == 8032,
              stored.prefix(16) == current.prefix(16),
              stored[24..<32] == current[24..<32] else { return "PVB2 형식이 달라 비교할 수 없습니다" }
        let sameLayout = stored[16..<24] == current[16..<24] && stride(from: 32, to: 8032, by: 20).allSatisfy {
            stored[$0..<$0 + 8] == current[$0..<$0 + 8] && stored[$0 + 16..<$0 + 20] == current[$0 + 16..<$0 + 20]
        }
        if sameLayout, stored != current {
            return "전체 샘플·시작 샘플·블록 크기는 같고 바이트 위치만 다름; 현재 압축 프레임 배치와 저장 탐색표가 다릅니다"
        }
        return "PVB2 샘플·블록 또는 머리 값 차이로 원인 미확인; rekordbox에서 재분석 전후를 비교하세요"
    }

    public static func mp3Cue(stored: Int, counted: [Int]) -> String {
        guard let first = counted.first else { return "현재 음원 프레임 없음; 파일을 확인하세요" }
        let relative = counted.map { $0 - first }
        if relative.contains(stored) {
            return "저장 위치의 프레임 경계는 맞음; 큐 시각·계산 규칙 차이는 재분석 전후 비교가 필요합니다"
        }
        let lower = relative.last { $0 < stored }.map(String.init) ?? "없음"
        let upper = relative.first { $0 > stored }.map(String.init) ?? "없음"
        return "저장 위치는 현재 음원의 프레임 경계가 아님(이웃 \(lower)/\(upper)); 파일 변경·옛 큐 생성 규칙 중 원인은 미확인입니다"
    }
}
