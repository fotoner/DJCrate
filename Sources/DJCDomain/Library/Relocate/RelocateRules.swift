import Foundation

/// 파일 없는 곡의 새 위치 후보를 맞추는 기준과 허용 오차(#62). 값은 한 곳에 모으고 `RelocateMatcherTests`가 고정한다.
/// 이 기준은 읽기만 하는 맞추기용이다. rekordbox가 Relocate에서 무엇으로 찾는지는 아직 실험으로 확인하지 않았다(#62 S62).
public enum RelocateRules {
    // MARK: 점수표 — 모든 근거가 맞으면 100점

    /// 정규화(NFC)한 파일 이름이 글자까지 같다. 파일 시스템에 따라 NFD로 오는 이름은 NFC로 맞춰 비교한다.
    public static let exactNamePoints = 40
    /// 대소문자만 다르다.
    public static let foldedNamePoints = 36
    /// 확장자만 다르다(예: 같은 곡을 FLAC에서 MP3로 바꾼 파일). 확장자가 다르면 확실로 올리지 않는다.
    public static let stemOnlyPoints = 20
    /// 파일 크기가 바이트까지 같다.
    public static let sizePoints = 25
    /// 길이가 허용 오차 안이다.
    public static let durationPoints = 20
    /// 태그 제목이 같다(정규화·대소문자·앞뒤 공백을 무시).
    public static let titlePoints = 10
    /// 태그 아티스트가 같다.
    public static let artistPoints = 5

    // MARK: 허용 오차와 문턱

    /// 길이 허용 오차(초, 경계 포함). 곡 행의 길이는 초 단위로 버린 값이라 파일 길이가 1초 가까이 길 수 있다.
    /// 양쪽 길이를 알고 이 오차를 넘으면 다른 파일로 보고 후보에서 뺀다.
    public static let durationToleranceSeconds = 2.0
    /// 이 점수 밑이면 후보로 치지 않는다.
    public static let candidateScore = 40
    /// 이 점수 이상이고 하나뿐이며 확장자가 같을 때만 확실로 친다. 이름·크기·길이가 모두 맞으면 85점이다.
    public static let confidentScore = 80
    /// 1위와 이 점수 안쪽(경계 포함)인 후보는 같은 급으로 보고 애매로 돌린다. 같은 파일이 두 곳에 있는 경우 등을 사람에게 맡긴다.
    public static let ambiguityGap = 10
    /// 애매한 곡에 보여 줄 후보 수(점수 높은 순).
    public static let maxOptionsPerTrack = 5
}
