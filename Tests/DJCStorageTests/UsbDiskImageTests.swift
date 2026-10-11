import DJCDomain
@testable import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

/// 디스크 이미지 도구: 순수 계산과 가짜 hdiutil·diskutil로 절차를 시험한다(실제 장치에 닿지 않는다)
@Suite("USB 디스크 이미지")
struct UsbDiskImageTests {
    static let mib: Int64 = 1 << 20
    static let gib: Int64 = 1 << 30

    /// 임시 폴더(/private/tmp 아래) 하나를 만들고 끝나면 지운다
    func withFolder(_ body: (String) throws -> Void) throws {
        let folder = "/private/tmp/djc-image-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try body(folder)
    }

    /// 가짜 환경: 시계는 sleep만큼 간다
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed = 0.0
        func sleep(_ seconds: Double) { lock.withLock { elapsed += seconds } }
        var now: Date { lock.withLock { Date(timeIntervalSince1970: 1_000 + elapsed) } }
    }

    func environment(_ runner: FakeToolRunner, rekordbox: Bool = false, clock: Clock = Clock(),
                     volume: UsbVolumeInfo? = nil) -> UsbDiskImage.Environment {
        UsbDiskImage.Environment(
            runner: runner, isRekordboxRunning: { rekordbox }, sleep: { clock.sleep($0) }, now: { clock.now },
            statfs: { path in
                StatfsFacts(fileSystemTypeName: "msdos", mountedOn: UsbScratchRoots.realPath(path) ?? path, mountedFrom: runner.partition,
                            blockSize: 4096, isReadOnly: false, isRootFileSystem: false, isLocal: true)
            },
            volumeInfo: { url in
                if let volume { return volume }
                var info = FakeUsbVolume.diskImageFAT32()
                info.mountPoint = url.path
                info.diskImagePath = runner.attachedImage.flatMap { UsbScratchRoots.realPath($0) }
                return info
            })
    }

    /// newfs가 부르면 이미지에 실제와 같은 모양의 BPB를 쓴다
    func formatting(_ runner: FakeToolRunner, image: String, clusters: UInt32 = 1_046_272, spc: UInt8 = 8) {
        runner.onNewfs = { _ in FakeToolRunner.writeBootSector(FakeToolRunner.bootSector(clusters: clusters, sectorsPerCluster: spc), toImage: image) }
    }

    // MARK: - 순수 계산

    @Test func mbrBytes0x0B() {
        let mbr = UsbDiskImage.mbr(totalSectors: 8_388_608, type: 0x0B)
        #expect(mbr.count == 512)
        #expect(Array(mbr[0x1BE..<0x1CE]) == [0x00, 0xFE, 0xFF, 0xFF, 0x0B, 0xFE, 0xFF, 0xFF, 0x00, 0x08, 0x00, 0x00, 0x00, 0xF8, 0x7F, 0x00])
        #expect(mbr[0x1CE..<0x1FE].allSatisfy { $0 == 0 })
    }

    @Test func mbrBytes0x0C() {
        let mbr = UsbDiskImage.mbr(totalSectors: 131_072, type: 0x0C)
        #expect(mbr[0x1C2] == 0x0C)
        // LBA 2048, 섹터 수 = 131072 − 2048 = 129024(0x0001F800)
        #expect(Array(mbr[0x1C6..<0x1CE]) == [0x00, 0x08, 0x00, 0x00, 0x00, 0xF8, 0x01, 0x00])
    }

    @Test func mbrSignature() {
        let mbr = UsbDiskImage.mbr(totalSectors: 131_072, type: 0x0B)
        #expect(mbr[0x1FE] == 0x55 && mbr[0x1FF] == 0xAA)
        #expect(mbr[0..<0x1BE].allSatisfy { $0 == 0 })
    }

    @Test("클러스터: 4GiB·2GiB는 4KiB, 64MiB는 512B")
    func clusterChoice4g_2g_64m() throws {
        for (size, spc) in [(4 * Self.gib, 8), (2 * Self.gib, 8), (64 * Self.mib, 1)] {
            let partition = UInt64(size / 512) - 2048
            let chosen = try UsbDiskImage.sectorsPerCluster(partitionSectors: partition, requestedBytes: nil)
            #expect(chosen == spc, "\(size)")
            #expect(UsbDiskImage.estimatedClusters(partitionSectors: partition, spc: chosen) >= 65_525 + 1_000)
        }
        // 64MiB에서 반으로 줄여 가는 추정값
        let partition: UInt64 = 129_024
        #expect([8, 4, 2, 1].map { UsbDiskImage.estimatedClusters(partitionSectors: partition, spc: $0) } == [16_092, 32_122, 63_994, 126_992])
    }

    @Test("2GiB에 32KiB 클러스터는 FAT32 최소 클러스터 수에 모자란다")
    func forced32KOn2gFails() {
        #expect(throws: UsbError.self) {
            _ = try UsbDiskImage.sectorsPerCluster(partitionSectors: UInt64(2 * Self.gib / 512) - 2048, requestedBytes: 32_768)
        }
        #expect(throws: Never.self) {
            _ = try UsbDiskImage.sectorsPerCluster(partitionSectors: UInt64(2 * Self.gib / 512) - 2048, requestedBytes: 4096)
        }
    }

    @Test("64MiB에 1KiB 클러스터(spc 2)는 모자란다")
    func forcedSpc2On64mFails() {
        #expect(throws: UsbError.self) {
            _ = try UsbDiskImage.sectorsPerCluster(partitionSectors: 129_024, requestedBytes: 1024)
        }
    }

    @Test("64MiB보다 작으면 파일을 만들기 전에 거부")
    func under64MiBRefused() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            let image = folder + "/small.img"
            do {
                _ = try UsbDiskImage.create(image: image, size: 63 * Self.mib, name: "DJCTEST", environment: environment(runner))
                Issue.record("거부하지 않았다")
            } catch let UsbError.diskImageToolFailed(detail) {
                #expect(detail.contains("최소 64MiB"))
            }
            #expect(!FileManager.default.fileExists(atPath: image))
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("크기 인자: 4g·2g·64m")
    func parseSize() {
        #expect(UsbDiskImage.parseSize("4g") == 4 * Self.gib)
        #expect(UsbDiskImage.parseSize("2G") == 2 * Self.gib)
        #expect(UsbDiskImage.parseSize("64m") == 64 * Self.mib)
        #expect(UsbDiskImage.parseSize("abc") == nil)
    }

    @Test("BPB로 FAT32 판정")
    func bpbFAT32Check() throws {
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.BootSector.parse(FakeToolRunner.bootSector(clusters: 65_524)) }
        let ok = try UsbDiskImage.BootSector.parse(FakeToolRunner.bootSector(clusters: 65_525))
        #expect(ok.clusters == 65_525)
        #expect(ok.clusterBytes == 4096)
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.BootSector.parse(FakeToolRunner.bootSector(clusters: 70_000, fatSize16: 3)) }
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.BootSector.parse(FakeToolRunner.bootSector(clusters: 70_000, type: "FAT16   ")) }
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.BootSector.parse(FakeToolRunner.bootSector(clusters: 70_000, bytesPerSector: 4096)) }
        var unsigned = FakeToolRunner.bootSector(clusters: 70_000)
        unsigned[0x1FF] = 0
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.BootSector.parse(unsigned) }
    }

    // MARK: - 만들기

    @Test("hdiutil 경고(stderr)는 실패가 아니다. rc가 실패면 stderr 첫 줄을 이유로")
    func stderrWarningsIgnored() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            let runner = FakeToolRunner()
            formatting(runner, image: image)
            let created = try UsbDiskImage.create(image: image, size: 4 * Self.gib, name: "DJCTEST", environment: environment(runner))
            #expect(created.summary.hasPrefix("FAT32 만듦: 0x0B, 클러스터 4096B × "))
            #expect(runner.attachedImage == nil)
            let failing = FakeToolRunner()
            failing.attachStatus = 1
            do {
                _ = try UsbDiskImage.create(image: folder + "/f.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(failing))
                Issue.record("실패하지 않았다")
            } catch let UsbError.diskImageToolFailed(detail) {
                #expect(detail.contains("synthetic failure"))
            }
        }
    }

    @Test("attach plist에서 전체·파티션을 content-hint로 고른다(순서와 무관)")
    func attachPlistEntityOrder() throws {
        let partition: [String: Any] = ["dev-entry": "/dev/disk9s1", "content-hint": "DOS_FAT_32"]
        let whole: [String: Any] = ["dev-entry": "/dev/disk9", "content-hint": "FDisk_partition_scheme"]
        let other: [String: Any] = ["dev-entry": "/dev/disk9s2"]
        for entities in [[partition, whole], [whole, partition], [other, partition, whole]] {
            let picked = try UsbDiskImage.pickDevices(entities)
            #expect(picked.whole == "/dev/disk9" && picked.partition == "/dev/disk9s1")
        }
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.pickDevices([partition, partition, whole]) }
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.pickDevices([partition, whole, ["dev-entry": "/dev/disk8", "content-hint": "FDisk_partition_scheme"]]) }
        #expect(throws: UsbError.self) { _ = try UsbDiskImage.pickDevices([["dev-entry": "/dev/disk9s2", "content-hint": "DOS_FAT_32"], whole]) }
        // 잘못 고른 뒤에는 떼어 낸다
        try withFolder { folder in
            let runner = FakeToolRunner()
            runner.entities = [partition, partition, whole]
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(runner.verbs.contains("hdiutil detach"))
            #expect(!runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test("만든 뒤 떼기가 실패하면 강제로 뗀다(이미지를 붙인 채 두지 않는다)")
    func createDetachFailureForcesDetach() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            let runner = FakeToolRunner()
            runner.plainDetachStatus = 16
            formatting(runner, image: image)
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: image, size: 4 * Self.gib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(runner.calls.contains(["/usr/bin/hdiutil", "detach", "-force", runner.whole]))
            #expect(runner.attachedImage == nil)
        }
    }

    @Test("attach 결과에 전체 디스크 모양 항목이 없어도 파티션 이름에서 전체 디스크를 얻어 뗀다")
    func attachPickFailureDetachesByPartitionEntry() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            let partition: [String: Any] = ["dev-entry": "/dev/disk9s1", "content-hint": "DOS_FAT_32"]
            runner.entities = [partition, partition]
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(runner.calls.contains(["/usr/bin/hdiutil", "detach", "-force", "/dev/disk9"]))
            #expect(runner.attachedImage == nil)
            #expect(!runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test("장치 번호는 자기 attach plist에서만 받는다")
    func deviceOnlyFromAttachPlist() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            let runner = FakeToolRunner()
            runner.whole = "/dev/disk12"
            runner.partition = "/dev/disk12s1"
            formatting(runner, image: image)
            _ = try UsbDiskImage.create(image: image, size: 4 * Self.gib, name: "DJCTEST", environment: environment(runner))
            let newfs = try #require(runner.calls.first { ($0[0] as NSString).lastPathComponent == "newfs_msdos" })
            #expect(newfs.last == "/dev/disk12s1")
            #expect(Array(newfs.dropFirst().prefix(7)) == ["-F", "32", "-c", "8", "-o", "2048", "-v"])
            #expect(runner.calls.contains(["/usr/bin/hdiutil", "detach", "/dev/disk12"]))
        }
    }

    @Test("image-path가 우리 이미지가 아니면 아무것도 하지 않고 뗀다")
    func imagePathMismatchDoesNothing() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            FileManager.default.createFile(atPath: folder + "/other.img", contents: Data())
            runner.infoImagePath = folder + "/other.img"
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(!runner.verbs.contains("newfs_msdos"))
            #expect(runner.verbs.contains("hdiutil detach"))
        }
    }

    @Test func busProtocolNotDiskImageDoesNothing() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            runner.busProtocol = "USB"
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(!runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test func internalTrueDoesNothing() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            runner.isInternal = true
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            }
            #expect(!runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test("이미지를 /tmp로 주고 hdiutil이 /private/tmp를 돌려줘도 짝으로 본다")
    func imagePathComparedByRealpath() throws {
        try withFolder { folder in
            let short = folder.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") + "/t.img"
            let runner = FakeToolRunner()
            runner.infoImagePath = folder + "/t.img"
            formatting(runner, image: folder + "/t.img")
            _ = try UsbDiskImage.create(image: short, size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            #expect(runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test("반대로 /private/tmp로 주고 hdiutil이 /tmp 철자를 돌려줘도 짝으로 본다")
    func imagePathComparedByRealpathReverse() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            runner.infoImagePath = folder.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") + "/t.img"
            formatting(runner, image: folder + "/t.img")
            _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, name: "DJCTEST", environment: environment(runner))
            #expect(runner.verbs.contains("newfs_msdos"))
        }
    }

    @Test("포맷 직후 파일 시스템 이름은 보지 않는다(0x0B는 MS-DOS, 0x0C는 없음)", arguments: [UInt8(0x0B), UInt8(0x0C)])
    func createDoesNotRequireFilesystemNameAfterFormat(type: UInt8) throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            let runner = FakeToolRunner()
            runner.partitionType = type
            formatting(runner, image: image, clusters: 126_992, spc: 1)
            let created = try UsbDiskImage.create(image: image, size: 64 * Self.mib, type: type, name: "DJCTEST", environment: environment(runner))
            #expect(created.summary.hasPrefix(String(format: "FAT32 만듦: 0x%02X, 클러스터 512B × 126992", type)))
        }
    }

    @Test("포맷 뒤 Content·파티션 표 모양이 다르면 실패")
    func createChecksContentAndScheme() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            runner.partitionType = 0x0C
            formatting(runner, image: folder + "/t.img")
            // 0x0B로 만들라 했는데 파티션이 Windows_FAT_32로 보인다
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/t.img", size: 64 * Self.mib, type: 0x0B, name: "DJCTEST", environment: environment(runner))
            }
            #expect(runner.verbs.last == "hdiutil detach")
        }
    }

    @Test("볼륨 이름·파티션 형식 검사")
    func createValidatesArguments() throws {
        try withFolder { folder in
            let runner = FakeToolRunner()
            for name in ["djctest", "TOO-LONG-NAME-X", ""] {
                #expect(throws: UsbError.self) {
                    _ = try UsbDiskImage.create(image: folder + "/n.img", size: 64 * Self.mib, name: name, environment: environment(runner))
                }
            }
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.create(image: folder + "/n.img", size: 64 * Self.mib, type: 0x07, name: "DJCTEST", environment: environment(runner))
            }
            #expect(runner.calls.isEmpty)
        }
    }

    // MARK: - 붙이기·떼기·정보·채우기

    @Test("마운트 뒤 파일 시스템 이름을 5초까지 기다린다")
    func attachPollsFilesystemNameUpTo5s() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            try FileManager.default.createDirectory(atPath: folder + "/mnt", withIntermediateDirectories: false)
            let runner = FakeToolRunner()
            let attached = try UsbDiskImage.attach(image: image, mountPoint: folder + "/mnt", environment: environment(runner))
            #expect(attached.partitionDevice == runner.partition)
            #expect(attached.mountPoint == folder + "/mnt")
            #expect(runner.calls.filter { $0.contains("info") && $0.last == runner.partition }.count == 3)
            #expect(runner.calls.contains(["/usr/sbin/diskutil", "mount", "-mountOptions", "nobrowse", "-mountPoint", folder + "/mnt", runner.partition]))
        }
    }

    @Test("5초 안에 FAT32로 보이지 않으면 떼고 실패")
    func attachFailsIfNeverFAT32() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            try FileManager.default.createDirectory(atPath: folder + "/mnt", withIntermediateDirectories: false)
            let runner = FakeToolRunner()
            runner.neverFAT32 = true
            let clock = Clock()
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.attach(image: image, mountPoint: folder + "/mnt", environment: environment(runner, clock: clock))
            }
            #expect(runner.verbs.last == "hdiutil detach")
            #expect(clock.now.timeIntervalSince1970 - 1_000 >= 5)
        }
    }

    @Test("떼기는 image-path(realpath)로 장치를 찾는다")
    func detachResolvesDeviceByImagePath() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            let runner = FakeToolRunner()
            runner.whole = "/dev/disk15"
            runner.partition = "/dev/disk15s1"
            runner.attach(image: image.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
            let env = environment(runner)
            let detached = try UsbDiskImage.detach(image: image, force: true, environment: env)
            #expect(detached)
            #expect(runner.calls.last == ["/usr/bin/hdiutil", "detach", "-force", "/dev/disk15"])
            // 붙어 있지 않으면 부르지 않는다
            let again = try UsbDiskImage.detach(image: image, force: false, environment: env)
            #expect(!again)
            #expect(runner.verbs.filter { $0 == "hdiutil detach" }.count == 1)
        }
    }

    @Test("rekordbox가 켜져 있으면 만들기·붙이기·채우기를 거부(떼기·정보는 허용)")
    func rekordboxRunningRefusesAttachAndSeed() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data(count: 4096))
            try FileManager.default.createDirectory(atPath: folder + "/mnt", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: folder + "/from", withIntermediateDirectories: false)
            let runner = FakeToolRunner()
            let env = environment(runner, rekordbox: true)
            #expect(throws: UsbError.self) { _ = try UsbDiskImage.create(image: folder + "/n.img", size: 64 * Self.mib, name: "DJCTEST", environment: env) }
            #expect(throws: UsbError.self) { _ = try UsbDiskImage.attach(image: image, mountPoint: folder + "/mnt", environment: env) }
            #expect(throws: UsbError.self) { _ = try UsbDiskImage.seed(image: image, from: folder + "/from", environment: env) }
            #expect(runner.calls.isEmpty)
            let detached = try UsbDiskImage.detach(image: image, force: false, environment: env)
            #expect(!detached)
            #expect(throws: Never.self) { _ = try UsbDiskImage.info(image: image, environment: env) }
        }
    }

    @Test("정보: 붙어 있지 않으면 BPB만")
    func infoDetachedShowsBPB() throws {
        try withFolder { folder in
            let image = folder + "/c.img"
            FileManager.default.createFile(atPath: image, contents: nil)
            let handle = try #require(FileHandle(forWritingAtPath: image))
            try handle.truncate(atOffset: UInt64(64 * Self.mib))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: UsbDiskImage.mbr(totalSectors: 131_072, type: 0x0C))
            try handle.close()
            FakeToolRunner.writeBootSector(FakeToolRunner.bootSector(clusters: 126_992, sectorsPerCluster: 1), toImage: image)
            let lines = try UsbDiskImage.info(image: image, environment: environment(FakeToolRunner()))
            #expect(lines.contains { $0.contains("0x0C") })
            #expect(lines.contains { $0.contains("126992") })
            #expect(lines.contains { $0.contains("붙어 있지 않음") })
        }
    }

    @Test("채우기: 실물로 보이는 볼륨이면 아무것도 복사하지 않는다")
    func seedRefusesNonDiskImageVolume() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            try FileManager.default.createDirectory(atPath: folder + "/from/PIONEER", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder + "/from/PIONEER/x.bin", contents: Data("x".utf8))
            try FileManager.default.createDirectory(atPath: folder + "/mnt", withIntermediateDirectories: false)
            let runner = FakeToolRunner()
            runner.attach(image: image)
            _ = try runner.run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", folder + "/mnt", runner.partition])
            #expect(throws: UsbError.self) {
                _ = try UsbDiskImage.seed(image: image, from: folder + "/from", environment: environment(runner, volume: FakeUsbVolume.physicalFAT32()))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder + "/mnt").isEmpty)
        }
    }

    @Test("채우기: 붙어 있지 않으면 먼저 붙이라고 한다")
    func seedRequiresAttachedImage() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            try FileManager.default.createDirectory(atPath: folder + "/from", withIntermediateDirectories: false)
            do {
                _ = try UsbDiskImage.seed(image: image, from: folder + "/from", environment: environment(FakeToolRunner()))
                Issue.record("거부하지 않았다")
            } catch let UsbError.diskImageToolFailed(detail) {
                #expect(detail.contains("usb-image attach"))
            }
        }
    }

    @Test("채우기: 열지 않는 경로·._·시스템 폴더를 빼고 데이터만, 트리 기록은 이미지 옆에")
    func seedCopiesDataOnly() throws {
        try withFolder { folder in
            let image = folder + "/t.img"
            FileManager.default.createFile(atPath: image, contents: Data())
            let from = folder + "/from"
            for (path, text) in [("PIONEER/rekordbox/export.pdb", "pdb"), ("PIONEER/extracted/x", "secret"), ("PIONEER/._x", "ad"),
                                 (".Spotlight-V100/x", "idx"), ("Contents/A/a.mp3", "audio")] {
                try FileManager.default.createDirectory(atPath: (from + "/" + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: from + "/" + path, contents: Data(text.utf8))
            }
            try FileManager.default.createDirectory(atPath: folder + "/mnt", withIntermediateDirectories: false)
            let runner = FakeToolRunner()
            runner.attach(image: image)
            _ = try runner.run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", folder + "/mnt", runner.partition])
            let seeded = try UsbDiskImage.seed(image: image, from: from, environment: environment(runner))
            #expect(seeded.files == 2)
            let copied = try FileManager.default.subpathsOfDirectory(atPath: folder + "/mnt").sorted()
            #expect(copied == ["Contents", "Contents/A", "Contents/A/a.mp3", "PIONEER", "PIONEER/rekordbox", "PIONEER/rekordbox/export.pdb"])
            let tree = try String(contentsOfFile: image + ".seed-tree.txt", encoding: .utf8)
            #expect(tree.contains("PIONEER/rekordbox/export.pdb"))
            #expect(tree.trimmingCharacters(in: .newlines).hasSuffix("# appledouble 0"))
        }
    }

    @Test("모든 경로 인자는 임시 폴더 아래만", arguments: ["/Volumes/X/x.img", NSHomeDirectory() + "/Library/Pioneer/x.img", NSHomeDirectory() + "/djc-x.img"])
    func pathsGoThroughScratchCheck(path: String) throws {
        let runner = FakeToolRunner()
        let env = environment(runner)
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch UsbError.pathRefused { return true } catch { return false }
        }
        #expect(refused { _ = try UsbDiskImage.create(image: path, size: 64 * Self.mib, name: "DJCTEST", environment: env) })
        #expect(refused { _ = try UsbDiskImage.attach(image: path, mountPoint: "/private/tmp", environment: env) })
        #expect(refused { _ = try UsbDiskImage.seed(image: path, from: "/private/tmp", environment: env) })
        #expect(refused { _ = try UsbDiskImage.detach(image: path, force: false, environment: env) })
        #expect(refused { _ = try UsbDiskImage.info(image: path, environment: env) })
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
