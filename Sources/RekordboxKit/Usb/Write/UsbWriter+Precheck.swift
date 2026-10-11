import DJCDomain
import Foundation

/// A 막힘 확인(부작용 없음, 백업 전). USB는 이름·크기만 읽는다(DB 지문만 해시).
extension UsbWriter {
    /// 만들 대상이 기존 파일을 조용히 덮지 않는지. rename(2)은 대상이 있으면 바꿔치고, FAT(macOS msdos)는 대소문자·NFC/NFD만
    /// 다른 이름을 같은 이름으로 본다. 그래서 부모 폴더를 열거해 같은 충돌 키의 이름이 있으면 막는다. 파일을 쓰지 않는다(list만)
    public static func createCollisionBlocks(_ changes: UsbChangeSet, root: UsbRoot,
                                             fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws -> [UsbBlock] {
        try collisionBlocks(changes, root: root, fileSystem: fileSystem, skipping: [])
    }

    static func collisionBlocks(_ changes: UsbChangeSet, root: UsbRoot, fileSystem: any UsbFileSystem,
                                skipping: Set<String>) throws -> [UsbBlock] {
        // 받을 수 없는 경로(루트 밖·열지 않는 곳)는 경로 검사가 막는다. 여기서는 stat·열거하지 않고 건너뛴다
        func checkable(_ path: String) -> Bool { !skipping.contains(path) && isSafeRelativePath(path) }
        var targets = changes.copies.filter { $0.disposition == .create }.map(\.destination)
            + changes.writes.filter { $0.disposition == .create }.map(\.destination)
        for database in changes.databases where checkable(database.destination) {
            // 수정이어도 없던 DB는 새로 만드는 것이다
            let missing = try fileSystem.stat(root.url.appending(path: database.destination)) == nil
            if changes.base == nil || missing {
                targets.append(database.destination)
            }
        }
        var listings: [String: [String]?] = [:]
        func names(_ directory: String) throws -> [String]? {
            if let cached = listings[directory] { return cached }
            let url = directory.isEmpty ? root.url : root.url.appending(path: directory)
            var result: [String]?
            if let info = try fileSystem.stat(url), info.kind == .directory { result = try fileSystem.list(url) }
            listings[directory] = result
            return result
        }
        var blocks: [UsbBlock] = []
        var blocked: Set<String> = []
        func block(_ path: String) {
            guard blocked.insert(path).inserted else { return }
            blocks.append(UsbBlock(code: "destinationExists", scope: .file(path),
                                   message: String(ui: "USB에 같은 이름의 파일이 이미 있습니다. 빈 USB를 쓰거나 USB 수정으로 여세요")))
        }
        for target in targets where checkable(target) {
            let components = UsbLayout.nfc(target).split(separator: "/").map(String.init)
            var parent = ""
            for (index, component) in components.enumerated() {
                let path = UsbPath.join(parent, component)
                // 열지 않는 폴더는 열거하지 않는다. 부모가 새로 만들 폴더면 그 아래에는 충돌이 있을 수 없다
                guard parent.isEmpty || !UsbLayout.isNeverRead(parent), let listed = try names(parent) else { break }
                let key = UsbLayout.collisionKey(component)
                let matches = listed.filter { UsbLayout.collisionKey($0) == key }
                if index == components.count - 1 {
                    if !matches.isEmpty { block(target) }
                } else if matches.isEmpty {
                    break
                } else if !matches.contains(where: { UsbLayout.nfc($0) == component }) {
                    // 키만 같고 철자가 다른 폴더: 계획이 USB 철자를 다시 썼어야 한다
                    block(path)
                    break
                }
                parent = path
            }
        }
        return blocks
    }

    /// USB 상대 경로로 받아도 되는지(파일 연산 전에 모양만 본다): 비어 있지 않음, "/"로 시작하지 않음, ""·"."·".." 성분 없음,
    /// 첫 성분이 PIONEER·Contents(대소문자·NFC 무시), 열지 않는 곳·시스템 폴더가 아님. 쓰기 전 확인·되돌리기·회복이 같이 쓴다
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let first = components.first, ["pioneer", "contents"].contains(UsbLayout.collisionKey(first)) else { return false }
        return !UsbLayout.isNeverRead(path) && !UsbLayout.isSystemIgnored(path)
    }

    /// 우리 임시 이름(`.djc-part-…`, 폴더 구분자 없음)인지
    static func isSafeTempName(_ name: String) -> Bool {
        !name.contains("/") && !name.contains("\0") && UsbLayout.isTemp(name)
    }

    /// 세션 번호는 임시 이름·준비 폴더 이름에 들어가므로 영문·숫자·-·_만 받는다
    static func isSafeSession(_ session: String) -> Bool {
        !session.isEmpty && session.count <= 64 && session.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// 저널이 가리키는 경로·임시 이름·세션 중 받을 수 없는 것(빈 배열 = 통과). 되돌리기·회복은 백업 폴더·usb-sessions의
    /// 기록을 읽어 USB 파일을 지우고 이름을 바꾸므로, 깨졌거나 누가 고친 기록이 USB 루트 밖을 가리키면 파일 연산 전에 막는다
    static func unsafeEntries(in journal: UsbJournal) -> [String] {
        var bad: [String] = []
        func path(_ value: String) { if !isSafeRelativePath(value) { bad.append(value) } }
        func temp(_ value: String) {
            if !isSafeTempName(value) || !value.hasPrefix(UsbLayout.tempPrefix + journal.session + "-") { bad.append(value) }
        }
        func database(_ value: String) { if !databaseOrder.contains(value) { bad.append(value) } }
        func sidecar(_ value: String) { if !databaseFamily.contains(value) { bad.append(value) } }
        if !isSafeSession(journal.session) { bad.append(journal.session) }
        for entry in journal.entries {
            path(entry.destination)
            entry.tempName.map(temp)
        }
        for entry in journal.databases {
            database(entry.destination)
            temp(entry.tempName)
            entry.sidecarsPreexisted.forEach(sidecar)
        }
        journal.plannedDatabases.forEach { database($0.destination) }
        journal.createdDirs.forEach(path)
        journal.deletedSidecars.forEach(sidecar)
        journal.removals.forEach { path($0.path) }
        var deletedPaths: Set<String> = []
        for entry in journal.sidecarDeletions ?? [] {
            sidecar(entry.destination)
            if databaseOrder.contains(entry.destination) || !deletedPaths.insert(entry.destination).inserted
                || entry.operation != .delete || entry.tempName != nil || entry.backupSHA256 != nil
                || [.copying, .renamePending, .renameEntered].contains(entry.phase) { bad.append(entry.destination) }
        }
        var restoredPaths: Set<String> = []
        for (destination, target) in journal.restorationBaseline ?? [:] {
            path(destination)
            if target.sha256?.isEmpty == true || (target.sha256 != nil && target.link != nil) { bad.append(destination) }
        }
        for entry in journal.restorations ?? [] {
            path(entry.destination)
            entry.tempName.map(temp)
            if !restoredPaths.insert(entry.destination).inserted { bad.append(entry.destination) }
            switch entry.operation {
            case .replace:
                if entry.tempName == nil || entry.backupSHA256 == nil || [.deletePending, .deleteEntered].contains(entry.phase) { bad.append(entry.destination) }
            case .delete:
                if entry.tempName != nil || entry.backupSHA256 != nil || [.copying, .renamePending, .renameEntered].contains(entry.phase) { bad.append(entry.destination) }
            }
        }
        let changes = journal.changes
        changes.databases.forEach { database($0.destination) }
        changes.copies.forEach { path($0.destination) }
        changes.writes.forEach {
            path($0.destination)
            if $0.afterDatabases == true, !UsbSyncSelectionStage.isSelectionPath($0.destination) { bad.append($0.destination) }
        }
        changes.removals.forEach { path($0.path) }
        changes.base?.files.keys.forEach(path)
        changes.target.mustExist.keys.forEach(path)
        changes.target.mustNotExist.forEach(path)
        return bad
    }

    /// 백업 목록(manifest)의 경로 중 받을 수 없는 것(빈 배열 = 통과)
    static func unsafeEntries(in manifest: UsbManifest) -> [String] {
        let paths = Array(manifest.files.keys) + Array(manifest.before.keys) + manifest.absentBefore + manifest.removedAudio.map(\.path)
            + manifest.appleDoublesPreexisting
        return paths.filter { !isSafeRelativePath($0) }
    }
}

extension UsbWriteRun {
    /// 쓰기 전 확인에서 정한 DB별 처리
    struct Plan {
        var databases: [UsbJournal.PlannedDatabase] = []
    }

    /// 5–11. 하나라도 걸리면 `writeRefused`(USB·백업·저널 그대로)
    func precheck(_ changes: UsbChangeSet, inspectors: [any UsbWriteInspector]) throws -> Plan {
        var blocks: [UsbBlock] = []
        // 5. 닫히지 않은 저널. 깨져 읽지 못하는 저널은 회복도 거부하므로 회복하라고 하지 않고 회복과 같은 이유로 막는다
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .open:
            blocks.append(UsbBlock(code: "recoveryNeeded", scope: .volume,
                                   message: String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요")))
        case .corrupt: blocks.append(UsbWriter.journalUnreadableBlock)
        case .missing, .closed: break
        }
        // 6. 다른 쓰기(다른 맥·다른 DJC_HOME)가 남긴 임시 파일
        if try !UsbWriter.tempFiles(root: root, fileSystem: fs).isEmpty {
            blocks.append(UsbBlock(code: "tempFilesPresent", scope: .volume,
                                   message: String(ui: "USB에 끝나지 않은 쓰기의 임시 파일이 있습니다. `djc usb-recover --discard-temp`로 지운 뒤 다시 시도하세요")))
        }
        // 7. 수정: 계획 뒤 DB가 그대로인지. 내보내기: 빈 USB
        if let base = changes.base {
            if !(try UsbWriter.databaseFingerprint(root: root, fileSystem: fs)).sameContent(as: base) {
                blocks.append(UsbBlock(code: "usbChanged", scope: .volume, message: String(ui: "USB가 그 사이 바뀌었습니다. USB를 다시 읽은 뒤 쓰세요")))
            }
        } else {
            if changes.purpose == .edit {
                blocks.append(UsbBlock(code: "baseMissing", scope: .volume, message: String(ui: "USB를 다시 읽은 뒤 쓰세요")))
            }
            let count = try pioneerTopLevelCount()
            if count > 0 {
                blocks.append(UsbBlock(code: "notEmpty", scope: .volume,
                                       message: String(ui: "USB에 이미 PIONEER 폴더 내용(\(count)개)이 있습니다. 빈 USB를 쓰거나 USB 수정으로 여세요")))
            }
        }
        // 10. 대상 경로. 형식 검사기보다 먼저 본다: 받을 수 없는 경로가 있으면 검사기가 그 경로를 읽지 않게 건너뛴다
        let pathBlocks = try pathBlocks(changes)
        blocks += pathBlocks
        // 8. 형식별 막힘
        if pathBlocks.isEmpty {
            blocks += try UsbSyncSelectionStage.precheckBlocks(changes, root: root, stagingRoot: UsbRoot(paths.staging), fileSystem: fs)
            for inspector in inspectors { blocks += try inspector.blocks(root: root, changes: changes) }
        }
        let refused = Set(pathBlocks.compactMap { block -> String? in if case let .file(path) = block.scope { path } else { nil } })
        // 9. 용량
        if let block = capacityBlock(changes) { blocks.append(block) }
        // 11. 만들 대상 충돌
        blocks += try UsbWriter.collisionBlocks(changes, root: root, fileSystem: fs, skipping: refused)

        var plan = Plan()
        for database in changes.databases where !refused.contains(database.destination) {
            let url = usb(database.destination)
            if let info = try fs.stat(url), info.kind == .file {
                let old = try changes.base?.files[database.destination]?.sha256 ?? fs.sha256(url, uncached: true)
                plan.databases.append(.init(destination: database.destination, disposition: .overwritten, oldSHA256: old))
            } else {
                plan.databases.append(.init(destination: database.destination, disposition: .created, oldSHA256: nil))
            }
        }
        if !blocks.isEmpty { throw UsbError.writeRefused(Self.unique(blocks)) }
        return plan
    }

    static func unique(_ blocks: [UsbBlock]) -> [UsbBlock] {
        var seen: Set<UsbBlock> = []
        return blocks.filter { seen.insert($0).inserted }
    }

    /// `PIONEER/` 바로 아래 이름 수(macOS가 만드는 "."로 시작하는 이름 빼고). 하위 폴더로 내려가지 않는다
    func pioneerTopLevelCount() throws -> Int {
        let url = usb("PIONEER")
        guard let info = try fs.stat(url) else { return 0 }
        guard info.kind == .directory else { return 1 }
        return try fs.list(url).filter { !$0.hasPrefix(".") }.count
    }

    /// 모든 대상·지울 경로: 상대 경로, ".."·"."·빈 성분 없음, 열지 않는 곳 아님, 우리 폴더 아래, 부모에 심볼릭 링크 없음
    func pathBlocks(_ changes: UsbChangeSet) throws -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        func refuse(_ path: String, _ message: String = String(ui: "USB에 쓸 수 없는 경로입니다. USB를 다시 읽은 뒤 쓰세요")) {
            blocks.append(UsbBlock(code: "pathRefused", scope: .file(path), message: message))
        }
        func check(_ path: String, destination: Bool) throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard UsbWriter.isSafeRelativePath(path), components.count >= 2 else { return refuse(path) }
            let name = components.last!
            if destination, UsbLayout.isAppleDouble(name) || UsbLayout.isTemp(name) { return refuse(path) }
            var current = root.url
            for (index, component) in components.enumerated() {
                current = current.appending(path: component)
                guard let info = try fs.stat(current) else { break }
                if info.kind == .symlink { return refuse(path) }
                if index < components.count - 1, info.kind != .directory { return refuse(path) }
                if index == components.count - 1, info.kind != .file { return refuse(path) }
            }
        }
        // 세션 번호는 임시 이름이 된다(폴더 구분자가 들어가면 다른 폴더에 쓰게 된다)
        if !UsbWriter.isSafeSession(changes.session) {
            blocks.append(UsbBlock(code: "pathRefused", scope: .volume, message: String(ui: "USB에 쓸 수 없는 경로입니다. USB를 다시 읽은 뒤 쓰세요")))
        }
        var seen: [String: String] = [:]
        func duplicate(_ path: String) {
            let key = UsbLayout.collisionKey(path)
            if seen[key] != nil {
                blocks.append(UsbBlock(code: "destinationDuplicate", scope: .file(path),
                                       message: String(ui: "같은 USB 경로에 파일 두 개를 쓰려 합니다. 다시 미리 보기한 뒤 쓰세요")))
            }
            seen[key] = path
        }
        for copy in changes.copies {
            try check(copy.destination, destination: true)
            duplicate(copy.destination)
            if copy.disposition == .overwrite {
                blocks.append(UsbBlock(code: "unsupportedDisposition", scope: .file(copy.destination),
                                       message: String(ui: "USB의 음원 파일은 덮어쓰지 않습니다. 다시 미리 보기한 뒤 쓰세요")))
            }
        }
        for write in changes.writes {
            try check(write.destination, destination: true)
            duplicate(write.destination)
            if write.afterDatabases == true, !UsbSyncSelectionStage.isSelectionPath(write.destination) {
                refuse(write.destination)
            }
            if write.disposition == .overwrite, write.expectedExistingSHA256 == nil {
                blocks.append(UsbBlock(code: "missingExpectedHash", scope: .file(write.destination),
                                       message: String(ui: "덮어쓸 파일의 계획 때 상태를 모릅니다. USB를 다시 읽은 뒤 쓰세요")))
            }
        }
        for database in changes.databases {
            duplicate(database.destination)
            if !UsbWriter.databaseOrder.contains(database.destination) { refuse(database.destination) } else {
                try check(database.destination, destination: true)
            }
        }
        for removal in changes.removals { try check(removal.path, destination: false) }
        // 덮어쓰기·재사용은 대상이 있어야 한다
        let refused = Set(blocks.compactMap { block -> String? in if case let .file(path) = block.scope { path } else { nil } })
        let existing = changes.copies.filter { $0.disposition == .reuse }.map(\.destination)
            + changes.writes.filter { $0.disposition != .create }.map(\.destination)
        for path in existing where !refused.contains(path) {
            if try fs.stat(usb(path))?.kind != .file {
                blocks.append(UsbBlock(code: "destinationMissing", scope: .file(path),
                                       message: String(ui: "USB가 그 사이 바뀌었습니다. USB를 다시 읽은 뒤 쓰세요")))
            }
        }
        return blocks
    }

    /// 새로 쓰는 크기(클러스터로 올림) + 가장 큰 DB × 2 + 여유(64MiB와 가용 1% 중 큰 것) − 지울 크기 ≤ 가용
    func capacityBlock(_ changes: UsbChangeSet) -> UsbBlock? {
        let cluster = Int64(max(volume.clusterSize ?? 32_768, 512))
        func rounded(_ size: Int64) -> Int64 { (max(size, 0) + cluster - 1) / cluster * cluster }
        var needed = changes.copies.filter { $0.disposition == .create }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.writes.filter { $0.disposition != .reuse }.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += changes.databases.reduce(Int64(0)) { $0 + rounded($1.size) }
        needed += 2 * (changes.databases.map(\.size).max() ?? 0)
        needed += max(64 * 1024 * 1024, volume.available / 100)
        needed -= changes.removals.reduce(Int64(0)) { $0 + $1.expectedSize }
        guard needed > volume.available else { return nil }
        let megabyte: Int64 = 1024 * 1024
        let need = (needed + megabyte - 1) / megabyte, free = volume.available / megabyte
        return UsbBlock(code: "insufficientSpace", scope: .volume,
                        message: String(ui: "USB 여유 공간이 모자랍니다(필요 \(need)MB, 여유 \(free)MB). 곡을 줄이거나 공간이 더 있는 USB를 쓰세요"))
    }
}
