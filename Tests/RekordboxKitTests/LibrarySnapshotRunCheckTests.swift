import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 스냅샷의 rekordbox 실행 확인(#292): 쓰기 관문과 같은 '라이브 원본인가' 판정을 따른다.
/// 라이브 원본은 rekordbox가 켜져 있거나 켜졌는지 확인하지 못하면 스냅샷을 뜨지 않는다(#323). 임시 사본은 rekordbox가 건드리지 못하므로
/// 실행 여부와 상관없이 뜬다. 실행 여부는 주입한 관문으로 정해 이 Mac의 rekordbox와 가짜 프로세스를 쓰지 않는다.
@Suite("스냅샷의 rekordbox 실행 확인")
struct LibrarySnapshotRunCheckTests {
    /// 라이브 폴더와 사본 폴더. master.db는 복사만 보므로 자리 파일이다(DB를 열지 않아 키 유도 비용이 없다)
    struct Places {
        let folder: TemporaryFolder
        let live: URL
        let copy: URL
        let snapshots: URL

        init() throws {
            folder = try TemporaryFolder()
            live = folder.url.appending(path: "live")
            copy = folder.url.appending(path: "copy")
            snapshots = folder.url.appending(path: "snapshots")
            for directory in [live, copy] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("자리".utf8).write(to: directory.appending(path: "master.db"))
            }
        }

        var liveDatabase: URL { live.appending(path: "master.db") }
        var copyDatabase: URL { copy.appending(path: "master.db") }

        /// `live` 폴더만 라이브로 보는 관문
        func guardFor(running: Bool) -> RekordboxWriteGuard { guardFor(isRunning: { running }) }

        func guardFor(isRunning: @escaping @Sendable () -> Bool) -> RekordboxWriteGuard {
            RekordboxWriteGuard(isRekordboxRunning: isRunning, appVersion: { nil }, liveDirectories: [live])
        }

        /// 스냅샷 폴더에 뜬 사본 수(임시 파일 제외)
        func snapshotCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []).filter { $0.hasSuffix(".db") }.count
        }
    }

    static func isRunningRefusal(_ error: any Error) -> Bool {
        if case DJCError.rekordboxRunning = error { return true }
        return false
    }

    @Test func 라이브_원본은_켜져_있으면_스냅샷을_뜨지_않는다() throws {
        let places = try Places()
        #expect { try LibrarySnapshot.take(from: places.liveDatabase, into: places.snapshots, guard: places.guardFor(running: true)) }
            throws: { Self.isRunningRefusal($0) }
        #expect(places.snapshotCount() == 0)
    }

    @Test func 라이브_원본도_꺼져_있으면_뜬다() throws {
        let places = try Places()
        let taken = try LibrarySnapshot.take(from: places.liveDatabase, into: places.snapshots, guard: places.guardFor(running: false))
        #expect(try Data(contentsOf: taken) == Data("자리".utf8) && places.snapshotCount() == 1)
    }

    @Test func 임시_사본은_켜져_있어도_뜬다() throws {
        let places = try Places()
        let taken = try LibrarySnapshot.take(from: places.copyDatabase, into: places.snapshots, guard: places.guardFor(running: true))
        #expect(try Data(contentsOf: taken) == Data("자리".utf8) && places.snapshotCount() == 1)
    }

    @Test func 사본은_실행_확인을_부르지_않는다() throws {
        let places = try Places()
        let asked = AskedCount()
        _ = try LibrarySnapshot.take(from: places.copyDatabase, into: places.snapshots,
                                     guard: places.guardFor(isRunning: { asked.add(); return true }))
        #expect(asked.value == 0)
    }

    @Test func 확인하지_못해도_라이브_원본은_막고_사본은_뜬다() throws {
        let places = try Places()
        // 띄우지 못함·종료 코드 0·1 밖·신호·시간 초과는 모두 '모름'이고 켜진 것으로 다룬다(#323)
        for failure in RekordboxProcessCheckTests.failures {
            let check = RekordboxProcessCheck { _ in failure }
            let unsure = places.guardFor(isRunning: check.isRunning)
            #expect { try LibrarySnapshot.take(from: places.liveDatabase, into: places.snapshots, guard: unsure) }
                throws: { Self.isRunningRefusal($0) }
            #expect(places.snapshotCount() == 0, "\(failure)")
            // 사본은 라이브 판정부터 아니므로 '모름'을 보지도 않는다. 같은 폴더에 떠도 라이브 쪽 막힘은 그대로다.
            _ = try LibrarySnapshot.take(from: places.copyDatabase, into: places.copy.appending(path: "snapshots"), guard: unsure)
        }
    }

    @Test(arguments: [true, false])
    func 라이브_DB의_링크_별칭도_라이브로_보고_막는다(symbolic: Bool) throws {
        let places = try Places()
        let alias = places.copy.appending(path: "alias.db")
        if symbolic {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: places.liveDatabase)
        } else {
            try FileManager.default.linkItem(at: places.liveDatabase, to: alias)
        }
        #expect { try LibrarySnapshot.take(from: alias, into: places.snapshots, guard: places.guardFor(running: true)) }
            throws: { Self.isRunningRefusal($0) }
        #expect(places.snapshotCount() == 0)
    }

    @Test func force는_라이브_원본도_켜져_있어도_뜬다() throws {
        let places = try Places()
        // 앱은 켜진 것을 알면 force로 떠서 사본 안에서 WAL을 합친다. 이 길은 그대로다.
        let taken = try LibrarySnapshot.take(from: places.liveDatabase, into: places.snapshots, force: true, guard: places.guardFor(running: true))
        #expect(try Data(contentsOf: taken) == Data("자리".utf8))
    }

    @Test func WAL이_남은_사본은_실행_여부와_상관없이_막는다() throws {
        let places = try Places()
        try Data([1]).write(to: URL(filePath: places.copyDatabase.path + "-wal"))
        for running in [true, false] {
            #expect { try LibrarySnapshot.take(from: places.copyDatabase, into: places.snapshots, guard: places.guardFor(running: running)) }
                throws: { if case DJCError.writeAheadLogPresent = $0 { true } else { false } }
        }
        #expect(places.snapshotCount() == 0)
    }

    @Test func 기본_관문은_실제_rekordbox_폴더와_환경으로_고른_폴더를_라이브로_보고_임시_사본은_보지_않는다() throws {
        let places = try Places()
        let system = RekordboxWriteGuard.system
        #expect(system.isLive(LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")))
        #expect(system.isLive(LibrarySnapshot.rekordboxDirectory.appending(path: "master.db")))
        #expect(!system.isLive(places.copyDatabase) && !system.isLive(places.liveDatabase))
    }
}

/// 실행 확인을 몇 번 불렀는지(스레드에 안전한 세기)
private final class AskedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
