import DJCDomain
import Darwin
import Foundation

/// USB ANLZ에서 로컬 초안으로 옮길 수 있는 큐·박만 읽는다. DB·분석 파일에는 쓰지 않는다.
public enum UsbCueGridReader {
    public typealias Result = UsbCueGridRead
    public typealias ReadFailure = UsbCueGridReadFailure

    /// OneLibrary 사본에서 기기 큐 행(`cue` 표)이 있는 content_id. 이 행의 해석은 확인하지 않아 그 곡의 큐는 가져오지 않는다
    public static func deviceCueContentIDs(oneLibraryCopy url: URL) throws -> Set<Int> {
        let database = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
        defer { database.close() }
        var ids: Set<Int> = []
        try database.query("SELECT DISTINCT content_id FROM cue") { if let id = $0.int(0) { ids.insert(id) } }
        return ids
    }

    /// 가져오기가 짝을 맞출 로컬 키: 스냅샷 사본을 읽기 전용으로 열어 라이브 DB가 아닌지·DBID가 하나인지 본 뒤 읽는다
    public static func localKeys(snapshot: URL) throws -> LocalLibraryKeys {
        let database = try CipherDatabase(path: snapshot.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { database.close() }
        _ = try UsbLocalSource(database: database).localDBID()
        return try LocalLibraryKeysReader.load(database: database)
    }

    /// USB DB 셋(사이드카 포함)이 사본을 뜬 때(`fingerprint`)와 같은지: 크기·수정 시각·SHA-256. 사본을 읽는 동안 매체 DB가 바뀌었으면 거짓
    public static func databasesUnchanged(since fingerprint: UsbFingerprint, root: UsbRoot, access: SnapshotFileAccess = .posix) throws -> Bool {
        let paths = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
            + UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 }
        for path in paths {
            let url = try root.url(for: path)
            let stamp = try access.stat(url)
            guard let old = fingerprint.files[path] else {
                if stamp != nil { return false }
                continue
            }
            guard let stamp, stamp.isRegularFile, stamp.size == old.size, stamp.modificationDate == old.mtime,
                  try access.sha256(url) == old.sha256 else { return false }
        }
        return true
    }

    public static func read(root: UsbRoot, track: UsbTrack) throws -> Result {
        let relative = String(track.analysisDataPath.drop(while: { $0 == "/" }))
        // DB가 가리키는 번호를 그대로 쓴다. ANLZ0000을 짐작해 다른 곡의 큐를 읽지 않는다.
        guard relative.hasPrefix("PIONEER/USBANLZ/"), relative.hasSuffix(".DAT"),
              !relative.split(separator: "/").contains(".") else {
            throw failure(String(ui: "분석 파일 경로를 확인하지 못했으니 rekordbox에서 이 곡을 다시 내보내세요."))
        }
        let base = String(relative.dropLast(4))
        let access = SnapshotFileAccess.posix
        func bytes(_ path: String, required: Bool) throws -> Data? {
            let url = try root.url(for: path)
            guard let stamp = try access.stat(url) else {
                if required { throw failure(String(ui: "분석 파일이 없으니 rekordbox에서 이 곡을 다시 내보내세요.")) }
                return nil
            }
            guard stamp.isRegularFile else {
                throw failure(String(ui: "분석 파일이 일반 파일이 아니니 rekordbox에서 이 곡을 다시 내보내세요."))
            }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw failure(String(ui: "분석 파일을 열지 못했으니 USB를 다시 연결한 뒤 가져오세요."))
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            guard try access.stat(url) == stamp else {
                throw failure(String(ui: "읽는 동안 분석 파일이 바뀌었으니 기기 사용을 마친 뒤 다시 가져오세요."))
            }
            return data
        }
        return try decode(dat: bytes(relative, required: true)!, ext: bytes(base + ".EXT", required: false),
                          twoEx: bytes(base + ".2EX", required: false), expectedPath: track.path)
    }

    /// 합성 자료 시험과 읽기 사본에 같은 해석을 적용한다. 큐 실패와 그리드 실패는 서로 막지 않는다.
    public static func decode(dat: Data, ext: Data?, twoEx: Data? = nil, expectedPath: String) throws -> Result {
        guard expectedPath.hasPrefix("/Contents/"), !expectedPath.split(separator: "/").contains("..") else {
            throw failure(String(ui: "USB 음원 경로를 확인하지 못했으니 rekordbox에서 이 곡을 다시 내보내세요."))
        }
        let dat = try AnlzFile(data: dat), ext = try ext.map { try AnlzFile(data: $0) }
        for file in [Optional(dat), ext, try twoEx.map { try AnlzFile(data: $0) }].compactMap({ $0 }) {
            let paths = file.tags.filter { $0.fourcc == "PPTH" }
            guard paths.count == 1, UsbLayout.nfc(try AnlzPathTag.decode(paths[0].bytes)) == UsbLayout.nfc(expectedPath) else {
                throw failure(String(ui: "분석 파일이 다른 곡을 가리키니 rekordbox에서 이 곡을 다시 내보내세요."))
            }
        }
        var result = Result(cues: nil, grid: nil, usesLegacyCues: false, cueIssue: nil, gridIssue: nil)
        do {
            let decoded = try decodeCues(dat: dat, ext: ext)
            result.cues = decoded.cues
            result.usesLegacyCues = decoded.legacy
        } catch { result.cueIssue = issue(error, fallback: String(ui: "큐 태그를 읽지 못했으니 rekordbox에서 이 곡을 다시 내보내세요.")) }
        do { result.grid = try decodeGrid(dat: dat, ext: ext) }
        catch { result.gridIssue = issue(error, fallback: String(ui: "박 태그를 읽지 못했으니 rekordbox에서 이 곡을 다시 내보내세요.")) }
        return result
    }

    private struct CueKey: Hashable {
        var hot: UInt32
        var type: UInt8
        var start: UInt32
        var end: UInt32
    }

    private static func decodeCues(dat: AnlzFile, ext: AnlzFile?) throws -> (cues: [EditableCue], legacy: Bool) {
        let old = try legacyEntries(dat)
        guard old[0] != nil, old[1] != nil else { throw cueMismatch() }
        let extra = try ext.map(legacyEntries) ?? [:]
        let tags = ext?.tags.filter { $0.fourcc == "PCO2" } ?? []
        var cues: [EditableCue] = []
        if !tags.isEmpty {
            var lists: [UInt32: [AnlzCueTags.PCP2Entry]] = [:]
            for tag in tags {
                let (kind, entries) = try AnlzCueTags.decodePCO2(tag.bytes)
                guard kind <= 1, lists[kind] == nil else { throw cueMismatch() }
                lists[kind] = entries
            }
            guard lists[0] != nil, lists[1] != nil else { throw cueMismatch() }
            for kind in [UInt32(1), UInt32(0)] {
                let entries = lists[kind]!
                for entry in entries {
                    try validate(kind: kind, hot: entry.hotCue, type: entry.type, start: entry.inMsec, end: entry.outMsec)
                    let expectedColor: [UInt8] = kind == 0 ? [0, 0, 0, 0] : entry.type == 2 ? [0, 255, 140, 0] : [0, 26, 255, 0]
                    guard entry.colorID == 0, entry.color == expectedColor else {
                        throw failure(String(ui: "색 큐를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
                    }
                    let numerator = Int(entry.beatNumerator), denominator = Int(entry.beatDenominator)
                    guard (numerator == 0 && denominator == 0) || (entry.type == 2 && numerator > 0 && denominator > 0) else { throw cueMismatch() }
                    let beats: Double? = numerator > 0 ? Double(numerator) / Double(denominator) : nil
                    guard beats == nil || EditableCue.Loop.beats(beatLoopSize: EditableCue.Loop.beatLoopSize(beats: beats)) == beats else {
                        throw failure(String(ui: "이 루프의 박 수를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
                    }
                    cues.append(EditableCue(id: UUID(), kind: kind == 0 ? .memory : .hot(Int(entry.hotCue) - 1),
                                            time: Double(entry.inMsec) / 1000, name: entry.comment,
                                            loop: entry.type == 2 ? .init(end: Double(entry.outMsec) / 1000, beats: beats) : nil))
                }
                // DAT(A–C·메모리)와 EXT(D–H)의 위치가 PCO2와 다르면 어느 쪽 기기 편집인지 짐작하지 않는다.
                let short = kind == 0 ? old[0] ?? [] : (old[1] ?? []) + (extra[1] ?? [])
                let expected = entries.map { CueKey(hot: $0.hotCue, type: $0.type, start: $0.inMsec, end: $0.outMsec) }
                let actual = short.map { CueKey(hot: $0.hotCue, type: $0.type, start: $0.inMsec, end: $0.outMsec) }
                guard multiset(expected) == multiset(actual), (extra[0] ?? []).isEmpty else { throw cueMismatch() }
            }
        } else {
            guard old[0] != nil, old[1] != nil else { throw cueMismatch() }
            for kind in [UInt32(1), UInt32(0)] {
                for entry in (old[kind] ?? []) + (extra[kind] ?? []) {
                    try validate(kind: kind, hot: entry.hotCue, type: entry.type, start: entry.inMsec, end: entry.outMsec)
                    guard entry.type == 1 else {
                        throw failure(String(ui: "확장 큐 정보가 없어 루프의 박 수를 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
                    }
                    cues.append(EditableCue(id: UUID(), kind: kind == 0 ? .memory : .hot(Int(entry.hotCue) - 1), time: Double(entry.inMsec) / 1000))
                }
            }
        }
        let hot = cues.compactMap { cue -> Int? in if case let .hot(slot) = cue.kind { return slot }; return nil }
        guard Set(hot).count == hot.count else { throw cueMismatch() }
        return (cues.sorted { $0.time < $1.time }, tags.isEmpty)
    }

    private static func legacyEntries(_ file: AnlzFile) throws -> [UInt32: [AnlzCueTags.PCPTEntry]] {
        var lists: [UInt32: [AnlzCueTags.PCPTEntry]] = [:]
        for tag in file.tags where tag.fourcc == "PCOB" {
            let (kind, entries) = try AnlzCueTags.decodePCOB(tag.bytes)
            guard kind <= 1, lists[kind] == nil else { throw cueMismatch() }
            guard entries.allSatisfy({ $0.status == 0 }) else {
                throw failure(String(ui: "큐 상태와 활성 루프를 확인하지 못했으니 rekordbox에서 직접 가져오세요."))
            }
            lists[kind] = entries
        }
        return lists
    }

    private static func validate(kind: UInt32, hot: UInt32, type: UInt8, start: UInt32, end: UInt32) throws {
        guard (kind == 0 ? hot == 0 : (1...8).contains(hot)), type == 1 || type == 2,
              (type == 2 ? end > start && end != .max : end == .max) else { throw cueMismatch() }
    }

    private static func decodeGrid(dat: AnlzFile, ext: AnlzFile?) throws -> BeatGrid {
        let z = dat.tags.filter { $0.fourcc == "PQTZ" }, e = ext?.tags.filter { $0.fourcc == "PQT2" } ?? []
        guard z.count == 1, e.count <= 1 else { throw gridMismatch() }
        let bytes = [UInt8](z[0].bytes)
        guard bytes.count >= 24, AnlzFile.u32(bytes, 4) == 24,
              24 + Int(AnlzFile.u32(bytes, 20)) * 8 == bytes.count else { throw gridMismatch() }
        if let tag = e.first {
            let data = [UInt8](tag.bytes)
            guard data.count >= 56, AnlzFile.u32(data, 4) == 56 else { throw gridMismatch() }
            let count = Int(AnlzFile.u32(bytes, 20))
            guard data.count == 56 || (Int(AnlzFile.u32(data, 40)) == count && data.count == 56 + count * 2) else { throw gridMismatch() }
            if data.count > 56 {
                guard count > 0, data[24..<32].elementsEqual(bytes[24..<32]),
                      data[32..<40].elementsEqual(bytes[(bytes.count - 8)..<bytes.count]),
                      stride(from: 56, to: data.count, by: 2).allSatisfy({ AnlzFile.u16(data, $0) < 1024 }) else { throw gridMismatch() }
            }
        }
        let decoded = BeatGridTags.decode(pqtz: z[0].bytes, pqt2: e.first?.bytes).beats
        guard !decoded.isEmpty, decoded.allSatisfy({ (1...4).contains($0.number) && (2_000...65_535).contains($0.bpm100) }),
              zip(decoded, decoded.dropFirst()).allSatisfy({ $0.time < $1.time }) else { throw gridMismatch() }
        return BeatGrid(beats: decoded.map { .init(number: $0.number, bpm: Double($0.bpm100) / 100, time: $0.time / 1000) })
    }

    private static func multiset(_ values: [CueKey]) -> [CueKey: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    private static func failure(_ message: String) -> ReadFailure { ReadFailure(message: message) }
    private static func cueMismatch() -> ReadFailure {
        failure(String(ui: "큐 태그의 개수나 위치가 서로 맞지 않으니 rekordbox에서 이 곡을 확인한 뒤 다시 가져오세요."))
    }
    private static func gridMismatch() -> ReadFailure {
        failure(String(ui: "박 태그의 개수나 값이 서로 맞지 않으니 rekordbox에서 이 곡을 확인한 뒤 다시 가져오세요."))
    }
    private static func issue(_ error: any Error, fallback: String) -> String { (error as? ReadFailure)?.message ?? fallback }
}
