import DJCDomain
@testable import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// DiskArbitration 설명 사전 + statfs + hdiutil info → UsbVolumeInfo(순수 판정)
@Suite("USB 볼륨 정보")
struct UsbVolumesTests {
    /// 이미지 파일 하나(실제 파일이어야 realpath가 풀린다)
    func withImage(_ body: (String) throws -> Void) throws {
        let folder = "/private/tmp/djc-volumes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        FileManager.default.createFile(atPath: folder + "/t.img", contents: Data())
        try body(folder + "/t.img")
    }

    func facts(mountedOn: String = "/private/tmp/djc-mnt", type: String = "msdos", readOnly: Bool = false, root: Bool = false,
               local: Bool = true, from: String = "/dev/disk7s1") -> StatfsFacts {
        StatfsFacts(fileSystemTypeName: type, mountedOn: mountedOn, mountedFrom: from, blockSize: 4096, isReadOnly: readOnly,
                    isRootFileSystem: root, isLocal: local)
    }

    func make(_ description: [String: Any], whole: [String: Any]? = FakeDiskArbitration.diskImageWhole(), statfs: StatfsFacts? = nil,
              hdiutil: Data? = nil, root: String = "/private/tmp/djc-mnt", regular: Bool = true) -> UsbVolumeInfo {
        UsbVolumes.make(description: description, wholeDescription: whole, statfs: statfs ?? facts(), hdiutilInfo: hdiutil,
                        rootRealPath: root, isRegularFile: { _ in regular })
    }

    @Test("Virtual Interface·Disk Image 사전에 hdiutil 짝이 있으면 디스크 이미지")
    func protocolVirtualInterfaceIsImageWhenHdiutilPairs() throws {
        try withImage { image in
            let volume = make(FakeDiskArbitration.diskImagePartition(), hdiutil: FakeDiskArbitration.hdiutilInfo(imagePath: image))
            #expect(volume.isDiskImage)
            #expect(!volume.isInternal)
            #expect(volume.diskImagePath == image)
            #expect(volume.fileSystem == .fat32)
            #expect(volume.partitionScheme == .mbr)
            #expect(volume.partitionIndex == 1)
            #expect(volume.sectorSize == 512)
            #expect(volume.clusterSize == 4096)
            #expect(volume.volumeUUID == FakeDiskArbitration.imageUUID)
            #expect(volume.name == "DJCTEST")
            #expect(volume.rootIsMountPoint)
            #expect(UsbVolumePolicy.problems(volume, purpose: .export).isEmpty)
        }
    }

    @Test("Disk Image 모델이어도 hdiutil 짝이 없으면 실물(내장으로 보고 막는다)")
    func modelDiskImageWithoutHdiutilPairIsPhysical() throws {
        try withImage { image in
            let unrelated = FakeDiskArbitration.hdiutilInfo(imagePath: image, whole: "/dev/disk20", partition: "/dev/disk20s1")
            for hdiutil in [unrelated, nil] {
                let volume = make(FakeDiskArbitration.diskImagePartition(), hdiutil: hdiutil)
                #expect(!volume.isDiskImage)
                #expect(volume.isInternal)
                #expect(volume.diskImagePath == nil)
            }
        }
    }

    @Test("image-path가 일반 파일이 아니거나 없으면 실물")
    func imagePathNotRegularFileIsPhysical() throws {
        try withImage { image in
            #expect(!make(FakeDiskArbitration.diskImagePartition(), hdiutil: FakeDiskArbitration.hdiutilInfo(imagePath: image), regular: false).isDiskImage)
            #expect(!make(FakeDiskArbitration.diskImagePartition(),
                          hdiutil: FakeDiskArbitration.hdiutilInfo(imagePath: "/private/tmp/djc-none-\(UUID().uuidString).img")).isDiskImage)
        }
    }

    @Test("연결 방식·이동식 매체 여부를 읽는다(외장 SSD는 고정 디스크, 모르면 nil)")
    func readsProtocolAndRemovable() {
        let stick = make(FakeDiskArbitration.physicalUsbPartition(), whole: FakeDiskArbitration.physicalUsbWhole())
        #expect(stick.deviceProtocol == "USB")
        #expect(stick.isRemovable == true)
        var ssd = FakeDiskArbitration.physicalUsbPartition()
        ssd["DAMediaRemovable"] = false
        #expect(make(ssd, whole: FakeDiskArbitration.physicalUsbWhole()).isRemovable == false)
        var unknown = FakeDiskArbitration.physicalUsbPartition()
        unknown["DAMediaRemovable"] = nil
        unknown["DADeviceProtocol"] = nil
        let volume = make(unknown, whole: FakeDiskArbitration.physicalUsbWhole())
        #expect(volume.isRemovable == nil)
        #expect(volume.deviceProtocol == nil)
        // 파티션에 값이 없으면 전체 디스크 값을 본다
        var whole = FakeDiskArbitration.physicalUsbWhole()
        whole["DAMediaRemovable"] = true
        #expect(make(unknown, whole: whole).isRemovable == true)
    }

    @Test("hdiutil 출력이 깨졌으면 실물")
    func hdiutilFailureIsPhysical() {
        #expect(!make(FakeDiskArbitration.diskImagePartition(), hdiutil: Data("not a plist".utf8)).isDiskImage)
    }

    @Test("모델 키가 없으면 실물")
    func modelMissingIsPhysical() throws {
        try withImage { image in
            var description = FakeDiskArbitration.diskImagePartition()
            description["DADeviceModel"] = nil
            #expect(!make(description, hdiutil: FakeDiskArbitration.hdiutilInfo(imagePath: image)).isDiskImage)
        }
    }

    @Test("Protocol \"Disk Image\"만으로는 이미지가 아니다")
    func protocolDiskImageAloneIsNotEnough() throws {
        try withImage { image in
            var description = FakeDiskArbitration.diskImagePartition()
            description["DADeviceModel"] = nil
            description["DADeviceProtocol"] = "Disk Image"
            #expect(!make(description, hdiutil: FakeDiskArbitration.hdiutilInfo(imagePath: image)).isDiskImage)
        }
    }

    @Test("실물 USB는 DADeviceInternal 키 값대로")
    func physicalUsbInternalFalseFromKey() {
        let volume = make(FakeDiskArbitration.physicalUsbPartition(), whole: FakeDiskArbitration.physicalUsbWhole())
        #expect(!volume.isDiskImage)
        #expect(!volume.isInternal)
        #expect(volume.fileSystem == .fat32)
        #expect(volume.volumeUUID == FakeDiskArbitration.physicalUUID)
        let internalDisk = make(FakeDiskArbitration.internalDisk(), whole: ["DAMediaContent": "GUID_partition_scheme"],
                                statfs: facts(type: "apfs"))
        #expect(internalDisk.isInternal)
        #expect(internalDisk.fileSystem == .apfs)
        #expect(internalDisk.partitionScheme == .gpt)
        #expect(internalDisk.sectorSize == 4096)
    }

    @Test("루트가 마운트 지점인지는 realpath끼리(/tmp·/private/tmp 둘 다)")
    func rootIsMountPointUsesRealpath() throws {
        let folder = "/private/tmp/djc-rootcheck-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for given in [folder, folder.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")] {
            let real = try #require(UsbScratchRoots.realPath(given))
            #expect(make(FakeDiskArbitration.diskImagePartition(), statfs: facts(mountedOn: folder), root: real).rootIsMountPoint)
        }
        #expect(!make(FakeDiskArbitration.diskImagePartition(), statfs: facts(mountedOn: folder), root: folder + "/sub").rootIsMountPoint)
    }

    @Test("0x0B 파티션 안의 FAT16은 FAT16으로 보고 막는다")
    func fat16InFat32PartitionRefused() throws {
        let volume = make(FakeDiskArbitration.fat16InFat32Partition(), whole: FakeDiskArbitration.physicalUsbWhole())
        #expect(volume.fileSystem == .fat16)
        #expect(volume.partitionContent == "DOS_FAT_32")
        let export = UsbVolumePolicy.problems(volume, purpose: .export)
        #expect(export.contains { $0.code == "unsupportedFileSystem" && $0.message.hasPrefix("이 USB 형식(FAT16)에는") })
        #expect(UsbVolumePolicy.problems(volume, purpose: .edit).contains { $0.code == "unsupportedFileSystem" })
        // 이 볼륨으로 쓰기: 가드와 무관한 마운트 확인 말고는 파일 연산 없이 막힌다
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.volume = volume
        fixture.volume.isDiskImage = true
        let fs = fixture.fileSystem()
        do {
            try fixture.write(fixture.exportChanges(), fileSystem: fs)
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code).contains("unsupportedFileSystem"))
        }
        #expect(fs.calls == ["mountedOn ."])
        // DAVolumeType이 없으면 모르는 msdos(fail-closed)
        var unknown = FakeDiskArbitration.fat16InFat32Partition()
        unknown["DAVolumeType"] = nil
        let other = make(unknown, whole: FakeDiskArbitration.physicalUsbWhole())
        #expect(other.fileSystem == .other("msdos"))
        #expect(UsbVolumePolicy.problems(other, purpose: .export).contains { $0.code == "unsupportedFileSystem" })
    }

    @Test("모양 조합", arguments: [
        ("fat32-0x0B", "DOS_FAT_32", "MS-DOS (FAT32)", "msdos"), ("fat32-0x0C", "Windows_FAT_32", "MS-DOS (FAT32)", "msdos"),
        ("fat16", "DOS_FAT_16", "MS-DOS (FAT16)", "msdos"), ("fat12", "DOS_FAT_12", "MS-DOS (FAT12)", "msdos"),
        ("exfat", "Windows_NTFS", "ExFAT", "exfat"), ("hfs", "Apple_HFS", "Mac OS Extended", "hfs"),
    ])
    func shapes(name: String, content: String, volumeType: String, kind: String) {
        var description = FakeDiskArbitration.physicalUsbPartition(content: content, volumeType: volumeType)
        description["DAVolumeKind"] = kind
        let volume = make(description, whole: FakeDiskArbitration.physicalUsbWhole())
        let expected: UsbFileSystemKind = switch name {
        case "fat32-0x0B", "fat32-0x0C": .fat32
        case "fat16": .fat16
        case "fat12": .fat12
        case "exfat": .exfat
        default: .hfsPlus
        }
        #expect(volume.fileSystem == expected)
        #expect(UsbVolumePolicy.problems(volume, purpose: .export).contains { $0.code == "unsupportedFileSystem" }
            == (expected != .fat32 && expected != .exfat))
    }

    @Test("GPT FAT32(두 번째 파티션)는 FAT32로 보고 쓴다. 네트워크·읽기 전용·4096 섹터")
    func otherShapes() {
        let gpt = make(FakeDiskArbitration.physicalUsbPartition(bsd: "disk9s2", content: "Microsoft Basic Data"),
                       whole: FakeDiskArbitration.physicalUsbWhole(content: "GUID_partition_scheme"))
        #expect(gpt.partitionScheme == .gpt)
        #expect(gpt.partitionIndex == 2)
        #expect(gpt.fileSystem == .fat32)
        #expect(UsbVolumePolicy.problems(gpt, purpose: .export).isEmpty)
        #expect(UsbVolumePolicy.warnings(gpt).map(\.code) == ["gpt"])
        var network = FakeDiskArbitration.physicalUsbPartition()
        network["DAVolumeNetwork"] = true
        #expect(make(network).isNetwork)
        #expect(make(FakeDiskArbitration.physicalUsbPartition(), statfs: facts(readOnly: true)).isReadOnly)
        #expect(make(FakeDiskArbitration.physicalUsbPartition(), statfs: facts(mountedOn: "/")).isRootVolume)
        var big = FakeDiskArbitration.physicalUsbPartition()
        big["DAMediaBlockSize"] = 4096
        #expect(UsbVolumePolicy.problems(make(big, whole: FakeDiskArbitration.physicalUsbWhole()), purpose: .export).isEmpty)
        // 파티션 표가 없는 USB(전체 디스크가 곧 볼륨)
        #expect(make(FakeDiskArbitration.physicalUsbPartition(bsd: "disk9"), whole: nil).partitionScheme == .none)
    }

    @Test("CFUUID 값도 대문자 문자열로")
    func uuidFromCFUUID() {
        var description = FakeDiskArbitration.physicalUsbPartition()
        description["DAVolumeUUID"] = CFUUIDCreateFromString(nil, "0000abcd-0000-0000-0000-000000000001" as CFString)
        #expect(make(description).volumeUUID == "0000ABCD-0000-0000-0000-000000000001")
    }
}
