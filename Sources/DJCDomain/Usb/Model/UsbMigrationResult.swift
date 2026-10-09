import Foundation

/// 옮기기 계획 결과. `changes`가 있으면 `UsbWriter.write`로 쓴다
public struct UsbMigrationResult: Sendable {
    /// nil = 쓰지 않음(막힘)
    public var changes: UsbChangeSet?
    /// 두 형식 모델(OneLibrary 검증 기대값)
    public var library: UsbLibrary?
    /// 옮기기 전체를 막는 것
    public var blocks: [UsbBlock] = []
    public var notes: [String] = []
    public var trackCount = 0
    public var playlistCount = 0
    /// 새로 만드는 b 그림 수(같은 바이트가 이미 있어 다시 쓰지 않는 것은 빼고)
    public var artworkFiles = 0
    /// 쓰기 전 USB에 이미 있던 불변식 문제(Device Library 쪽). 검증은 이것을 빼고 새로 생긴 문제만 센다
    public var preexistingProblems: Set<String> = []

    public init() {}
}
