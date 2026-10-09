import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxKit

/// USB 쓰기 시험 재료: 임시 폴더 하나에 USB 루트 흉내·준비 폴더·로컬 음원·DJC_HOME 흉내를 만들고
/// 합성 변경 묶음(`UsbChangeSet`)을 돌려준다. 내용은 모두 무작위 바이트이고 이름은 지어낸 것이다.
/// "DB" 파일도 이름만 DB인 합성 바이트다(쓰기 절차는 형식을 모른다).
public final class UsbChangeSetFixture: @unchecked Sendable {
    public let folder: URL
    /// USB 루트 흉내(임시 폴더라 `FaultyUsbFileSystem`이 마운트 지점으로 보이게 한다)
    public let usbURL: URL
    public let staging: URL
    public let sources: URL
    public let home: URL
    public let paths: UsbWritePaths
    public var volume: UsbVolumeInfo = FakeUsbVolume.diskImageFAT32()
    /// 가드의 실물 관문(기본: 실물 쓰기 스위치 끔)
    public var gate: UsbPhysicalWriteGate = FakeUsbVolume.gate()
    /// 가드가 돌려줄 rekordbox 실행 여부
    public var rekordboxRunning = false
    /// 가드 호출을 이 파일 시스템 기록에 함께 남긴다
    public var recorder: FaultyUsbFileSystem?

    public init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "djc-usbwrite-\(UUID().uuidString)")
        usbURL = folder.appending(path: "usb")
        staging = folder.appending(path: "staging")
        sources = folder.appending(path: "sources")
        home = folder.appending(path: "home")
        for url in [usbURL, staging, sources, home] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        paths = UsbWritePaths(backups: home.appending(path: "usb-backups"), sessions: home.appending(path: "usb-sessions"),
                              staging: home.appending(path: "usb-staging"))
    }

    public var root: UsbRoot { UsbRoot(usbURL) }
    public var volumeKey: String { volume.volumeUUID!.uppercased() }

    public func remove() {
        // 권한을 뺀 시험 폴더도 지울 수 있게 되돌린다.
        if let walker = FileManager.default.enumerator(atPath: folder.path) {
            for case let path as String in walker { chmod(folder.path + "/" + path, 0o755) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// 새 시험 파일 시스템(실패 주입 없음). 가드 호출도 이 기록에 남기려면 `recorder`에 둔다
    public func fileSystem(appleDouble: Bool = false) -> FaultyUsbFileSystem {
        let fs = FaultyUsbFileSystem(root: usbURL)
        fs.simulateAppleDouble = appleDouble
        return fs
    }

    /// 디스크 이미지 FAT32로 보이는 가드. 볼륨·rekordbox 확인은 `recorder`가 있으면 거기에 적는다
    public func writeGuard(gate: UsbPhysicalWriteGate? = nil, protectedRoots: [URL] = []) -> UsbWriteGuard {
        let gate = gate ?? self.gate
        return UsbWriteGuard(volume: { [self] _ in
            recorder?.record("guard.volume")
            return volume
        }, isRekordboxRunning: { [self] in
            recorder?.record("guard.rekordbox")
            return rekordboxRunning
        }, protectedRoots: protectedRoots, gate: gate)
    }

    // MARK: - 파일

    public func usb(_ relative: String) -> URL { usbURL.appending(path: relative) }

    /// USB에 파일을 만든다(중간 폴더 포함)
    public func write(_ relative: String, _ data: Data) {
        let url = usb(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }

    public func exists(_ relative: String) -> Bool {
        var info = Darwin.stat()
        return lstat(usb(relative).path, &info) == 0
    }

    public func data(_ relative: String) -> Data? { try? Data(contentsOf: usb(relative)) }

    /// USB 트리: 상대 경로(NFC) → SHA-256. 일반 파일 전부(`._*` 포함)
    public func tree() -> [String: String] {
        var result: [String: String] = [:]
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: usbURL.path) else { return [:] }
        for relative in paths {
            let full = usbURL.path + "/" + relative
            guard (try? FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeRegular,
                  let data = FileManager.default.contents(atPath: full) else { continue }
            result[UsbLayout.nfc(relative)] = Self.sha256(data)
        }
        return result
    }

    /// 폴더 목록(상대 경로, NFC)
    public func directories() -> Set<String> {
        var result: Set<String> = []
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: usbURL.path) else { return [] }
        for relative in paths where (try? FileManager.default.attributesOfItem(atPath: usbURL.path + "/" + relative)[.type]
            as? FileAttributeType) == .typeDirectory {
            result.insert(UsbLayout.nfc(relative))
        }
        return result
    }

    public func appleDoubleCount(in tree: [String: String]? = nil) -> Int {
        (tree ?? self.tree()).keys.filter { UsbLayout.isAppleDouble(($0 as NSString).lastPathComponent) }.count
    }

    public func tempCount(in tree: [String: String]? = nil) -> Int {
        (tree ?? self.tree()).keys.filter { UsbLayout.isTemp(($0 as NSString).lastPathComponent) }.count
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 한 번에 채운다(바이트마다 시스템 난수를 부르면 병렬 시험에서 잠금 경합으로 느렸다, #167)
    public static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { if let base = $0.baseAddress { arc4random_buf(base, $0.count) } }
        return data
    }

    /// 합성 분석 파일: 앞에 "PPTH:<경로>\n"을 두고 무작위 바이트를 붙인다
    public static func anlz(ppth: String, extra: Int = 600) -> Data {
        Data("PPTH:\(ppth)\n".utf8) + random(extra)
    }

    /// 합성 분석 파일에서 PPTH를 읽는다(쓰기 절차에 주입하는 가짜 `ppthReader`)
    public static let ppthReader: @Sendable (Data) -> String? = { data in
        guard data.starts(with: Data("PPTH:".utf8)), let end = data.firstIndex(of: 0x0A) else { return nil }
        return String(data: data[data.startIndex + 5..<end], encoding: .utf8)
    }

    /// 준비 폴더에 파일을 둔다
    public func stage(_ name: String, _ data: Data) -> (path: String, sha256: String, size: Int64) {
        let url = staging.appending(path: name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        return (url.path, Self.sha256(data), Int64(data.count))
    }

    /// 로컬 음원(원본)을 만든다
    public func source(_ name: String, _ data: Data) -> URL {
        let url = sources.appending(path: name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        return url
    }

    /// 볼륨 저널 파일(`usb-sessions/<볼륨키>.json`)을 읽는다
    public func journal() -> UsbJournal? {
        guard let data = try? Data(contentsOf: paths.sessions.appending(path: volumeKey + ".json")) else { return nil }
        return try? UsbJournal.decoder().decode(UsbJournal.self, from: data)
    }

    public func backupFolders() -> [URL] { UsbWriter.backups(paths: paths, volumeKey: volumeKey) }

    // MARK: - 변경 묶음

    public static let exportAudio = ["Contents/Artist A/Album B/_intro.mp3", "Contents/Caf\u{E9}/Album/Caf\u{E9} Song.mp3"]
    public static let exportAnalysis = ["PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT", "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.EXT",
                                        "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.2EX"]
    public static let exportArtwork = ["PIONEER/Artwork/00001/a1.jpg", "PIONEER/Artwork/00001/a1_m.jpg",
                                       "PIONEER/Artwork/00001/b2.jpg", "PIONEER/Artwork/00001/b2_m.jpg"]
    public static let databasePaths = [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb]
    public static let audioDate = Date(timeIntervalSince1970: 1_600_000_000)

    /// 빈 USB에 내보내기: 음원 둘(하나는 "_"로 시작, 하나는 원본 이름이 NFD), 분석 파일 셋, 아트워크 넷, DB 셋
    public func exportChanges(label: String = "export", audioSize: Int = 40_000) -> UsbChangeSet {
        let session = UsbLayout.newSessionID()
        var mustExist: [String: UsbTreeStamp] = [:]
        var copies: [UsbFileCopy] = []
        for (index, destination) in Self.exportAudio.enumerated() {
            let data = Self.random(audioSize + index * 1000)
            // 원본 파일 이름은 macOS가 받은 NFD 그대로, USB 경로는 NFC
            let name = (destination as NSString).lastPathComponent.decomposedStringWithCanonicalMapping
            let url = source("\(session)-\(index)/\(name)", data)
            copies.append(UsbFileCopy(source: url.path, destination: destination, size: Int64(data.count),
                                      sourceSHA1: Self.sha1(data), modificationDate: Self.audioDate, disposition: .create))
            mustExist[destination] = UsbTreeStamp(size: Int64(data.count), sha256: Self.sha256(data))
        }
        var writes: [UsbFileWrite] = []
        for (index, destination) in (Self.exportAnalysis + Self.exportArtwork).enumerated() {
            let data = destination.contains("USBANLZ") ? Self.anlz(ppth: "/" + Self.exportAudio[0]) : Self.random(2000 + index)
            let staged = stage("\(session)/w\(index)", data)
            let date: Date? = destination.contains("Artwork") ? Self.audioDate : nil
            writes.append(UsbFileWrite(staged: staged.path, destination: destination, sha256: staged.sha256, size: staged.size,
                                       modificationDate: date, disposition: .create))
            mustExist[destination] = UsbTreeStamp(size: staged.size, sha256: staged.sha256)
        }
        var databases: [UsbDatabaseReplacement] = []
        for (index, destination) in Self.databasePaths.enumerated() {
            let staged = stage("\(session)/db\(index)", Self.random(8192 + index))
            databases.append(UsbDatabaseReplacement(format: index == 0 ? .oneLibrary : .deviceLibrary, destination: destination,
                                                    staged: staged.path, sha256: staged.sha256, size: staged.size))
            mustExist[destination] = UsbTreeStamp(size: staged.size, sha256: staged.sha256)
        }
        return UsbChangeSet(session: session, label: label, purpose: .export, formats: UsbFormat.defaultSet, requiredRules: [],
                            databases: databases, copies: copies, writes: writes, removals: [], base: nil,
                            target: UsbTargetFingerprint(mustExist: mustExist, mustNotExist: []),
                            stagingDirectory: staging.appending(path: session).path, idHighWater: ["content": 2])
    }

    // 수정 모양: 남길 곡(분석 .DAT 덮어쓰기), 뺄 곡(음원·분석 셋·아트워크 둘), 더할 곡(음원·분석 둘·아트워크)
    public static let keepAudio = "Contents/Keep/Album/keep.mp3"
    public static let keepAnalysis = ["PIONEER/USBANLZ/P001/00000001/ANLZ0000.DAT", "PIONEER/USBANLZ/P001/00000001/ANLZ0000.EXT",
                                      "PIONEER/USBANLZ/P001/00000001/ANLZ0000.2EX"]
    public static let keepArtwork = ["PIONEER/Artwork/00001/a1.jpg", "PIONEER/Artwork/00001/a1_m.jpg"]
    public static let goneAudio = "Contents/Gone/Album/gone.mp3"
    public static let goneAnalysis = ["PIONEER/USBANLZ/P002/00000002/ANLZ0000.DAT", "PIONEER/USBANLZ/P002/00000002/ANLZ0000.EXT",
                                      "PIONEER/USBANLZ/P002/00000002/ANLZ0000.2EX"]
    public static let goneArtwork = ["PIONEER/Artwork/00001/a2.jpg", "PIONEER/Artwork/00001/a2_m.jpg"]
    public static let newAudio = "Contents/New/Album/new.mp3"
    public static let newAnalysis = ["PIONEER/USBANLZ/P003/00000003/ANLZ0000.DAT", "PIONEER/USBANLZ/P003/00000003/ANLZ0000.EXT"]
    public static let newArtwork = ["PIONEER/Artwork/00001/a3.jpg"]

    /// 수정 시험 전 USB 모양: DB 셋(옛것)과 두 곡. 뺄 곡의 로컬 원본도 만든다(복원이 다시 복사한다)
    @discardableResult
    public func seedEdit(extraSidecar: Bool = false, extraAppleDouble: Bool = false) -> [String: Data] {
        var seeded: [String: Data] = [:]
        func put(_ path: String, _ data: Data) {
            write(path, data)
            seeded[path] = data
        }
        for path in Self.databasePaths { put(path, Self.random(6000)) }
        put(Self.keepAudio, Self.random(30_000))
        for path in Self.keepAnalysis { put(path, Self.anlz(ppth: "/" + Self.keepAudio)) }
        for path in Self.keepArtwork { put(path, Self.random(1500)) }
        let gone = Self.random(25_000)
        put(Self.goneAudio, gone)
        _ = source("gone/gone.mp3", gone)
        for path in Self.goneAnalysis { put(path, Self.anlz(ppth: "/" + Self.goneAudio)) }
        for path in Self.goneArtwork { put(path, Self.random(1400)) }
        if extraSidecar { put(UsbLayout.oneLibrary + "-wal", Self.random(4000)) }
        if extraAppleDouble { put("PIONEER/rekordbox/._export.pdb", Data(count: 4096)) }
        return seeded
    }

    /// 수정: DB 셋 덮어쓰기, 남길 곡 .DAT 덮어쓰기(PPTH·해시 확인), 새 곡 더하기, 뺄 곡 지우기. base는 지금 USB DB 지문
    public func editChanges(label: String = "edit", removals includeRemovals: Bool = true, ppth: String? = nil) throws -> UsbChangeSet {
        let session = UsbLayout.newSessionID()
        var mustExist: [String: UsbTreeStamp] = [:]
        var mustNotExist: Set<String> = []
        let tree = self.tree()
        func keepStamp(_ path: String) {
            let data = self.data(path)!
            mustExist[path] = UsbTreeStamp(size: Int64(data.count), sha256: Self.sha256(data))
        }
        // 남길 곡
        keepStamp(Self.keepAudio)
        for path in Self.keepAnalysis.dropFirst() + Self.keepArtwork { keepStamp(path) }
        var copies = [UsbFileCopy(source: sources.appending(path: "keep.mp3").path, destination: Self.keepAudio,
                                  size: Int64(data(Self.keepAudio)!.count), sourceSHA1: nil, modificationDate: Self.audioDate,
                                  disposition: .reuse)]
        let newAudioData = Self.random(33_000)
        let newSource = source("\(session)/new.mp3", newAudioData)
        copies.append(UsbFileCopy(source: newSource.path, destination: Self.newAudio, size: Int64(newAudioData.count),
                                  sourceSHA1: Self.sha1(newAudioData), modificationDate: Self.audioDate, disposition: .create))
        mustExist[Self.newAudio] = UsbTreeStamp(size: Int64(newAudioData.count), sha256: Self.sha256(newAudioData))

        var writes: [UsbFileWrite] = []
        let datData = Self.anlz(ppth: "/" + Self.keepAudio)
        let dat = stage("\(session)/keep.DAT", datData)
        writes.append(UsbFileWrite(staged: dat.path, destination: Self.keepAnalysis[0], sha256: dat.sha256, size: dat.size,
                                   modificationDate: nil, disposition: .overwrite,
                                   expectedExistingPPTH: ppth ?? "/" + Self.keepAudio,
                                   expectedExistingSHA256: tree[Self.keepAnalysis[0]]))
        mustExist[Self.keepAnalysis[0]] = UsbTreeStamp(size: dat.size, sha256: dat.sha256)
        for (index, path) in (Self.newAnalysis + Self.newArtwork).enumerated() {
            let data = path.contains("USBANLZ") ? Self.anlz(ppth: "/" + Self.newAudio) : Self.random(1700)
            let staged = stage("\(session)/n\(index)", data)
            writes.append(UsbFileWrite(staged: staged.path, destination: path, sha256: staged.sha256, size: staged.size,
                                       modificationDate: nil, disposition: .create))
            mustExist[path] = UsbTreeStamp(size: staged.size, sha256: staged.sha256)
        }
        // 한 파일은 이미 같은 내용이라 다시 쓰지 않는다
        let reuseData = data(Self.keepArtwork[0])!
        writes.append(UsbFileWrite(staged: stage("\(session)/reuse.jpg", reuseData).path, destination: Self.keepArtwork[0],
                                   sha256: Self.sha256(reuseData), size: Int64(reuseData.count), modificationDate: nil,
                                   disposition: .reuse))

        var removals: [UsbFileRemoval] = []
        if includeRemovals {
            let goneData = data(Self.goneAudio)!
            removals.append(UsbFileRemoval(path: Self.goneAudio, expectedSHA256: Self.sha256(goneData), expectedSize: Int64(goneData.count),
                                           expectedPPTH: nil, localOriginal: sources.appending(path: "gone/gone.mp3").path,
                                           localOriginalSHA1: Self.sha1(goneData)))
            for path in Self.goneAnalysis + Self.goneArtwork {
                let data = self.data(path)!
                removals.append(UsbFileRemoval(path: path, expectedSHA256: Self.sha256(data), expectedSize: Int64(data.count),
                                               expectedPPTH: path.contains("USBANLZ") ? "/" + Self.goneAudio : nil,
                                               localOriginal: nil, localOriginalSHA1: nil))
            }
            mustNotExist = Set(removals.map(\.path))
        } else {
            for path in [Self.goneAudio] + Self.goneAnalysis + Self.goneArtwork { keepStamp(path) }
        }

        var databases: [UsbDatabaseReplacement] = []
        for (index, destination) in Self.databasePaths.enumerated() {
            let staged = stage("\(session)/db\(index)", Self.random(7000 + index))
            databases.append(UsbDatabaseReplacement(format: index == 0 ? .oneLibrary : .deviceLibrary, destination: destination,
                                                    staged: staged.path, sha256: staged.sha256, size: staged.size))
            mustExist[destination] = UsbTreeStamp(size: staged.size, sha256: staged.sha256)
        }
        let base = try UsbWriter.databaseFingerprint(root: root, fileSystem: PosixUsbFileSystem())
        return UsbChangeSet(session: session, label: label, purpose: .edit, formats: UsbFormat.defaultSet, requiredRules: [],
                            databases: databases, copies: copies, writes: writes, removals: removals, base: base,
                            target: UsbTargetFingerprint(mustExist: mustExist, mustNotExist: mustNotExist),
                            stagingDirectory: staging.appending(path: session).path, idHighWater: ["content": 3])
    }

    /// 지금 USB DB 지문을 base로 한 작은 수정 묶음(DB 하나만 바꿈). 드라이 런으로 저널 파일을 덮는 데 쓴다
    public func smallEditChanges(label: String = "small") throws -> UsbChangeSet {
        let session = UsbLayout.newSessionID()
        let staged = stage("\(session)/db", Self.random(5000))
        var mustExist: [String: UsbTreeStamp] = [:]
        mustExist[UsbLayout.exportPdb] = UsbTreeStamp(size: staged.size, sha256: staged.sha256)
        let base = try UsbWriter.databaseFingerprint(root: root, fileSystem: PosixUsbFileSystem())
        return UsbChangeSet(session: session, label: label, purpose: .edit, formats: [.deviceLibrary], requiredRules: [],
                            databases: [UsbDatabaseReplacement(format: .deviceLibrary, destination: UsbLayout.exportPdb,
                                                               staged: staged.path, sha256: staged.sha256, size: staged.size)],
                            copies: [], writes: [], removals: [], base: base,
                            target: UsbTargetFingerprint(mustExist: mustExist, mustNotExist: []),
                            stagingDirectory: staging.appending(path: session).path, idHighWater: [:])
    }

    /// 한 번 쓰기(시험 기본값)
    @discardableResult
    public func write(_ changes: UsbChangeSet, fileSystem: FaultyUsbFileSystem? = nil, options: UsbWriteOptions = .init(),
                      verifiers: [any UsbWriteVerifier] = [UsbFingerprintVerifier()], inspectors: [any UsbWriteInspector] = [],
                      now: Date = .now, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> UsbWriteReport {
        try UsbWriter.write(changes, root: root, paths: paths, guard: writeGuard(), fileSystem: fileSystem ?? self.fileSystem(),
                            verifiers: verifiers, inspectors: inspectors, options: options, ppthReader: Self.ppthReader, now: now,
                            isCancelled: isCancelled)
    }

    public func recover(fileSystem: FaultyUsbFileSystem? = nil, discardTemp: Bool = false, confirmName: String? = nil,
                        expectedVolumeUUID: String? = nil) throws -> UsbWriteReport {
        try UsbWriter.recover(root: root, paths: paths, guard: writeGuard(), fileSystem: fileSystem ?? self.fileSystem(),
                              ppthReader: Self.ppthReader, discardTemp: discardTemp, confirmName: confirmName,
                              expectedVolumeUUID: expectedVolumeUUID)
    }

    public func restore(backup: URL? = nil, fileSystem: FaultyUsbFileSystem? = nil, discardDeviceChanges: Bool = false,
                        dryRun: Bool = false, confirmName: String? = nil, expectedVolumeUUID: String? = nil) throws -> UsbWriteReport {
        try UsbWriter.restore(root: root, paths: paths, backup: backup, guard: writeGuard(), fileSystem: fileSystem ?? self.fileSystem(),
                              discardDeviceChanges: discardDeviceChanges, confirmName: confirmName, dryRun: dryRun,
                              expectedVolumeUUID: expectedVolumeUUID)
    }
}
