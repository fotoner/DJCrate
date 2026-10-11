import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 라이브러리 형식 작성 실험(임시 폴더에만 쓴다). 출력은 표 이름·칸 이름·수만 — 곡 제목·경로·값을 찍지 않는다.
enum UsbExportLab {
    static let all: [Command] = [
        Command("onelib-rebuild", "<USB 폴더> <출력 폴더>",
                "USB OneLibrary를 모델로 읽어 새로 만든 뒤 표마다 rowid·typeof·값과 sqlite_master.sql을 원본과 비교(값은 찍지 않음)",
                UsbExportLab.rebuild),
        Command("onelib-export",
                "--db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <출력 폴더> [--snapshot-time <ISO 8601>]",
                "로컬 사본의 곡·목록으로 <출력>/PIONEER/rekordbox/exportLibrary.db만 만든다(음원·분석 파일·다른 형식은 쓰지 않음)",
                UsbExportLab.export),
        Command("pdb-verify", "<USB 폴더>",
                "USB의 export.pdb·exportExt.pdb를 사본으로 떠서 쪽마다 칸 값만으로 다시 만들어 바이트 비교"
                    + "(쪽 번호·next·순번은 원본 값, 제자리 수정 이력이 있는 쪽은 뺌, 값은 찍지 않음)",
                UsbExportLab.pdbVerify),
        Command("usb-rebuild", "<USB 폴더> <출력 폴더>",
                "USB의 두 형식을 읽어 합친 모델로 DB 셋(exportLibrary.db·export.pdb·exportExt.pdb)만 새 내보내기 모양으로 다시 만든다"
                    + "(음원·분석 파일은 복사하지 않음, usb-diff <USB> <출력> --ignore-ids로 비교)",
                UsbExportLab.usbRebuild),
        Command("pdb-export",
                "--db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <출력 폴더> [--snapshot-time <ISO 8601>]",
                "로컬 사본의 곡·목록으로 <출력>/PIONEER/rekordbox/export.pdb·exportExt.pdb만 만든다(음원·분석 파일·다른 형식은 쓰지 않음)",
                UsbExportLab.pdbExport),
    ]

    static let clusterSize = 32_768

    // MARK: - onelib-rebuild

    static func rebuild(_ args: [String]) async throws {
        guard args.count == 3 else { throw UsageError() }
        let input = try UsbScratchPath.check(args[1], as: .existingDirectory)
        let output = try UsbScratchPath.check(args[2], as: .outputDirectory)
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-rebuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: UsbRoot(URL(filePath: input)), into: work)
        guard let source = snapshot.oneLibrary else {
            print("입력에 OneLibrary(exportLibrary.db)가 없다")
            return
        }
        let model = try OneLibraryReader.read(copyAt: source)
        let target = try database(in: output)
        try OneLibraryWriter.create(model, at: target)
        let sidecars = UsbLayout.oneLibrarySidecarSuffixes.filter { FileManager.default.fileExists(atPath: target.path + $0) }

        let left = try quietConnection(source), right = try quietConnection(target)
        defer {
            left.close()
            right.close()
        }
        var allSame = true
        for table in OneLibrarySchema.tables {
            let a = try dump(left, table), b = try dump(right, table)
            let result = compare(a, b, columns: table.columns.map(\.name))
            allSame = allSame && result.same
            print(result.line(table.name))
        }
        let sqlA = try schema(left), sqlB = try schema(right)
        let sqlSame = zip(sqlA, sqlB).filter { $0 == $1 }.count
        allSame = allSame && sqlA == sqlB
        print("sql \(sqlSame)/\(max(sqlA.count, sqlB.count)) 같음")
        print(sidecars.isEmpty ? "-wal·-shm 없음" : "남은 사이드카: \(sidecars.joined(separator: " "))")
        if allSame, sidecars.isEmpty {
            print("행·rowid·typeof·sql 골든과 같음(표 \(OneLibrarySchema.tables.count)), -wal·-shm 없음")
        } else {
            print("다름: 위 표·칸을 본다")
        }
    }

    /// 표 비교 결과(수만)
    struct TableComparison {
        var leftRows = 0, rightRows = 0, sameRows = 0
        /// "rowid"·"typeof(칸)"·칸 이름 → 다른 행 수
        var fields: [String: Int] = [:]
        var same: Bool { leftRows == rightRows && sameRows == leftRows }

        func line(_ table: String) -> String {
            let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            return "\(table) \(sameRows)/\(max(leftRows, rightRows))행 같음"
                + (leftRows == rightRows ? "" : ", 행 수 \(leftRows) vs \(rightRows)")
                + (details.isEmpty ? "" : ", 다른 칸: " + details.joined(separator: ", "))
        }
    }

    /// rowid 순서대로 짝지어 rowid·칸마다 typeof·값을 비교한다
    static func compare(_ left: [[String]], _ right: [[String]], columns: [String]) -> TableComparison {
        var result = TableComparison(leftRows: left.count, rightRows: right.count)
        for (a, b) in zip(left, right) {
            if a == b { result.sameRows += 1; continue }
            if a.first != b.first { result.fields["rowid", default: 0] += 1 }
            for (index, column) in columns.enumerated() {
                let type = 1 + index * 2, value = type + 1
                if a[type] != b[type] { result.fields["typeof(\(column))", default: 0] += 1 }
                if a[value] != b[value] { result.fields[column, default: 0] += 1 }
            }
        }
        return result
    }

    /// (rowid, typeof(칸), quote(칸), …) rowid 순
    static func dump(_ db: CipherDatabase, _ table: OneLibrarySchema.Table) throws -> [[String]] {
        let select = (["rowid"] + table.columns.flatMap { ["typeof(\($0.name))", "quote(\($0.name))"] }).joined(separator: ", ")
        var rows: [[String]] = []
        try db.query("SELECT \(select) FROM \(table.name) ORDER BY rowid") { row in
            rows.append((0..<row.count).map { row.string(Int32($0)) ?? "NULL" })
        }
        return rows
    }

    /// sqlite_master의 (종류, 이름, 표, sql) 이름 순(rowid·rootpage는 맞추지 않는다)
    static func schema(_ db: CipherDatabase) throws -> [[String]] {
        var rows: [[String]] = []
        try db.query("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name") { row in
            rows.append((0..<4).map { row.string(Int32($0)) ?? "NULL" })
        }
        return rows
    }

    /// 읽기만 하는 연결. 쓰기 가능하게 열어야 닫을 때 SQLite가 -wal·-shm을 치운다(읽기 전용 연결은 WAL 파일 옆에 남긴다)
    static func quietConnection(_ url: URL) throws -> CipherDatabase {
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readWrite)
        try db.execute("PRAGMA query_only = ON")
        return db
    }

    /// <출력>/PIONEER/rekordbox/exportLibrary.db(폴더를 만든다)
    static func database(in output: String) throws -> URL {
        let target = URL(filePath: output).appending(path: UsbLayout.oneLibrary)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return target
    }

    // MARK: - onelib-export

    static func export(_ args: [String]) async throws {
        let (model, output) = try plannedModel(args, formats: [.oneLibrary])
        let target = try database(in: output)
        try OneLibraryWriter.create(model.library, at: target)
        let library = model.library
        print("exportLibrary.db: " + modelCounts(library))
        printFileKinds(model)
        print("확인 문제 \(try OneLibraryWriter.verify(target, expected: library).count)")
    }

    /// 로컬 사본 → 내보내기 계획 → 목표 모델(onelib-export·pdb-export 공통). 계획 줄을 찍는다
    static func plannedModel(_ args: [String], formats: Set<UsbFormat>) throws -> (model: UsbExportModel, output: String) {
        guard let dbArgument = value(after: "--db", in: args), let shareArgument = value(after: "--share", in: args),
              let outArgument = value(after: "--out", in: args) else { throw UsageError() }
        // 사본은 임시 폴더 아래만 연다(라이브 master.db·DJCrate 스냅샷 폴더는 거부된다). share는 읽기만 해 확인하지 않는다
        let databasePath = try UsbScratchPath.check(dbArgument, as: .existingFile)
        let output = try UsbScratchPath.check(outArgument, as: .outputDirectory)
        let snapshot = try UsbSnapshotTime.resolve(explicit: value(after: "--snapshot-time", in: args), database: URL(filePath: databasePath))
        print("스냅샷 시각: \(snapshot.source.rawValue)")

        let db = try CipherDatabase.diagnostic(path: databasePath, key: RekordboxKey.derive())
        defer { db.close() }
        var playlists: [UsbPlaylistInput] = []
        var ids: [String]
        if let playlist = value(after: "--playlist", in: args) {
            playlists = try UsbExportCandidates.playlistTree(database: db, rootIDs: [playlist])
            var seen: Set<String> = []
            ids = playlists.flatMap(\.trackLocalIDs).filter { seen.insert($0).inserted }
        } else if let tracks = value(after: "--tracks", in: args) {
            ids = tracks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            throw UsageError()
        }
        let share = URL(filePath: shareArgument)
        let candidates = try UsbExportCandidates.load(database: db, share: share, contentIDs: ids)
        let plan = UsbExportPlanner.plan(UsbExportRequest(
            candidates: candidates, playlists: playlists, existing: nil, formats: formats, naming: RekordboxAnalysisNaming(),
            snapshotTakenAt: snapshot.date, clusterSize: clusterSize))
        print("후보 \(ids.count) · 계획 \(plan.tracks.count)곡 · 목록 \(plan.playlists.count) · 막힘 \(plan.blocked.count)"
            + (plan.blocked.isEmpty ? "" : "(\(UsbPlanLab.counts(plan.blocked.map(\.code))))"))
        let model = try UsbLibraryBuilder.build(plan: plan, formats: formats, local: UsbLocalSource(database: db), share: share,
                                                myTagMasterDBID: UsbLibraryBuilder.randomMyTagMasterDBID(), createdDate: today())
        return (model, output)
    }

    /// 표마다 행 수(값은 찍지 않는다)
    static func modelCounts(_ library: UsbLibrary) -> String {
        "곡 \(library.tracks.count) · artist \(library.artists.count) · album \(library.albums.count) · "
            + "genre \(library.genres.count) · key \(library.keys.count) · label \(library.labels.count) · color \(library.colors.count) · "
            + "image \(library.images.count) · 목록 \(library.playlists.count) · myTag \(library.myTags.count) · "
            + "menuItem \(library.menuItems.count) · category \(library.categories.count) · sort \(library.sorts.count)"
    }

    static func printFileKinds(_ model: UsbExportModel) {
        let kinds = model.files.map { file -> String in
            switch file.kind {
            case .audio: "음원"
            case .artwork: "아트워크"
            case .analysis: "분석"
            }
        }
        print("파일 작업(옮기지 않음): \(UsbPlanLab.counts(kinds))")
    }

    // MARK: - usb-rebuild

    /// USB(임시 폴더 아래 사본·디스크 이미지 마운트 지점)의 두 형식을 읽어 합친 모델 → 출력 폴더(없거나 빈 폴더)에 DB 셋만
    static func usbRebuild(_ args: [String]) async throws {
        guard args.count == 3 else { throw UsageError() }
        let input = try UsbScratchPath.check(args[1], as: .existingDirectory)
        let output = try UsbScratchPath.check(args[2], as: .outputDirectory)
        let (model, formats) = try readMerged(URL(filePath: input))
        guard !formats.isEmpty else {
            print("입력에 USB 라이브러리(exportLibrary.db·export.pdb)가 없다")
            return
        }
        if formats.contains(.oneLibrary) {
            let target = try database(in: output)
            try OneLibraryWriter.create(model, at: target)
            print("exportLibrary.db: 확인 문제 \(try OneLibraryWriter.verify(target, expected: model).count)")
        }
        if formats.contains(.deviceLibrary) {
            let files = try PdbWriter.files(model, mode: .fresh)
            let folder = URL(filePath: output).appending(path: UsbLayout.rekordboxDir)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.export.write(to: URL(filePath: output).appending(path: UsbLayout.exportPdb), options: .withoutOverwriting)
            try files.exportExt.write(to: URL(filePath: output).appending(path: UsbLayout.exportExtPdb), options: .withoutOverwriting)
            print("export.pdb \(files.export.count / PdbPage.size)쪽 · exportExt.pdb \(files.exportExt.count / PdbPage.size)쪽")
        }
        print("다시 만든 모델: " + modelCounts(model))
    }

    /// 한 USB 폴더의 두 형식(있는 것만)을 사본으로 떠서 읽어 합친다
    static func readMerged(_ root: URL) throws -> (UsbLibrary, Set<UsbFormat>) {
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-usb-rebuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: UsbRoot(root), into: work)
        let oneLibrary = try snapshot.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }
        let deviceLibrary = try PdbReader.read(snapshot: snapshot)?.0
        let formats = Set([oneLibrary.map { _ in UsbFormat.oneLibrary }, deviceLibrary.map { _ in UsbFormat.deviceLibrary }].compactMap { $0 })
        return (UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary).0, formats)
    }

    /// 두 USB 폴더의 합친 모델 차이 수(ID 무시, `usb-diff --ignore-ids`와 같은 비교)
    static func rebuildDifferences(_ a: URL, _ b: URL) throws -> Int {
        let (left, _) = try readMerged(a), (right, _) = try readMerged(b)
        return UsbLibraryDiff.compare(left, right, options: .init(ignoreIDs: true)).differences.count
    }

    // MARK: - pdb-export

    /// 두 형식 모델(실제 내보내기와 같게)을 만들어 Device Library 두 파일만 쓴다
    static func pdbExport(_ args: [String]) async throws {
        let (model, output) = try plannedModel(args, formats: UsbFormat.defaultSet)
        let files = try PdbWriter.files(model.library, mode: .fresh)
        let folder = URL(filePath: output).appending(path: (UsbLayout.exportPdb as NSString).deletingLastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.export.write(to: URL(filePath: output).appending(path: UsbLayout.exportPdb), options: .withoutOverwriting)
        try files.exportExt.write(to: URL(filePath: output).appending(path: UsbLayout.exportExtPdb), options: .withoutOverwriting)
        print("Device Library: " + modelCounts(files.written))
        printFileKinds(model)
        print("export.pdb \(files.export.count / PdbPage.size)쪽 · exportExt.pdb \(files.exportExt.count / PdbPage.size)쪽")
        print("확인 안 된 규칙: " + (files.rules.isEmpty ? "없음" : files.rules.map(\.rawValue).sorted().joined(separator: ", "))
            + " · 규칙이 붙은 곡 \(files.rulesByTrack.count)")
        let (reread, report) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        let differences = UsbLibraryDiff.compare(reread, files.written, options: .init(formats: [.deviceLibrary])).differences
        print("다시 읽기: 구조 문제 \(report.issues.count) · 확인 차이 \(differences.count)")
        print("왕복 문제 \(try PdbRoundTrip.check(export: files.export, exportExt: files.exportExt).count)")
    }

    // MARK: - pdb-verify

    static func pdbVerify(_ args: [String]) async throws {
        guard args.count == 2 else { throw UsageError() }
        let input = try UsbScratchPath.check(args[1], as: .existingDirectory)
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-pdb-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: UsbRoot(URL(filePath: input)), into: work)
        guard let export = snapshot.exportPdb else {
            print("입력에 Device Library(export.pdb)가 없다")
            return
        }
        var summaries: [String] = []
        for url in [snapshot.exportExtPdb, export].compactMap({ $0 }) {
            let report = try PdbPageCheck.check(try Data(contentsOf: url))
            pdbVerifyLines(report).forEach { print($0) }
            summaries.append(pdbVerifySummary(report))
        }
        summaries.forEach { print($0) }
    }

    /// 파일 하나: 분류별 같은 쪽 수, 뺀 쪽, 다른 쪽 번호·오프셋(값은 찍지 않는다)
    static func pdbVerifyLines(_ report: PdbPageCheck.Report) -> [String] {
        let same = report.compared.filter(\.isSame).count
        var lines = ["\(report.kind.fileName) \(same)/\(report.compared.count)쪽 바이트 같음(파일 \(report.pageCount)쪽, 뺀 쪽 \(report.excluded.count))"]
        let names: [PdbPageCheck.Category: String] = [.header: "머리", .index: "인덱스 쪽", .zero: "빈 쪽", .data: "데이터 쪽"]
        lines.append("  " + PdbPageCheck.Category.allCases.map { category in
            let count = report.count(category)
            return "\(names[category] ?? category.rawValue) \(count.same)/\(count.total)"
        }.joined(separator: " · "))
        let labels = [("deadRows", "지운 행이 있는 데이터 쪽"), ("inPlaceShape", "제자리 수정 모양 데이터 쪽"),
                      ("indexEntries", "지운 쪽 목록이 있는 인덱스 쪽"), ("nfcStrings", "NFC로 바꿔 쓰는 문자열이 든 데이터 쪽")]
        for (reason, label) in labels {
            let pages = report.excluded.filter { $0.reason == reason }.map(\.number)
            guard !pages.isEmpty else { continue }
            lines.append("  뺀 쪽(\(label)) \(pages.count): " + pages.map(String.init).joined(separator: ","))
        }
        let failures: [PdbPageCheck.RebuildFailure: String] = [.rowUnreadable: "행 해석 실패", .rowsDoNotFit: "다시 만든 행이 한 쪽에 들어가지 않음"]
        for page in report.compared where !page.isSame {
            let failure = page.rebuildFailure.flatMap { failures[$0] }.map { "(\($0))" } ?? ""
            let offset = page.firstDifference.map { $0 < 0 ? "행을 다시 만들지 못함\(failure)" : String(format: "오프셋 0x%03X", $0) } ?? ""
            lines.append("  다른 쪽 \(page.number) \(page.category.rawValue) \(page.table.isEmpty ? "-" : page.table) \(offset)")
            for row in page.rows {
                lines.append("    자리 \(row.slot): 크기 \(row.originalSize) → \(row.rebuiltSize), 행 안 처음 다른 자리 "
                    + String(format: "0x%03X", row.firstDifference))
            }
        }
        return lines
    }

    /// 완료 기준 한 줄: exportExt는 파일 전체 쪽, export는 머리 + 데이터 쪽
    static func pdbVerifySummary(_ report: PdbPageCheck.Report) -> String {
        switch report.kind {
        case .exportExt:
            let same = report.compared.filter(\.isSame).count
            return "exportExt \(same)/\(report.pageCount)쪽 바이트 같음"
        case .export:
            let header = report.count(.header), data = report.count(.data)
            return "export 머리 \(header.same)/\(header.total) + 데이터 쪽 \(data.same)/\(data.total)개 바이트 같음(쪽 번호·next·seq는 원본 값)"
        }
    }

    /// 오늘(이 Mac의 시간대) "YYYY-MM-DD"
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
