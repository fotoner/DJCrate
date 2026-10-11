import DJCDomain
import DJCTestKit
import Foundation
import Testing

@Suite("USB 볼륨 정책")
struct UsbVolumePolicyTests {
    func codes(_ volume: UsbVolumeInfo, _ purpose: UsbVolumePurpose = .export) -> [String] {
        UsbVolumePolicy.problems(volume, purpose: purpose).map(\.code)
    }

    func warnings(_ volume: UsbVolumeInfo) -> [String] {
        UsbVolumePolicy.warnings(volume).map(\.code)
    }

    @Test("디스크 이미지 FAT32·MBR은 내보내고 고칠 수 있다")
    func diskImageFAT32MBRPasses() {
        #expect(codes(FakeUsbVolume.diskImageFAT32()).isEmpty)
        #expect(codes(FakeUsbVolume.diskImageFAT32(), .edit).isEmpty)
        #expect(warnings(FakeUsbVolume.diskImageFAT32()).isEmpty)
    }

    @Test("FAT32는 파티션 형식(0x0B·0x0C·GPT 기본 데이터)과 무관하게 통과")
    func fat32Passes() {
        #expect(codes(FakeUsbVolume.physicalFAT32(content: "DOS_FAT_32")).isEmpty)
        #expect(codes(FakeUsbVolume.windowsFAT32()).isEmpty)
        var unknown = FakeUsbVolume.physicalFAT32()
        unknown.partitionContent = nil
        #expect(codes(unknown).isEmpty)
    }

    @Test("exFAT은 쓰되 이전 기기가 읽지 못할 수 있다고 알린다")
    func exfatPassesWithWarning() {
        #expect(codes(FakeUsbVolume.exfat()).isEmpty)
        #expect(codes(FakeUsbVolume.exfat(), .edit).isEmpty)
        #expect(warnings(FakeUsbVolume.exfat()) == ["exfat"])
        #expect(UsbVolumePolicy.warnings(FakeUsbVolume.exfat())[0].message
            == "exFAT USB는 CDJ-2000NXS2 등 이전 기기가 읽지 못할 수 있습니다")
    }

    @Test("GPT는 쓰되 일부 기기가 읽지 못할 수 있다고 알린다(두 번째 파티션이어도)")
    func gptPassesWithWarning() {
        #expect(codes(FakeUsbVolume.gpt()).isEmpty)
        #expect(codes(FakeUsbVolume.gpt(), .edit).isEmpty)
        #expect(warnings(FakeUsbVolume.gpt()) == ["gpt"])
        #expect(UsbVolumePolicy.warnings(FakeUsbVolume.gpt())[0].message
            == "GPT로 포맷한 USB는 일부 기기가 읽지 못할 수 있습니다. 기기에서 읽히지 않으면 MBR로 포맷하세요")
        var both = FakeUsbVolume.gpt()
        both.fileSystem = .exfat
        #expect(warnings(both) == ["exfat", "gpt"])
    }

    @Test("외장 SSD·SD 카드 리더·Thunderbolt 디스크·두 번째 파티션·4096바이트 섹터도 통과")
    func widerDevicesPass() {
        for volume in [FakeUsbVolume.externalSSD(), FakeUsbVolume.sdCardReader(), FakeUsbVolume.thunderboltDisk(),
                       FakeUsbVolume.secondPartition(), FakeUsbVolume.sector4096()] {
            #expect(codes(volume).isEmpty)
        }
    }

    @Test("rekordbox USB가 아닌 파일 시스템(FAT16·HFS+·APFS·NTFS 등)은 막는다")
    func otherFileSystemsBlocked() {
        for volume in [FakeUsbVolume.fat16(), FakeUsbVolume.hfsPlus(), FakeUsbVolume.apfs()] {
            #expect(codes(volume) == ["unsupportedFileSystem"])
        }
        var ntfs = FakeUsbVolume.physicalFAT32()
        ntfs.fileSystem = .other("ntfs")
        #expect(codes(ntfs) == ["unsupportedFileSystem"])
        let message = UsbVolumePolicy.problems(FakeUsbVolume.apfs(), purpose: .export)[0].message
        #expect(message == "이 USB 형식(APFS)에는 rekordbox 라이브러리를 쓸 수 없습니다. FAT32나 exFAT로 포맷한 뒤 다시 시도하세요")
    }

    @Test("MBR·GPT가 아닌 파티션(APM·파티션 표 없음·모름)은 막는다")
    func otherPartitionSchemesBlocked() {
        for scheme in [UsbPartitionScheme.apm, .none, .unknown] {
            var volume = FakeUsbVolume.physicalFAT32()
            volume.partitionScheme = scheme
            #expect(codes(volume) == ["partitionScheme"])
        }
    }

    @Test func internalBlocked() {
        #expect(codes(FakeUsbVolume.internal()) == ["internal"])
    }

    @Test func networkBlocked() {
        #expect(codes(FakeUsbVolume.network()) == ["network"])
    }

    @Test func readOnlyBlocked() {
        #expect(codes(FakeUsbVolume.readOnly()) == ["readOnly"])
    }

    @Test func rootVolumeBlocked() {
        #expect(codes(FakeUsbVolume.rootVolume()) == ["rootVolume"])
    }

    @Test func notMountPointBlocked() {
        #expect(codes(FakeUsbVolume.notMountPoint()) == ["notMountPoint"])
        let problem = UsbVolumePolicy.problems(FakeUsbVolume.notMountPoint(), purpose: .export)[0]
        #expect(problem.message == "USB 볼륨의 맨 위 폴더를 고르세요")
    }

    @Test("Time Machine 디스크(APFS·GPT)는 파일 시스템으로 막힌다")
    func timeMachineBlocked() {
        var volume = FakeUsbVolume.apfs()
        volume.name = "Time Machine"
        #expect(codes(volume) == ["unsupportedFileSystem"])
    }

    @Test("판정 순서대로 모두 낸다")
    func problemsFollowOrder() {
        var volume = FakeUsbVolume.apfs()
        volume.isReadOnly = true
        volume.partitionScheme = .apm
        #expect(codes(volume) == ["readOnly", "unsupportedFileSystem", "partitionScheme"])
    }

    @Test("읽기는 모든 모양을 허용한다")
    func readPurposeHasNoProblems() {
        let volumes = [FakeUsbVolume.exfat(), FakeUsbVolume.gpt(), FakeUsbVolume.internal(), FakeUsbVolume.readOnly(),
                       FakeUsbVolume.notMountPoint(), FakeUsbVolume.sector4096(), FakeUsbVolume.apfs()]
        for volume in volumes {
            #expect(UsbVolumePolicy.problems(volume, purpose: .read).isEmpty)
        }
    }

    @Test("막힘은 볼륨 범위로 같은 code·문구를 쓴다")
    func blocksMirrorProblems() {
        let blocks = UsbVolumePolicy.blocks(FakeUsbVolume.readOnly(), purpose: .export)
        #expect(blocks.map(\.code) == ["readOnly"])
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "USB가 읽기 전용으로 연결됐습니다. 잠금 스위치를 풀고 다시 연결하세요")
        #expect(blocks[0].rule == nil)
    }
}
