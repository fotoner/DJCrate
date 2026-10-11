import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 분석 파일(ANLZ) 실험
enum UsbAnlzLab {
    static let all: [Command] = [
        Command("usb-anlz-check", "--db <스냅샷 사본> --share <share> [--snapshot-time <ISO 8601>] [--playlist <재생 목록 ID>] <USB 폴더>",
                "USB 분석 파일을 로컬 분석 파일·큐로 다시 만들어 바이트 비교(모두 읽기만)", UsbAnlzLab.check),
        Command("usb-anlz-naming", "<USB 폴더>",
                "export.pdb 곡마다 분석 폴더가 곡 경로의 rekordbox 해시 이름과 같은지 수만(읽기만)", UsbAnlzLab.naming),
    ]

    /// 골든 대조: rekordbox가 만든 USB 사본의 pdb 분석 경로(문자열 14)가 `RekordboxAnalysisNaming`과 같은지 센다.
    /// 경로·ID는 적지 않는다(수와 파일 번호 분포만)
    static func naming(_ args: [String]) async throws {
        let folders = Array(args.dropFirst())
        guard folders.count == 1 else { throw UsageError() }
        let usbPath = try UsbScratchPath.check(folders[0], as: .existingDirectory)
        let pdb = URL(filePath: usbPath).appending(path: "PIONEER/rekordbox/export.pdb")
        let (library, _) = try PdbReader.read(export: try Data(contentsOf: pdb), exportExt: nil)
        let naming = RekordboxAnalysisNaming()
        var same = 0, different = 0, unreadable = 0
        var slots: [String: Int] = [:]
        for track in library.tracks {
            let parts = track.analysisDataPath.split(separator: "/").map(String.init)
            guard parts.count == 5, parts[0] == "PIONEER", parts[1] == "USBANLZ",
                  let expected = naming.folder(contentsPath: track.path, contentID: track.id) else { unreadable += 1; continue }
            if parts[2] + "/" + parts[3] == expected { same += 1 } else { different += 1 }
            slots[parts[4], default: 0] += 1
        }
        print("곡 \(library.tracks.count) · 해시 이름과 같음 \(same) · 다름 \(different) · 분석 경로 모양 아님 \(unreadable)")
        print("파일 이름: " + slots.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
    }

    /// 로컬 곡 행(짝짓기·변환에 쓰는 칸만)
    struct LocalTrack {
        var id: String
        var analysisDataPath: String
        var fileType: Int
    }

    /// USB 분석 파일 하나(.DAT 상대 경로)와 그 PPTH 경로
    struct UsbTrack {
        var dat: String
        var contentsPath: String
    }

    /// 한 곡을 변환해 USB 파일과 비교한 결과
    struct Comparison {
        var files: [(ext: String, made: Data?, usb: Data?)]
        var cueSame = 0, cueTotal = 0
        var warnings: [String] = []
        var rules: Set<UsbProvisionalRule> = []
        var allSame: Bool { files.allSatisfy { $0.made != nil && $0.made == $0.usb } }
    }

    /// USB 폴더의 분석 파일마다 PPTH 경로 → 음원 파일 이름·크기로 로컬 곡과 짝짓고, 로컬 분석 파일과 큐로 변환해 바이트를 비교한다.
    /// 출력에는 곡 제목·경로·ID·값을 적지 않는다(몇 번째 곡인지, 태그 이름·오프셋·수만).
    static func check(_ args: [String]) async throws {
        guard let dbArgument = value(after: "--db", in: args), let shareArgument = value(after: "--share", in: args) else {
            throw UsageError()
        }
        let folders = positional(args)
        guard folders.count == 1 else { throw UsageError() }
        let usbPath = try UsbScratchPath.check(folders[0], as: .existingDirectory)
        let dbPath = try UsbScratchPath.check(dbArgument, as: .existingFile)
        let snapshot = try UsbSnapshotTime.resolve(explicit: value(after: "--snapshot-time", in: args), database: URL(filePath: dbPath))
        print("스냅샷 시각: \(snapshot.source.rawValue)")
        print("  기준 \(snapshot.date.ISO8601Format())")

        let db = try CipherDatabase.diagnostic(path: dbPath, key: RekordboxKey.derive())
        defer { db.close() }
        let local = try localTracks(db: db, playlistID: value(after: "--playlist", in: args))

        let root = UsbRoot(URL(filePath: usbPath))
        let audioSizes = Dictionary(try UsbTree.walk(root, under: "Contents").filter { !$0.isDirectory }.map { ($0.relativePath, $0.size) },
                                    uniquingKeysWith: { first, _ in first })
        let datFiles = try UsbTree.walk(root, under: "PIONEER/USBANLZ").filter { entry in
            let name = entry.relativePath.split(separator: "/").last.map(String.init) ?? ""
            return !entry.isDirectory && !entry.isSymlink && name.hasPrefix("ANLZ") && name.hasSuffix(".DAT")
        }

        // 짝: (음원 파일 이름, 크기)가 로컬 곡 하나와만 맞을 때
        var pairs: [(usb: UsbTrack, track: LocalTrack)] = []
        var ambiguous: [(usb: UsbTrack, candidates: [LocalTrack])] = []
        var unpaired = (unreadable: 0, noAudio: 0, noLocal: 0)
        for entry in datFiles {
            guard let data = try? Data(contentsOf: root.url(for: entry.relativePath)),
                  let ppth = try? AnlzFile(data: data).tag("PPTH"), let contentsPath = try? AnlzPathTag.decode(ppth.bytes)
            else { unpaired.unreadable += 1; continue }
            let relative = UsbLayout.nfc(String(contentsPath.drop(while: { $0 == "/" })))
            let name = relative.split(separator: "/").last.map(String.init) ?? relative
            guard let size = audioSizes[relative] else { unpaired.noAudio += 1; continue }
            let usb = UsbTrack(dat: entry.relativePath, contentsPath: contentsPath)
            let matches = local[key(name: name, size: size)] ?? []
            if matches.count == 1 {
                pairs.append((usb, matches[0]))
            } else if matches.isEmpty {
                unpaired.noLocal += 1
            } else {
                ambiguous.append((usb, matches))
            }
        }
        print("짝: \(pairs.count)/\(datFiles.count) (짝 없음 \(datFiles.count - pairs.count))")
        if pairs.count < datFiles.count {
            print("  짝 없음 이유: PPTH 못 읽음 \(unpaired.unreadable) · 음원 없음 \(unpaired.noAudio) · 로컬 곡 없음 \(unpaired.noLocal) · 로컬 곡 여럿 \(ambiguous.count)")
        }

        let share = URL(filePath: shareArgument)
        var same = ["DAT": 0, "EXT": 0, "2EX": 0]
        var cueTags = (same: 0, total: 0)
        var changedAfterSnapshot = 0, changedAndDifferent = 0
        var warnings: [String: Int] = [:], rules: [UsbProvisionalRule: Int] = [:]
        for (number, pair) in pairs.enumerated() {
            let label = "곡 \(number + 1)"
            let changed = latestLocalChange(share: share, analysisDataPath: pair.track.analysisDataPath).map { $0 > snapshot.date } ?? false
            if changed { changedAfterSnapshot += 1 }
            let comparison: Comparison
            do {
                comparison = try compare(pair.usb, pair.track, root: root, share: share, db: db)
            } catch {
                print("  \(label): 변환 못 함 — \(type(of: error))")
                if changed { changedAndDifferent += 1 }
                continue
            }
            comparison.warnings.forEach { warnings[$0, default: 0] += 1 }
            comparison.rules.forEach { rules[$0, default: 0] += 1 }
            cueTags.same += comparison.cueSame
            cueTags.total += comparison.cueTotal
            for file in comparison.files {
                if let made = file.made, made == file.usb {
                    same[file.ext, default: 0] += 1
                } else {
                    print("  \(label): \(file.ext) 다름 — \(describe(made: file.made, usb: file.usb))")
                }
            }
            if changed && !comparison.allSame { changedAndDifferent += 1 }
        }

        let equal = same.values.reduce(0, +)
        print("ANLZ \(equal)/\(pairs.count * 3) 파일 바이트 같음(DAT \(same["DAT"]!)·EXT \(same["EXT"]!)·2EX \(same["2EX"]!)), 큐 태그 \(cueTags.same)/\(cueTags.total)")
        print("스냅샷 뒤 바뀜 \(changedAfterSnapshot)(그중 다름 \(changedAndDifferent))")
        if !warnings.isEmpty {
            print("경고: " + warnings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        }
        if !rules.isEmpty {
            print("확인 안 된 규칙: " + rules.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: " · "))
        }
        // 짝 세기에서 뺀 곡도 후보마다 변환해 본다(참고용). 곡마다 파일 셋이 모두 같은 후보 수를 적는다.
        if !ambiguous.isEmpty {
            let counts = ambiguous.map { item in
                item.candidates.filter { (try? compare(item.usb, $0, root: root, share: share, db: db).allSame) == true }.count
            }
            print("참고 — 로컬 곡 여럿 \(ambiguous.count)곡(후보 \(ambiguous.map(\.candidates.count))): 파일 셋이 모두 같은 후보 수 \(counts)")
        }
    }

    /// 값을 받는 옵션. 그 값은 USB 폴더 인자로 세지 않는다.
    static let valueFlags: Set = ["--db", "--share", "--snapshot-time", "--playlist"]

    /// 명령 이름(args[0])과 옵션·그 값을 뺀 나머지
    static func positional(_ args: [String]) -> [String] {
        var positional: [String] = []
        var index = 1
        while index < args.count {
            if valueFlags.contains(args[index]) { index += 2 } else { positional.append(args[index]); index += 1 }
        }
        return positional
    }

    /// 로컬 곡을 (음원 파일 이름, 크기)로 묶는다. 이름·크기가 같은 곡이 라이브러리에 여럿이면 짝이 하나로 정해지지 않으므로,
    /// 내보낸 재생 목록 ID를 주면 그 목록(지우지 않은 항목)의 곡으로만 좁힌다.
    static func localTracks(db: CipherDatabase, playlistID: String?) throws -> [String: [LocalTrack]] {
        var local: [String: [LocalTrack]] = [:]
        let playlist: CipherDatabase.Value = playlistID.map { .text($0) } ?? .null
        try db.query("""
            SELECT ID, FileNameL, FileSize, AnalysisDataPath, FileType FROM djmdContent
            WHERE rb_local_deleted = 0 AND FileNameL IS NOT NULL AND AnalysisDataPath IS NOT NULL AND AnalysisDataPath != ''
              AND (? IS NULL OR ID IN (SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = ? AND rb_local_deleted = 0))
            """, [playlist, playlist]) { row in
            guard let id = row.string(0), let name = row.string(1), let size = row.int(2), let path = row.string(3) else { return }
            local[key(name: name, size: Int64(size)), default: []].append(LocalTrack(id: id, analysisDataPath: path, fileType: row.int(4) ?? 0))
        }
        return local
    }

    static func compare(_ usb: UsbTrack, _ track: LocalTrack, root: UsbRoot, share: URL, db: CipherDatabase) throws -> Comparison {
        let files = try UsbAnlzTransform.readLocal(share: share, analysisDataPath: track.analysisDataPath)
        let cues = try UsbCueSource(database: db).cues(contentID: track.id)
        let result = try UsbAnlzTransform.transform(localDAT: files.dat, localEXT: files.ext, local2EX: files.twoEx,
                                                    contentsPath: usb.contentsPath, cues: cues, fileType: track.fileType)
        let base = String(usb.dat.dropLast(4))
        var comparison = Comparison(files: [], warnings: result.warnings, rules: result.rules)
        for (ext, made) in [("DAT", Optional(result.dat)), ("EXT", Optional(result.ext)), ("2EX", result.twoEx)] {
            let written = try? Data(contentsOf: root.url(for: base + "." + ext))
            let usbTags = written.flatMap { try? AnlzFile(data: $0) }?.tags.filter(isCueTag) ?? []
            let madeTags = made.flatMap { try? AnlzFile(data: $0) }?.tags.filter(isCueTag) ?? []
            comparison.cueTotal += usbTags.count
            comparison.cueSame += zip(usbTags, madeTags).filter { $0.bytes == $1.bytes }.count
            comparison.files.append((ext, made, written))
        }
        return comparison
    }

    static func key(name: String, size: Int64) -> String { UsbLayout.nfc(name) + "\u{0}" + String(size) }

    static func isCueTag(_ tag: AnlzFile.Tag) -> Bool { tag.fourcc == "PCOB" || tag.fourcc == "PCO2" }

    /// 로컬 분석 파일 셋 중 가장 늦은 수정 시각(읽기만)
    static func latestLocalChange(share: URL, analysisDataPath: String) -> Date? {
        guard let files = UsbAnlzTransform.localFiles(share: share, analysisDataPath: analysisDataPath) else { return nil }
        return [files.dat, files.ext, files.twoEx]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .max()
    }

    /// 처음 다른 바이트가 든 태그 이름과 오프셋, 파일 길이(값은 적지 않는다)
    static func describe(made: Data?, usb: Data?) -> String {
        guard let made else { return "만든 파일 없음" }
        guard let usb else { return "USB 파일 없음" }
        let a = [UInt8](made), b = [UInt8](usb)
        let offset = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        var tagName = "끝", start = offset
        if let file = try? AnlzFile(data: made) {
            if offset < file.header.count {
                tagName = "PMAI"; start = 0
            } else {
                var p = file.header.count
                for tag in file.tags {
                    if offset < p + tag.bytes.count { tagName = tag.fourcc; start = p; break }
                    p += tag.bytes.count
                }
            }
        }
        func hex(_ value: Int) -> String { "0x" + String(value, radix: 16, uppercase: true) }
        return "태그 \(tagName) @\(hex(offset))(태그 안 \(hex(offset - start))), 길이 \(a.count)/\(b.count)"
    }
}
