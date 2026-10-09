import DJCStorage
import Foundation

/// 가짜 hdiutil·diskutil·newfs_msdos. macOS 27에서 본 모양대로 답한다:
/// - `hdiutil attach`·`detach`는 성공해도 stderr에 deprecated 경고 한 줄을 찍는다(지어낸 문장).
/// - attach plist의 `system-entities`는 파티션(…s1)이 먼저, 전체 디스크가 뒤다.
/// - `hdiutil info`의 image-path는 attach에 준 철자 그대로다.
/// - newfs 직후 `diskutil info <s1>`: 0x0B면 FilesystemName "MS-DOS"·FilesystemType "msdos", 0x0C면 둘 다 없음.
///   마운트 뒤에는 "MS-DOS FAT32"·"msdos"(처음 몇 번은 옛 값을 되풀이한다).
public final class FakeToolRunner: UsbToolRunner, @unchecked Sendable {
    public struct Output {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public init(status: Int32 = 0, stdout: Data = Data(), stderr: Data = Data()) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public static let warning = Data("hdiutil: this verb is deprecated and will be removed in a future release (synthetic warning)\n".utf8)

    private let lock = NSLock()
    private var recorded: [[String]] = []

    public var whole = "/dev/disk9"
    public var partition = "/dev/disk9s1"
    /// MBR 파티션 형식(0x0B → DOS_FAT_32, 0x0C → Windows_FAT_32)
    public var partitionType: UInt8 = 0x0B
    /// attach plist의 장치 목록. nil이면 실측 순서(파티션 먼저)
    public var entities: [[String: Any]]?
    /// `hdiutil info`가 돌려줄 image-path. nil이면 attach에 준 철자 그대로
    public var infoImagePath: String?
    public var busProtocol = "Disk Image"
    public var isInternal = false
    public var attachStatus: Int32 = 0
    public var attachStderr = FakeToolRunner.warning
    public var detachStatus: Int32 = 0
    /// 강제(-force)가 아닌 떼기만 이 값으로 답한다(nil이면 detachStatus)
    public var plainDetachStatus: Int32?
    public var newfsStatus: Int32 = 0
    public var mountStatus: Int32 = 0
    /// 마운트한 뒤 파티션 정보가 몇 번 옛 값을 되풀이하는지
    public var staleReadsAfterMount = 2
    /// 마운트한 뒤에도 끝내 FAT32로 보이지 않게
    public var neverFAT32 = false
    /// newfs 때 부른다(시험이 이미지 파일에 합성 BPB를 쓴다)
    public var onNewfs: (([String]) -> Void)?

    /// 붙어 있는 이미지(attach에 준 철자)와 마운트 지점
    public private(set) var attachedImage: String?
    public private(set) var mountPoint: String?
    private var formatted = false
    private var readsAfterMount = 0

    public init() {}

    public var calls: [[String]] { lock.withLock { recorded } }

    /// 명령 이름(실행 파일 끝 이름, hdiutil·diskutil은 하위 명령까지)만
    public var verbs: [String] {
        calls.map { call in
            let tool = (call[0] as NSString).lastPathComponent
            return ["hdiutil", "diskutil"].contains(tool) ? ([tool] + call.dropFirst().prefix(1)).joined(separator: " ") : tool
        }
    }

    public func attach(image: String) {
        attachedImage = image
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        lock.withLock { recorded.append([executable] + arguments) }
        let tool = (executable as NSString).lastPathComponent
        let output: Output
        switch (tool, arguments.first) {
        case ("hdiutil", "attach"?):
            if attachStatus == 0 { attachedImage = arguments.last }
            output = Output(status: attachStatus, stdout: attachStatus == 0 ? Self.plist(["system-entities": attachEntities]) : Data(),
                            stderr: attachStatus == 0 ? attachStderr : Data("hdiutil: attach failed - synthetic failure\n".utf8))
        case ("hdiutil", "detach"?):
            let status = arguments.contains("-force") ? detachStatus : plainDetachStatus ?? detachStatus
            if status == 0 {
                attachedImage = nil
                mountPoint = nil
            }
            output = Output(status: status, stderr: Self.warning)
        case ("hdiutil", "info"?):
            output = Output(stdout: infoPlist())
        case ("newfs_msdos", _):
            onNewfs?(arguments)
            formatted = newfsStatus == 0
            output = Output(status: newfsStatus, stderr: newfsStatus == 0 ? Data() : Data("newfs_msdos: synthetic failure\n".utf8))
        case ("diskutil", "info"?):
            output = Output(stdout: Self.plist(diskutilInfo(arguments.last ?? "")))
        case ("diskutil", "mount"?):
            if mountStatus == 0, let index = arguments.firstIndex(of: "-mountPoint") { mountPoint = arguments[index + 1] }
            output = Output(status: mountStatus)
        default:
            output = Output(status: 127, stderr: Data("unknown tool\n".utf8))
        }
        return (output.status, output.stdout, output.stderr)
    }

    var attachEntities: [[String: Any]] {
        entities ?? [["dev-entry": partition, "content-hint": partitionContent, "potentially-mountable": true],
                     ["dev-entry": whole, "content-hint": "FDisk_partition_scheme"]]
    }

    var partitionContent: String { partitionType == 0x0C ? "Windows_FAT_32" : "DOS_FAT_32" }

    func infoPlist() -> Data {
        guard let attachedImage else { return Self.plist(["images": [[String: Any]]()]) }
        var entities = attachEntities
        if let mountPoint, let index = entities.firstIndex(where: { ($0["dev-entry"] as? String) == partition }) {
            entities[index]["mount-point"] = mountPoint
        }
        return Self.plist(["images": [["image-path": infoImagePath ?? attachedImage, "system-entities": entities]]])
    }

    func diskutilInfo(_ device: String) -> [String: Any] {
        if device == whole {
            return ["Content": "FDisk_partition_scheme", "BusProtocol": busProtocol, "Internal": isInternal, "DeviceNode": whole]
        }
        var info: [String: Any] = ["Content": partitionContent, "BusProtocol": busProtocol, "Internal": isInternal, "DeviceNode": partition]
        if mountPoint != nil {
            readsAfterMount += 1
            if !neverFAT32, readsAfterMount > staleReadsAfterMount {
                info["FilesystemName"] = "MS-DOS FAT32"
                info["FilesystemType"] = "msdos"
                info["MountPoint"] = mountPoint
                return info
            }
        }
        if formatted || mountPoint != nil, partitionType == 0x0B {
            info["FilesystemName"] = "MS-DOS"
            info["FilesystemType"] = "msdos"
        }
        return info
    }

    public static func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// FAT32 부트 섹터(BPB) 합성: 클러스터 수가 정확히 `clusters`가 되게 전체 섹터 수를 맞춘다
    public static func bootSector(clusters: UInt32, sectorsPerCluster: UInt8 = 8, reserved: UInt16 = 32, fatSize: UInt32 = 1024,
                                  bytesPerSector: UInt16 = 512, fatSize16: UInt16 = 0, type: String = "FAT32   ") -> Data {
        var sector = Data(count: 512)
        func put16(_ value: UInt16, _ offset: Int) { sector[offset] = UInt8(value & 0xFF); sector[offset + 1] = UInt8(value >> 8) }
        func put32(_ value: UInt32, _ offset: Int) { for i in 0..<4 { sector[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) } }
        sector[0] = 0xEB; sector[1] = 0x58; sector[2] = 0x90
        put16(bytesPerSector, 0x0B)
        sector[0x0D] = sectorsPerCluster
        put16(reserved, 0x0E)
        sector[0x10] = 2
        put16(fatSize16, 0x16)
        put32(UInt32(reserved) + 2 * fatSize + clusters * UInt32(sectorsPerCluster), 0x20)
        put32(fatSize, 0x24)
        sector.replaceSubrange(0x52..<0x5A, with: Data(type.utf8.prefix(8)))
        sector[0x1FE] = 0x55; sector[0x1FF] = 0xAA
        return sector
    }

    /// 이미지 파일의 파티션 시작(2048 × 512)에 BPB를 쓴다
    public static func writeBootSector(_ sector: Data, toImage path: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        try! handle.seek(toOffset: 2048 * 512)
        try! handle.write(contentsOf: sector)
        try! handle.close()
    }
}
