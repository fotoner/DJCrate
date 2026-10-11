import DJCDomain
import Foundation

/// F 지우기: 허용 목록(`UsbRemovalPolicy`) + 크기·SHA-256 = 계획 + 분석 파일이면 PPTH = 계획일 때만 지우고 짝 `._<이름>`도 지운다.
/// 조건이 안 맞으면 건너뛰고 알린다(분석 파일은 같은 곡의 .DAT·.EXT·.2EX를 함께 남긴다). 비게 된 우리 폴더만 지운다.
extension UsbWriteRun {
    func cleanup(_ changes: UsbChangeSet) throws {
        if journal.state == .cleaned { return }
        try checkRekordbox()
        try ensureSameVolume()
        emit(.cleanup, total: changes.removals.count, cancellable: false)
        for group in Self.removalGroups(changes.removals) {
            let pending = group.filter { removal in journal.removals.first { $0.path == removal.path }?.state == .pending }
            guard !pending.isEmpty else { continue }
            var skip: UsbJournal.SkipReason?
            var present: [UsbFileRemoval] = []
            for removal in pending {
                try ensureMounted()
                guard try fs.stat(usb(removal.path)) != nil else {
                    // 이미 없다(지난 회복이 지웠거나 기기가 지움)
                    setRemoval(removal.path, .removed)
                    continue
                }
                if let reason = try skipReason(removal) {
                    skip = skip ?? reason
                } else {
                    present.append(removal)
                }
            }
            if let skip {
                for removal in pending { setRemoval(removal.path, .skipped, reason: skip) }
                report.notes.append(Self.skipNote(skip, path: pending[0].path))
                try saveJournal()
                continue
            }
            for removal in present {
                try ensureMounted()
                try fs.remove(usb(removal.path))
                setRemoval(removal.path, .removed)
                try saveJournal()
                try removeExactAppleDouble(parent: UsbPath.parent(removal.path), name: UsbPath.name(removal.path))
                report.filesRemoved += 1
            }
        }
        // 비게 된 폴더는 저널 기준으로 본다: 끊긴 쓰기를 회복이 마저 할 때 끊기기 전에 지운 파일의 폴더도 들어간다
        for folder in Self.emptiableFolders(of: journal.removals.filter { $0.state == .removed }.map(\.path)) {
            try ensureMounted()
            if try fs.removeDirectoryIfEmpty(usb(folder)) {
                try removeExactAppleDouble(parent: UsbPath.parent(folder), name: UsbPath.name(folder))
            }
        }
        try journal.move(to: .cleaned)
        try saveJournal()
    }

    func setRemoval(_ path: String, _ state: UsbJournal.RemovalState, reason: UsbJournal.SkipReason? = nil) {
        guard let index = journal.removals.firstIndex(where: { $0.path == path }) else { return }
        journal.removals[index].state = state
        journal.removals[index].reason = reason
    }

    /// 지우면 안 되는 이유(없으면 nil)
    func skipReason(_ removal: UsbFileRemoval) throws -> UsbJournal.SkipReason? {
        guard try UsbRemovalPolicy.allows(removal.path, root: root, fileSystem: fs) else { return .notAllowed }
        let url = usb(removal.path)
        guard let info = try fs.stat(url), info.size == removal.expectedSize,
              try fs.sha256(url, uncached: false) == removal.expectedSHA256 else { return .hashDiffers }
        if UsbPath.isAnalysis(removal.path) {
            guard let expected = removal.expectedPPTH else { return .notAllowed }
            if let ppthReader {
                // 그 사이 다른 곡이 이 번호를 쓰게 됐거나 기기가 다시 분석해 썼다
                let found = ppthReader(try fs.read(url, maxBytes: 64 << 20)).map(UsbLayout.nfc)
                if found != UsbLayout.nfc(expected) { return .ppthDiffers }
            }
        }
        return nil
    }

    static func skipNote(_ reason: UsbJournal.SkipReason, path: String) -> String {
        switch reason {
        case .ppthDiffers: String(ui: "분석 파일이 다른 곡 것이라 지우지 않았습니다: \(path)")
        case .hashDiffers: String(ui: "USB 파일이 계획 때와 달라 지우지 않았습니다: \(path)")
        case .notAllowed: String(ui: "지워도 되는 파일이 아니라 지우지 않았습니다: \(path)")
        }
    }

    /// 분석 파일은 같은 폴더·같은 이름 줄기(.DAT·.EXT·.2EX)끼리 묶는다. 나머지는 하나씩. 순서는 처음 나온 순
    static func removalGroups(_ removals: [UsbFileRemoval]) -> [[UsbFileRemoval]] {
        var groups: [[UsbFileRemoval]] = []
        var index: [String: Int] = [:]
        for removal in removals {
            guard UsbPath.isAnalysis(removal.path) else {
                groups.append([removal])
                continue
            }
            let key = UsbLayout.collisionKey((removal.path as NSString).deletingPathExtension)
            if let at = index[key] { groups[at].append(removal) } else {
                index[key] = groups.count
                groups.append([removal])
            }
        }
        return groups
    }

    /// 지운 파일 위의 우리 폴더(깊은 것부터): Contents/A/B·Contents/A, USBANLZ/P…/…·USBANLZ/P…, Artwork/0000N
    static func emptiableFolders(of paths: [String]) -> [String] {
        var folders: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let first = UsbLayout.collisionKey(components[0])
            let keep: Int
            if first == "contents" {
                keep = 1
            } else if UsbPath.isAnalysis(path) || UsbPath.isArtwork(path) {
                keep = 2
            } else {
                continue
            }
            var depth = components.count - 1
            while depth > keep {
                folders.insert(components[0..<depth].joined(separator: "/"))
                depth -= 1
            }
        }
        return folders.sorted { ($0.split(separator: "/").count, $0) > ($1.split(separator: "/").count, $1) }
    }
}
