@testable import DJCDomain
import DJCTestKit
import Foundation
import Testing

@Suite("실물 USB 쓰기 관문")
struct UsbPhysicalWriteGateTests {
    /// 코드 관문과 사용자 동의를 모두 연 관문(시험 전용 init)
    let open = UsbPhysicalWriteGate(consented: true, buildEnabled: true)

    func codes(_ blocks: [UsbBlock]) -> [String] { blocks.map(\.code) }

    @Test("사용자 동의(앱 확인 창·--allow-physical)가 없으면 막는다")
    func noConsentBlocks() {
        let gate = UsbPhysicalWriteGate()
        #expect(gate.consented == false)
        #expect(gate.isOpen == false)
        let blocks = gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["physicalDisabled"])
        #expect(blocks[0].rule == .physicalVolume)
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "실물 USB에 쓰려면 앱은 볼륨 이름을 확인하고 ‘USB에 쓰기’를 누르고, djc는 --allow-physical --confirm <볼륨 이름>을 주세요")
    }

    @Test("코드 관문이 닫혀 있으면 동의해도 막는다")
    func buildDisabledBlocksEvenIfConsented() {
        let gate = UsbPhysicalWriteGate(consented: true, buildEnabled: false)
        #expect(gate.isOpen == false)
        let blocks = gate.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "DJCPHYS")
        #expect(codes(blocks) == ["physicalDisabled"])
        #expect(blocks[0].message == "이 판에서는 실물 USB 쓰기가 닫혀 있습니다. 디스크 이미지로만 시험할 수 있습니다")
    }

    @Test("코드 관문은 열려 있다")
    func buildEnabled() {
        #expect(UsbPhysicalWriteGate.buildEnabled)
        #expect(FakeUsbVolume.gate(consented: true).isOpen)
    }

    @Test("동의하고 볼륨 이름이 맞으면 등록 없이 쓴다(USB 메모리·외장 SSD·SD 카드 리더·exFAT·GPT)")
    func consentedPassesWithoutRegistration() {
        for volume in [FakeUsbVolume.physicalFAT32(), FakeUsbVolume.externalSSD(), FakeUsbVolume.sdCardReader(),
                       FakeUsbVolume.exfat(), FakeUsbVolume.gpt(), FakeUsbVolume.thunderboltDisk()] {
            #expect(open.blocks(volume, confirmName: volume.name).isEmpty)
            #expect(FakeUsbVolume.gate(consented: true).blocks(volume, confirmName: volume.name).isEmpty)
        }
    }

    @Test("볼륨 이름 확인이 다르면 막는다")
    func confirmMismatchBlocks() {
        let blocks = open.blocks(FakeUsbVolume.physicalFAT32(), confirmName: "OTHER")
        #expect(codes(blocks) == ["confirmMismatch"])
        #expect(blocks[0].message == "볼륨 이름 확인이 맞지 않습니다. --confirm에 볼륨 이름(DJCPHYS)을 정확히 주세요")
        #expect(codes(open.blocks(FakeUsbVolume.physicalFAT32(), confirmName: nil)) == ["confirmMismatch"])
    }

    @Test("볼륨 UUID가 없으면 막는다(백업·저널을 볼륨별로 둘 수 없다)")
    func missingUUIDBlocks() {
        var volume = FakeUsbVolume.physicalFAT32()
        volume.volumeUUID = nil
        #expect(codes(open.blocks(volume, confirmName: volume.name)) == ["noVolumeUUID"])
    }

    @Test("디스크 이미지는 동의·이름 확인 없이 통과")
    func diskImagePasses() {
        #expect(UsbPhysicalWriteGate().blocks(FakeUsbVolume.diskImageFAT32(), confirmName: nil).isEmpty)
        #expect(UsbPhysicalWriteGate(consented: false, buildEnabled: false).blocks(FakeUsbVolume.diskImageFAT32(), confirmName: nil).isEmpty)
    }

    @Test("임시 폴더 밖에 붙은 디스크 이미지는 실물로 판정한다")
    func outsideScratchIsPhysical() {
        let image = FakeUsbVolume.diskImageFAT32()
        #expect(image.judgedForWrite(underScratch: true).isDiskImage)
        #expect(!image.judgedForWrite(underScratch: false).isDiskImage)
        #expect(!FakeUsbVolume.physicalFAT32().judgedForWrite(underScratch: true).isDiskImage)
        #expect(codes(UsbPhysicalWriteGate().blocks(image.judgedForWrite(underScratch: false), confirmName: nil)) == ["physicalDisabled"])
    }
}
