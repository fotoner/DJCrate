import DJCDomain
import Foundation

/// 후보 맞추기 결과를 사람이 읽는 문구로(#62). 판정은 `DJCDomain`의 `RelocateMatcher`가 하고, 여기는 글자만 만든다.
enum RelocateText {
    /// 후보가 어떤 근거로 맞는지: "이름 일치 · 크기 일치 · 길이 일치". 모르는 값은 말하지 않는다.
    static func evidence(_ evidence: RelocateEvidence) -> String {
        var parts: [String] = []
        switch evidence.name {
        case .exact: parts.append(String(ui: "이름 일치"))
        case .caseInsensitive: parts.append(String(ui: "이름 일치(대소문자 다름)"))
        case .stemOnly: parts.append(String(ui: "확장자만 다름"))
        case .different: break
        }
        switch evidence.size {
        case .equal: parts.append(String(ui: "크기 일치"))
        case .different: parts.append(String(ui: "크기 다름"))
        case .unknown: break
        }
        if evidence.duration == .equal { parts.append(String(ui: "길이 일치")) }
        if evidence.title == .equal { parts.append(String(ui: "제목 일치")) }
        if evidence.artist == .equal { parts.append(String(ui: "아티스트 일치")) }
        return parts.joined(separator: " · ")
    }

    /// 애매한 이유(무엇을 하면 되는지까지: 후보 중에서 고르거나 고르지 않는다).
    static func reason(_ reason: RelocateOutcome.AmbiguityReason) -> String {
        switch reason {
        case .severalCandidates: String(ui: "같은 정도로 맞는 후보가 여럿입니다. 알맞은 파일을 고르세요")
        case .sharedFile: String(ui: "다른 곡도 같은 파일을 후보로 삼습니다. 알맞은 곡에만 고르세요")
        case .differentExtension: String(ui: "확장자가 달라 같은 음원인지 직접 확인해야 합니다")
        case .weakEvidence: String(ui: "길이·크기로 확인된 근거가 모자랍니다. 직접 확인해 고르세요")
        }
    }

    /// 외장 디스크가 연결되지 않아 없는 곡에 붙이는 표시. 디스크가 연결돼 있는데 없는 곡은 nil(표시 없음).
    static func absence(_ absence: RelocateAbsence) -> String? {
        guard let name = absence.unmountedVolumeName else { return nil }
        return String(ui: "외장 디스크 연결 안 됨: \(name)")
    }

    static func filterTitle(_ filter: RelocateModel.Filter) -> String {
        switch filter {
        case .all: String(ui: "전체")
        case .confident: String(ui: "확실")
        case .ambiguous: String(ui: "애매")
        case .noCandidate: String(ui: "없음")
        }
    }

    static func progress(_ progress: RelocateProgress) -> String {
        switch progress.phase {
        case .listing: String(ui: "폴더의 음원 파일을 찾는 중… \(progress.audioFiles)개")
        case .reading: String(ui: "이름이나 크기가 맞는 파일의 길이와 태그를 읽는 중… \(progress.filesRead)/\(progress.filesToRead)")
        case .matching: String(ui: "후보를 맞추는 중…")
        }
    }
}
