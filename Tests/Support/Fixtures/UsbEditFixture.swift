import DJCDomain
import Foundation
import RekordboxKit

/// USB 수정 시험 재료: 합성 로컬 라이브러리(`UsbExportFixture`)와 임시 폴더 USB(`UsbChangeSetFixture`, 디스크 이미지로 보이는 가짜 가드).
/// USB는 DJCrate 내보내기 경로로 만들거나(`export`) rekordbox가 만든 것 같은 합성 USB(`UsbLibraryFixture`)를 둔다.
/// 제목·이름·경로·ID는 모두 지어낸 값이다.
public final class UsbEditFixture: @unchecked Sendable {
    public let usb = UsbChangeSetFixture()
    public let local: UsbExportFixture
    public var appVersion: String? = "7.2.18"
    /// 로컬 사본을 뜬 시각(분석 파일 시각 막힘이 없게 기본은 먼 미래)
    public var snapshotTakenAt: Date? = .distantFuture

    public init() throws {
        local = try UsbExportFixture()
    }

    deinit { usb.remove() }

    /// 곡 여럿(아티스트·앨범은 하나를 함께 쓴다)
    public func addLocal(_ ids: [String], artist: (id: String, name: String) = ("1", "합성 아티스트"),
                         album: (id: String, name: String) = ("30", "합성 앨범")) throws {
        for id in ids { try local.addTrack(id: id, artist: artist, album: album) }
    }

    /// DJCrate 내보내기(빈 USB)로 USB를 만든다
    public func export(tracks: [String], playlists: [String] = [], formats: Set<UsbFormat> = UsbFormat.defaultSet) throws {
        let db = try local.open()
        defer { db.close() }
        let request = try local.request(db, ids: tracks, playlists: playlists, formats: formats)
        let build = try local.build(db, request)
        let staging = usb.folder.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let assembled = try UsbExportAssembly.assembled(model: build.model, plan: build.plan, localDatabase: db, share: local.share,
                                                        staging: staging, formats: formats, session: UsbLayout.newSessionID())
        let report = try UsbWriter.write(assembled.changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(),
                                         fileSystem: usb.fileSystem(), verifiers: UsbExportAssembly.verifiers(for: assembled),
                                         inspectors: [UsbEmptyVolumeInspector()], ppthReader: UsbExportAssembly.ppthReader)
        precondition(report.outcome == .written, "시험 USB를 만들지 못함")
    }

    /// rekordbox가 만든 것 같은 합성 USB를 루트에 둔다
    public func write(_ library: UsbLibraryFixture) throws {
        try library.write(to: UsbTreeFixture(base: usb.usbURL))
    }

    /// USB DB 사본을 떠서 읽는다
    public func source() throws -> UsbEditSource {
        try UsbEditEngine.load(root: usb.root, into: usb.folder.appending(path: "snapshot-\(UUID().uuidString)"))
    }

    /// 편집을 계획한다(준비 폴더는 임시 폴더). withLocal이 거짓이면 로컬 사본 없이
    public func plan(_ edits: [UsbLibraryEdit], withLocal: Bool = true, highWater: [String: Int] = [:],
                     volume: UsbVolumeInfo? = nil) throws -> UsbEditResult {
        let source = try source()
        let db = withLocal ? try local.open() : nil
        defer { db?.close() }
        return try UsbEditEngine.plan(source: source, edits: edits, localDatabase: db, share: withLocal ? local.share : nil,
                                      volume: volume ?? usb.volume, existingFiles: usb.root, fileSystem: usb.fileSystem(),
                                      staging: usb.folder.appending(path: "staging-\(UUID().uuidString)"), session: UsbLayout.newSessionID(),
                                      highWater: highWater, snapshotTakenAt: snapshotTakenAt, localAppVersion: appVersion)
    }

    /// 계획한 것을 쓴다(수정 검사기·검증기 모두)
    public func write(_ result: UsbEditResult, options: UsbWriteOptions = .init()) throws -> UsbWriteReport {
        guard let changes = result.changes else { throw UsbError.writeRefused(result.blocks) }
        let preexisting = try UsbInvariantVerifier.appleDoubles(on: usb.root)
        return try UsbWriter.write(changes, root: usb.root, paths: usb.paths, guard: usb.writeGuard(), fileSystem: usb.fileSystem(),
                                   verifiers: result.verifiers(preexistingAppleDoubles: preexisting), inspectors: [UsbEditInspector()],
                                   options: options, ppthReader: UsbExportAssembly.ppthReader)
    }

    /// 계획하고 바로 쓴다
    @discardableResult
    public func edit(_ edits: [UsbLibraryEdit], withLocal: Bool = true) throws -> (UsbEditResult, UsbWriteReport) {
        let result = try plan(edits, withLocal: withLocal, highWater: usb.journal()?.changes.idHighWater ?? [:])
        return (result, try write(result))
    }

    /// 지금 USB를 읽은 합친 모델
    public func read() throws -> UsbLibrary { try source().current }

    /// 한 형식만 읽은 모델
    public func read(_ format: UsbFormat) throws -> UsbLibrary? {
        let folder = usb.folder.appending(path: "read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = try UsbSnapshot.take(root: usb.root, into: folder)
        switch format {
        case .oneLibrary: return try snapshot.oneLibrary.map { try OneLibraryReader.read(copyAt: $0) }
        case .deviceLibrary: return try PdbReader.read(snapshot: snapshot)?.0
        }
    }

    /// USB의 OneLibrary에 SQL을 바로 쓴다(시험 재료 만들기 전용. 연결을 닫아 사이드카를 남기지 않는다)
    public func oneLibrarySQL(_ sql: String, _ values: [CipherDatabase.Value] = []) throws {
        let db = try CipherDatabase(path: usb.usb(UsbLayout.oneLibrary).path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readWrite)
        defer { db.close() }
        try db.run(sql, values)
        try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in }
    }

    /// OneLibrary 질의 결과(칸 이름 → 글자)
    public func oneLibraryRows(_ sql: String) throws -> [[String: String]] {
        let folder = usb.folder.appending(path: "rows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try UsbSnapshot.copyDatabase(usb.usb(UsbLayout.oneLibrary), into: {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }())
        let db = try CipherDatabase(path: copy.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readOnly)
        defer { db.close() }
        var rows: [[String: String]] = []
        try db.query(sql) { row in
            var values: [String: String] = [:]
            for index in 0..<row.count { values[row.name(Int32(index))] = row.string(Int32(index)) ?? "NULL" }
            rows.append(values)
        }
        return rows
    }

    /// export.pdb(또는 exportExt.pdb) 머리 0x10을 바꾼다
    public func setPdbFlag(_ value: UInt32, file: String = UsbLayout.exportPdb) {
        var data = usb.data(file)!
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(0x10..<0x14, with: $0) }
        usb.write(file, data)
    }

    /// 로컬 곡 칸을 바꾼다(곡 정보 갱신 횟수 등)
    public func updateLocal(_ id: String, _ assignments: String, _ values: [CipherDatabase.Value] = []) throws {
        try local.local.execute("UPDATE djmdContent SET \(assignments) WHERE ID = ?", values + [.text(id)])
    }

    /// 로컬 곡의 share 분석 파일 셋 경로(.DAT)
    public func localAnalysis(_ id: String) -> URL {
        local.share.appending(path: "PIONEER/USBANLZ/l\(id)/m\(id)/ANLZ0000.DAT")
    }
}
