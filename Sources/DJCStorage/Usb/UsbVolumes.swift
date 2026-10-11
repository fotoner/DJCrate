import DJCDomain
import Darwin
import DiskArbitration
import Foundation
import RekordboxKit

/// statfs(2) 결과 중 쓰는 칸(순수 판정 함수의 입력)
struct StatfsFacts: Sendable, Hashable {
    /// f_fstypename, 예 "msdos"
    var fileSystemTypeName: String
    /// f_mntonname(커널이 준 그대로 — realpath 모양)
    var mountedOn: String
    /// f_mntfromname, 예 "/dev/disk7s1"
    var mountedFrom: String
    /// f_bsize(클러스터 크기)
    var blockSize: Int
    var isReadOnly: Bool
    var isRootFileSystem: Bool
    var isLocal: Bool

    static func read(_ path: String) -> StatfsFacts? {
        var info = Darwin.statfs()
        guard statfs(path, &info) == 0 else { return nil }
        func text<T>(_ value: inout T) -> String {
            withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let flags = Int32(truncatingIfNeeded: info.f_flags)
        return StatfsFacts(fileSystemTypeName: text(&info.f_fstypename), mountedOn: text(&info.f_mntonname),
                           mountedFrom: text(&info.f_mntfromname), blockSize: Int(info.f_bsize),
                           isReadOnly: flags & MNT_RDONLY != 0, isRootFileSystem: flags & MNT_ROOTFS != 0, isLocal: flags & MNT_LOCAL != 0)
    }
}

/// 마운트된 USB 볼륨 정보: DiskArbitration 설명 사전 + statfs + `hdiutil info` 짝.
/// 디스크 이미지는 셋(DA 모델 "Disk Image", hdiutil에 그 장치의 이미지가 있음, 그 image-path가 일반 파일)이 모두 맞을 때만 참이고,
/// 모르면 실물로 본다(실물 쓰기 관문에 걸리게).
public enum UsbVolumes {
    public static func info(root: URL, runner: any UsbToolRunner = SystemToolRunner()) throws -> UsbVolumeInfo {
        guard let rootReal = UsbScratchRoots.realPath(root.path), let facts = StatfsFacts.read(rootReal) else {
            throw UsbError.readFailed(detail: "statfs \(root.path): \(String(cString: strerror(errno)))")
        }
        let bsd = facts.mountedFrom.hasPrefix("/dev/") ? String(facts.mountedFrom.dropFirst(5)) : facts.mountedFrom
        var description: [String: Any] = [:]
        var whole: [String: Any]?
        if let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) {
            description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
            if let wholeDisk = DADiskCopyWholeDisk(disk) { whole = DADiskCopyDescription(wholeDisk) as? [String: Any] }
        }
        var hdiutil: Data?
        if description[kDADiskDescriptionDeviceModelKey as String] as? String == diskImageModel,
           let result = try? runner.run("/usr/bin/hdiutil", ["info", "-plist"]), result.status == 0 {
            hdiutil = result.stdout
        }
        var volume = make(description: description, wholeDescription: whole, statfs: facts, hdiutilInfo: hdiutil, rootRealPath: rootReal,
                          isRegularFile: isRegularFile)
        let values = try? URL(filePath: rootReal).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        volume.capacity = Int64(values?.volumeTotalCapacity ?? 0)
        volume.available = Int64(values?.volumeAvailableCapacity ?? 0)
        return volume
    }

    /// 마운트된 볼륨 전부(시동 볼륨 빼고). 읽지 못한 볼륨은 뺀다
    public static func mounted(runner: any UsbToolRunner = SystemToolRunner()) -> [UsbVolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" }.compactMap { try? info(root: $0, runner: runner) }
    }

    static let diskImageModel = "Disk Image"

    static func isRegularFile(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// 순수: DA 설명 사전 + statfs 값 + hdiutil info plist → UsbVolumeInfo.
    /// rootRealPath = realpath(3)(root). isRegularFile = lstat으로 일반 파일인지(주입)
    static func make(description: [String: Any], wholeDescription: [String: Any]?, statfs: StatfsFacts, hdiutilInfo: Data?,
                     rootRealPath: String, isRegularFile: (String) -> Bool) -> UsbVolumeInfo {
        let bsd = description["DAMediaBSDName"] as? String
        var partitionIndex: Int?
        var wholeBSD = bsd
        if let bsd, let range = bsd.range(of: #"s[0-9]+$"#, options: .regularExpression), bsd.hasPrefix("disk") {
            partitionIndex = Int(bsd[range].dropFirst())
            wholeBSD = String(bsd[..<range.lowerBound])
        }
        let content = description["DAMediaContent"] as? String
        let fileSystem = fileSystemKind(kind: (description["DAVolumeKind"] as? String)?.lowercased(),
                                        volumeType: description["DAVolumeType"] as? String, content: content)
        let scheme: UsbPartitionScheme
        if partitionIndex == nil {
            // 파티션 표 없이 디스크 전체가 볼륨이다
            scheme = .none
        } else {
            switch wholeDescription?["DAMediaContent"] as? String {
            case "FDisk_partition_scheme"?: scheme = .mbr
            case "GUID_partition_scheme"?: scheme = .gpt
            case "Apple_partition_scheme"?: scheme = .apm
            default: scheme = .unknown
            }
        }
        var imagePath: String?
        if description["DADeviceModel"] as? String == diskImageModel, let hdiutilInfo, let wholeBSD {
            for image in hdiutilImages(hdiutilInfo) where image.devices.contains("/dev/" + wholeBSD) {
                if let real = UsbScratchRoots.realPath(image.path), isRegularFile(real) { imagePath = real }
            }
        }
        let isDiskImage = imagePath != nil
        return UsbVolumeInfo(
            mountPoint: statfs.mountedOn, rootIsMountPoint: rootRealPath == statfs.mountedOn,
            volumeUUID: uuidString(description["DAVolumeUUID"]), name: description["DAVolumeName"] as? String
                ?? (statfs.mountedOn as NSString).lastPathComponent,
            fileSystem: fileSystem, partitionContent: content, partitionScheme: scheme, partitionIndex: partitionIndex,
            sectorSize: (description["DAMediaBlockSize"] as? NSNumber)?.intValue, clusterSize: statfs.blockSize,
            // 키가 없는데 디스크 이미지로 확인되지 않으면 내장으로 보고 막는다
            isInternal: (description["DADeviceInternal"] as? Bool) ?? !isDiskImage,
            isNetwork: (description["DAVolumeNetwork"] as? Bool) ?? !statfs.isLocal,
            isReadOnly: statfs.isReadOnly, isRootVolume: statfs.mountedOn == "/" || statfs.isRootFileSystem,
            isDiskImage: isDiskImage, diskImagePath: imagePath, capacity: 0, available: 0,
            // 참고용(판정에 쓰지 않는다)
            deviceProtocol: description["DADeviceProtocol"] as? String,
            isRemovable: (description["DAMediaRemovable"] as? Bool) ?? (wholeDescription?["DAMediaRemovable"] as? Bool))
    }

    /// FAT32는 DAVolumeKind msdos + DAVolumeType "MS-DOS (FAT32)"(파일 시스템 자체가 알린 형식). 파티션 형식은 MBR(0x0B·0x0C)·GPT(기본 데이터)마다
    /// 달라 보지 않는다. 형식을 모르는 msdos는 막는다
    static func fileSystemKind(kind: String?, volumeType: String?, content: String?) -> UsbFileSystemKind {
        switch kind {
        case "msdos"?:
            let fat16Content = ["DOS_FAT_16", "Windows_FAT_16", "DOS_FAT_16_S"].contains(content ?? "")
            switch volumeType {
            case "MS-DOS (FAT32)"?: return .fat32
            case "MS-DOS (FAT16)"?: return .fat16
            case "MS-DOS (FAT12)"?: return .fat12
            default: return fat16Content ? .fat16 : .other("msdos")
            }
        case "exfat"?: return .exfat
        case "hfs"?: return .hfsPlus
        case "apfs"?: return .apfs
        case let other?: return .other(other)
        case nil: return .other("unknown")
        }
    }

    static func uuidString(_ value: Any?) -> String? {
        if let text = value as? String { return text.uppercased() }
        if let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            // swiftlint:disable:next force_cast
            return (CFUUIDCreateString(nil, (value as! CFUUID)) as String).uppercased()
        }
        return nil
    }

    /// `hdiutil info -plist`의 이미지들: image-path(받은 철자 그대로)와 장치 dev-entry·마운트 지점
    struct HdiutilImage {
        var path: String
        var devices: [String]
        var entities: [[String: Any]]
    }

    static func hdiutilImages(_ data: Data) -> [HdiutilImage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return HdiutilImage(path: path, devices: entities.compactMap { $0["dev-entry"] as? String }, entities: entities)
        }
    }
}
