import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("로컬 스냅샷 시각")
struct UsbSnapshotTimeTests {
    /// 임시 폴더에 빈 사본 파일을 만들고 mtime을 준다.
    func database(named name: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-snaptime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data("db".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test("명시한 시각이 이름보다 앞선다")
    func explicitWins() throws {
        let url = try database(named: "master-2026-01-02T030405.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolved = try UsbSnapshotTime.resolve(explicit: "2026-09-27T11:41:08Z", database: url)
        #expect(resolved.date == utc(2026, 9, 27, 11, 41, 8))
        #expect(resolved.source == .explicit)
        let offset = try UsbSnapshotTime.resolve(explicit: "2026-09-27T20:41:08+09:00", database: url)
        #expect(offset.date == utc(2026, 9, 27, 11, 41, 8))
    }

    @Test("이름의 시각은 UTC")
    func fileNameUTC() throws {
        let url = try database(named: "master-2026-01-02T030405.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolved = try UsbSnapshotTime.resolve(explicit: nil, database: url)
        #expect(resolved.date == utc(2026, 1, 2, 3, 4, 5))
        #expect(resolved.source == .fileName)
    }

    @Test("이름에 시각이 없으면 파일 mtime")
    func mtimeFallback() throws {
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        let url = try database(named: "m.db", modified: modified)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolved = try UsbSnapshotTime.resolve(explicit: nil, database: url)
        #expect(resolved.date == modified)
        #expect(resolved.source == .modificationDate)
    }

    @Test("풀리지 않는 명시 시각과 없는 파일은 던진다")
    func badExplicitThrows() throws {
        let url = try database(named: "master-2026-01-02T030405.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for bad in ["2026-09-27 11:41:08", "2026-09-27T11:41:08", "어제", ""] {
            #expect(throws: UsbError.self, "\(bad)") { try UsbSnapshotTime.resolve(explicit: bad, database: url) }
        }
        let missing = url.deletingLastPathComponent().appending(path: "none.db")
        #expect(throws: UsbError.self) { try UsbSnapshotTime.resolve(explicit: nil, database: missing) }
    }

    @Test("어디서 풀었는지 알려 준다")
    func sourceReported() throws {
        let named = try database(named: "master-2026-01-02T030405.db")
        let plain = try database(named: "copy.db")
        defer {
            try? FileManager.default.removeItem(at: named.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: plain.deletingLastPathComponent())
        }
        // 보고에 적는 이름(rawValue)
        let sources = try [
            UsbSnapshotTime.resolve(explicit: "2026-09-27T11:41:08.250Z", database: plain).source,
            UsbSnapshotTime.resolve(explicit: nil, database: named).source,
            UsbSnapshotTime.resolve(explicit: nil, database: plain).source,
        ]
        #expect(sources.map(\.rawValue) == ["explicit", "fileName", "modificationDate"])
    }
}
