import Foundation

/// USB에 쓰기 전에 보는 환경. 앱·CLI는 `UsbWriteGuard.system`(DJCStorage), 시험은 가짜를 준다.
/// 값만 있다(#167: 유스케이스가 조립 지점의 가드를 그대로 받아 쓰기 절차 `UsbWriter`에 넘기도록 DJCDomain에 둔다).
/// 실물 쓰기가 닫혀 있는 동안은 이 값과 무관하게 임시 폴더 아래 루트만 받는다(거짓 가드 하나로 뚫리지 않게).
public struct UsbWriteGuard: Sendable {
    /// 루트 → 볼륨 정보(읽기만, 부작용 없음)
    public var volume: @Sendable (URL) throws -> UsbVolumeInfo
    public var isRekordboxRunning: @Sendable () -> Bool
    /// 이 안(또는 이것을 품은 곳)은 USB로 보지 않는다(rekordbox 라이브러리·DJCrate 데이터 폴더 등)
    public var protectedRoots: [URL]
    public var gate: UsbPhysicalWriteGate

    public init(volume: @escaping @Sendable (URL) throws -> UsbVolumeInfo, isRekordboxRunning: @escaping @Sendable () -> Bool,
                protectedRoots: [URL], gate: UsbPhysicalWriteGate) {
        self.volume = volume
        self.isRekordboxRunning = isRekordboxRunning
        self.protectedRoots = protectedRoots
        self.gate = gate
    }
}
