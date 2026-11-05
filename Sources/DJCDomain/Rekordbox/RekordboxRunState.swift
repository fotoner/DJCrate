/// rekordbox 실행 감지 결과(#323). 쓰기 관문의 확인(pgrep)과 앱의 감지 서비스(프로세스 목록)가 같은 이름 목록·같은 판정을 쓴다.
/// 꺼짐(`stopped`)만 쓰기를 막지 않는다. 확인하지 못하면 '모름'이고 켜진 것으로 다룬다(fail-closed).
public enum RekordboxRunState: Sendable, Equatable {
    /// rekordbox가 켜져 있다(rekordboxAgent는 상관없다)
    case running
    /// rekordbox는 꺼졌고 rekordboxAgent만 켜져 있다. 이때도 쓰지 않는다(SAFE-1)
    case agentOnly
    /// 둘 다 꺼져 있다
    case stopped
    /// 확인하지 못했다(실행 실패·시간 초과·목록 읽기 실패). 켜진 것으로 다룬다
    case unknown

    /// rekordbox 본체의 프로세스 이름
    public static let appName = "rekordbox"
    /// rekordbox 도우미의 프로세스 이름
    public static let agentName = "rekordboxAgent"
    /// 찾는 프로세스 이름. 본체를 먼저 본다. 이름이 정확히 같은 것만 센다(`pgrep -x`와 같다)
    public static let processNames = [appName, agentName]

    /// 켜져 있는 프로세스 이름 목록으로 판정한다
    public init(runningNames: some Sequence<String>) {
        let names = Set(runningNames)
        if names.contains(Self.appName) {
            self = .running
        } else if names.contains(Self.agentName) {
            self = .agentOnly
        } else {
            self = .stopped
        }
    }

    /// rekordbox 라이브러리·USB 쓰기와 LINK 포트 열기를 막는가. 꺼짐만 막지 않는다
    public var blocksWrites: Bool { self != .stopped }
}
