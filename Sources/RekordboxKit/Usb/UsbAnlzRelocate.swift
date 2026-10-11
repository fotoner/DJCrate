import DJCDomain
import Darwin
import Foundation

/// 기기 실험용 사본 준비: 한 곡의 분석 파일 위치·두 DB의 분석 경로를 일부러 어긋나게 만든다.
/// Mac 데이터 볼륨의 임시 폴더 아래 USB 모양 **사본 폴더**에만 쓴다(마운트된 볼륨 위·링크·임시 폴더 밖은 거부).
/// USB에 쓰는 길은 `UsbWriter`뿐이다.
public enum UsbAnlzRelocate {
    public enum Mode: String, Sendable, CaseIterable {
        /// 파일을 새 폴더로 옮기고 두 DB 경로도 옮긴다(기기가 DB 경로를 따르는지)
        case dbOnly
        /// 파일은 그대로, 두 DB 경로만 같은 길이의 없는 폴더로(기기가 폴더를 스스로 계산하는지)
        case filesOnly
        /// 파일과 두 DB 경로를 함께 옮긴다(dbOnly와 같은 결과)
        case both
        /// 계산 폴더의 ANLZ0000은 PPTH를 바꾼 가짜, 진짜는 ANLZ0001, DB는 ANLZ0001(새 폴더는 쓰지 않는다)
        case decoySlot0
        /// 두 곳에 파일을 두고 새 폴더 .DAT의 핫큐 A 위치만 다르게, DB는 새 폴더
        case cueVariant
    }

    static let analysisPrefix = "/" + UsbLayout.analysisRoot + "/"
    /// Mac 시동·데이터 볼륨의 마운트 지점(임시 폴더가 있는 곳). 사본 폴더는 이 위에만 있어야 한다
    static let macVolumeMounts: Set<String> = ["/", "/System/Volumes/Data"]
    static let extensions = ["DAT", "EXT", "2EX"]
    /// 새 핫큐 A를 옮기는 폭(ms)
    static let cueShift: UInt32 = 4_000
    /// 핫큐 A가 없을 때 새로 두는 자리(ms)
    static let addedCue = 4_000

    /// 바꾼 것 목록(곡 id·폴더 이름·파일 이름만)을 돌려준다. 모든 확인을 먼저 하고, 하나라도 걸리면 아무것도 바꾸지 않는다.
    public static func apply(copy: UsbRoot, trackID: Int, newFolder: String, mode: Mode) throws -> [String] {
        let resolved = try checkCopy(copy.url.path)
        let root = UsbRoot(URL(filePath: resolved))
        if mode != .decoySlot0 {
            guard newFolder.wholeMatch(of: /P[0-9A-F]{3}\/[0-9A-F]{8}/) != nil else {
                throw UsbError.pathRefused(path: newFolder, reason: "badFolder")
            }
        }
        for suffix in UsbLayout.oneLibrarySidecarSuffixes where exists(root, UsbLayout.oneLibrary + suffix) {
            throw UsbError.readFailed(detail: "sidecar present: exportLibrary.db\(suffix)")
        }

        // ① 두 DB에서 곡의 분석 경로와 곡 경로를 읽는다
        let pdb = exists(root, UsbLayout.exportPdb) ? try PdbAnalyzePath(root: root, trackID: trackID) : nil
        let oneLibrary = exists(root, UsbLayout.oneLibrary) ? try oneLibraryPaths(root: root, trackID: trackID) : nil
        guard pdb != nil || oneLibrary != nil else { throw UsbError.readFailed(detail: "track \(trackID) not found") }
        let paths = Set([pdb?.value, oneLibrary?.analysis].compactMap { $0 })
        guard paths.count == 1, let oldPath = paths.first else { throw UsbError.readFailed(detail: "analysis paths differ between formats") }
        guard oldPath.hasPrefix(analysisPrefix), oldPath.uppercased().hasSuffix(".DAT") else {
            throw UsbError.readFailed(detail: "analysis path is not under USBANLZ")
        }
        let oldBase = String(oldPath.dropFirst().dropLast(4))
        let oldFolder = (oldBase as NSString).deletingLastPathComponent
        let stem = (oldBase as NSString).lastPathComponent

        // ② 새 DB 경로와 파일 작업
        let newBase: String
        switch mode {
        case .decoySlot0:
            guard stem.uppercased() == "ANLZ0000" else { throw UsbError.readFailed(detail: "analysis file is not slot 0") }
            newBase = oldFolder + "/ANLZ0001"
        default:
            newBase = UsbLayout.analysisRoot + "/" + newFolder + "/" + stem
            if exists(root, UsbLayout.analysisRoot + "/" + newFolder) { throw UsbError.readFailed(detail: "target folder exists") }
        }
        let newPath = "/" + newBase + ".DAT"
        if let pdb, newPath.utf8.count != pdb.value.utf8.count {
            throw UsbError.readFailed(detail: "pdb analyze path length differs (\(pdb.value.utf8.count) → \(newPath.utf8.count))")
        }
        let present = extensions.filter { exists(root, oldBase + "." + $0) }
        if mode != .filesOnly {
            guard present.contains("DAT") else { throw UsbError.readFailed(detail: "analysis file missing") }
            for ext in present where exists(root, newBase + "." + ext) { throw UsbError.readFailed(detail: "target file exists") }
        }
        let trackPath = oneLibrary?.track ?? pdb?.trackPath ?? ""
        let variant = mode == .cueVariant ? try cueVariant(Data(contentsOf: root.url(for: oldBase + ".DAT"))) : nil
        let decoys = mode == .decoySlot0 ? try present.map { ($0, try decoy(Data(contentsOf: root.url(for: oldBase + "." + $0)), trackPath: trackPath)) } : []

        // ③ 파일
        var changes: [String] = []
        let label = "곡 \(trackID)"
        let fm = FileManager.default
        switch mode {
        case .dbOnly, .both:
            try fm.createDirectory(at: root.url(for: UsbLayout.analysisRoot + "/" + newFolder), withIntermediateDirectories: true)
            for ext in present { try fm.moveItem(at: root.url(for: oldBase + "." + ext), to: root.url(for: newBase + "." + ext)) }
            changes.append("\(label): 분석 파일 \(present.count)개를 \(newFolder)로 옮김")
            if try removeIfEmpty(root, oldFolder) { changes.append("\(label): 빈 옛 폴더 지움") }
        case .filesOnly:
            changes.append("\(label): 분석 파일은 그대로(\(newFolder)는 없음)")
        case .cueVariant:
            try fm.createDirectory(at: root.url(for: UsbLayout.analysisRoot + "/" + newFolder), withIntermediateDirectories: true)
            for ext in present where ext != "DAT" { try fm.copyItem(at: root.url(for: oldBase + "." + ext), to: root.url(for: newBase + "." + ext)) }
            try variant!.data.write(to: root.url(for: newBase + ".DAT"), options: .withoutOverwriting)
            changes.append("\(label): 분석 파일 \(present.count)개를 \(newFolder)에 복사, 그쪽 .DAT 핫큐 A \(variant!.before.map(String.init) ?? "없음") → \(variant!.after) ms")
        case .decoySlot0:
            for ext in present { try fm.moveItem(at: root.url(for: oldBase + "." + ext), to: root.url(for: newBase + "." + ext)) }
            for (ext, data) in decoys { try data.write(to: root.url(for: oldBase + "." + ext), options: .withoutOverwriting) }
            changes.append("\(label): 진짜 분석 파일 \(present.count)개를 ANLZ0001로, ANLZ0000은 PPTH를 바꾼 가짜")
        }

        // ④ DB
        let shown = mode == .decoySlot0 ? "ANLZ0001.DAT" : newFolder + "/" + stem + ".DAT"
        if let pdb {
            try pdb.replace(with: newPath, root: root)
            changes.append("\(label): export.pdb 분석 경로 → \(shown)")
        }
        if oneLibrary != nil {
            try updateOneLibrary(root: root, trackID: trackID, path: newPath)
            changes.append("\(label): exportLibrary.db 분석 경로 → \(shown)")
        }
        return changes
    }

    // MARK: - 경로 확인

    /// 사본 폴더 확인: 있는 폴더(링크 아님)이고, realpath가 임시 폴더 아래이며 Mac 시동·데이터 볼륨 위여야 한다. 통과하면 realpath
    static func checkCopy(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw UsbError.pathRefused(path: path, reason: errno == ENOENT ? "notFound" : "unreadable") }
        if info.st_mode & S_IFMT == S_IFLNK { throw UsbError.pathRefused(path: path, reason: "symlink") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw UsbError.pathRefused(path: path, reason: "kindMismatch") }
        guard let resolved = UsbScratchRoots.realPath(path) else { throw UsbError.pathRefused(path: path, reason: "unreadable") }
        if let reason = refusal(resolved: resolved, mountedOn: UsbScratchRoots.mountedOn(resolved)) {
            throw UsbError.pathRefused(path: path, reason: reason)
        }
        return resolved
    }

    /// 순수 판정: resolved = realpath, mountedOn = statfs f_mntonname. nil이면 받는다
    public static func refusal(resolved: String, mountedOn: String?) -> String? {
        guard UsbScratchRoots.isUnderAllowedRoot(resolved) else { return "outsideScratch" }
        let denied = ["/dev", "/Volumes"] + [UsbScratchRoots.realPath(NSHomeDirectory() + "/Library/Pioneer")].compactMap { $0 }
        if denied.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) { return "deniedPrefix" }
        guard let mountedOn else { return "unreadable" }
        // 임시 폴더에 붙인 디스크 이미지·실물의 맨 위와 그 안 폴더도 받지 않는다(볼륨에 쓰는 길은 UsbWriter뿐)
        if mountedOn == resolved { return "volumeRoot" }
        if !macVolumeMounts.contains(mountedOn) { return "onMountedVolume" }
        return nil
    }

    static func exists(_ root: UsbRoot, _ relative: String) -> Bool {
        guard let url = try? root.url(for: relative) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 폴더가 비었으면 지우고, 그 부모(P???)도 비었으면 지운다
    static func removeIfEmpty(_ root: UsbRoot, _ folder: String) throws -> Bool {
        let fm = FileManager.default
        let url = try root.url(for: folder)
        guard (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { return false }
        try fm.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent != "USBANLZ", (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try fm.removeItem(at: parent)
        }
        return true
    }

    // MARK: - 분석 파일 바꾸기

    /// 새 .DAT: 핫큐 목록 PCOB의 핫큐 A만 옮긴다(없으면 더한다). 나머지 큐는 원래 태그를 인코더로 다시 만든 바이트와
    /// 같을 때만 쓴다(다시 만든 바이트가 다르면 핫큐 A 말고도 달라지므로 거부)
    static func cueVariant(_ data: Data) throws -> (data: Data, before: UInt32?, after: UInt32) {
        var file = try AnlzFile(data: data)
        func isHotList(_ tag: AnlzFile.Tag) throws -> Bool {
            guard tag.fourcc == "PCOB" else { return false }
            return try AnlzCueTags.decodePCOB(tag.bytes).kind == AnlzCueTags.hotList
        }
        guard let index = try file.tags.firstIndex(where: isHotList) else { throw UsbError.readFailed(detail: "no hot cue list in .DAT") }
        let entries = try AnlzCueTags.decodePCOB(file.tags[index].bytes).entries
        var cues = entries.map { entry in
            UsbCueInput(id: "", kind: entry.hotCue <= 3 ? Int(entry.hotCue) : Int(entry.hotCue) + 1, inMsec: Int(entry.inMsec),
                        outMsec: entry.type == 2 ? Int(entry.outMsec) : -1)
        }
        guard AnlzCueTags.pcob(kind: AnlzCueTags.hotList, cues: cues) == file.tags[index].bytes else {
            throw UsbError.readFailed(detail: "hot cue list does not round-trip")
        }
        let before = entries.first { $0.hotCue == 1 }?.inMsec
        let after: UInt32
        if let position = cues.firstIndex(where: { $0.hotCueNumber == 1 }), let before {
            after = before >= 2 * cueShift ? before - cueShift : before + cueShift
            let length = cues[position].isLoop ? cues[position].outMsec - cues[position].inMsec : nil
            cues[position].inMsec = Int(after)
            if let length { cues[position].outMsec = Int(after) + length }
        } else {
            after = UInt32(addedCue)
            cues.append(UsbCueInput(id: "", kind: 1, inMsec: addedCue))
        }
        file.tags[index].bytes = AnlzCueTags.pcob(kind: AnlzCueTags.hotList, cues: cues)
        return (file.serialized(), before, after)
    }

    /// 가짜: PPTH만 다른 곡 경로로 바꾼 같은 파일
    static func decoy(_ data: Data, trackPath: String) throws -> Data {
        var file = try AnlzFile(data: data)
        let name = (trackPath as NSString).lastPathComponent
        guard file.replace("PPTH", with: AnlzPathTag.encode("/Contents/DJC-DECOY/" + (name.isEmpty ? "decoy" : name))) else {
            throw UsbError.readFailed(detail: "no PPTH")
        }
        return file.serialized()
    }

    // MARK: - OneLibrary

    static func oneLibraryPaths(root: UsbRoot, trackID: Int) throws -> (analysis: String, track: String)? {
        let db = try CipherDatabase(path: root.url(for: UsbLayout.oneLibrary).path, key: .passphrase(RekordboxKey.oneLibrary()),
                                    mode: .readWrite)
        defer { closeClean(db) }
        try OneLibraryCompatibility.check(db)
        var found: (String, String)?
        try db.query("SELECT analysisDataFilePath, path FROM content WHERE content_id = ?", [.int(trackID)]) { row in
            found = (row.string(0) ?? "", row.string(1) ?? "")
        }
        guard let found else { throw UsbError.readFailed(detail: "track \(trackID) not in OneLibrary") }
        return found
    }

    /// `UPDATE content` → `wal_checkpoint(TRUNCATE)` → 닫기. 사이드카가 남으면 실패
    static func updateOneLibrary(root: UsbRoot, trackID: Int, path: String) throws {
        let url = try root.url(for: UsbLayout.oneLibrary)
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readWrite)
        let changed: Int
        do {
            changed = try db.run("UPDATE content SET analysisDataFilePath = ? WHERE content_id = ?", [.text(path), .int(trackID)])
        } catch {
            closeClean(db)
            throw error
        }
        closeClean(db)
        guard changed == 1 else { throw UsbError.readFailed(detail: "OneLibrary update changed \(changed) rows") }
        for suffix in UsbLayout.oneLibrarySidecarSuffixes where FileManager.default.fileExists(atPath: url.path + suffix) {
            throw UsbError.readFailed(detail: "sidecar left: exportLibrary.db\(suffix)")
        }
    }

    /// WAL을 파일에 합친 뒤 닫는다(-wal·-shm을 남기지 않게)
    static func closeClean(_ db: CipherDatabase) {
        try? db.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
        db.close()
    }
}

/// export.pdb 트랙 행의 분석 경로(문자열 14, 짧은 ASCII) 자리
struct PdbAnalyzePath {
    /// 파일 안 절대 위치(문자열 머리 바이트)
    var offset: Int
    var value: String
    var trackPath: String

    static let stringIndex = 14

    init(root: UsbRoot, trackID: Int) throws {
        let data = try Data(contentsOf: root.url(for: UsbLayout.exportPdb))
        let file = try PdbFile(data: data)
        guard let pointer = file.header.tables.first(where: { $0.type == UInt32(PdbTableType.tracks.rawValue) }) else {
            throw UsbError.readFailed(detail: "no tracks table")
        }
        var found: [(Int, String, String)] = []
        for page in try file.chain(of: pointer) where !page.header.isIndex {
            for slot in page.slots where slot.isLive && page.isInsideHeap(slot) {
                let row = page.row(slot)
                let reader = PdbRowReader(row)
                guard Int(try reader.u32(0x48)) == trackID else { continue }
                let stringOffset = try reader.u16(0x5E + 2 * Self.stringIndex)
                let decoded = try PdbStringDecoder.decode(row, at: stringOffset)
                guard decoded.kind == .shortASCII else { throw UsbError.readFailed(detail: "analyze path is not short ASCII") }
                let pathOffset = try reader.u16(0x5E + 2 * 20)
                let trackPath = try PdbStringDecoder.decode(row, at: pathOffset).value
                found.append((Int(page.header.pageIndex) * PdbPage.size + PdbPage.heapStart + slot.offset + stringOffset, decoded.value, trackPath))
            }
        }
        guard found.count == 1, let (offset, value, trackPath) = found.first else {
            throw UsbError.readFailed(detail: "track \(trackID): \(found.count) live rows in export.pdb")
        }
        self.offset = offset
        self.value = value
        self.trackPath = trackPath
    }

    /// 같은 길이 문자열로 제자리 교체(사본 파일에서만)
    func replace(with path: String, root: UsbRoot) throws {
        let url = try root.url(for: UsbLayout.exportPdb)
        var data = try Data(contentsOf: url)
        let bytes = Array(path.utf8)
        guard bytes.count == value.utf8.count, bytes.allSatisfy({ $0 < 0x80 }) else {
            throw UsbError.readFailed(detail: "pdb analyze path length differs")
        }
        data.replaceSubrange((offset + 1)..<(offset + 1 + bytes.count), with: bytes)
        try data.write(to: url, options: .atomic)
    }
}
