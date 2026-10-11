import DJCDomain
import Foundation

/// 쓴 뒤 검증(G 단계)의 형식별 검증기. USB DB는 늘 Mac 쪽 사본(`UsbSnapshot`)을 떠서 연다(USB 위에서 SQLite를 열지 않는다).
/// 문제는 영어 고정 표기(표·칸 이름·곡 id·수)만 넣고 글자 값·경로는 넣지 않는다. 빈 배열 = 통과.

/// OneLibrary: 사이드카 없음 → 사본 무결성(integrity ok·cipher_integrity_check 0줄) → 다시 읽은 모델 = 기대 모델의 OneLibrary 투영
public struct OneLibraryVerifier: UsbWriteVerifier {
    let expected: UsbLibrary

    public init(expected: UsbLibrary) {
        self.expected = expected
    }

    public func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
        // 남은 사이드카가 있으면 사본을 뜨지 않는다(SQLite가 사본과 함께 집어 가 증거가 바뀐다)
        var problems: [String] = []
        for suffix in UsbLayout.oneLibrarySidecarSuffixes where try fileSystem.stat(root.url.appending(path: UsbLayout.oneLibrary + suffix)) != nil {
            problems.append("sidecar \(suffix)")
        }
        guard problems.isEmpty else { return problems }
        let folder = scratch.appending(path: "onelibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot: UsbSnapshot
        do {
            snapshot = try UsbSnapshot.take(root: root, into: folder)
        } catch {
            return ["onelibrary unreadable: \(error)"]
        }
        guard let copy = snapshot.oneLibrary else { return ["onelibrary missing"] }
        let reread = try OneLibraryReader.read(copyAt: copy)
        let differences = UsbLibraryDiff.compare(reread, expected.projected(to: .oneLibrary), options: .init(formats: [.oneLibrary])).differences
        return differences.map { "onelibrary \($0.table) \($0.key) \($0.field)" }
    }
}

/// Device Library: 두 파일의 칸 = 기대 모델의 Device Library 투영, 머리 0x10 = 5, 머리 순번 > 모든 쪽 순번,
/// 사슬·빈 후보 규칙(구조 문제 0, 먼 모양 행 0, 빈 후보는 0으로 채운 쪽이거나 파일 끝 너머)
public struct PdbVerifier: UsbWriteVerifier {
    let expected: UsbLibrary

    /// expected: 작성기가 쓴 모델(`PdbFiles.written`)
    public init(expected: UsbLibrary) {
        self.expected = expected
    }

    /// 정상으로 닫은 파일의 머리 0x10
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let closedFlag: UInt32 = 5

    public func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
        let folder = scratch.appending(path: "pdb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot: UsbSnapshot
        do {
            snapshot = try UsbSnapshot.take(root: root, into: folder)
        } catch {
            return ["pdb unreadable: \(error)"]
        }
        guard let exportURL = snapshot.exportPdb, let extURL = snapshot.exportExtPdb else { return ["pdb missing"] }
        let export = try Data(contentsOf: exportURL), ext = try Data(contentsOf: extURL)
        var problems: [String] = []
        for (name, data) in [("export", export), ("exportExt", ext)] {
            let report = try PdbReader.inspect(data)
            problems += Self.fileProblems(name, report, data: data)
        }
        let (reread, report) = try PdbReader.read(export: export, exportExt: ext)
        problems += report.issues.map { "pdb structure \($0)" }
        let differences = UsbLibraryDiff.compare(reread, expected.projected(to: .deviceLibrary), options: .init(formats: [.deviceLibrary]))
            .differences
        problems += differences.map { "pdb \($0.table) \($0.key) \($0.field)" }
        return problems
    }

    /// 파일 하나의 머리·순번·사슬 규칙
    static func fileProblems(_ name: String, _ report: PdbFileReport, data: Data) -> [String] {
        var problems: [String] = []
        let header = report.header
        if header.flag10 != closedFlag { problems.append("flag10 \(name) \(header.flag10)") }
        if header.sequence <= report.maxPageSequence { problems.append("sequence \(name) \(header.sequence) <= \(report.maxPageSequence)") }
        if !report.issues.isEmpty { problems.append("structure \(name) \(report.issues.count)") }
        // 작성기는 아티스트·앨범만 먼 모양으로 쓴다(My Tag 먼 모양은 쓰지 않는다)
        let far = report.farShapeRows.filter { !PdbRowSize.farShapeTables.contains($0.key) }.values.reduce(0, +)
        if far > 0 { problems.append("far_shape_rows \(name) \(far)") }
        let pages = data.count / PdbPage.size
        for table in report.tables {
            let candidate = Int(table.pointer.emptyCandidate)
            // 빈 후보는 파일 끝 너머이거나 0으로 채운 쪽
            if candidate < pages {
                let start = candidate * PdbPage.size
                if data[data.startIndex + start..<data.startIndex + start + PdbPage.size].contains(where: { $0 != 0 }) {
                    problems.append("candidate \(name) \(table.name)")
                }
            }
            // 사슬 마지막 쪽 = 표 포인터 last_page, 그 쪽 next = 빈 후보
            if let last = table.pages.last {
                if last.header.pageIndex != table.pointer.lastPage { problems.append("last_page \(name) \(table.name)") }
                if last.header.nextPage != table.pointer.emptyCandidate { problems.append("chain \(name) \(table.name)") }
            }
        }
        return problems
    }
}

/// 두 형식과 파일이 서로 맞는지(불변식 1–7):
/// 1 곡마다 pdb 분석 경로 = OneLibrary 분석 경로(NFC) · 2 `.DAT` PPTH = 두 DB의 곡 경로 · 3 fileName = 경로 끝 성분 ·
/// 4 DB가 가리키는 파일(음원·분석 파일 셋·아트워크)이 모두 있고 음원 크기 = fileSize(이 쓰기가 로컬 FileSize로 적은 곡은 빼고) ·
/// 5 분석 파일 폴더 안 같은 번호를 두 곡이 쓰지 않음 ·
/// 6 곡 수 칸(OneLibrary property·pdb 표 19)과 곡 수가 같음 · 7 이 쓰기가 남긴 `._*`·`.djc-part-*` 0개
public struct UsbInvariantVerifier: UsbWriteVerifier {
    /// 쓰기 전부터 USB에 있던 `._*`(NFC 상대 경로). 사용자·macOS가 둔 것(루트 `._.Trashes`, 사용자 음원 옆 등)은
    /// 쓰기 전 확인이 막지 않으므로 여기서도 세지 않는다. 빈 집합이면 모두 센다
    let preexistingAppleDoubles: Set<String>
    /// 쓰기 전부터 있던 불변식 1–6 문제(`problems(snapshot:root:fileSystem:checkFormatCounts:)`). USB 수정은 편집이 건드리지 않은 곡까지
    /// USB 전체를 보므로, 쓰던 USB에 이미 있던 문제(번호가 엉킨 분석 파일·없는 음원 등)는 빼고 이번 쓰기가 새로 만든 문제만 센다
    let preexistingProblems: Set<String>
    /// 두 형식의 곡 수가 같아야 하는지. USB 수정에서 한 형식이 막혀 다른 형식만 고쳤으면 끈다(막힌 형식은 그대로 두었다)
    let checkFormatCounts: Bool
    /// 이 쓰기가 파일 크기 칸에 로컬 FileSize를 적고 지금 음원을 그대로 복사한 곡(USB content id, `audioChangedSinceAnalysis`).
    /// rekordbox도 이렇게 쓴다(§5). 복사한 크기는 목표 지문이 본다
    let audioSizeFromDatabase: Set<Int>

    public init(preexistingAppleDoubles: Set<String> = [], preexistingProblems: Set<String> = [], checkFormatCounts: Bool = true,
                audioSizeFromDatabase: Set<Int> = []) {
        self.preexistingAppleDoubles = preexistingAppleDoubles
        self.preexistingProblems = preexistingProblems
        self.checkFormatCounts = checkFormatCounts
        self.audioSizeFromDatabase = audioSizeFromDatabase
    }

    /// 볼륨의 `._*` 항목(NFC 상대 경로, 이름만 본다). 쓰기 직전에 떠서 `preexistingAppleDoubles`로 넘긴다
    public static func appleDoubles(on root: UsbRoot) throws -> Set<String> {
        Set(try UsbTree.walk(root).filter { UsbLayout.isAppleDouble(($0.relativePath as NSString).lastPathComponent) }.map(\.relativePath))
    }

    /// 지금 USB의 불변식 1–6 문제(DB 사본을 `scratch` 아래에 떠서 읽는다). 쓰기 전에 떠서 `preexistingProblems`로 넘긴다
    public static func problems(on root: UsbRoot, fileSystem: any UsbFileSystem, scratch: URL, checkFormatCounts: Bool = true) throws -> Set<String> {
        let folder = scratch.appending(path: "invariants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try problems(snapshot: UsbSnapshot.take(root: root, into: folder), root: root, fileSystem: fileSystem,
                            checkFormatCounts: checkFormatCounts)
    }

    /// 이미 뜬 USB DB 사본으로 본 불변식 1–6 문제
    public static func problems(snapshot: UsbSnapshot, root: UsbRoot, fileSystem: any UsbFileSystem, checkFormatCounts: Bool = true) throws
        -> Set<String> {
        let oneLibrary = try snapshot.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }
        let deviceLibrary = try PdbReader.read(snapshot: snapshot)?.0
        return Set(try libraryProblems(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary, root: root, fileSystem: fileSystem,
                                       checkFormatCounts: checkFormatCounts))
    }

    public func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
        let folder = scratch.appending(path: "invariants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var problems: [String] = []
        let snapshot: UsbSnapshot
        do {
            snapshot = try UsbSnapshot.take(root: root, into: folder)
        } catch {
            return ["databases unreadable: \(error)"]
        }
        let oneLibrary = try snapshot.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }
        let deviceLibrary = try PdbReader.read(snapshot: snapshot)?.0
        for format in changes.formats {
            if (format == .oneLibrary ? oneLibrary : deviceLibrary) == nil { problems.append("database missing \(format.rawValue)") }
        }
        let exempt = Set(audioSizeFromDatabase.map(Self.audioSizeProblem))
        problems += try Self.libraryProblems(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary, root: root, fileSystem: fileSystem,
                                             checkFormatCounts: checkFormatCounts).filter { !preexistingProblems.contains($0) && !exempt.contains($0) }

        // 7 남은 `._*`(쓰기 전부터 있던 것 빼고)·`.djc-part-*`(늘 우리 것). 이름만 본다
        let entries = try UsbTree.walk(root)
        let names = entries.map { ($0.relativePath as NSString).lastPathComponent }
        let appleDouble = entries.filter {
            UsbLayout.isAppleDouble(($0.relativePath as NSString).lastPathComponent) && !preexistingAppleDoubles.contains($0.relativePath)
        }.count
        let temp = names.filter(UsbLayout.isTemp).count
        if appleDouble > 0 { problems.append("appledouble \(appleDouble)") }
        if temp > 0 { problems.append("temp \(temp)") }
        return problems
    }

    /// 불변식 1–6. 문제 글은 곡·그림 id와 형식 이름만 담아 쓰기 전후를 견줄 수 있게 한다
    static func libraryProblems(oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?, root: UsbRoot, fileSystem: any UsbFileSystem,
                                checkFormatCounts: Bool) throws -> [String] {
        var problems: [String] = []
        // 6 곡 수
        for (name, library) in [("onelibrary", oneLibrary), ("pdb", deviceLibrary)] {
            guard let library else { continue }
            if library.property.numberOfContents != library.tracks.count {
                problems.append("trackCount \(name) \(library.property.numberOfContents) != \(library.tracks.count)")
            }
        }
        if checkFormatCounts, let oneLibrary, let deviceLibrary, oneLibrary.tracks.count != deviceLibrary.tracks.count {
            problems.append("trackCount formats \(oneLibrary.tracks.count) != \(deviceLibrary.tracks.count)")
        }

        let pdbTracks = Dictionary((deviceLibrary?.tracks ?? []).map { ($0.id, $0) }) { first, _ in first }
        let olTracks = Dictionary((oneLibrary?.tracks ?? []).map { ($0.id, $0) }) { first, _ in first }
        // 1 분석 경로가 두 DB에서 같음
        for (id, track) in olTracks.sorted(by: { $0.key < $1.key }) {
            if let other = pdbTracks[id], UsbLayout.nfc(other.analysisDataPath) != UsbLayout.nfc(track.analysisDataPath) {
                problems.append("analysisPath content \(id)")
            }
        }
        let all = [("onelibrary", oneLibrary), ("pdb", deviceLibrary)].compactMap { name, library in library.map { (name, $0) } }
        var checked: Set<String> = []
        var slots: [String: (paths: Set<String>, tracks: Set<Int>)] = [:]
        for (name, library) in all {
            for track in library.tracks.sorted(by: { $0.id < $1.id }) {
                // 3 파일 이름
                if UsbLayout.nfc(track.fileName) != UsbLayout.nfc((track.path as NSString).lastPathComponent) {
                    problems.append("fileName content \(track.id) \(name)")
                }
                // 4 음원
                let audio = relative(track.path)
                if let info = try? stat(root, audio, fileSystem), info.kind == .file {
                    // 형식 이름을 적지 않는다: 한 형식만 있던 USB에 다른 형식을 더해도(옮기기) 같은 문제로 센다.
                    // rekordbox가 분석 뒤 바뀐 음원을 로컬 FileSize로 적은 USB는 이 문제를 이미 갖고 있다(§5)
                    if info.size != track.fileSize, checked.insert("size\u{0}\(track.id)").inserted {
                        problems.append(audioSizeProblem(track.id))
                    }
                } else if checked.insert("audio\u{0}" + audio).inserted {
                    problems.append("missing audio content \(track.id)")
                }
                // 4·2·5 분석 파일
                let dat = relative(track.analysisDataPath)
                let base = dat.uppercased().hasSuffix(".DAT") ? String(dat.dropLast(4)) : dat
                slots[UsbLayout.collisionKey(base), default: ([], [])].paths.insert(UsbLayout.nfc(track.path))
                slots[UsbLayout.collisionKey(base), default: ([], [])].tracks.insert(track.id)
                for ext in [".DAT", ".EXT", ".2EX"] where checked.insert("anlz\u{0}" + base + ext).inserted {
                    guard let info = try? stat(root, base + ext, fileSystem), info.kind == .file else {
                        problems.append("missing \(ext.dropFirst()) content \(track.id)")
                        continue
                    }
                }
                if let info = try? stat(root, dat, fileSystem), info.kind == .file {
                    let ppth = UsbExportAssembly.ppthReader(try fileSystem.read(root.url.appending(path: dat), maxBytes: Int(info.size)))
                    if ppth.map(UsbLayout.nfc) != UsbLayout.nfc(track.path) { problems.append("ppth content \(track.id) \(name)") }
                }
            }
            // 4 아트워크
            for image in library.images.sorted(by: { $0.id < $1.id }) {
                guard let path = name == "onelibrary" ? image.oneLibraryPath : image.pdbPath else { continue }
                if (try? stat(root, relative(path), fileSystem))?.kind != .file { problems.append("missing artwork image \(image.id) \(name)") }
            }
        }
        // 5 같은 분석 파일을 다른 곡(다른 음원)이 가리킴
        for slot in slots.sorted(by: { $0.key < $1.key }).map(\.value) where slot.paths.count > 1 {
            problems.append("slotDuplicate content \(slot.tracks.sorted().map(String.init).joined(separator: ","))")
        }
        return problems
    }

    static func audioSizeProblem(_ id: Int) -> String { "audioSize content \(id)" }

    static func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    /// 열지 않는 경로·안전하지 않은 경로는 없는 것으로 본다
    static func stat(_ root: UsbRoot, _ relative: String, _ fileSystem: any UsbFileSystem) throws -> UsbFileStat? {
        guard !relative.isEmpty, UsbWriter.isSafeRelativePath(relative) else { return nil }
        return try fileSystem.stat(root.url.appending(path: relative))
    }
}
