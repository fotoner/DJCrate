import Foundation

public enum UsbFileSystemKind: Codable, Hashable, Sendable {
    case fat32, fat16, fat12, exfat, hfsPlus, apfs
    case other(String)

    /// 문구에 넣는 이름(번역하지 않는 형식 이름)
    public var displayName: String {
        switch self {
        case .fat32: "FAT32"
        case .fat16: "FAT16"
        case .fat12: "FAT12"
        case .exfat: "exFAT"
        case .hfsPlus: "HFS+"
        case .apfs: "APFS"
        case let .other(name): name
        }
    }
}

public enum UsbPartitionScheme: String, Codable, Sendable {
    case mbr, gpt, apm, none, unknown
}

/// 볼륨을 무엇에 쓰려는지. 읽기는 모든 모양을 받고, 내보내기·고치기는 rekordbox가 쓰는 모양만 받는다.
public enum UsbVolumePurpose: String, Codable, Sendable {
    case export, edit, read
}

/// 마운트된 USB 볼륨 하나의 정보(DiskArbitration·statfs에서 읽는다)
public struct UsbVolumeInfo: Codable, Hashable, Sendable {
    /// 볼륨 마운트 지점 경로
    public var mountPoint: String
    /// 대상 루트 = 마운트 지점
    public var rootIsMountPoint: Bool
    /// 대문자
    public var volumeUUID: String?
    public var name: String
    public var fileSystem: UsbFileSystemKind
    /// DiskArbitration MediaContent: "DOS_FAT_32"(0x0B), "Windows_FAT_32"(0x0C), "DOS_FAT_16" …
    public var partitionContent: String?
    public var partitionScheme: UsbPartitionScheme
    /// 1부터(diskNs1 → 1)
    public var partitionIndex: Int?
    public var sectorSize: Int?
    public var clusterSize: Int?
    /// 내장 여부를 모르면 디스크 이미지가 아닌 한 내장으로 보고 막는다
    public var isInternal: Bool
    public var isNetwork: Bool
    public var isReadOnly: Bool
    public var isRootVolume: Bool
    /// 디스크 이미지임을 확인했을 때만 참. 확인하지 못하면 실물로 본다
    public var isDiskImage: Bool
    /// realpath(3) 결과
    public var diskImagePath: String?
    public var capacity: Int64
    public var available: Int64
    /// DiskArbitration DADeviceProtocol("USB", "Secure Digital", "PCI-Express", 디스크 이미지는 "Virtual Interface"). 모르면 nil(참고용, 판정에 쓰지 않는다)
    public var deviceProtocol: String?
    /// DiskArbitration DAMediaRemovable. USB 메모리는 참, USB로 붙은 외장 SSD는 거짓(고정 디스크)으로 나온다. 모르면 nil(참고용)
    public var isRemovable: Bool?

    public init(mountPoint: String, rootIsMountPoint: Bool, volumeUUID: String?, name: String, fileSystem: UsbFileSystemKind,
                partitionContent: String?, partitionScheme: UsbPartitionScheme, partitionIndex: Int?, sectorSize: Int?,
                clusterSize: Int?, isInternal: Bool, isNetwork: Bool, isReadOnly: Bool, isRootVolume: Bool,
                isDiskImage: Bool, diskImagePath: String?, capacity: Int64, available: Int64,
                deviceProtocol: String? = nil, isRemovable: Bool? = nil) {
        self.mountPoint = mountPoint
        self.rootIsMountPoint = rootIsMountPoint
        self.volumeUUID = volumeUUID
        self.name = name
        self.fileSystem = fileSystem
        self.partitionContent = partitionContent
        self.partitionScheme = partitionScheme
        self.partitionIndex = partitionIndex
        self.sectorSize = sectorSize
        self.clusterSize = clusterSize
        self.isInternal = isInternal
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
        self.isRootVolume = isRootVolume
        self.isDiskImage = isDiskImage
        self.diskImagePath = diskImagePath
        self.capacity = capacity
        self.available = available
        self.deviceProtocol = deviceProtocol
        self.isRemovable = isRemovable
    }

    /// 쓰기 판정에 쓸 볼륨: 마운트 지점(realpath)이 임시 폴더 뿌리 밖이면 디스크 이미지라고 나와도 실물로 본다.
    /// 디스크 이미지는 lab 도구·자가 테스트가 늘 임시 폴더 아래에 붙인다. 볼륨 정보 하나가 틀려도 실물 관문을 건너뛰지 않게 한다
    public func judgedForWrite(underScratch: Bool) -> UsbVolumeInfo {
        guard isDiskImage, !underScratch else { return self }
        var judged = self
        judged.isDiskImage = false
        return judged
    }
}

public struct UsbVolumeProblem: Codable, Hashable, Sendable {
    /// 영어 고정 식별자
    public var code: String
    /// 이유와 할 일(`String(ui:)`)
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// 어떤 볼륨에 쓸 수 있는지. rekordbox·CDJ가 읽는 파일 시스템(FAT32·exFAT)과 파티션(MBR·GPT)의 바깥 저장장치만 받는다.
/// USB 메모리·외장 SSD·SD 카드 리더를 가리지 않는다. 내장·시동·네트워크·읽기 전용 볼륨과 APFS·HFS+(Time Machine 디스크 포함)는 막는다.
public enum UsbVolumePolicy {
    /// 쓸 수 있는 파일 시스템
    public static let fileSystems: Set<UsbFileSystemKind> = [.fat32, .exfat]
    /// 쓸 수 있는 파티션 방식
    public static let partitionSchemes: Set<UsbPartitionScheme> = [.mbr, .gpt]

    /// 문제를 판정 순서대로 모두 낸다. 읽기는 모든 모양을 받는다. 내보내기·고치기는 같은 조건이다.
    public static func problems(_ volume: UsbVolumeInfo, purpose: UsbVolumePurpose) -> [UsbVolumeProblem] {
        guard purpose != .read else { return [] }
        var problems: [UsbVolumeProblem] = []
        func add(_ code: String, _ message: String) { problems.append(UsbVolumeProblem(code: code, message: message)) }

        if !volume.rootIsMountPoint { add("notMountPoint", String(ui: "USB 볼륨의 맨 위 폴더를 고르세요")) }
        if volume.isInternal { add("internal", String(ui: "내장 디스크에는 쓸 수 없습니다. USB를 연결해 고르세요")) }
        if volume.isNetwork { add("network", String(ui: "네트워크 볼륨에는 쓸 수 없습니다. USB를 연결해 고르세요")) }
        if volume.isRootVolume { add("rootVolume", String(ui: "시동 디스크에는 쓸 수 없습니다")) }
        if volume.isReadOnly {
            add("readOnly", String(ui: "USB가 읽기 전용으로 연결됐습니다. 잠금 스위치를 풀고 다시 연결하세요"))
        }
        if !fileSystems.contains(volume.fileSystem) {
            add("unsupportedFileSystem",
                String(ui: "이 USB 형식(\(volume.fileSystem.displayName))에는 rekordbox 라이브러리를 쓸 수 없습니다. FAT32나 exFAT로 포맷한 뒤 다시 시도하세요"))
        }
        if !partitionSchemes.contains(volume.partitionScheme) {
            add("partitionScheme", String(ui: "MBR이나 GPT 파티션이 아닌 USB에는 쓸 수 없습니다. 디스크 유틸리티에서 MBR로 포맷한 뒤 다시 시도하세요"))
        }
        return problems
    }

    /// 막지 않고 쓰기 확인 창·내보내기 시트에 한 줄로 알리는 것. 근거: 제조사 사양(CDJ-3000은 exFAT을 읽고 CDJ-2000NXS2는 읽지 않음),
    /// GPT USB를 기기가 읽지 못했다는 사용자 보고(`docs/usb-internals.md` §12)
    public static func warnings(_ volume: UsbVolumeInfo) -> [UsbVolumeProblem] {
        var warnings: [UsbVolumeProblem] = []
        if volume.fileSystem == .exfat {
            warnings.append(UsbVolumeProblem(code: "exfat", message: String(ui: "exFAT USB는 CDJ-2000NXS2 등 이전 기기가 읽지 못할 수 있습니다")))
        }
        if volume.partitionScheme == .gpt {
            warnings.append(UsbVolumeProblem(code: "gpt",
                                             message: String(ui: "GPT로 포맷한 USB는 일부 기기가 읽지 못할 수 있습니다. 기기에서 읽히지 않으면 MBR로 포맷하세요")))
        }
        return warnings
    }

    /// 볼륨 문제를 볼륨 범위 막힘으로
    public static func blocks(_ volume: UsbVolumeInfo, purpose: UsbVolumePurpose) -> [UsbBlock] {
        problems(volume, purpose: purpose).map { UsbBlock(code: $0.code, scope: .volume, message: $0.message) }
    }
}

extension UsbVolumeInfo {
    /// 볼륨키: 볼륨 UUID(대문자, 쓰기·백업 폴더와 같은 키). UUID가 없으면 마운트 지점으로 만든다(사본 폴더 이름 한 성분이 되게 "/"를 뺀다)
    public var usbKey: String {
        if let uuid = volumeUUID?.uppercased(), !uuid.isEmpty { return uuid }
        return "mount" + mountPoint.replacingOccurrences(of: "/", with: "_")
    }
}
