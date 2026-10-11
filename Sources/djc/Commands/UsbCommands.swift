import DJCApplication
import DJCDomain
import Foundation

/// USB 라이브러리 명령(읽기·계획·내보내기·고치기·회복). 흐름은 앱과 같은 유스케이스(`UsbWriteService`·`UsbRead`, `CLIComposition`)가 하고
/// 여기서는 인자를 풀고 결과를 찍는다
enum UsbCommands {
    static let all: [Command] = [
        Command("usb-info", String(ui: "<볼륨|폴더> [--json]"),
                String(ui: "USB를 읽기만 해서 형식·곡 수·경고를 보여 준다"), { try await info($0) }),
        Command("usb-export", String(ui: "--volume <마운트> [--db <스냅샷 사본.db>] [--share <폴더>] [--playlist <ID>]… [--tracks <ContentID>,…] [--formats onelibrary,device] [--naming identifier] [--dry-run] [--allow-physical --confirm <볼륨 이름>] [--verify-audio] [--settings <로컬 설정 폴더>] [--snapshot-time <ISO 8601>]"),
                String(ui: "스냅샷 사본의 곡·재생 목록을 빈 USB(FAT32·exFAT)에 OneLibrary·Device Library로 내보낸다(실물 USB는 --allow-physical --confirm <볼륨 이름>이 있어야 씀)"),
                { try await export($0) }),
        Command("usb-edit", String(ui: "--volume <마운트> (<편집.json> | --draft) [--db <스냅샷 사본.db>] [--share <폴더>] [--dry-run] [--allow-physical --confirm <볼륨 이름>] [--snapshot-time <ISO 8601>]"),
                String(ui: "이미 라이브러리가 있는 USB에 곡 더하기·빼기·갱신과 재생 목록 편집을 한 번에 쓴다(실물 USB는 --allow-physical --confirm <볼륨 이름>이 있어야 씀)"),
                { try await edit($0) }),
        Command("usb-migrate", String(ui: "--volume <마운트> [--dry-run] [--allow-physical --confirm <볼륨 이름>]"),
                String(ui: "Device Library(export.pdb)만 있는 USB에 OneLibrary(exportLibrary.db)를 더한다. 원래 파일은 그대로 둔다(실물 USB는 --allow-physical --confirm <볼륨 이름>이 있어야 씀)"),
                { try await migrate($0) }),
        Command("usb-restore", String(ui: "--volume <마운트> [--backup <폴더>] [--discard-device-changes] [--allow-physical --confirm <볼륨 이름>] [--dry-run]"),
                String(ui: "USB에 쓴 것을 그 쓰기 전 백업으로 되돌린다(그 뒤 기기가 바꾼 것이 있으면 막는다)"), { try await restore($0) }),
        Command("usb-recover", String(ui: "--volume <마운트> [--discard-temp] [--allow-physical --confirm <볼륨 이름>]"),
                String(ui: "끝나지 않은 USB 쓰기를 마저 쓰거나 되돌린다"), { try await recover($0) }),
    ]

    /// `usb-restore` 인자
    struct RestoreRequest: Equatable {
        var volume: String
        var backup: String?
        var discardDeviceChanges: Bool
        var confirmName: String?
        var dryRun: Bool
        /// 실물 쓰기 동의(`--allow-physical`)
        var allowPhysical = false
    }

    /// `usb-recover` 인자
    struct RecoverRequest: Equatable {
        var volume: String
        var discardTemp: Bool
        var confirmName: String?
        var allowPhysical = false
    }

    static func restoreRequest(_ args: [String]) throws -> RestoreRequest {
        let volume = try volumeArgument(args)
        return RestoreRequest(volume: volume, backup: try optionalValue("--backup", in: args),
                              discardDeviceChanges: args.contains("--discard-device-changes"),
                              confirmName: try optionalValue("--confirm", in: args), dryRun: args.contains("--dry-run"),
                              allowPhysical: args.contains("--allow-physical"))
    }

    static func recoverRequest(_ args: [String]) throws -> RecoverRequest {
        let volume = try volumeArgument(args)
        return RecoverRequest(volume: volume, discardTemp: args.contains("--discard-temp"), confirmName: try optionalValue("--confirm", in: args),
                              allowPhysical: args.contains("--allow-physical"))
    }

    static func restore(_ args: [String], paths: @autoclosure () -> UsbWritePaths = CLIComposition.usbWritePaths) async throws {
        let request = try restoreRequest(args)
        let report = try CLIComposition.usb(allowPhysical: request.allowPhysical, paths: paths())
            .restore(root: URL(filePath: request.volume), backup: request.backup.map { URL(filePath: $0) },
                     discardDeviceChanges: request.discardDeviceChanges, confirmName: request.confirmName, dryRun: request.dryRun,
                     expectedVolumeUUID: nil)
        printReport(report)
    }

    static func recover(_ args: [String], paths: @autoclosure () -> UsbWritePaths = CLIComposition.usbWritePaths) async throws {
        let request = try recoverRequest(args)
        let report = try CLIComposition.usb(allowPhysical: request.allowPhysical, paths: paths())
            .recover(root: URL(filePath: request.volume), discardTemp: request.discardTemp, confirmName: request.confirmName,
                     expectedVolumeUUID: nil)
        printReport(report)
    }

    /// 값이 있어야 하는 선택 인자. 이름만 있고 값이 없거나 값 자리에 다른 인자가 오면 사용법
    static func optionalValue(_ flag: String, in args: [String]) throws -> String? {
        guard args.contains(flag) else { return nil }
        guard let text = value(after: flag, in: args), !text.hasPrefix("--"), !text.isEmpty else { throw UsageError() }
        return text
    }

    /// `--volume` 값. rekordbox 라이브러리·DJCrate 데이터 폴더는 USB로 받지 않는다(문자열로 먼저 보고, 그 안은 열지 않는다)
    static func volumeArgument(_ args: [String]) throws -> String {
        guard let volume = value(after: "--volume", in: args), !volume.hasPrefix("--"), !volume.isEmpty else { throw UsageError() }
        try rejectLiveLibrary(volume)
        return volume
    }

    /// rekordbox 라이브러리·DJCrate 데이터 폴더(또는 그 아래)면 거부한다
    static func rejectLiveLibrary(_ volume: String) throws {
        let absolute = volume.hasPrefix("/") ? volume : FileManager.default.currentDirectoryPath + "/" + volume
        let live = CLIComposition.liveLibraryFolders
        let candidates = [(absolute as NSString).standardizingPath]
            + (live.contains { absolute.hasPrefix($0) } ? [] : [CLIComposition.realPath(absolute)].compactMap { $0 })
        for path in candidates where live.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw UsbError.writeRefused([UsbBlock(code: "liveLibrary", scope: .volume,
                                                  message: String(ui: "rekordbox 라이브러리나 DJCrate 데이터 폴더는 USB가 아닙니다. USB 볼륨의 맨 위 폴더를 주세요"))])
        }
    }

    // MARK: - usb-export

    /// `usb-export` 인자
    struct ExportRequest: Equatable {
        var volume: String
        var database: String?
        var share: String?
        var playlists: [String] = []
        var tracks: [String] = []
        var formats: Set<UsbFormat> = UsbFormat.defaultSet
        var dryRun = false
        var confirmName: String?
        var verifyAudio = false
        /// 기기 설정 파일을 옮길 로컬 rekordbox 설정 폴더(주지 않으면 옮기지 않는다)
        var settingsFolder: String?
        var snapshotTime: String?
        var allowPhysical = false
    }

    /// 모르는 인자·값 없는 인자는 사용법. 목록도 곡도 없으면 사용법
    static func exportRequest(_ args: [String]) throws -> ExportRequest {
        var volume: String?, database: String?, share: String?, confirm: String?, settings: String?, snapshotTime: String?
        var playlists: [String] = [], tracks: [String] = []
        var formats = UsbFormat.defaultSet
        var dryRun = false, verifyAudio = false, allowPhysical = false
        var index = 1
        func next() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
            index += 1
            return args[index]
        }
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        while index < args.count {
            switch args[index] {
            case "--volume": volume = try next()
            case "--db": database = try next()
            case "--share": share = try next()
            case "--playlist": playlists.append(try next())
            case "--tracks": tracks += list(try next())
            case "--formats":
                formats = []
                for name in list(try next()) {
                    switch name.lowercased() {
                    case "onelibrary": formats.insert(.oneLibrary)
                    case "device", "devicelibrary": formats.insert(.deviceLibrary)
                    default: throw UsageError()
                    }
                }
                if formats.isEmpty { throw UsageError() }
            // 지금은 DJCrate 고유 이름(content ID) 하나뿐이다
            case "--naming": guard try next() == "identifier" else { throw UsageError() }
            case "--dry-run": dryRun = true
            case "--confirm": confirm = try next()
            case "--verify-audio": verifyAudio = true
            case "--allow-physical": allowPhysical = true
            case "--settings": settings = try next()
            case "--snapshot-time": snapshotTime = try next()
            default: throw UsageError()
            }
            index += 1
        }
        guard let volume, !playlists.isEmpty || !tracks.isEmpty else { throw UsageError() }
        try rejectLiveLibrary(volume)
        return ExportRequest(volume: volume, database: database, share: share, playlists: playlists, tracks: tracks, formats: formats,
                             dryRun: dryRun, confirmName: confirm, verifyAudio: verifyAudio,
                             settingsFolder: settings, snapshotTime: snapshotTime, allowPhysical: allowPhysical)
    }

    /// 빈 USB에 내보낸다. 진행은 표준 오류로, 요약은 표준 출력으로(첫 줄은 스냅샷 시각). 곡 제목·경로는 찍지 않는다
    static func export(_ args: [String], paths: @autoclosure () -> UsbWritePaths = CLIComposition.usbWritePaths) async throws {
        let request = try exportRequest(args)
        // --db를 주지 않으면 가장 최근 스냅샷(읽기만 한다. 새로 뜨거나 정리하지 않는다)
        let database = try request.database.map { URL(filePath: $0) } ?? CLIComposition.latestSnapshot()
        let share = request.share.map { URL(filePath: $0) } ?? CLIComposition.liveShare
        let options = UsbExportOptions(formats: request.formats, dryRun: request.dryRun, confirmName: request.confirmName,
                                       verifyAudio: request.verifyAudio, settingsFolder: request.settingsFolder.map { URL(filePath: $0) },
                                       snapshotTime: request.snapshotTime)
        let selection: UsbSelection = request.playlists.isEmpty ? .tracks(request.tracks)
            : (request.tracks.isEmpty ? .playlists(request.playlists) : .both(playlists: request.playlists, tracks: request.tracks))
        let session = CLIComposition.usb(allowPhysical: request.allowPhysical, paths: paths())
            .exportSession(database: database, share: share, root: URL(filePath: request.volume))
        let printer = ProgressPrinter()
        let report: UsbWriteReport
        do {
            report = try session.write(selection: selection, options: options, progress: { printer.show($0) }, isCancelled: { false })
        } catch {
            // 막혔어도 계획 요약(막힘 code·수)은 보여 준다
            if let preview = session.lastPreview { exportLines(preview: preview, report: nil).forEach { print($0) } }
            throw error
        }
        guard let preview = session.lastPreview else { return }
        exportLines(preview: preview, report: report).forEach { print($0) }
    }

    /// 단계가 바뀔 때만 한 줄
    final class ProgressPrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UsbProgress.Phase?

        func show(_ progress: UsbProgress) {
            let changed = lock.withLock { () -> Bool in
                defer { last = progress.phase }
                return last != progress.phase
            }
            guard changed else { return }
            FileHandle.standardError.write(Data((String(ui: "진행: \(UsbCommands.phaseName(progress.phase))") + "\n").utf8))
        }
    }

    static func phaseName(_ phase: UsbProgress.Phase) -> String {
        switch phase {
        case .planning: String(ui: "계획")
        case .staging: String(ui: "준비(분석 파일·앨범아트·DB)")
        case .backup: String(ui: "백업")
        case .files: String(ui: "파일 쓰기")
        case .commit: String(ui: "DB 교체")
        case .cleanup: String(ui: "정리")
        case .verify: String(ui: "검증")
        case .restore: String(ui: "되돌리기")
        case .recover: String(ui: "회복")
        }
    }

    /// 사람용 요약: 스냅샷 시각 → 수 → 막힘(code별 수·ContentID) → 확인 안 된 규칙 → 경고 → 결과. 곡 제목·USB 경로는 찍지 않는다
    static func exportLines(preview: UsbExportPreview, report: UsbWriteReport?) -> [String] {
        var lines = [String(ui: "스냅샷 시각: \(preview.snapshotSource.rawValue)")]
        let playlists = preview.plan.playlists.count
        lines.append(String(ui: "내보낼 곡 \(preview.plan.tracks.count) · 재생 목록 \(playlists) · 막힌 곡 \(preview.blockedTrackCount)"))
        var byCode: [String: [String]] = [:], order: [String] = []
        for block in preview.blocks {
            if byCode[block.code] == nil { order.append(block.code) }
            let target: String = switch block.scope {
            case let .track(id): id
            case let .playlist(id): String(ui: "재생 목록 \(id)")
            case .volume, .format, .file: ""
            }
            byCode[block.code, default: []].append(target)
        }
        for code in order {
            let targets = byCode[code, default: []].filter { !$0.isEmpty }
            let message = preview.blocks.first { $0.code == code }?.message ?? ""
            lines.append(String(ui: "막힘 \(code) \(byCode[code, default: []].count): \(message)") + (targets.isEmpty ? "" : " (\(targets.joined(separator: ", ")))"))
        }
        let rules = preview.requiredRules.sorted { $0.rawValue < $1.rawValue }.map { rule in
            preview.ruleCounts[rule].map { "\(rule.rawValue) \($0)" } ?? rule.rawValue
        }
        lines.append(rules.isEmpty ? String(ui: "확인 안 된 규칙: 없음") : String(ui: "확인 안 된 규칙: \(rules.joined(separator: ", "))"))
        if !preview.warnings.isEmpty {
            var counts: [String: Int] = [:]
            for warning in preview.warnings { counts[warning.code, default: 0] += 1 }
            lines.append(String(ui: "경고: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"))
        }
        if preview.requiredBytes > 0 {
            let megabyte: Int64 = 1024 * 1024
            lines.append(String(ui: "필요 공간 \((preview.requiredBytes + megabyte - 1) / megabyte)MB · 여유 \(preview.availableBytes / megabyte)MB"))
        }
        guard let report else { return lines }
        lines += reportLines(report)
        if report.outcome == .written { lines.append(String(ui: "USB를 꺼낸 뒤 뽑으세요(Finder 또는 `diskutil eject`)")) }
        return lines
    }

    // MARK: - usb-edit

    /// `usb-edit` 인자
    struct EditRequest: Equatable {
        var volume: String
        /// 편집 파일(`[UsbLibraryEdit]` JSON). nil이면 초안
        var editsFile: String?
        var draft = false
        var database: String?
        var share: String?
        var dryRun = false
        var confirmName: String?
        var snapshotTime: String?
        var allowPhysical = false
    }

    /// 편집 파일과 `--draft` 중 하나만. 모르는 인자·값 없는 인자는 사용법
    static func editRequest(_ args: [String]) throws -> EditRequest {
        var volume: String?, file: String?, database: String?, share: String?, confirm: String?, snapshotTime: String?
        var draft = false, dryRun = false, allowPhysical = false
        var index = 1
        func next() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
            index += 1
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--volume": volume = try next()
            case "--db": database = try next()
            case "--share": share = try next()
            case "--draft": draft = true
            case "--dry-run": dryRun = true
            case "--allow-physical": allowPhysical = true
            case "--confirm": confirm = try next()
            case "--snapshot-time": snapshotTime = try next()
            default:
                guard !arg.hasPrefix("--"), !arg.isEmpty, file == nil else { throw UsageError() }
                file = arg
            }
            index += 1
        }
        guard let volume, (file == nil) == draft else { throw UsageError() }
        try rejectLiveLibrary(volume)
        return EditRequest(volume: volume, editsFile: file, draft: draft, database: database, share: share, dryRun: dryRun,
                           confirmName: confirm, snapshotTime: snapshotTime, allowPhysical: allowPhysical)
    }

    /// 편집 파일: `UsbLibraryEdit` 배열(합성 Codable JSON 그대로)
    static func editList(_ data: Data) throws -> [UsbLibraryEdit] {
        do {
            return try JSONDecoder().decode([UsbLibraryEdit].self, from: data)
        } catch {
            throw UsbError.writeRefused([UsbBlock(code: "editFileInvalid", scope: .volume,
                                                  message: String(ui: "편집 파일을 읽지 못했습니다. docs/cli.md의 usb-edit JSON 모양을 확인하세요"))])
        }
    }

    /// USB 안을 고친다. 요약은 표준 출력(첫 줄 스냅샷 시각), 진행은 표준 오류. 곡 제목·경로는 찍지 않는다
    static func edit(_ args: [String], paths: @autoclosure () -> UsbWritePaths = CLIComposition.usbWritePaths) async throws {
        let request = try editRequest(args)
        let root = URL(filePath: request.volume)
        let edits: [UsbLibraryEdit]
        if let file = request.editsFile {
            edits = try editList(Data(contentsOf: URL(filePath: file)))
        } else {
            // 초안에 곡 더하기·갱신·동기화가 있는지 보려고 볼륨 번호로 초안만 읽는다(USB 파일은 열지 않는다)
            let key = try UsbEditSession.volumeKey(try CLIComposition.usbDevice.volumeInfo(root))
            edits = try CLIComposition.usbDrafts.load(key)?.edits ?? []
        }
        // --db를 주지 않으면 곡 더하기·갱신·동기화가 있을 때만 가장 최근 스냅샷을 읽기만 한다(새로 뜨거나 정리하지 않는다)
        let local = UsbEditSession.needsLocal(edits)
        let database = try request.database.map { URL(filePath: $0) } ?? (local ? CLIComposition.latestSnapshot() : nil)
        let share = request.share.map { URL(filePath: $0) } ?? (local ? CLIComposition.liveShare : nil)
        let options = UsbWriteOptions(dryRun: request.dryRun, confirmName: request.confirmName)
        let session = CLIComposition.usb(allowPhysical: request.allowPhysical, paths: paths()).editSession(root: root, database: database, share: share)
        let printer = ProgressPrinter()
        let written: (UsbEditResult, UsbWriteReport?)
        do {
            written = request.draft
                ? try session.writeDraft(options: options, snapshotTime: request.snapshotTime, progress: { printer.show($0) }, isCancelled: { false })
                : try session.write(edits, options: options, snapshotTime: request.snapshotTime, progress: { printer.show($0) },
                                    isCancelled: { false })
        } catch {
            if let result = session.lastResult { editLines(result: result, report: nil).forEach { print($0) } }
            throw error
        }
        editLines(result: written.0, report: written.1).forEach { print($0) }
    }

    /// 사람용 요약: 스냅샷 시각 → 편집별 결과 → 형식 → 알림 → 확인 안 된 규칙 → 쓰기 결과. 곡 제목·USB 경로는 찍지 않는다
    static func editLines(result: UsbEditResult, report: UsbWriteReport?) -> [String] {
        var lines = [String(ui: "스냅샷 시각: \(result.snapshotSource?.rawValue ?? String(ui: "없음"))")]
        for block in result.blocks { lines.append(String(ui: "막힘 \(block.code): \(block.message)")) }
        for (edit, outcome) in result.outcomes {
            switch outcome {
            case let .blocked(block): lines.append(String(ui: "편집 \(edit): \(outcome.name) \(block.code) — \(block.message)"))
            case let .deferred(reason): lines.append(String(ui: "편집 \(edit): \(outcome.name) — \(reason)"))
            case .written, .unchanged: lines.append(String(ui: "편집 \(edit): \(outcome.name)"))
            }
        }
        let names: [UsbFormat: String] = [.oneLibrary: "OneLibrary", .deviceLibrary: "Device Library"]
        let written = UsbFormat.allCases.filter(result.formatsWritten.contains).compactMap { names[$0] }
        lines.append(written.isEmpty ? String(ui: "쓴 형식: 없음") : String(ui: "쓴 형식: \(written.joined(separator: " · "))"))
        for format in UsbFormat.allCases {
            guard let block = result.formatsBlocked[format] else { continue }
            lines.append(String(ui: "막힌 형식 \(names[format] ?? format.rawValue) \(block.code): \(block.message)"))
        }
        var counts: [String: Int] = [:]
        for block in result.trackBlocks { counts[block.code, default: 0] += 1 }
        if !counts.isEmpty {
            lines.append(String(ui: "빼고 쓴 곡: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"))
        }
        lines += groupedNotes(result.notes)
        if let changes = result.changes {
            let rules = changes.requiredRules.map(\.rawValue).sorted()
            lines.append(rules.isEmpty ? String(ui: "확인 안 된 규칙: 없음") : String(ui: "확인 안 된 규칙: \(rules.joined(separator: ", "))"))
        }
        if let report { lines += reportLines(report) }
        return lines
    }

    /// 끝에 USB 상대 경로가 붙은 알림은 같은 이유끼리 수로만 적는다(오류 이유 등은 그대로)
    static func groupedNotes(_ notes: [String]) -> [String] {
        var lines: [String] = [], counts: [(head: String, count: Int)] = []
        for note in notes {
            guard let range = note.range(of: ": "),
                  ["contents/", "pioneer/"].contains(where: { note[range.upperBound...].lowercased().hasPrefix($0) }) else {
                lines.append(note)
                continue
            }
            let head = String(note[..<range.lowerBound])
            if let index = counts.firstIndex(where: { $0.head == head }) { counts[index].count += 1 } else { counts.append((head, 1)) }
        }
        return lines + counts.map { String(ui: "\($0.head) (\($0.count)개)") }
    }

    // MARK: - usb-migrate

    /// `usb-migrate` 인자
    struct MigrateRequest: Equatable {
        var volume: String
        var dryRun = false
        var confirmName: String?
        var allowPhysical = false
    }

    /// 모르는 인자·값 없는 인자는 사용법
    static func migrateRequest(_ args: [String]) throws -> MigrateRequest {
        var volume: String?, confirm: String?, dryRun = false, allowPhysical = false
        var index = 1
        func next() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
            index += 1
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--volume": volume = try next()
            case "--dry-run": dryRun = true
            case "--allow-physical": allowPhysical = true
            case "--confirm": confirm = try next()
            default: throw UsageError()
            }
            index += 1
        }
        guard let volume else { throw UsageError() }
        try rejectLiveLibrary(volume)
        return MigrateRequest(volume: volume, dryRun: dryRun, confirmName: confirm, allowPhysical: allowPhysical)
    }

    /// Device Library만 있는 USB에 OneLibrary를 더한다. 요약은 표준 출력, 진행은 표준 오류. 곡 제목·경로는 찍지 않는다
    static func migrate(_ args: [String], paths: @autoclosure () -> UsbWritePaths = CLIComposition.usbWritePaths) async throws {
        let request = try migrateRequest(args)
        let options = UsbWriteOptions(dryRun: request.dryRun, confirmName: request.confirmName)
        let session = CLIComposition.usb(allowPhysical: request.allowPhysical, paths: paths()).migrateSession(root: URL(filePath: request.volume))
        let printer = ProgressPrinter()
        do {
            let (result, report) = try session.write(options: options, progress: { printer.show($0) }, isCancelled: { false })
            migrateLines(result: result, report: report).forEach { print($0) }
        } catch let UsbError.writeRefused(blocks) {
            var refused = UsbMigrationResult()
            refused.blocks = blocks
            migrateLines(result: refused, report: nil).forEach { print($0) }
            throw UsbError.writeRefused(blocks)
        }
    }

    /// 사람용 요약: 막힘 → 옮길 수 → 알림 → 확인 안 된 규칙 → 쓰기 결과. 곡 제목·USB 경로는 찍지 않는다
    static func migrateLines(result: UsbMigrationResult, report: UsbWriteReport?) -> [String] {
        var lines = result.blocks.map { String(ui: "막힘 \($0.code): \($0.message)") }
        guard let changes = result.changes else { return lines }
        lines.append(String(ui: "옮길 것: 곡 \(result.trackCount) · 재생 목록 \(result.playlistCount) · OneLibrary 앨범아트 \(result.artworkFiles)"))
        lines += groupedNotes(result.notes)
        let rules = changes.requiredRules.map(\.rawValue).sorted()
        lines.append(rules.isEmpty ? String(ui: "확인 안 된 규칙: 없음") : String(ui: "확인 안 된 규칙: \(rules.joined(separator: ", "))"))
        if let report { lines += reportLines(report) }
        return lines
    }

    // MARK: - usb-info

    /// `usb-info <볼륨|폴더> [--json]`: 읽기만 한다. DB 사본은 DJC_HOME/usb-snapshots 아래에 떴다가 지운다
    static func info(_ args: [String]) async throws {
        let json = args.contains("--json")
        let operands = args.dropFirst().filter { $0 != "--json" }
        guard operands.count == 1, let target = operands.first, !target.hasPrefix("--"), !target.isEmpty else {
            if json {
                throw ReadFailure("invalid_arguments", String(ui: "\(String(ui: "명령 인자 수가 맞지 않습니다")). djc로 사용법을 확인하세요"))
            }
            throw UsageError()
        }
        let result: UsbInfo
        do {
            try rejectLiveLibrary(target)
            let root = URL(filePath: target)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else {
                throw ReadFailure("not_found", String(ui: "USB 폴더를 찾지 못했습니다. 볼륨이나 폴더 경로를 확인하세요"))
            }
            let reader = CLIComposition.usbRead
            let volume = try reader.volume(for: root)
            let scratch = CLIComposition.usbSnapshots.appending(path: "info-\(UUID().uuidString)")
            result = try reader.info(root: root, scratch: scratch, volume: volume)
        } catch let UsbError.writeRefused(blocks) {
            throw ReadFailure(blocks.first?.code ?? "read_failed", blocks.map(\.message).joined(separator: "\n"))
        }
        if json {
            print(String(decoding: try ReadJSON.encode(command: "usb-info", data: result), as: UTF8.self))
        } else {
            infoLines(result).forEach { print($0) }
        }
    }

    /// 사람용 요약: 형식·수·경고만(곡 제목·경로·볼륨 이름은 찍지 않는다)
    static func infoLines(_ info: UsbInfo) -> [String] {
        func yes(_ value: Bool) -> String { value ? String(ui: "예") : String(ui: "아니요") }
        var lines: [String] = []
        let names = info.formats.map { $0 == UsbFormat.oneLibrary.rawValue ? "OneLibrary" : "Device Library" }
        lines.append(names.isEmpty ? String(ui: "형식: USB 라이브러리 없음") : String(ui: "형식: \(names.joined(separator: " · "))"))
        if let volume = info.volume {
            let kind = volume.isDiskImage ? String(ui: "디스크 이미지") : String(ui: "실물 USB")
            lines.append(String(ui: "볼륨: \(kind) · \(volume.fileSystem) · \(volume.partitionScheme.uppercased()) · 내보내기 \(yes(volume.writableForExport)) · 고치기 \(yes(volume.writableForEdit))")
                + (volume.problems.isEmpty ? "" : " (\(volume.problems.joined(separator: ", ")))"))
        }
        if let part = info.oneLibrary {
            lines.append(String(ui: "OneLibrary: 곡 \(part.tracks) · 재생 목록 \(part.playlists) · My Tag \(part.myTags) · 기록 \(part.histories)"))
            lines.append(String(ui: "  모양 확인 \(yes(part.schemaOK)) · 무결성 \(yes(part.integrityOK)) · 머리 \(part.headerMode) · -wal \(yes(part.walPresent)) · -journal \(yes(part.journalPresent))"))
        }
        if let part = info.deviceLibrary {
            lines.append(String(ui: "Device Library: 곡 \(part.tracks) · 재생 목록 \(part.playlists) · 기록 행 \(part.historyRows)"))
            let ext = part.extFlag10.map(String.init) ?? "-"
            lines.append(String(ui: "  머리 0x10 \(part.exportFlag10)/\(ext) · 모르는 표 행 \(part.unknownTableRows) · 구조 문제 \(part.structureIssues)"))
            if part.roundTripChecked { lines.append(String(ui: "  다시 쓰기 왕복 검사 통과 \(yes(part.roundTripOK == true))")) }
        }
        if info.oneLibrary != nil && info.deviceLibrary != nil {
            let c = info.consistency
            lines.append(String(ui: "두 형식: 곡 ID 같음 \(yes(c.trackIDsMatch)) · 경로 같음 \(yes(c.pathsMatch)) · 다른 재생 목록 \(c.playlistMismatches) · 고치기 막힘 \(yes(c.editBlocked))"))
            lines.append(String(ui: "  masterDbId 한 값 \(yes(c.masterDbIdConsistent)) · myTagMasterDBID 같음 \(yes(c.myTagMasterDBIDConsistent))"))
        }
        if !info.formats.isEmpty {
            let a = info.analysis
            lines.append(String(ui: "분석 파일: 곡 \(a.tracksChecked) · 없는 파일 \(a.missingFiles) · 곡 경로 다름 \(a.ppthMismatches) · 번호 0 아님 \(a.slotCollisions)"))
            let m = info.media
            lines.append(String(ui: "음원: 곡 \(m.tracksChecked) · 파일 \(m.filesChecked) · 없는 파일 \(m.missingFiles)"))
        }
        for setting in info.settings {
            let status = switch setting.status {
            case .missing: String(ui: "없음")
            case .valid: String(ui: "형식·CRC 확인")
            case .invalid: String(ui: "형식 또는 CRC 오류")
            case .unreadable: String(ui: "읽지 못함")
            }
            lines.append(String(ui: "설정 파일 \(setting.fileName): \(status)") + (setting.issue.map { " (\($0))" } ?? ""))
        }
        if let local = info.localCompatibility {
            lines.append(local.rekordboxVersion.map { version in
                local.verified ? String(ui: "이 Mac의 rekordbox: \(version)(확인한 버전)") : String(ui: "이 Mac의 rekordbox: \(version)(확인하지 않은 버전)")
            } ?? String(ui: "이 Mac의 rekordbox: 찾지 못함"))
        }
        lines.append(info.warnings.isEmpty ? String(ui: "경고: 없음") : String(ui: "경고 \(info.warnings.count)개:"))
        lines += info.warnings.map { "- \($0.message)" }
        return lines
    }

    static func printReport(_ report: UsbWriteReport) {
        for line in reportLines(report) { print(line) }
    }

    /// 보고 줄. USB 경로가 붙은 알림은 같은 이유끼리 수로만 적는다(분석 파일·음원 경로는 찍지 않는다)
    static func reportLines(_ report: UsbWriteReport) -> [String] {
        let outcome = switch report.outcome {
        case .dryRun: String(ui: "미리 보기만 했습니다(USB는 그대로)")
        case .written: String(ui: "썼습니다")
        case .rolledBack: String(ui: "쓰기 전 상태로 되돌렸습니다")
        case .restoreFailed: String(ui: "되돌리지 못했습니다")
        case .restorePending: String(ui: "되돌리기를 미뤘습니다")
        case .recovered: String(ui: "끊긴 쓰기를 마저 썼습니다")
        case .restored: String(ui: "쓰기 전 백업으로 되돌렸습니다")
        case .needsReplan: String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요")
        }
        // 저널이 없던 회복(session 없음)은 한 일이 없다: 마저 썼다고 하지 않는다
        var lines = [report.outcome == .recovered && report.session.isEmpty ? String(ui: "결과: 회복할 쓰기가 없습니다")
            : String(ui: "결과: \(outcome)")]
        if let backup = report.backup { lines.append(String(ui: "백업: \(backup)")) }
        if report.filesCreated + report.filesOverwritten + report.filesRemoved > 0 {
            lines.append(String(ui: "파일: 만든 것 \(report.filesCreated)개 · 덮어쓴 것 \(report.filesOverwritten)개 · 지운 것 \(report.filesRemoved)개"))
        }
        return lines + groupedNotes(report.notes)
    }
}
