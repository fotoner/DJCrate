import DJCDomain
import Darwin
import Foundation
import RekordboxKit

/// USB 쓰기 시험용 디스크 이미지(MBR + FAT32, raw). 임시 폴더 아래 경로만 받고, 장치 번호는 늘 이미지 경로에서 찾는다:
/// 만들기·붙이기는 자기 `hdiutil attach` 결과에서만, 떼기·정보·채우기는 `hdiutil info`의 image-path(realpath) 짝에서.
/// 파괴 명령(newfs) 직전에 그 장치가 이 이미지인지(image-path), 디스크 이미지인지(BusProtocol·Internal) 다시 본다.
/// hdiutil은 성공해도 stderr에 경고를 찍으므로 성공·실패는 rc와 stdout plist로만 판정한다. 출력은 개발자용(번역하지 않음).
public enum UsbDiskImage {
    public static let minimumSize: Int64 = 64 << 20
    /// FAT32 최소 클러스터 수
    public static let minimumClusters: UInt64 = 65_525
    /// 자동으로 고를 때 경계에서 떨어뜨리는 여유
    static let clusterMargin: UInt64 = 1_000
    static let partitionStart: UInt64 = 2048
    static let hdiutil = "/usr/bin/hdiutil"
    static let diskutil = "/usr/sbin/diskutil"
    static let newfs = "/sbin/newfs_msdos"
    static let fat32Hints: Set<String> = ["DOS_FAT_32", "Windows_FAT_32"]

    /// 바깥 세계(도구·시계·statfs·볼륨 정보·관문). 시험은 가짜를 준다
    struct Environment: Sendable {
        var runner: any UsbToolRunner
        var isRekordboxRunning: @Sendable () -> Bool
        var sleep: @Sendable (Double) -> Void
        var now: @Sendable () -> Date
        var statfs: @Sendable (String) -> StatfsFacts?
        var volumeInfo: @Sendable (URL) throws -> UsbVolumeInfo

        static var system: Environment {
            let runner = SystemToolRunner()
            return Environment(runner: runner, isRekordboxRunning: { LibrarySnapshot.isRekordboxRunning() },
                               sleep: { Thread.sleep(forTimeInterval: $0) }, now: { Date() }, statfs: { StatfsFacts.read($0) },
                               volumeInfo: { try UsbVolumes.info(root: $0, runner: runner) })
        }
    }

    public struct Created: Sendable {
        public var image: String
        public var partitionType: UInt8
        public var clusterBytes: Int
        public var clusters: UInt64
        public var summary: String
    }

    public struct Attached: Sendable {
        public var image: String
        public var wholeDevice: String
        public var partitionDevice: String
        public var mountPoint: String
    }

    public struct Seeded: Sendable {
        public var files: Int
        public var treeFile: String
    }

    // MARK: - 공개 명령

    public static func create(image: String, size: Int64 = 4 << 30, type: UInt8 = 0x0B, clusterBytes: Int? = nil, name: String) throws -> Created {
        try create(image: image, size: size, type: type, clusterBytes: clusterBytes, name: name, environment: .system)
    }

    public static func attach(image: String, mountPoint: String) throws -> Attached {
        try attach(image: image, mountPoint: mountPoint, environment: .system)
    }

    /// 붙어 있지 않으면 false
    public static func detach(image: String, force: Bool = false) throws -> Bool {
        try detach(image: image, force: force, environment: .system)
    }

    public static func info(image: String) throws -> [String] {
        try info(image: image, environment: .system)
    }

    public static func seed(image: String, from: String) throws -> Seeded {
        try seed(image: image, from: from, environment: .system)
    }

    // MARK: - 만들기

    static func create(image: String, size: Int64, type: UInt8 = 0x0B, clusterBytes: Int? = nil, name: String,
                       environment env: Environment) throws -> Created {
        let real = try UsbScratchPath.check(image, as: .newFile)
        guard type == 0x0B || type == 0x0C else { throw failure("파티션 형식은 0x0B나 0x0C만 씁니다") }
        guard isValidName(name) else { throw failure("볼륨 이름은 대문자·숫자·_·- 11자 이하로 주세요") }
        guard size >= minimumSize else { throw failure("이미지가 너무 작습니다(최소 64MiB)") }
        if env.isRekordboxRunning() { throw rekordboxRefusal }
        let totalSectors = UInt64(size) / 512
        let spc = try sectorsPerCluster(partitionSectors: totalSectors - partitionStart, requestedBytes: clusterBytes)
        try makeFile(real, size: Int64(totalSectors * 512), mbr: mbr(totalSectors: totalSectors, type: type))
        let devices = try attachRaw(real, env)
        do {
            let result = try env.runner.run(newfs, ["-F", "32", "-c", String(spc), "-o", String(partitionStart), "-v", name, devices.partition])
            guard result.status == 0 else { throw failure("newfs_msdos rc=\(result.status): \(firstLine(result.stderr))") }
            // 포맷 직후에는 파티션 표 값만 본다(파일 시스템 이름은 마운트해야 제대로 나온다)
            let expected = type == 0x0B ? "DOS_FAT_32" : "Windows_FAT_32"
            let partition = try diskutilInfo(devices.partition, env)
            guard partition["Content"] as? String == expected else {
                throw failure("포맷한 파티션의 Content가 \(expected)가 아닙니다(\(partition["Content"] as? String ?? "없음"))")
            }
            let whole = try diskutilInfo(devices.whole, env)
            guard whole["Content"] as? String == "FDisk_partition_scheme" else {
                throw failure("전체 디스크가 MBR(FDisk_partition_scheme)이 아닙니다(\(whole["Content"] as? String ?? "없음"))")
            }
        } catch {
            detachQuietly(devices.whole, force: true, env)
            throw error
        }
        do {
            try detachDevice(devices.whole, force: false, env)
        } catch {
            // 방금 만든 이미지를 붙인 채 두지 않는다
            detachQuietly(devices.whole, force: true, env)
            throw error
        }
        // FAT32 판정은 BPB로(이미지 파일은 남겨 둔다)
        let boot = try BootSector.parse(readBootSector(real))
        let summary = String(format: "FAT32 만듦: 0x%02X, 클러스터 %ldB × %llu(≥ 65,525)", type, boot.clusterBytes, boot.clusters)
        return Created(image: real, partitionType: type, clusterBytes: boot.clusterBytes, clusters: boot.clusters, summary: summary)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 11 && name.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" || $0 == "-" }
    }

    /// sparse 파일(ftruncate)을 만들고 앞 512바이트에 MBR을 쓴다
    static func makeFile(_ path: String, size: Int64, mbr: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw failure("이미지 파일을 만들지 못했습니다: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else { throw failure("이미지 크기를 잡지 못했습니다: \(String(cString: strerror(errno)))") }
        let written = mbr.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == mbr.count, fsync(descriptor) == 0 else { throw failure("MBR을 쓰지 못했습니다") }
    }

    // MARK: - 순수 계산

    /// 512바이트 MBR: 0x1BE 항목 = 상태 0, CHS FE FF FF, 형식, CHS FE FF FF, LBA 시작 2048, 섹터 수 = 전체 − 2048. 끝 55 AA
    public static func mbr(totalSectors: UInt64, type: UInt8) -> Data {
        var sector = Data(count: 512)
        let entry: [UInt8] = [0x00, 0xFE, 0xFF, 0xFF, type, 0xFE, 0xFF, 0xFF]
        sector.replaceSubrange(0x1BE..<0x1C6, with: entry)
        let count = UInt32(truncatingIfNeeded: totalSectors - partitionStart)
        for index in 0..<4 {
            sector[0x1C6 + index] = UInt8((UInt32(partitionStart) >> (8 * UInt32(index))) & 0xFF)
            sector[0x1CA + index] = UInt8((count >> (8 * UInt32(index))) & 0xFF)
        }
        sector[0x1FE] = 0x55
        sector[0x1FF] = 0xAA
        return sector
    }

    /// 파티션 크기로 섹터당 클러스터 수를 고른다(≤8GiB 8, ≤16GiB 16, ≤32GiB 32, 그 위 64). 추정 클러스터 수가
    /// 최소 + 여유보다 적으면 반으로 줄인다. 크기를 주면 그대로 쓰고 모자라면 실패
    public static func sectorsPerCluster(partitionSectors: UInt64, requestedBytes: Int?) throws -> Int {
        let shortage = failure("클러스터 수가 FAT32 최소(65,525)에 모자랍니다")
        if let requestedBytes {
            let spc = requestedBytes / 512
            guard requestedBytes % 512 == 0, spc >= 1, spc <= 128, spc & (spc - 1) == 0 else {
                throw failure("클러스터 크기는 512바이트의 2의 거듭제곱 배(512–65536)로 주세요")
            }
            guard estimatedClusters(partitionSectors: partitionSectors, spc: spc) >= minimumClusters else { throw shortage }
            return spc
        }
        let gib = UInt64(1 << 30) / 512
        var spc = partitionSectors <= 8 * gib ? 8 : partitionSectors <= 16 * gib ? 16 : partitionSectors <= 32 * gib ? 32 : 64
        while estimatedClusters(partitionSectors: partitionSectors, spc: spc) < minimumClusters + clusterMargin {
            guard spc > 1 else { throw shortage }
            spc /= 2
        }
        return spc
    }

    /// FAT32 식(예약 32섹터, FAT 2개)으로 본 클러스터 수. 실제 값은 포맷 뒤 BPB로 본다
    public static func estimatedClusters(partitionSectors: UInt64, spc: Int) -> UInt64 {
        let reserved: UInt64 = 32
        guard partitionSectors > reserved, spc > 0 else { return 0 }
        let divisor = UInt64(256 * spc + 2) / 2
        let fatSize = (partitionSectors - reserved + divisor - 1) / divisor
        guard partitionSectors > reserved + 2 * fatSize else { return 0 }
        return (partitionSectors - reserved - 2 * fatSize) / UInt64(spc)
    }

    /// FAT32 부트 섹터(BPB, 리틀 엔디언)
    public struct BootSector: Sendable {
        public var bytesPerSector: Int
        public var sectorsPerCluster: Int
        public var reservedSectors: Int
        public var fatCount: Int
        public var totalSectors: UInt32
        public var fatSize: UInt32
        public var clusters: UInt64
        public var clusterBytes: Int { bytesPerSector * sectorsPerCluster }

        /// FAT32가 아니면 이유를 적어 실패
        public static func parse(_ data: Data) throws -> BootSector {
            guard data.count >= 512 else { throw failure("BPB를 읽지 못했습니다") }
            let bytes = [UInt8](data.prefix(512))
            func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
            func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) } }
            guard bytes[0x1FE] == 0x55, bytes[0x1FF] == 0xAA else { throw failure("BPB 서명(55 AA)이 없습니다") }
            guard u16(0x0B) == 512 else { throw failure("섹터 크기가 512가 아닙니다(\(u16(0x0B)))") }
            guard u16(0x16) == 0 else { throw failure("FATSz16이 0이 아닙니다(FAT32가 아님)") }
            guard String(decoding: bytes[0x52..<0x5A], as: UTF8.self) == "FAT32   " else { throw failure("BS_FilSysType이 FAT32가 아닙니다") }
            let spc = Int(bytes[0x0D]), reserved = u16(0x0E), fats = Int(bytes[0x10])
            let total = u32(0x20), fatSize = u32(0x24)
            let overhead = UInt64(reserved) + UInt64(fats) * UInt64(fatSize)
            guard spc > 0, UInt64(total) > overhead else { throw failure("BPB 값이 맞지 않습니다") }
            let clusters = (UInt64(total) - overhead) / UInt64(spc)
            guard clusters >= minimumClusters else { throw failure("클러스터 수가 FAT32 최소(65,525)에 모자랍니다(\(clusters))") }
            return BootSector(bytesPerSector: 512, sectorsPerCluster: spc, reservedSectors: reserved, fatCount: fats, totalSectors: total,
                              fatSize: fatSize, clusters: clusters)
        }
    }

    static func readBootSector(_ image: String) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: image) else { throw failure("이미지를 열지 못했습니다") }
        defer { try? handle.close() }
        try handle.seek(toOffset: partitionStart * 512)
        return try handle.read(upToCount: 512) ?? Data()
    }

    /// `size` 인자: 4g·2g·64m 모양(g·m·k, 없으면 바이트)
    public static func parseSize(_ text: String) -> Int64? {
        let lower = text.lowercased()
        let units: [Character: Int64] = ["g": 1 << 30, "m": 1 << 20, "k": 1 << 10]
        if let last = lower.last, let unit = units[last] { return Int64(lower.dropLast()).map { $0 * unit } }
        return Int64(lower)
    }

    // MARK: - 장치

    /// attach plist의 `system-entities`에서 전체 디스크와 FAT32 파티션을 content-hint로 하나씩 고른다(순서에 기대지 않는다)
    static func pickDevices(_ entities: [[String: Any]]) throws -> (whole: String, partition: String) {
        var wholes = entities.filter { $0["content-hint"] as? String == "FDisk_partition_scheme" }.compactMap { $0["dev-entry"] as? String }
        if wholes.isEmpty { wholes = entities.compactMap { $0["dev-entry"] as? String }.filter(isWholeDevice) }
        let partitions = entities.filter { fat32Hints.contains($0["content-hint"] as? String ?? "") }.compactMap { $0["dev-entry"] as? String }
        guard wholes.count == 1, partitions.count == 1 else {
            throw failure("attach 결과에서 전체 디스크와 FAT32 파티션을 하나씩 고르지 못했습니다(전체 \(wholes.count), 파티션 \(partitions.count))")
        }
        guard partitions[0] == wholes[0] + "s1" else { throw failure("파티션이 그 디스크의 첫 파티션이 아닙니다: \(partitions[0])") }
        return (wholes[0], partitions[0])
    }

    static func isWholeDevice(_ device: String) -> Bool {
        device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
    }

    /// `/dev/diskNsM` → `/dev/diskN`(파티션 모양이 아니면 nil)
    static func wholeDevice(ofPartition device: String) -> String? {
        guard let range = device.range(of: #"^/dev/disk[0-9]+(?=s[0-9]+$)"#, options: .regularExpression) else { return nil }
        return String(device[range])
    }

    /// 붙이되 마운트하지 않고, 자기 plist에서 장치를 고른 뒤 그 장치가 이 이미지·디스크 이미지인지 확인한다. 어긋나면 뗀다
    static func attachRaw(_ real: String, _ env: Environment) throws -> (whole: String, partition: String) {
        let result = try env.runner.run(hdiutil, ["attach", "-plist", "-nomount", "-nobrowse", "-imagekey", "diskimage-class=CRawDiskImage", real])
        guard result.status == 0 else { throw failure("hdiutil attach rc=\(result.status): \(firstLine(result.stderr))") }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw failure("hdiutil attach 출력이 plist가 아닙니다")
        }
        let devices: (whole: String, partition: String)
        do {
            devices = try pickDevices(entities)
        } catch {
            // 고르지 못해도 붙인 것은 뗀다: 전체 디스크 모양이 없으면 파티션 이름(diskNsM)에서 전체 디스크(diskN)를 얻는다
            let entries = entities.compactMap { $0["dev-entry"] as? String }
            for device in Set(entries.filter(isWholeDevice) + entries.compactMap(wholeDevice(ofPartition:))).sorted() {
                detachQuietly(device, force: true, env)
            }
            throw error
        }
        do {
            try verifyDevice(devices.whole, image: real, env)
        } catch {
            detachQuietly(devices.whole, force: true, env)
            throw error
        }
        return devices
    }

    /// 파괴 명령 직전: hdiutil info에서 그 장치를 담은 이미지의 image-path(realpath)가 우리 이미지이고, 디스크 이미지·외장이어야 한다
    static func verifyDevice(_ whole: String, image real: String, _ env: Environment) throws {
        let images = try hdiutilImages(env)
        guard let image = images.first(where: { $0.devices.contains(whole) }), UsbScratchRoots.realPath(image.path) == real else {
            throw failure("hdiutil info에서 \(whole)의 이미지가 이 이미지가 아닙니다")
        }
        let info = try diskutilInfo(whole, env)
        guard info["BusProtocol"] as? String == "Disk Image", info["Internal"] as? Bool == false else {
            throw failure("\(whole)이 디스크 이미지로 보이지 않습니다(BusProtocol·Internal)")
        }
    }

    static func hdiutilImages(_ env: Environment) throws -> [UsbVolumes.HdiutilImage] {
        let result = try env.runner.run(hdiutil, ["info", "-plist"])
        guard result.status == 0 else { throw failure("hdiutil info rc=\(result.status): \(firstLine(result.stderr))") }
        return UsbVolumes.hdiutilImages(result.stdout)
    }

    static func diskutilInfo(_ device: String, _ env: Environment) throws -> [String: Any] {
        let result = try env.runner.run(diskutil, ["info", "-plist", device])
        guard result.status == 0, let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        else { throw failure("diskutil info \(device) rc=\(result.status): \(firstLine(result.stderr))") }
        return plist
    }

    /// 이 이미지(realpath)가 붙어 있으면 그 장치들과 마운트 지점
    static func attachedDevices(_ real: String, _ env: Environment) throws -> (whole: String, partition: String?, mountPoint: String?)? {
        for image in try hdiutilImages(env) where UsbScratchRoots.realPath(image.path) == real {
            let whole = image.entities.first { $0["content-hint"] as? String == "FDisk_partition_scheme" }?["dev-entry"] as? String
                ?? image.devices.first(where: isWholeDevice)
            guard let whole else { continue }
            let partition = image.entities.first { ($0["dev-entry"] as? String) == whole + "s1" }
            return (whole, partition?["dev-entry"] as? String, partition?["mount-point"] as? String)
        }
        return nil
    }

    static func detachDevice(_ whole: String, force: Bool, _ env: Environment) throws {
        let result = try env.runner.run(hdiutil, ["detach"] + (force ? ["-force"] : []) + [whole])
        guard result.status == 0 else { throw failure("hdiutil detach rc=\(result.status): \(firstLine(result.stderr))") }
    }

    static func detachQuietly(_ whole: String, force: Bool, _ env: Environment) {
        _ = try? detachDevice(whole, force: force, env)
    }

    // MARK: - 붙이기·떼기·정보

    static func attach(image: String, mountPoint: String, environment env: Environment) throws -> Attached {
        let real = try UsbScratchPath.check(image, as: .existingFile)
        let mount = try UsbScratchPath.check(mountPoint, as: .outputDirectory)
        if env.isRekordboxRunning() { throw rekordboxRefusal }
        if try attachedDevices(real, env) != nil { throw failure("이미 붙어 있습니다. 먼저 usb-image detach로 떼세요") }
        if !FileManager.default.fileExists(atPath: mount) {
            try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: false)
        }
        let devices = try attachRaw(real, env)
        do {
            let result = try env.runner.run(diskutil, ["mount", "-mountOptions", "nobrowse", "-mountPoint", mount, devices.partition])
            guard result.status == 0 else { throw failure("diskutil mount rc=\(result.status): \(firstLine(result.stderr))") }
            // 마운트 직후에는 파일 시스템 이름이 늦게 바뀐다: 5초까지 0.25초 간격으로 본다
            let deadline = env.now().addingTimeInterval(5)
            while true {
                let info = try diskutilInfo(devices.partition, env)
                let facts = env.statfs(mount)
                if info["FilesystemName"] as? String == "MS-DOS FAT32", info["FilesystemType"] as? String == "msdos",
                   facts?.fileSystemTypeName == "msdos", facts?.mountedOn == mount { break }
                if env.now() >= deadline { throw failure("마운트한 볼륨이 FAT32로 보이지 않습니다") }
                env.sleep(0.25)
            }
        } catch {
            detachQuietly(devices.whole, force: true, env)
            throw error
        }
        return Attached(image: real, wholeDevice: devices.whole, partitionDevice: devices.partition, mountPoint: mount)
    }

    static func detach(image: String, force: Bool, environment env: Environment) throws -> Bool {
        let real = try UsbScratchPath.check(image, as: .existingFile)
        guard let devices = try attachedDevices(real, env) else { return false }
        try detachDevice(devices.whole, force: force, env)
        return true
    }

    static func info(image: String, environment env: Environment) throws -> [String] {
        let real = try UsbScratchPath.check(image, as: .existingFile)
        var lines = ["이미지: \(real)"]
        if let devices = try attachedDevices(real, env) {
            lines.append("장치: \(devices.whole) (파티션 \(devices.partition ?? "없음"))")
            if let partition = devices.partition {
                let info = try diskutilInfo(partition, env)
                lines.append("Content: \(info["Content"] as? String ?? "없음")")
                if devices.mountPoint != nil {
                    lines.append("FilesystemName: \(info["FilesystemName"] as? String ?? "없음")")
                    lines.append("FilesystemType: \(info["FilesystemType"] as? String ?? "없음")")
                } else {
                    lines.append("파일 시스템 이름: 마운트 전이라 확인 안 함")
                }
            }
            let whole = try diskutilInfo(devices.whole, env)
            lines.append("전체: \(whole["Content"] as? String ?? "없음")")
            lines.append("BusProtocol: \(whole["BusProtocol"] as? String ?? "없음")")
            lines.append("마운트 지점: \(devices.mountPoint ?? "없음")")
        } else {
            lines.append("붙어 있지 않음")
        }
        if let handle = FileHandle(forReadingAtPath: real), let head = try? handle.read(upToCount: 512), head.count == 512 {
            try? handle.close()
            lines.append(String(format: "MBR 파티션 형식: 0x%02X", head[0x1C2]))
        }
        do {
            let boot = try BootSector.parse(readBootSector(real))
            lines.append("BPB: 클러스터 \(boot.clusterBytes)B × \(boot.clusters)")
        } catch {
            lines.append("BPB: \(error)")
        }
        return lines
    }

    // MARK: - 채우기

    /// 골든 사본 등(임시 폴더 아래)을 붙어 있는 이미지에 데이터만 복사한다. 관문 둘(디스크 이미지, 그 이미지 경로)을 지나야 쓴다
    static func seed(image: String, from: String, environment env: Environment) throws -> Seeded {
        let real = try UsbScratchPath.check(image, as: .existingFile)
        let source = try UsbScratchPath.check(from, as: .existingDirectory)
        if env.isRekordboxRunning() { throw rekordboxRefusal }
        guard let devices = try attachedDevices(real, env), let mount = devices.mountPoint else {
            throw failure("이미지가 마운트돼 있지 않습니다. 먼저 usb-image attach로 붙이세요")
        }
        let volume = try env.volumeInfo(URL(filePath: mount))
        guard volume.isDiskImage, let imagePath = volume.diskImagePath, UsbScratchRoots.realPath(imagePath) == real,
              (try? UsbScratchPath.check(imagePath, as: .existingFile)) != nil else {
            throw UsbError.writeRefused([UsbBlock(code: "seedRefused", scope: .volume,
                                                  message: String(ui: "디스크 이미지로 확인되지 않은 볼륨에는 쓰지 않습니다. usb-image attach로 붙인 이미지를 주세요"))])
        }
        let fs = PosixUsbFileSystem()
        let target = URL(filePath: mount)
        var files = 0
        var created: [String] = []
        func walk(_ relative: String) throws {
            let directory = URL(filePath: relative.isEmpty ? source : source + "/" + relative)
            for name in try fs.list(directory).sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                if UsbLayout.isAppleDouble(name) || UsbLayout.isNeverRead(path) || UsbLayout.isSystemIgnored(path) { continue }
                let from = URL(filePath: source + "/" + path)
                guard let info = try fs.stat(from) else { continue }
                let to = target.appending(path: path)
                switch info.kind {
                case .directory:
                    if try fs.stat(to) == nil {
                        try fs.makeDirectory(to)
                        created.append(path)
                    }
                    try walk(path)
                case .file:
                    _ = try fs.copyDataNew(from: from, to: to) { _ in }
                    try fs.setModificationDate(to, info.modificationDate)
                    created.append(path)
                    files += 1
                case .symlink, .other:
                    continue
                }
            }
        }
        try walk("")
        // 우리가 만든 경로의 정확한 `._<이름>`만 지운다
        for path in created {
            guard let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) else { continue }
            if try fs.stat(target.appending(path: companion)) != nil { try fs.remove(target.appending(path: companion)) }
        }
        let tree = UsbTree.render(try UsbTree.fingerprint(UsbRoot(target)))
        let treeFile = real + ".seed-tree.txt"
        try (tree + "\n").write(toFile: treeFile, atomically: true, encoding: .utf8)
        return Seeded(files: files, treeFile: treeFile)
    }

    // MARK: -

    static func failure(_ detail: String) -> UsbError { .diskImageToolFailed(detail: detail) }

    static var rekordboxRefusal: UsbError {
        .writeRefused([UsbBlock(code: "rekordboxRunning", scope: .volume, message: String(ui: "rekordbox를 완전히 종료한 뒤 다시 시도하세요"))])
    }

    static func firstLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
    }
}
