import DJCApplication
import DJCDomain
import Foundation

/// `djc usb-snapshot`: USB 시점 스냅샷(#226) 만들기·목록·되돌리기·고정·지우기. 흐름은 앱과 같은 유스케이스(`UsbPointSnapshots`)가 하고
/// 여기서는 인자를 풀고 결과를 찍는다. 만들기·목록은 USB를 읽기만 한다. 되돌리기는 쓰기라 쓰기와 같은 관문을 지난다
/// (실물 USB는 `--allow-physical --confirm <볼륨 이름>`). 스냅샷 파일의 경로·내용은 찍지 않는다.
enum UsbSnapshotCommand {
    static let command = Command("usb-snapshot",
                                 String(ui: "create [--name 이름] | list | restore|pin|unpin|delete <ID> — --volume <마운트> [--discard-device-changes] [--dry-run] [--allow-physical --confirm <볼륨 이름>]"),
                                 String(ui: "USB 라이브러리 파일(DB·분석 파일·앨범아트·설정 파일)을 시점 스냅샷으로 남기고 같은 USB로 되돌린다(음원은 담지 않음)")) { args in
        try run(args)
    }

    /// `usb-snapshot` 인자
    struct Request: Equatable {
        enum Action: String { case create, list, restore, pin, unpin, delete }

        var action: Action
        var volume: String
        /// restore·pin·unpin·delete의 스냅샷 ID(폴더 이름) 또는 겹치지 않는 이름
        var key: String?
        var name: String?
        var discardDeviceChanges = false
        var dryRun = false
        var confirmName: String?
        /// 실물 쓰기 동의(되돌리기만 쓴다)
        var allowPhysical = false
    }

    /// 모르는 인자·값 없는 인자·하위 명령에 맞지 않는 인자는 사용법. 라이브 라이브러리·DJCrate 데이터 폴더는 USB로 받지 않는다
    static func request(_ args: [String]) throws -> Request {
        guard args.count > 1, let action = Request.Action(rawValue: args[1]) else { throw UsageError() }
        var volume: String?, key: String?, name: String?, confirm: String?
        var discard = false, dryRun = false, allowPhysical = false
        var index = 2
        func next() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
            index += 1
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--volume": volume = try next()
            case "--name" where action == .create: name = try next()
            case "--discard-device-changes" where action == .restore: discard = true
            case "--dry-run" where action == .restore: dryRun = true
            case "--allow-physical" where action == .restore: allowPhysical = true
            case "--confirm" where action == .restore: confirm = try next()
            case let operand where !operand.hasPrefix("--") && key == nil && ![.create, .list].contains(action): key = operand
            default: throw UsageError()
            }
            index += 1
        }
        guard let volume, !volume.isEmpty, (key == nil) == [.create, .list].contains(action) else { throw UsageError() }
        try UsbCommands.rejectLiveLibrary(volume)
        return Request(action: action, volume: volume, key: key, name: name, discardDeviceChanges: discard, dryRun: dryRun, confirmName: confirm,
                       allowPhysical: allowPhysical)
    }

    /// - snapshots: 유스케이스(시험은 임시 폴더·가짜 가드로 조립한 것). nil이면 조립 지점의 것
    /// - output: 결과 줄(표준 출력). 진행은 표준 오류
    static func run(_ args: [String], snapshots: UsbPointSnapshots? = nil, output: (String) -> Void = { print($0) }) throws {
        let request = try request(args)
        let snapshots = snapshots ?? CLIComposition.usbPointSnapshots(allowPhysical: request.allowPhysical, paths: CLIComposition.usbWritePaths)
        let root = URL(filePath: request.volume)
        switch request.action {
        case .create:
            let entry = try snapshots.create(root: root, name: request.name ?? "")
            createdLines(entry).forEach(output)
        case .list:
            listLines(snapshots.entries(volumeKey: try snapshots.volumeKey(root: root))).forEach(output)
        case .restore:
            let entry = try snapshots.find(request.key ?? "", volumeKey: try snapshots.volumeKey(root: root))
            let options = UsbWriteOptions(dryRun: request.dryRun, confirmName: request.confirmName)
            let printer = UsbCommands.ProgressPrinter()
            do {
                let written = try snapshots.restore(root: root, entry: entry, discardDeviceChanges: request.discardDeviceChanges, options: options,
                                                    progress: { printer.show($0) }, isCancelled: { false })
                restoreLines(entry: entry, written: written, volume: request.volume).forEach(output)
            } catch let UsbError.writeRefused(blocks) {
                blocks.map { String(ui: "막힘 \($0.code): \($0.message)") }.forEach(output)
                throw UsbError.writeRefused(blocks)
            }
        case .pin, .unpin:
            let entry = try snapshots.find(request.key ?? "", volumeKey: try snapshots.volumeKey(root: root))
            try snapshots.setPinned(request.action == .pin, entry)
            output(request.action == .pin ? String(ui: "고정했습니다: \(entry.id)") : String(ui: "고정을 풀었습니다: \(entry.id)"))
        case .delete:
            let entry = try snapshots.find(request.key ?? "", volumeKey: try snapshots.volumeKey(root: root))
            try snapshots.delete(entry)
            output(String(ui: "지웠습니다: \(entry.id)"))
        }
    }

    // MARK: - 출력(파일 경로·내용은 찍지 않는다)

    static func contentsLine(_ metadata: UsbPointSnapshotMetadata) -> String {
        let size = metadata.totalSize.formatted(.byteCount(style: .file).locale(UIStrings.locale))
        return String(ui: "담은 것: DB \(metadata.databases.count) · 분석 파일 \(metadata.analysisFiles) · 앨범아트 \(metadata.artworkFiles) · 설정 파일 \(metadata.settingFiles) · \(size)")
    }

    static func createdLines(_ entry: UsbPointSnapshotEntry) -> [String] {
        [String(ui: "USB 스냅샷을 남겼습니다: \(entry.id)"), contentsLine(entry.metadata), String(ui: "음원은 담지 않습니다.")]
    }

    static func listLines(_ entries: [UsbPointSnapshotEntry]) -> [String] {
        var lines = [String(ui: "USB 스냅샷 \(entries.count)개")]
        for entry in entries {
            var parts = [entry.id]
            if !entry.metadata.name.isEmpty { parts.append("‘\(entry.metadata.name)’") }
            parts.append(entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
            parts.append(String(ui: "파일 \(entry.metadata.files.count)개"))
            parts.append(entry.metadata.totalSize.formatted(.byteCount(style: .file).locale(UIStrings.locale)))
            if entry.metadata.pinned { parts.append(String(ui: "고정")) }
            lines.append("  " + parts.joined(separator: " · "))
        }
        return lines
    }

    static func restoreLines(entry: UsbPointSnapshotEntry, written: UsbPointRestoreWritten, volume: String) -> [String] {
        let result = written.summary.result
        var lines: [String] = []
        if result.isUnchanged {
            lines.append(String(ui: "지금 USB가 ‘\(entry.displayName)’ 시점과 같아 바꾸지 않았습니다."))
        } else {
            lines.append(String(ui: "‘\(entry.displayName)’ 시점으로: DB \(result.databases) · 만들 파일 \(result.created) · 덮을 파일 \(result.overwritten) · 지울 파일 \(result.removed)"))
        }
        lines += result.notes
        // 드라이 런은 USB를 바꾸지 않고 백업도 남기지 않는다
        if written.summary.deviceChanged {
            lines.append(written.report?.outcome == .written
                ? String(ui: "그 뒤 USB가 바뀐 내용(기기가 쓴 기록 등)은 버렸습니다. 쓰기 전 백업에는 남아 있습니다.")
                : String(ui: "실제로 되돌리면 그 뒤 USB가 바뀐 내용(기기가 쓴 기록 등)을 버립니다."))
        }
        guard let report = written.report else { return lines }
        lines += UsbCommands.reportLines(report)
        if report.outcome == .written {
            lines.append(String(ui: "되돌리기 전으로 돌리려면: djc usb-restore --volume \(volume)"))
        }
        return lines
    }
}
