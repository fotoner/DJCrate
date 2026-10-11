import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 라이브러리 읽기 실험(사본만 연다). 받는 경로는 임시 폴더 아래만이고, 출력에는 글자 칸 값을 찍지 않는다.
enum UsbReadLab {
    static let all: [Command] = [
        Command("onelib-sql", "<exportLibrary.db> <SELECT…|PRAGMA…>",
                "임시 폴더의 OneLibrary를 임시 사본으로 떠서 읽기 전용 질의(인증값 차단)", UsbReadLab.oneLibrarySQL),
        Command("usb-diff", "[--onelibrary|--device-library] <USB 폴더 A> <USB 폴더 B> [--files] [--mtime] [--anlz] [--ignore-anlz-folder] [--ignore-ids] [--skip <표,…>]",
                "두 USB 폴더를 사본으로 떠서 모델을 표·칸 단위로 비교(기본은 두 형식 모두, 값은 찍지 않음). --files는 파일 트리"
                    + "(--mtime이면 내용이 같은 파일의 수정 시각도 FAT 2초 단위로), --anlz는 분석 파일 태그도 비교",
                UsbReadLab.usbDiff),
        Command("usb-migrate-check", "<USB 폴더> [--ignore-ids]",
                "두 형식이 다 있는 USB(골든 사본 등)의 Device Library를 OneLibrary로 옮겼다고 치고, 그 USB의 OneLibrary와 표·칸 단위로 비교"
                    + "(값은 찍지 않음, USB에 쓰지 않음)",
                UsbReadLab.migrateCheck),
        Command("usb-anlz-relocate", "<USB 사본 폴더> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]",
                "기기 실험용: 임시 폴더의 USB 사본에서 한 곡의 분석 파일·두 DB 경로를 일부러 어긋나게 만든다(볼륨·원본은 거부)",
                UsbReadLab.anlzRelocate),
        Command("pdb-dump", "<export.pdb|exportExt.pdb> [--pages] [--rows <표>]",
                "임시 폴더의 Device Library 파일을 임시 사본으로 떠서 머리·표 포인터·표마다 산 행/자리·구조 문제 수를 찍는다(글자 값은 찍지 않음)",
                UsbReadLab.pdbDump),
    ]

    /// 임시 폴더 아래 OneLibrary 파일에 읽기 전용 질의. 원본 대신 사이드카까지 같이 뜬 임시 사본을 연다.
    static func oneLibrarySQL(_ args: [String]) async throws {
        guard args.count > 2 else { throw UsageError() }
        let database = try UsbScratchPath.check(args[1], as: .existingFile)
        let sql = args[2]
        guard isAllowedQuery(sql) else { print("허용하지 않는 쿼리"); return }
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = try UsbSnapshot.copyDatabase(URL(filePath: database), into: work)
        let db = try CipherDatabase.diagnostic(path: copy.path, key: .passphrase(RekordboxKey.oneLibrary()))
        defer { db.close() }
        try db.query(sql) { row in print((Int32(0)..<Int32(row.count)).map { row.string($0) ?? "nil" }.joined(separator: " | ")) }
    }

    /// SELECT와 키가 아닌 PRAGMA만. 인증값 표 이름이 들어 있으면 받지 않는다(연결의 authorizer도 한 번 더 막는다).
    /// PRAGMA는 이름으로 본다(`key`·`rekey`·`hexkey`는 막고 `table_info(key)`는 받는다).
    static func isAllowedQuery(_ sql: String) -> Bool {
        let lower = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !CipherDatabase.isCredentialIdentifier(lower) else { return false }
        if lower.hasPrefix("select") { return true }
        guard lower.hasPrefix("pragma") else { return false }
        let name = lower.dropFirst("pragma".count).drop { $0.isWhitespace }.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return !name.isEmpty && !name.contains("key")
    }

    /// 두 USB 폴더(임시 폴더 아래 사본·디스크 이미지 마운트 지점)의 모델 비교.
    /// `--onelibrary`는 OneLibrary만, `--device-library`는 pdb만, 둘 다 없으면 있는 형식을 모두 읽어 합친 모델끼리 비교한다.
    static func usbDiff(_ args: [String]) async throws {
        var positional: [String] = [], oneLibrary = false, deviceLibrary = false
        var options = UsbLibraryDiff.Options()
        var fileOptions = UsbFileDiff.Options(files: false, anlz: false)
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--onelibrary": oneLibrary = true
            case "--device-library": deviceLibrary = true
            case "--files": fileOptions.files = true
            case "--mtime":
                fileOptions.files = true
                fileOptions.mtime = true
            case "--anlz": fileOptions.anlz = true
            case "--ignore-anlz-folder":
                options.ignoreAnalysisFolder = true
                fileOptions.ignoreAnalysisFolder = true
            case "--ignore-ids": options.ignoreIDs = true
            case "--skip":
                guard index + 1 < args.count else { throw UsageError() }
                index += 1
                options.skipTables = Set(args[index].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            default: positional.append(args[index])
            }
            index += 1
        }
        guard positional.count == 2 else { throw UsageError() }
        options.formats = oneLibrary == deviceLibrary ? UsbFormat.defaultSet : (oneLibrary ? [.oneLibrary] : [.deviceLibrary])
        let roots = try positional.map { try UsbScratchPath.check($0, as: .existingDirectory) }
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-usb-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        var libraries: [UsbLibrary] = []
        for (side, root) in zip(["A", "B"], roots) {
            let snapshot = try UsbSnapshot.take(root: UsbRoot(URL(filePath: root)), into: work.appending(path: side))
            var ol: UsbLibrary?, dl: UsbLibrary?
            if options.formats.contains(.oneLibrary), let copy = snapshot.oneLibrary { ol = try OneLibraryReader.read(copyAt: copy) }
            if options.formats.contains(.deviceLibrary), let (library, report) = try PdbReader.read(snapshot: snapshot) {
                dl = library
                if !report.issues.isEmpty { print("구조 문제 \(side) \(report.issues.count)") }
            }
            if options.formats == [.oneLibrary], ol == nil { print("\(side)에 OneLibrary(exportLibrary.db)가 없다"); return }
            if options.formats == [.deviceLibrary], dl == nil { print("\(side)에 Device Library(export.pdb)가 없다"); return }
            if ol == nil, dl == nil { print("\(side)에 USB 라이브러리(exportLibrary.db·export.pdb)가 없다"); return }
            let (merged, mismatches) = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl)
            if ol != nil, dl != nil { print(renderMismatches(side, mismatches)) }
            libraries.append(merged)
        }
        let result = UsbLibraryDiff.compare(libraries[0], libraries[1], options: options)
        var lines = render(result)
        if fileOptions.files || fileOptions.anlz {
            // 분석 파일 차이는 경로 대신 A의 곡 id로 적는다
            fileOptions.trackIDs = Dictionary(libraries[0].tracks.map { (UsbLayout.nfc($0.path), $0.id) }) { first, _ in first }
            let files = try UsbFileDiff.compare(UsbRoot(URL(filePath: roots[0])), UsbRoot(URL(filePath: roots[1])), options: fileOptions)
            let total = result.differences.count + files.differences.count
            lines.removeLast()
            lines += [files.fileSummary, files.anlzSummary].filter { !$0.isEmpty } + files.differences + ["차이 \(total)"]
        }
        lines.forEach { print($0) }
    }

    /// `usb-migrate-check`: pdb에서 읽은 모델 → 옮기기 변환(`UsbMigration`) → OneLibrary 투영을 그 USB의 OneLibrary와 견준다
    static func migrateCheck(_ args: [String]) async throws {
        let ignoreIDs = args.contains("--ignore-ids")
        let positional = args.dropFirst().filter { $0 != "--ignore-ids" }
        guard positional.count == 1, let path = positional.first else { throw UsageError() }
        let root = UsbRoot(URL(filePath: try UsbScratchPath.check(path, as: .existingDirectory)))
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-usb-migrate-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: root, into: work)
        guard let copy = snapshot.oneLibrary, let (deviceLibrary, report) = try PdbReader.read(snapshot: snapshot) else {
            print("두 형식(exportLibrary.db·export.pdb)이 다 있는 USB만 비교한다")
            return
        }
        if !report.issues.isEmpty { print("구조 문제 \(report.issues.count)") }
        let actual = try OneLibraryReader.read(copyAt: copy)
        let converted = try UsbMigration.model(deviceLibrary: deviceLibrary, root: root).projected(to: .oneLibrary)
        print(renderMismatches("변환", UsbLibrary.merge(oneLibrary: converted, deviceLibrary: deviceLibrary).1))
        render(UsbLibraryDiff.compare(actual, converted, options: .init(ignoreIDs: ignoreIDs, formats: [.oneLibrary]))).forEach { print($0) }
    }

    /// 기기 실험 사본 준비. 사본 폴더는 임시 폴더 아래의 폴더만(볼륨 맨 위·링크 거부), rekordbox가 켜져 있으면 하지 않는다
    static func anlzRelocate(_ args: [String]) async throws {
        var positional: [String] = [], track: Int?, folder: String?
        var modes: [UsbAnlzRelocate.Mode] = []
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--track":
                guard index + 1 < args.count, let value = Int(args[index + 1]) else { throw UsageError() }
                track = value
                index += 1
            case "--folder":
                guard index + 1 < args.count else { throw UsageError() }
                folder = args[index + 1]
                index += 1
            case "--db-only": modes.append(.dbOnly)
            case "--files-only": modes.append(.filesOnly)
            case "--decoy-slot0": modes.append(.decoySlot0)
            case "--cue-variant": modes.append(.cueVariant)
            default: positional.append(args[index])
            }
            index += 1
        }
        let mode = modes.first ?? .both
        // 가짜 0번은 계산 폴더 안에서만 바꾸므로 --folder가 없어도 된다
        guard positional.count == 1, modes.count <= 1, let track, folder != nil || mode == .decoySlot0 else { throw UsageError() }
        let copy = try UsbScratchPath.check(positional[0], as: .existingDirectory)
        if LibrarySnapshot.isRekordboxRunning() { throw DJCError.rekordboxRunning }
        let changes = try UsbAnlzRelocate.apply(copy: UsbRoot(URL(filePath: copy)), trackID: track, newFolder: folder ?? "", mode: mode)
        print("모드 \(mode.rawValue)")
        changes.forEach { print($0) }
    }

    /// "형식 불일치 A <수>: 종류×수, …"(id·값은 넣지 않는다)
    static func renderMismatches(_ side: String, _ mismatches: [UsbFormatMismatch]) -> String {
        var counts: [String: Int] = [:]
        for mismatch in mismatches {
            let key = switch mismatch {
            case let .trackOnlyIn(format, _): "trackOnlyIn.\(format.rawValue)"
            case .trackPathDiffers: "trackPathDiffers"
            case let .trackFieldDiffers(_, field): "trackFieldDiffers.\(field)"
            case .playlistConflict: "playlistConflict"
            case .playlistEntriesDiffer: "playlistEntriesDiffer"
            case let .playlistOnlyIn(format, _): "playlistOnlyIn.\(format.rawValue)"
            case let .propertyDiffers(field): "propertyDiffers.\(field)"
            case let .sharedRowDiffers(table, _): "sharedRowDiffers.\(table)"
            }
            counts[key, default: 0] += 1
        }
        let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        return "형식 불일치 \(side) \(mismatches.count)" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
    }

    /// Device Library 파일 하나의 머리·표 포인터·표마다 산 행/자리. 원본 대신 임시 사본을 읽는다.
    static func pdbDump(_ args: [String]) async throws {
        var path: String?, pages = false, rowsTable: String?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--pages": pages = true
            case "--rows":
                guard index + 1 < args.count else { throw UsageError() }
                index += 1
                rowsTable = args[index]
            default:
                guard path == nil else { throw UsageError() }
                path = args[index]
            }
            index += 1
        }
        guard let path else { throw UsageError() }
        let file = try UsbScratchPath.check(path, as: .existingFile)
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-pdb-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appending(path: (file as NSString).lastPathComponent)
        try SnapshotFileAccess.posix.copyData(URL(filePath: file), copy)
        let report = try PdbReader.inspect(try Data(contentsOf: copy))
        pdbDumpLines(report, pages: pages, rows: rowsTable).forEach { print($0) }
    }

    static func pdbDumpLines(_ report: PdbFileReport, pages: Bool, rows: String?) -> [String] {
        let header = report.header
        func hex(_ value: some BinaryInteger, _ width: Int) -> String { String(format: "0x%0\(width)X", Int(value)) }
        var lines = [
            "file \(report.kind.fileName)",
            "header page_size \(header.pageSize) tables \(header.numTables) next_unused \(header.nextUnusedPage) flag10 \(header.flag10) "
                + "sequence \(header.sequence) gap \(header.gap) max_page_sequence \(report.maxPageSequence)",
        ]
        for table in report.tables {
            let pointer = table.pointer
            lines.append("pointer \(pointer.type) \(table.name) first \(pointer.firstPage) last \(pointer.lastPage) "
                + "empty_candidate \(pointer.emptyCandidate)")
        }
        for table in report.tables {
            lines.append("table \(table.pointer.type) \(table.name) \(table.liveRows)/\(table.slotCount) pages \(table.pages.count)")
        }
        let kinds = PdbStringKind.allCases.map { "\($0.rawValue) \(report.stringKinds[$0.rawValue] ?? 0)" }
        lines.append("strings " + kinds.joined(separator: " ")
            + " longest_short_ascii \(report.longestShortASCII) misaligned_utf16 \(report.misalignedUTF16)")
        if pages {
            for table in report.tables {
                for page in table.pages {
                    let h = page.header
                    lines.append("page \(h.pageIndex) \(table.name) next \(h.nextPage) seq \(h.sequence) slots \(h.rowSlots) live \(h.liveRows) "
                        + "flags \(hex(h.flags, 2)) free \(h.freeSize) used \(h.usedSize) tx \(h.txRowCount)/\(h.txRowIndex) "
                        + "u2 \(h.u2) u6 \(hex(h.u6, 4)) u7 \(h.u7)")
                }
            }
        }
        if let rows {
            let wanted = report.tables.filter { $0.name == rows || $0.name == "exportExt." + rows || String($0.pointer.type) == rows }
            for table in wanted {
                let hasShift = report.kind.rowHasIndexShift(table.pointer.type)
                for (page, slot) in table.slots {
                    let bytes = page.row(slot)
                    let shift = hasShift && bytes.count >= 4 ? hex(Int(bytes[bytes.startIndex + 2]) | Int(bytes[bytes.startIndex + 3]) << 8, 4) : "-"
                    let shapes = PdbReader.stringShapes(kind: report.kind, table: table.pointer.type, row: bytes)
                        .map { $0.isEmpty ? "-" : $0.map { "\($0.kind.rawValue)(\($0.length))" }.joined(separator: " ") } ?? "unreadable"
                    lines.append("page \(page.header.pageIndex) slot \(slot.index) offset \(hex(slot.offset, 4)) bytes \(bytes.count) "
                        + (slot.isLive ? "live" : "dead") + (slot.inTransaction ? " tx" : "") + " shift \(shift) strings \(shapes)")
                }
            }
        }
        lines.append(renderFarShapeRows(report.farShapeRows))
        lines.append(renderIssues(report.issues))
        return lines
    }

    /// "far_shape_rows <수>", 0이 아니면 표마다 수를 덧붙인다(먼 오프셋 모양은 쓰기가 확인하지 않은 모양)
    static func renderFarShapeRows(_ counts: [String: Int]) -> String {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return "far_shape_rows 0" }
        return "far_shape_rows \(total): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// "issues <수>", 0이 아니면 종류별 수와 쪽 번호만 덧붙인다
    static func renderIssues(_ issues: [PdbIssue]) -> String {
        guard !issues.isEmpty else { return "issues 0" }
        let groups = Dictionary(grouping: issues, by: \.kind).sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, items in
            let pages = Set(items.compactMap(\.page)).sorted().map(String.init)
            return "\(kind.rawValue)×\(items.count)" + (pages.isEmpty ? "" : "(page \(pages.joined(separator: ",")))")
        }
        return "issues \(issues.count): " + groups.joined(separator: ", ")
    }

    /// 표마다 "표 N/N행 일치, 다른 칸: 칸이름×수", 마지막 줄 "차이 <합계>". 값·제목은 넣지 않는다.
    static func render(_ result: (summaries: [UsbLibraryDiff.TableSummary], differences: [UsbLibraryDiff.Difference])) -> [String] {
        result.summaries.map { summary in
            let fields = summary.differingFields.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            return "\(summary.table) \(summary.matchedRows)/\(max(summary.leftRows, summary.rightRows))행 일치"
                + (fields.isEmpty ? "" : ", 다른 칸: " + fields.joined(separator: ", "))
        } + ["차이 \(result.differences.count)"]
    }
}
