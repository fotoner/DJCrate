import DJCDomain
import DJCTestKit
import Foundation
import Testing

@Suite("USB 규칙 확인")
struct UsbRuleCheckTests {
    let physical = FakeUsbVolume.physicalFAT32()
    let image = FakeUsbVolume.diskImageFAT32()

    @Test("실물이면 관문 결과를 낸다(동의 전에는 막힘)")
    func physicalReportsGate() {
        let blocks = UsbRuleCheck.blocks(required: [], volume: physical, gate: FakeUsbVolume.gate(), confirmName: physical.name)
        #expect(blocks.map(\.code) == ["physicalDisabled"])
        #expect(blocks.map(\.rule) == [.physicalVolume])
    }

    @Test("확인 안 된 규칙은 기기 기록 행 옮기기 말고 막지 않는다(디스크 이미지·실물 모두)")
    func provisionalRulesDoNotBlock() {
        let all = Set(UsbProvisionalRule.allCases)
        let gate = FakeUsbVolume.gate(consented: true)
        for volume in [image, physical] {
            let blocks = UsbRuleCheck.blocks(required: all, volume: volume, gate: gate, confirmName: volume.name)
            #expect(blocks.map(\.code) == ["provisional"])
            #expect(blocks.map(\.rule) == [.carriedDeviceRows])
            #expect(blocks[0].scope == .volume)
            #expect(blocks[0].message == "확인하지 않은 규칙(\(UsbProvisionalRule.carriedDeviceRows.summary))이 필요해 이 USB에 쓸 수 없습니다")
            #expect(UsbRuleCheck.blocks(required: [.cueVariant, .artworkMissing, .settingFiles, .editRefreshTracks], volume: volume,
                                        gate: gate, confirmName: volume.name).isEmpty)
        }
    }

    @Test("실물 볼륨 규칙은 관문으로만 본다")
    func physicalVolumeRuleIsGateOnly() {
        let closed = UsbRuleCheck.blocks(required: [.physicalVolume], volume: physical, gate: FakeUsbVolume.gate(), confirmName: physical.name)
        #expect(closed.map(\.code) == ["physicalDisabled"])
        let open = UsbRuleCheck.blocks(required: [.physicalVolume], volume: physical, gate: FakeUsbVolume.gate(consented: true),
                                       confirmName: physical.name)
        #expect(open.isEmpty == UsbPhysicalWriteGate.buildEnabled)
    }
}
