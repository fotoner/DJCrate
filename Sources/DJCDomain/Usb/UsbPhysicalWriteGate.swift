import Foundation

/// 실물 USB(디스크 이미지가 아닌 것)에 쓸 수 있는지 정하는 관문. 한 번에 처음 걸린 막힘 하나만 낸다.
///
/// 볼륨 모양(FAT32·exFAT, MBR·GPT, 내장·시동·읽기 전용이 아님)은 `UsbVolumePolicy`가 본다. 이 관문은
/// 코드 관문(`buildEnabled`) → 사용자 동의(앱은 볼륨 이름·용량을 보인 내보내기 시트·쓰기 확인 창의 쓰기 버튼, CLI는 `--allow-physical`) →
/// 볼륨 UUID가 있음 → 볼륨 이름 확인(앱은 확인 창에 보인 이름, CLI는 `--confirm`)만 본다. 볼륨을 미리 등록하지 않는다.
public struct UsbPhysicalWriteGate: Sendable {
    /// 코드 관문. 실기기에서 문제가 나오면 이 값 하나로 모든 실물 쓰기를 닫는다(동의·인자와 무관).
    public static let buildEnabled = true

    /// 사용자가 이 실물 USB 쓰기에 동의했는지: 앱은 볼륨 줄을 보인 내보내기 시트·쓰기 확인 창을 거친 쓰기, CLI는 `--allow-physical`. 기본 없음
    public let consented: Bool
    /// 시험 전용
    let buildEnabledOverride: Bool

    public init(consented: Bool = false) {
        self.init(consented: consented, buildEnabled: Self.buildEnabled)
    }

    /// `@testable` 시험만 쓴다: 코드 상수와 무관하게 관문 뒤쪽 판정을 시험한다.
    init(consented: Bool, buildEnabled: Bool) {
        self.consented = consented
        self.buildEnabledOverride = buildEnabled
    }

    /// 코드 관문과 사용자 동의가 둘 다 열렸는지(볼륨별 판정은 `blocks`)
    public var isOpen: Bool { buildEnabledOverride && consented }

    /// 실물 쓰기가 닫혀 있을 때의 막힘(코드 관문 → 동의 순)
    public var closedBlock: UsbBlock? {
        if !buildEnabledOverride {
            return UsbBlock(code: "physicalDisabled", scope: .volume,
                            message: String(ui: "이 판에서는 실물 USB 쓰기가 닫혀 있습니다. 디스크 이미지로만 시험할 수 있습니다"),
                            rule: .physicalVolume)
        }
        if !consented {
            return UsbBlock(code: "physicalDisabled", scope: .volume,
                            message: String(ui: "실물 USB에 쓰려면 앱은 볼륨 이름을 확인하고 ‘USB에 쓰기’를 누르고, djc는 --allow-physical --confirm <볼륨 이름>을 주세요"),
                            rule: .physicalVolume)
        }
        return nil
    }

    public func blocks(_ volume: UsbVolumeInfo, confirmName: String?) -> [UsbBlock] {
        if volume.isDiskImage { return [] }
        if let closedBlock { return [closedBlock] }
        guard let uuid = volume.volumeUUID, !uuid.isEmpty else { return [Self.noUUIDBlock] }
        if confirmName != volume.name {
            return [UsbBlock(code: "confirmMismatch", scope: .volume,
                             message: String(ui: "볼륨 이름 확인이 맞지 않습니다. --confirm에 볼륨 이름(\(volume.name))을 정확히 주세요"))]
        }
        return []
    }

    static var noUUIDBlock: UsbBlock {
        UsbBlock(code: "noVolumeUUID", scope: .volume, message: String(ui: "USB의 볼륨 UUID를 읽지 못해 쓰지 않습니다. USB를 다시 연결한 뒤 시도하세요"))
    }
}
