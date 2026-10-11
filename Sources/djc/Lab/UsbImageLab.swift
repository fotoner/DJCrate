import CryptoKit
import DJCDomain
import DJCStorage
import Darwin
import Foundation
import RekordboxKit

/// 디스크 이미지·USB 쓰기 절차 실험(임시 폴더 아래 디스크 이미지에만 쓴다). 출력은 개발자용이라 번역하지 않는다
enum UsbImageLab {
    static let all: [Command] = [
        Command("usb-image", "create <이미지> [--size 4g] [--name DJCTEST] [--type 0x0B|0x0C] [--cluster <바이트>] | attach <이미지> --mount <폴더> | detach <이미지> [--force] | info <이미지> | seed --image <이미지> --from <폴더>",
                "임시 폴더 아래 FAT32 디스크 이미지를 만들고 붙이고 떼고 채운다(장치 번호는 늘 이미지 경로로 찾는다)", { try await image($0) }),
        Command("usb-tree", "<루트>", "USB 트리: NFC 경로·크기·SHA-256(시각 없음), 마지막 줄 ._ 수", { try await tree($0) }),
        Command("usb-write-check", "--volume <마운트> [--pause-after <단계>] [--slow <밀리초>] [--no-reattach]",
                "합성 묶음을 디스크 이미지에 써 보고 떼었다 다시 붙여 한 번 더 검증한다", { try await writeCheck($0) }),
        Command("usb-commit-crash", "--image <빈 FAT32 틀> --repeat N",
                "쓰는 도중 강제 분리를 되풀이해 파일마다 옛것 또는 새것이고 회복되는지 본다(반복마다 틀의 복제본을 쓴다)",
                { try await commitCrash($0) }),
    ]

    static func failure(_ detail: String) -> UsbError { .diskImageToolFailed(detail: detail) }

    static var rekordboxRefusal: UsbError {
        .writeRefused([UsbBlock(code: "rekordboxRunning", scope: .volume, message: "rekordbox를 완전히 종료한 뒤 다시 시도하세요")])
    }

    // MARK: - usb-image

    static func image(_ args: [String]) async throws {
        guard args.count >= 2 else { throw UsageError() }
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "create":
            guard let path = rest.first, !path.hasPrefix("--") else { throw UsageError() }
            guard let size = UsbDiskImage.parseSize(value(after: "--size", in: rest) ?? "4g") else { throw UsageError() }
            let type = try partitionType(value(after: "--type", in: rest) ?? "0x0B")
            let cluster = try value(after: "--cluster", in: rest).map { text -> Int in
                guard let bytes = Int(text) else { throw UsageError() }
                return bytes
            }
            let created = try UsbDiskImage.create(image: path, size: size, type: type, clusterBytes: cluster,
                                                  name: value(after: "--name", in: rest) ?? "DJCTEST")
            print(created.summary)
        case "attach":
            guard let path = rest.first, !path.hasPrefix("--"), let mount = value(after: "--mount", in: rest) else { throw UsageError() }
            let attached = try UsbDiskImage.attach(image: path, mountPoint: mount)
            print("붙임: \(attached.partitionDevice) → \(attached.mountPoint) (MS-DOS FAT32, msdos 확인)")
        case "detach":
            guard let path = rest.first, !path.hasPrefix("--") else { throw UsageError() }
            print(try UsbDiskImage.detach(image: path, force: rest.contains("--force")) ? "뗌" : "붙어 있지 않음")
        case "info":
            guard let path = rest.first, !path.hasPrefix("--") else { throw UsageError() }
            try UsbDiskImage.info(image: path).forEach { print($0) }
        case "seed":
            // 마운트 지점은 받지 않는다: 늘 이미지 경로로 찾는다
            guard let path = value(after: "--image", in: rest), let from = value(after: "--from", in: rest), rest.count == 4 else {
                throw UsageError()
            }
            let seeded = try UsbDiskImage.seed(image: path, from: from)
            print("채움: 파일 \(seeded.files)개, 시작 트리 \(seeded.treeFile)")
        default:
            throw UsageError()
        }
    }

    static func partitionType(_ text: String) throws -> UInt8 {
        let lower = text.lowercased()
        guard let value = lower.hasPrefix("0x") ? UInt8(lower.dropFirst(2), radix: 16) : UInt8(lower) else { throw UsageError() }
        return value
    }

    // MARK: - usb-tree

    static func tree(_ args: [String]) async throws {
        guard args.count >= 2 else { throw UsageError() }
        let root = try UsbScratchPath.check(args[1], as: .existingDirectory)
        print(UsbTree.render(try UsbTree.fingerprint(UsbRoot(URL(filePath: root)))))
    }

    // MARK: - usb-write-check

    static func writeCheck(_ args: [String]) async throws {
        guard let volumeArgument = value(after: "--volume", in: args) else { throw UsageError() }
        let volume = try UsbScratchPath.check(volumeArgument, as: .existingDirectory)
        let slow = try value(after: "--slow", in: args).map { text -> Int in
            guard let milliseconds = Int(text), milliseconds >= 0 else { throw UsageError() }
            return milliseconds
        } ?? 0
        var pauseAfter: UsbWriteStage?
        if let raw = value(after: "--pause-after", in: args) {
            guard let stage = UsbWriteStage(rawValue: raw) else { throw UsageError() }
            pauseAfter = stage
        }
        guard !LibrarySnapshot.isRekordboxRunning() else { throw rekordboxRefusal }
        setvbuf(stdout, nil, _IOLBF, 0)
        let paths = UsbWritePaths.default
        let session = UsbLayout.newSessionID()
        print("SESSION \(session)")
        let staging = paths.staging.appending(path: session)
        // 저널이 열린 채 끝나면(볼륨 사라짐 등) 회복이 마저 쓸 수 있게 준비 폴더를 남긴다. 그 밖에는 지운다
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: staging) } }
        let changes = try UsbSyntheticChanges.make(session: session, staging: staging)
        let root = UsbRoot(URL(filePath: volume))
        let fileSystem: any UsbFileSystem = slow > 0 ? SlowUsbFileSystem(inner: PosixUsbFileSystem(), delayMilliseconds: slow) : PosixUsbFileSystem()
        let options = UsbWriteOptions(pauseAfter: pauseAfter, pauseHandler: { stage in
            print("멈춤: \(stage.rawValue) 뒤. Enter를 누르면 이어 쓴다")
            _ = readLine()
        })
        let report: UsbWriteReport
        do {
            report = try UsbWriter.write(changes, root: root, paths: paths, guard: .system, fileSystem: fileSystem, options: options)
        } catch {
            switch error {
            case UsbError.volumeLost, UsbError.volumeChanged, UsbError.restorePending, UsbError.restoreFailed: keepStaging = true
            default: break
            }
            // usb-commit-crash가 자식의 끝 상태를 언어와 무관하게 읽는 줄
            if case UsbError.volumeLost = error { print("RESULT volumeLost") } else { print("RESULT error") }
            throw error
        }
        print("쓰기: \(report.outcome.rawValue), 만든 파일 \(report.filesCreated)개, DB \(report.resultDatabases.count)개")
        var result = try check(root, changes, scratch: staging)
        if !args.contains("--no-reattach") {
            let info = try UsbVolumes.info(root: URL(filePath: volume))
            guard info.isDiskImage, let image = info.diskImagePath else { throw failure("디스크 이미지로 확인되지 않아 다시 붙이지 않았다") }
            _ = try UsbDiskImage.detach(image: image)
            _ = try UsbDiskImage.attach(image: image, mountPoint: volume)
            result = try check(root, changes, scratch: staging)
            print("떼었다 다시 붙여 한 번 더 확인했다")
        }
        print("RESULT written")
        print("USB 쓰기 시험 통과: 파일 \(result.files)개, ._* \(result.appleDouble)개, .djc-part \(result.temps)개")
    }

    /// 목표 지문(매체에서 다시 읽음) + 트리 전체: 파일 수 = 목표, `._*` 0개, 임시 파일 0개
    static func check(_ root: UsbRoot, _ changes: UsbChangeSet, scratch: URL) throws -> (files: Int, appleDouble: Int, temps: Int) {
        let problems = try UsbFingerprintVerifier().verify(root: root, changes: changes, fileSystem: PosixUsbFileSystem(), scratch: scratch)
        guard problems.isEmpty else { throw failure("검증 실패: " + problems.joined(separator: ", ")) }
        let tree = try UsbTree.fingerprint(root, hashing: false)
        let temps = tree.files.keys.filter { UsbLayout.isTemp(($0 as NSString).lastPathComponent) }.count
        guard tree.files.count == changes.target.mustExist.count, tree.appleDoubleCount == 0, temps == 0 else {
            throw failure("트리가 목표와 다르다: 파일 \(tree.files.count)/\(changes.target.mustExist.count), ._ \(tree.appleDoubleCount), 임시 \(temps)")
        }
        return (tree.files.count, tree.appleDoubleCount, temps)
    }

    // MARK: - usb-commit-crash

    struct RunResult {
        var elapsed: TimeInterval
        var child: String
        var stage: String
        var raw: String
        var outcome: String
        var problems: [String]
    }

    static func commitCrash(_ args: [String]) async throws {
        guard let imageArgument = value(after: "--image", in: args) else { throw UsageError() }
        let template = try UsbScratchPath.check(imageArgument, as: .existingFile)
        guard let repeats = Int(value(after: "--repeat", in: args) ?? ""), repeats > 0 else { throw UsageError() }
        guard !LibrarySnapshot.isRekordboxRunning() else { throw rekordboxRefusal }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let djc = Bundle.main.executablePath else { throw failure("djc 실행 파일 위치를 모른다") }
        if try UsbDiskImage.info(image: template).contains(where: { $0.hasPrefix("장치: ") }) {
            throw failure("틀 이미지가 붙어 있다. 틀은 붙이지 않고 복제본만 붙인다")
        }
        let paths = UsbWritePaths.default
        let measured = try crashRun(index: 0, template: template, djc: djc, paths: paths, detachAfter: nil)
        guard measured.problems.isEmpty else { throw failure("측정 반복 실패: " + measured.problems.joined(separator: "; ")) }
        let limit = max(measured.elapsed, 1)
        print(String(format: "측정 반복(판정 수에 넣지 않음): %.1f초, 자식 %@", limit, measured.child))
        var passed = 0, recovered = 0
        var distribution: [String: Int] = [:]
        for index in 1...repeats {
            let delay = Double.random(in: 0.5...max(0.6, limit))
            let result = try crashRun(index: index, template: template, djc: djc, paths: paths, detachAfter: delay)
            distribution["\(result.child) · \(result.stage)", default: 0] += 1
            print(String(format: "반복 %d: %.2f초에 강제 분리, 자식 %@(저널 %@), 원시 판정 %@, 회복 %@ → %@", index, delay, result.child,
                         result.stage, result.raw, result.outcome, result.problems.isEmpty ? "통과" : "실패"))
            if !result.problems.isEmpty {
                print("실패한 반복 \(index): " + result.problems.joined(separator: "; "))
                print("\(passed)/\(repeats) 파일마다 옛것 또는 새것, 회복 \(recovered)/\(repeats)")
                exit(1)
            }
            passed += 1
            recovered += 1
        }
        print("\(passed)/\(repeats) 파일마다 옛것 또는 새것, 회복 \(recovered)/\(repeats)")
        for (key, count) in distribution.sorted(by: { $0.key < $1.key }) { print("  \(key): \(count)번") }
    }

    /// 틀 이미지의 크기·MBR 파티션 형식·FAT32 볼륨 이름(부트 섹터 0x47의 11바이트)
    static func templateShape(_ path: String) throws -> (size: Int64, type: UInt8, name: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw failure("틀을 읽지 못했다") }
        defer { try? handle.close() }
        let mbr = try handle.read(upToCount: 512) ?? Data()
        try handle.seek(toOffset: 2048 * 512)
        let boot = try handle.read(upToCount: 512) ?? Data()
        let size = try handle.seekToEnd()
        guard mbr.count == 512, boot.count == 512 else { throw failure("틀의 MBR·부트 섹터가 짧다") }
        let label = String(decoding: boot[0x47..<0x52], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return (Int64(size), mbr[0x1C2], label.isEmpty ? "DJCTEST" : label)
    }

    /// 한 반복: 틀 복제 → 붙이고 빈 상태 확인 → 자식 쓰기 → (강제 분리) → 자식 끝 기다림 → 마운트 지점이 비었는지 →
    /// 다시 붙여 원시 판정 → 회복 → 판정 → 떼고 복제본 지우기
    static func crashRun(index: Int, template: String, djc: String, paths: UsbWritePaths, detachAfter delay: Double?) throws -> RunResult {
        let clone = template + ".run-\(index).img", mount = template + ".run-\(index).mnt"
        var problems: [String] = []
        // 남은 복제본·마운트 지점은 건드리지 않고 멈춘다: 정리(떼기·지우기)는 이번 반복이 만든 것에만 건다
        for leftover in [clone, mount] where FileManager.default.fileExists(atPath: leftover) {
            throw failure("반복 \(index)의 복제본이 이미 있다. 지우고 다시 실행하라: \(leftover)")
        }
        _ = try UsbScratchPath.check(clone, as: .newFile)
        defer {
            _ = try? UsbDiskImage.detach(image: clone, force: true)
            try? FileManager.default.removeItem(atPath: clone)
            rmdir(mount)
        }
        // 0. 시작 상태: 틀의 APFS 복제본(볼륨 UUID가 같다)
        if clonefile(template, clone, 0) != 0 {
            // APFS 복제가 안 되면 틀과 같은 크기·파티션 형식·볼륨 이름으로 새로 만든다
            let shape = try templateShape(template)
            _ = try UsbDiskImage.create(image: clone, size: shape.size, type: shape.type, name: shape.name)
        }
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: false)
        // 1. 붙이고 빈 상태인지
        let attached = try UsbDiskImage.attach(image: clone, mountPoint: mount)
        let root = UsbRoot(URL(filePath: attached.mountPoint))
        let start = try UsbTree.fingerprint(root, hashing: false)
        let top = try FileManager.default.contentsOfDirectory(atPath: attached.mountPoint)
        guard start.files.isEmpty, start.appleDoubleCount == 0, !top.contains(where: { ["pioneer", "contents"].contains($0.lowercased()) }) else {
            throw failure("반복 \(index)의 시작 상태가 비어 있지 않다")
        }
        guard let key = try UsbVolumes.info(root: root.url).volumeUUID?.uppercased() else { throw failure("볼륨 UUID를 읽지 못했다") }
        // 2. 자식 쓰기(볼륨 잠금은 자식이 쥔다)
        let process = Process()
        process.executableURL = URL(filePath: djc)
        process.arguments = ["lab", "usb-write-check", "--volume", attached.mountPoint, "--slow", "20", "--no-reattach"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let started = Date()
        try process.run()
        // 3. 무작위 시점에 강제 분리
        if let delay {
            Thread.sleep(forTimeInterval: delay)
            _ = try UsbDiskImage.detach(image: clone, force: true)
        }
        // 4. 자식이 끝날 때까지(볼륨 잠금이 풀려야 회복한다)
        let deadline = Date().addingTimeInterval(delay == nil ? 600 : 30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let elapsed = Date().timeIntervalSince(started)
        let stdoutText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderrText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let resultLine = stdoutText.split(separator: "\n").last { $0.hasPrefix("RESULT ") }.map { String($0.dropFirst(7)) }
        let child = process.terminationStatus == 0 ? "끝까지" : resultLine == "volumeLost" ? "볼륨 사라짐" : "그 밖 오류"
        if delay == nil, process.terminationStatus != 0 { problems.append("측정 자식 실패: \(stderrText.prefix(300))") }
        let session = stdoutText.split(separator: "\n").first { $0.hasPrefix("SESSION ") }.map { String($0.dropFirst(8)) }
        let journalURL = paths.sessions.appending(path: key + ".json")
        let journalAtLoss = (try? Data(contentsOf: journalURL)).flatMap { try? UsbJournal.decoder().decode(UsbJournal.self, from: $0) }
        let ours = journalAtLoss?.session == session ? journalAtLoss : nil
        let stage = ours?.state.rawValue ?? "저널 전"
        if delay != nil {
            // 5. 분리 뒤 맥 폴더에 새어 나간 쓰기가 없는지
            let leaked = (try? FileManager.default.contentsOfDirectory(atPath: attached.mountPoint)) ?? []
            if !leaked.isEmpty { problems.append("분리 뒤 마운트 지점 폴더에 쓴 흔적: " + leaked.sorted().joined(separator: ", ")) }
            guard problems.isEmpty else { return RunResult(elapsed: elapsed, child: child, stage: stage, raw: "-", outcome: "-", problems: problems) }
            // 6. 다시 붙인다
            _ = try UsbDiskImage.attach(image: clone, mountPoint: mount)
        }
        // 원시 판정(회복 전): 목표 파일마다 없음(옛것)·새것·그 밖, 임시 파일 수
        var absent = 0, fresh = 0, other = 0
        let fs = PosixUsbFileSystem()
        for (path, stamp) in ours?.target.mustExist ?? [:] {
            let url = root.url.appending(path: path)
            guard let info = try fs.stat(url) else {
                absent += 1
                continue
            }
            let hash = info.kind == .file && info.size == stamp.size && stamp.sha256 != nil ? try fs.sha256(url, uncached: true) : nil
            if info.kind == .file, info.size == stamp.size, stamp.sha256 == nil || hash == stamp.sha256 {
                fresh += 1
            } else {
                other += 1
            }
        }
        let beforeTree = try UsbTree.fingerprint(root, hashing: false)
        let temps = beforeTree.files.keys.filter { UsbLayout.isTemp(($0 as NSString).lastPathComponent) }.count
        let raw = "없음 \(absent)·새것 \(fresh)·그 밖 \(other)·임시 \(temps)"
        if other > 0 { problems.append("옛것도 새것도 아닌 파일 \(other)개") }
        // 7. 회복: 사람이 쓰는 명령 그대로(djc usb-recover). 자식이 남긴 준비 폴더는 회복이 끝난 뒤 지운다
        let recoverStatus = try runRecover(djc: djc, volume: attached.mountPoint)
        if let session { try? FileManager.default.removeItem(at: paths.staging.appending(path: session)) }
        if recoverStatus.code != 0 { problems.append("usb-recover rc=\(recoverStatus.code): \(recoverStatus.output.prefix(300))") }
        // 8. 판정
        let tree = try UsbTree.fingerprint(root)
        let target = ours?.target.mustExist ?? [:]
        let isStart = tree.files.isEmpty
        let isTarget = !target.isEmpty && tree.files.count == target.count
            && target.allSatisfy { path, stamp in tree.files[path].map { $0.size == stamp.size && (stamp.sha256 == nil || $0.sha256 == stamp.sha256) } ?? false }
        if !(isStart || isTarget) { problems.append("회복 뒤 트리가 시작도 목표도 아니다(파일 \(tree.files.count)개)") }
        if tree.files.keys.contains(where: { UsbLayout.isTemp(($0 as NSString).lastPathComponent) }) { problems.append("임시 파일이 남았다") }
        if tree.appleDoubleCount != 0 { problems.append("._ 파일 \(tree.appleDoubleCount)개") }
        let closed = (try? Data(contentsOf: journalURL)).flatMap { try? UsbJournal.decoder().decode(UsbJournal.self, from: $0) }
        if ours != nil, let closed, ![.recovered, .rolledBack, .verified].contains(closed.state) {
            problems.append("저널이 닫히지 않았다(\(closed.state.rawValue))")
        }
        if ours != nil, let backup = closed?.backupDirectory {
            let decoder = UsbJournal.decoder()
            let saved = (try? Data(contentsOf: URL(filePath: backup).appending(path: "report.json"))).flatMap { try? decoder.decode(UsbWriteReport.self, from: $0) }
            let copy = FileManager.default.fileExists(atPath: backup + "/journal.json")
            var current: [String: String] = [:]
            for path in [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb] where try fs.stat(root.url.appending(path: path)) != nil {
                current[path] = try fs.sha256(root.url.appending(path: path), uncached: true)
            }
            if saved == nil || !copy { problems.append("백업 폴더에 journal.json·report.json이 없다") }
            if let saved, saved.resultDatabases != current { problems.append("report.json의 결과 DB 해시가 지금 USB와 다르다") }
        }
        let outcome = ours == nil ? "저널 없음" : closed.map { "\($0.state.rawValue)" } ?? "저널 없음"
        return RunResult(elapsed: elapsed, child: child, stage: stage, raw: raw, outcome: "rc \(recoverStatus.code), \(outcome)", problems: problems)
    }

    /// `djc usb-recover --volume <마운트>`를 자식으로 돌린다(같은 DJC_HOME). 문구는 한국어로 고정
    static func runRecover(djc: String, volume: String) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: djc)
        process.arguments = ["usb-recover", "--volume", volume]
        var environment = ProcessInfo.processInfo.environment
        environment["DJC_LANG"] = "ko"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// 파일 연산마다 잠깐 자는 파일 시스템(`--slow`): 데이터 1MiB마다, 쓰기·rename·fsync마다. 결과는 같고 시간만 늘어난다
struct SlowUsbFileSystem: UsbFileSystem {
    let inner: any UsbFileSystem
    let delayMilliseconds: Int

    private func pause() {
        if delayMilliseconds > 0 { usleep(useconds_t(delayMilliseconds) * 1000) }
    }

    func stat(_ url: URL) throws -> UsbFileStat? { try inner.stat(url) }
    func list(_ directory: URL) throws -> [String] { try inner.list(directory) }
    func makeDirectory(_ url: URL) throws { try inner.makeDirectory(url); pause() }
    func writeNew(_ data: Data, to url: URL) throws { try inner.writeNew(data, to: url); pause() }

    func copyDataNew(from source: URL, to url: URL, progress: (Int64) -> Void) throws -> (size: Int64, sha256: String, sha1: String) {
        var slept: Int64 = 0
        return try inner.copyDataNew(from: source, to: url) { bytes in
            while slept + (1 << 20) <= bytes {
                slept += 1 << 20
                pause()
            }
            progress(bytes)
        }
    }

    func setModificationDate(_ url: URL, _ date: Date) throws { try inner.setModificationDate(url, date) }
    func fullSync(_ url: URL) throws { try inner.fullSync(url); pause() }
    func syncDirectory(_ url: URL) throws { try inner.syncDirectory(url); pause() }
    func rename(_ from: URL, to: URL) throws { try inner.rename(from, to: to); pause() }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func removeDirectoryIfEmpty(_ url: URL) throws -> Bool { try inner.removeDirectoryIfEmpty(url) }
    func sha256(_ url: URL, uncached: Bool) throws -> String { try inner.sha256(url, uncached: uncached) }
    func read(_ url: URL, maxBytes: Int) throws -> Data { try inner.read(url, maxBytes: maxBytes) }
    func readFile(root: UsbRoot, relativePath: String, maxBytes: Int) throws -> UsbFileRead? {
        try inner.readFile(root: root, relativePath: relativePath, maxBytes: maxBytes)
    }
    func mountedOn(_ url: URL) throws -> String? { try inner.mountedOn(url) }
    func holdVolume(_ root: URL) throws -> any UsbVolumeHold { try inner.holdVolume(root) }
}

/// lab 쓰기 시험의 합성 변경 묶음(빈 USB에 내보내기 모양). 내용은 무작위 바이트, 이름은 지어낸 것.
/// 이름이 "_"로 시작하는 파일, 원본 이름이 NFD인 파일, 중첩 새 폴더를 넣고 음원 합은 64MiB 이상으로 한다
enum UsbSyntheticChanges {
    static let audio = [("Contents/Synthetic Artist/Nested Album/_lead take.mp3", 34 << 20),
                        ("Contents/Caf\u{E9} Band/Caf\u{E9} Album/Caf\u{E9} Song.m4a", 31 << 20)]
    static let analysis = ["PIONEER/USBANLZ/P0A1/000012AB/ANLZ0000.DAT", "PIONEER/USBANLZ/P0A1/000012AB/ANLZ0000.EXT",
                           "PIONEER/USBANLZ/P0A1/000012AB/ANLZ0000.2EX"]
    static let artwork = ["PIONEER/Artwork/00001/a1.jpg", "PIONEER/Artwork/00001/a1_m.jpg", "PIONEER/Artwork/00001/a2.jpg",
                          "PIONEER/Artwork/00001/a2_m.jpg"]
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func make(session: String, staging: URL) throws -> UsbChangeSet {
        let sources = staging.appending(path: "sources"), files = staging.appending(path: "files")
        for url in [sources, files] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var generator = SplitMix(seed: UInt64(abs(session.hashValue)))
        var mustExist: [String: UsbTreeStamp] = [:]
        var copies: [UsbFileCopy] = []
        for (index, (destination, size)) in audio.enumerated() {
            let data = generator.data(size)
            // 원본 이름은 macOS가 받은 NFD 그대로
            let name = "\(index)-" + (destination as NSString).lastPathComponent.decomposedStringWithCanonicalMapping
            let url = sources.appending(path: name)
            try data.write(to: url)
            copies.append(UsbFileCopy(source: url.path, destination: destination, size: Int64(size), sourceSHA1: sha1(data),
                                      modificationDate: date, disposition: .create))
            mustExist[destination] = UsbTreeStamp(size: Int64(size), sha256: sha256(data))
        }
        var writes: [UsbFileWrite] = []
        for (index, destination) in (analysis + artwork).enumerated() {
            let data = destination.contains("USBANLZ") ? Data("PPTH:/\(audio[0].0)\n".utf8) + generator.data(4096) : generator.data(24_000 + index)
            let url = files.appending(path: "w\(index)")
            try data.write(to: url)
            writes.append(UsbFileWrite(staged: url.path, destination: destination, sha256: sha256(data), size: Int64(data.count),
                                       modificationDate: destination.contains("Artwork") ? date : nil, disposition: .create))
            mustExist[destination] = UsbTreeStamp(size: Int64(data.count), sha256: sha256(data))
        }
        var databases: [UsbDatabaseReplacement] = []
        for (index, destination) in [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb].enumerated() {
            let data = generator.data(256 << 10)
            let url = files.appending(path: "db\(index)")
            try data.write(to: url)
            databases.append(UsbDatabaseReplacement(format: index == 0 ? .oneLibrary : .deviceLibrary, destination: destination,
                                                    staged: url.path, sha256: sha256(data), size: Int64(data.count)))
            mustExist[destination] = UsbTreeStamp(size: Int64(data.count), sha256: sha256(data))
        }
        return UsbChangeSet(session: session, label: "write-check", purpose: .export, formats: UsbFormat.defaultSet, requiredRules: [],
                            databases: databases, copies: copies, writes: writes, removals: [], base: nil,
                            target: UsbTargetFingerprint(mustExist: mustExist, mustNotExist: []),
                            stagingDirectory: files.path, idHighWater: [:])
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 빠른 의사 난수(큰 합성 파일용)
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func data(_ count: Int) -> Data {
            var words = [UInt64](repeating: 0, count: (count + 7) / 8)
            for index in words.indices { words[index] = next() }
            return words.withUnsafeBytes { Data($0.prefix(count)) }
        }
    }
}
