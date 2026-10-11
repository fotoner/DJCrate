import DJCDomain
import Foundation

/// 시험용 USB 볼륨 모양. 이름·UUID는 지어낸 값만 쓴다.
/// 기본은 rekordbox가 쓰는 모양(MBR 첫 파티션 FAT32, 512바이트 섹터, 마운트 지점이 루트)이다.
public enum FakeUsbVolume {
    public static let physicalUUID = "00000000-0000-0000-0000-0000000000A1"

    /// 디스크 이미지로 만든 FAT32(파티션 형식 0x0C → Windows_FAT_32)
    public static func diskImageFAT32(name: String = "DJCTEST", uuid: String = "00000000-0000-0000-0000-000000000001") -> UsbVolumeInfo {
        var volume = base(name: name, uuid: uuid, content: "Windows_FAT_32")
        volume.isDiskImage = true
        volume.diskImagePath = "/private/tmp/djc-fixture/\(name).img"
        volume.deviceProtocol = "Virtual Interface"
        volume.isRemovable = false
        return volume
    }

    /// 실물 USB FAT32(rekordbox로 만든 USB는 파티션 형식 0x0B → DOS_FAT_32)
    public static func physicalFAT32(uuid: String = physicalUUID, name: String = "DJCPHYS", content: String = "DOS_FAT_32") -> UsbVolumeInfo {
        base(name: name, uuid: uuid, content: content)
    }

    /// 실물 USB FAT32, 파티션 형식 0x0C
    public static func windowsFAT32() -> UsbVolumeInfo {
        physicalFAT32(content: "Windows_FAT_32")
    }

    public static func fat16() -> UsbVolumeInfo {
        var volume = physicalFAT32(content: "DOS_FAT_16")
        volume.fileSystem = .fat16
        return volume
    }

    public static func exfat() -> UsbVolumeInfo {
        var volume = physicalFAT32(content: "Windows_NTFS")
        volume.fileSystem = .exfat
        return volume
    }

    public static func hfsPlus() -> UsbVolumeInfo {
        var volume = physicalFAT32(content: "Apple_HFS")
        volume.fileSystem = .hfsPlus
        volume.partitionScheme = .gpt
        volume.partitionIndex = 2
        return volume
    }

    public static func apfs() -> UsbVolumeInfo {
        var volume = physicalFAT32(content: "41504653-0000-11AA-AA11-00306543ECAC")
        volume.fileSystem = .apfs
        volume.partitionScheme = .gpt
        volume.partitionIndex = 2
        return volume
    }

    /// GPT 위의 FAT32(macOS 디스크 유틸리티 기본 "GUID 파티션 맵")
    public static func gpt() -> UsbVolumeInfo {
        var volume = physicalFAT32(content: "Microsoft Basic Data")
        volume.partitionScheme = .gpt
        volume.partitionIndex = 2
        return volume
    }

    public static func `internal`() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.isInternal = true
        return volume
    }

    public static func network() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.isNetwork = true
        return volume
    }

    public static func readOnly() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.isReadOnly = true
        return volume
    }

    public static func rootVolume() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.isRootVolume = true
        return volume
    }

    public static func secondPartition() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.partitionIndex = 2
        return volume
    }

    public static func sector4096() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.sectorSize = 4096
        return volume
    }

    /// USB로 붙었지만 고정 디스크로 보이는 외장 SSD
    public static func externalSSD() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.isRemovable = false
        return volume
    }

    /// USB가 아닌 연결(Thunderbolt 등)의 FAT32 디스크
    public static func thunderboltDisk() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.deviceProtocol = "PCI-Express"
        return volume
    }

    /// USB SD 카드 리더에 꽂은 SD 카드
    public static func sdCardReader() -> UsbVolumeInfo {
        var volume = physicalFAT32(name: "DJCSD")
        volume.deviceProtocol = "USB"
        volume.isRemovable = true
        return volume
    }

    /// 볼륨 안의 하위 폴더를 대상으로 고른 경우
    public static func notMountPoint() -> UsbVolumeInfo {
        var volume = physicalFAT32()
        volume.rootIsMountPoint = false
        return volume
    }

    /// 가짜 실물 USB의 용량(`physicalFAT32`)
    public static let physicalCapacity: Int64 = 16_000_000_000

    /// 공개 init만 쓰는 관문. 코드 관문(`buildEnabled`)은 상수 그대로, 사용자 동의(앱 쓰기 확인 창·`--allow-physical`)는 기본 없음
    public static func gate(consented: Bool = false) -> UsbPhysicalWriteGate {
        UsbPhysicalWriteGate(consented: consented)
    }

    private static func base(name: String, uuid: String, content: String) -> UsbVolumeInfo {
        UsbVolumeInfo(mountPoint: "/Volumes/\(name)", rootIsMountPoint: true, volumeUUID: uuid, name: name,
                      fileSystem: .fat32, partitionContent: content, partitionScheme: .mbr, partitionIndex: 1,
                      sectorSize: 512, clusterSize: 32_768, isInternal: false, isNetwork: false, isReadOnly: false,
                      isRootVolume: false, isDiskImage: false, diskImagePath: nil,
                      capacity: physicalCapacity, available: 8_000_000_000, deviceProtocol: "USB", isRemovable: true)
    }
}
