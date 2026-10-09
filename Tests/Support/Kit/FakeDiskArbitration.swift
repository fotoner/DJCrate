import Foundation

/// DiskArbitration 설명 사전 픽스처. 키는 DA가 주는 이름 그대로, 값은 모두 지어낸 것(UUID·이름·제품 이름).
/// 디스크 이미지 값은 macOS가 `hdiutil attach`한 raw 이미지에 주는 모양을 따른다: DADeviceProtocol "Virtual Interface",
/// DADeviceModel "Disk Image", DADeviceInternal 키 없음.
public enum FakeDiskArbitration {
    public static let imageUUID = "00000000-0000-0000-0000-00000000D001"
    public static let physicalUUID = "00000000-0000-0000-0000-00000000D0A1"

    /// 디스크 이미지 파티션(FAT32)
    public static func diskImagePartition(bsd: String = "disk7s1", content: String = "DOS_FAT_32",
                                          volumeType: String? = "MS-DOS (FAT32)", uuid: String = imageUUID,
                                          name: String = "DJCTEST") -> [String: Any] {
        var description: [String: Any] = [
            "DADeviceProtocol": "Virtual Interface",
            "DADeviceModel": "Disk Image",
            "DAVolumeKind": "msdos",
            "DAMediaContent": content,
            "DAMediaBSDName": bsd,
            "DAMediaBlockSize": 512,
            "DAVolumeNetwork": false,
            "DAVolumeUUID": uuid,
            "DAVolumeName": name,
        ]
        if let volumeType { description["DAVolumeType"] = volumeType }
        return description
    }

    /// 디스크 이미지 전체 디스크(MBR)
    public static func diskImageWhole(bsd: String = "disk7", content: String = "FDisk_partition_scheme") -> [String: Any] {
        ["DAMediaContent": content, "DAMediaBSDName": bsd, "DADeviceModel": "Disk Image", "DADeviceProtocol": "Virtual Interface"]
    }

    /// 실물 USB 파티션(지어낸 제품 이름)
    public static func physicalUsbPartition(bsd: String = "disk9s1", content: String = "DOS_FAT_32",
                                            volumeType: String? = "MS-DOS (FAT32)", uuid: String = physicalUUID,
                                            name: String = "DJCPHYS") -> [String: Any] {
        var description: [String: Any] = [
            "DADeviceProtocol": "USB",
            "DADeviceModel": "Imaginary Flash 3000",
            "DADeviceInternal": false,
            "DAMediaRemovable": true,
            "DAVolumeKind": "msdos",
            "DAMediaContent": content,
            "DAMediaBSDName": bsd,
            "DAMediaBlockSize": 512,
            "DAVolumeNetwork": false,
            "DAVolumeUUID": uuid,
            "DAVolumeName": name,
        ]
        if let volumeType { description["DAVolumeType"] = volumeType }
        return description
    }

    public static func physicalUsbWhole(bsd: String = "disk9", content: String = "FDisk_partition_scheme") -> [String: Any] {
        ["DAMediaContent": content, "DAMediaBSDName": bsd, "DADeviceModel": "Imaginary Flash 3000", "DADeviceProtocol": "USB",
         "DADeviceInternal": false]
    }

    /// 내장 디스크의 APFS 볼륨
    public static func internalDisk() -> [String: Any] {
        ["DADeviceProtocol": "Apple Fabric", "DADeviceModel": "Imaginary SSD", "DADeviceInternal": true, "DAVolumeKind": "apfs",
         "DAMediaContent": "41504653-0000-11AA-AA11-00306543ECAC", "DAMediaBSDName": "disk3s5", "DAMediaBlockSize": 4096,
         "DAVolumeNetwork": false, "DAVolumeUUID": "00000000-0000-0000-0000-00000000D0B1", "DAVolumeName": "Data"]
    }

    /// 0x0B(FAT32) 파티션 안에 FAT16으로 포맷한 USB
    public static func fat16InFat32Partition() -> [String: Any] {
        physicalUsbPartition(content: "DOS_FAT_32", volumeType: "MS-DOS (FAT16)")
    }

    /// `hdiutil info -plist` 모양: 이미지 하나와 그 장치들
    public static func hdiutilInfo(imagePath: String, whole: String = "/dev/disk7", partition: String = "/dev/disk7s1",
                                   mountPoint: String? = nil) -> Data {
        var partitionEntity: [String: Any] = ["dev-entry": partition, "content-hint": "DOS_FAT_32"]
        if let mountPoint { partitionEntity["mount-point"] = mountPoint }
        let plist: [String: Any] = ["images": [["image-path": imagePath,
                                                "system-entities": [partitionEntity, ["dev-entry": whole, "content-hint": "FDisk_partition_scheme"]]]]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
