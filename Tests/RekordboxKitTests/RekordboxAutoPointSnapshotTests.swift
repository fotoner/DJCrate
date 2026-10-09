import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 하루 한 번 자동 시점 스냅샷(#228). 시각·달력·클론 가능 여부·rekordbox 켜짐은 주입하고, 합성 사본(`RekordboxFixture`)으로만 뜬다.
@Suite("자동 시점 스냅샷")
struct RekordboxAutoPointSnapshotTests {
    /// 2026-09-25 12:00 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let day = 86_400.0
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func folder(_ fixture: RekordboxFixture) -> URL { fixture.root.appending(path: "point-snapshots") }

    func auto(_ fixture: RekordboxFixture, at time: Date, days: Int = 7, canClone: Bool = true,
              guard writeGuard: RekordboxWriteGuard = copyGuard) throws -> RekordboxPointSnapshot.AutoOutcome {
        try RekordboxPointSnapshot.takeAutoIfDue(database: fixture.database, shareRoot: nil, in: folder(fixture), autoDays: days,
                                                 now: time, calendar: utc, canClone: { _, _ in canClone }, guard: writeGuard)
    }

    /// 라이브러리를 바꾼다(수정 시각이 확실히 달라지게 시각도 밀어 둔다)
    func change(_ fixture: RekordboxFixture, at time: Date) throws {
        var track = TrackSpec(id: String(Int.random(in: 1000...9999)))
        track.title = "새 곡"
        try fixture.add(track)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: fixture.database.path)
    }

    @Test func 처음이면_뜨고_원본_DB의_크기·수정_시각을_적는다() throws {
        let fixture = try RekordboxFixture()
        let outcome = try auto(fixture, at: now)
        guard case let .took(entry) = outcome else { Issue.record("\(outcome)"); return }
        #expect(entry.metadata.kind == .auto && entry.metadata.name.isEmpty && !entry.metadata.pinned)
        #expect(entry.id == "2026-09-25T120000Z-auto")
        #expect(entry.metadata.source == RekordboxPointSnapshot.sourceStamp(of: fixture.database))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).first?.metadata.source == entry.metadata.source, "다시 읽어도 같다")
    }

    @Test func 같은_날에는_라이브러리가_바뀌어도_한_번만_뜬다() throws {
        let fixture = try RekordboxFixture()
        _ = try auto(fixture, at: now)
        try change(fixture, at: now.addingTimeInterval(60))
        #expect(try auto(fixture, at: now.addingTimeInterval(3_600)) == .skipped(.alreadyToday))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).count == 1)
    }

    @Test func 마지막_스냅샷_뒤_바뀌지_않았으면_다음_날에도_뜨지_않고_바뀌면_뜬다() throws {
        let fixture = try RekordboxFixture()
        _ = try auto(fixture, at: now)
        #expect(try auto(fixture, at: now.addingTimeInterval(day)) == .skipped(.unchanged))
        try change(fixture, at: now.addingTimeInterval(day + 60))
        let next = try auto(fixture, at: now.addingTimeInterval(day + 120))
        guard case let .took(entry) = next else { Issue.record("\(next)"); return }
        #expect(entry.id == "2026-09-26T120200Z-auto")
    }

    @Test func 수동_스냅샷_뒤_바뀌지_않았어도_뜨지_않는다() throws {
        let fixture = try RekordboxFixture()
        try RekordboxPointSnapshot.create(name: "정리 전", database: fixture.database, shareRoot: nil, in: folder(fixture), autoDays: 7,
                                          now: now, guard: Self.copyGuard)
        #expect(try auto(fixture, at: now.addingTimeInterval(day)) == .skipped(.unchanged))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.metadata.kind) == [.manual])
    }

    /// 원본 도장이 없는 옛 스냅샷(#224 때 만든 것)으로 만든다: 지금 코드로 뜬 스냅샷에서 도장만 지운다
    func oldSnapshot(_ fixture: RekordboxFixture, at time: Date) throws -> RekordboxPointSnapshot.Entry {
        let entry = try RekordboxPointSnapshot.take(name: "", kind: .manual, database: fixture.database, shareRoot: nil, in: folder(fixture),
                                                    now: time, guard: Self.copyGuard)
        var metadata = entry.metadata
        metadata.source = nil
        try RekordboxPointSnapshot.save(metadata, in: entry.url)
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).first?.metadata.source == nil)
        return entry
    }

    @Test func 원본_도장이_없는_옛_스냅샷_뒤에도_바뀌지_않았으면_스냅샷_안의_DB로_견주어_뜨지_않는다() throws {
        let fixture = try RekordboxFixture()
        _ = try oldSnapshot(fixture, at: now.addingTimeInterval(-day))
        #expect(try auto(fixture, at: now) == .skipped(.unchanged))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.metadata.kind) == [.manual])
    }

    @Test func 원본_도장이_없는_옛_스냅샷_뒤_라이브러리가_바뀌었으면_뜬다() throws {
        let fixture = try RekordboxFixture()
        _ = try oldSnapshot(fixture, at: now.addingTimeInterval(-day))
        try change(fixture, at: now.addingTimeInterval(-60))
        guard case .took = try auto(fixture, at: now) else { Issue.record("바뀐 뒤에도 뜨지 않았다"); return }
    }

    @Test func 원본_도장이_없고_스냅샷_안의_DB도_원본과_견줄_수_없으면_안전한_쪽으로_뜬다() throws {
        let fixture = try RekordboxFixture()
        // 스냅샷 안의 master.db 수정 시각이 달라져 원본과 같다고 볼 수 없다
        let old = try oldSnapshot(fixture, at: now.addingTimeInterval(-day))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * day)],
                                              ofItemAtPath: old.url.appending(path: "master.db").path)
        guard case .took = try auto(fixture, at: now) else { Issue.record("견줄 수 없는데 뜨지 않았다"); return }
    }

    @Test func 도장이_있는_스냅샷은_안의_DB가_아니라_도장으로_견준다() throws {
        let fixture = try RekordboxFixture()
        let entry = try auto(fixture, at: now.addingTimeInterval(-day))
        guard case let .took(taken) = entry else { Issue.record("\(entry)"); return }
        // 스냅샷 안의 DB를 만져도 원본 도장이 그대로면 원본이 바뀌지 않은 것이다
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * day)],
                                              ofItemAtPath: taken.url.appending(path: "master.db").path)
        #expect(try auto(fixture, at: now) == .skipped(.unchanged))
    }

    @Test func rekordbox가_켜져_있으면_건너뛰고_아무것도_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        // 사본이라도 rekordbox가 켜져 있으면 뜨지 않는다(자동은 rekordbox가 꺼졌을 때만)
        let running = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(try auto(fixture, at: now, guard: running) == .skipped(.rekordboxRunning))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder(fixture).path)) ?? []).isEmpty)
    }

    @Test func 뜨는_동안_rekordbox가_켜지면_버리고_오류를_낸다() throws {
        let fixture = try RekordboxFixture()
        let calls = PointSnapshotCallCounter()
        let flipping = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { calls.next() > 1 }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) { try auto(fixture, at: now, guard: flipping) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder(fixture).path)) ?? []).isEmpty)
    }

    @Test func 클론이_안_되면_큰_복사를_하지_않고_건너뛴다() throws {
        let fixture = try RekordboxFixture()
        #expect(try auto(fixture, at: now, canClone: false) == .skipped(.noClone))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).isEmpty)
    }

    @Test func WAL이_남아_있으면_오류_없이_건너뛴다() throws {
        let fixture = try RekordboxFixture()
        try Data(repeating: 1, count: 32).write(to: URL(filePath: fixture.database.path + "-wal"))
        #expect(try auto(fixture, at: now) == .skipped(.walPending))
        #expect(RekordboxPointSnapshot.list(in: folder(fixture)).isEmpty)
    }

    @Test func 보관_일수가_지난_자동은_가장_최근_하나만_남기고_수동·고정·복원_직전은_남긴다() throws {
        let fixture = try RekordboxFixture()
        let manual = try RekordboxPointSnapshot.take(name: "옛 수동", kind: .manual, database: fixture.database, shareRoot: nil,
                                                     in: folder(fixture), now: now.addingTimeInterval(-30 * day), guard: Self.copyGuard)
        let restore = try RekordboxPointSnapshot.take(name: "", kind: .beforeRestore, database: fixture.database, shareRoot: nil,
                                                      in: folder(fixture), now: now.addingTimeInterval(-29 * day), guard: Self.copyGuard)
        var autos: [RekordboxPointSnapshot.Entry] = []
        for offset in [-20.0, -10, -5] {
            try change(fixture, at: now.addingTimeInterval(offset * day - 60))
            guard case let .took(entry) = try auto(fixture, at: now.addingTimeInterval(offset * day), days: 90) else {
                Issue.record("자동 스냅샷을 뜨지 않았다"); return
            }
            autos.append(entry)
        }
        try RekordboxPointSnapshot.setPinned(true, autos[0].url, in: folder(fixture))

        // 바뀐 것이 없어 건너뛰어도 정리는 한다
        #expect(try auto(fixture, at: now, days: 7) == .skipped(.unchanged))
        let kept = Set(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.id))
        // 7일 넘은 자동은 -10일(가장 최근)과 고정한 -20일만, -5일은 보관 일수 안(#236)
        #expect(kept == [manual.id, restore.id, autos[0].id, autos[1].id, autos[2].id])
        // 더 옛 자동(고정 아님)은 지운다: 보관 일수를 줄이면 -5일이 가장 최근 옛 것이 되어 -10일이 지워진다
        #expect(try auto(fixture, at: now, days: 2) == .skipped(.unchanged))
        let shorter = Set(RekordboxPointSnapshot.list(in: folder(fixture)).map(\.id))
        #expect(shorter == [manual.id, restore.id, autos[0].id, autos[2].id])
    }

    @Test func 시험_프로세스는_실제_rekordbox_라이브러리에서_뜨지_않는다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-auto-point-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: DJCError.self) {
            try RekordboxPointSnapshot.takeAutoIfDue(database: real, shareRoot: nil, in: folder, autoDays: 7, now: now, calendar: utc,
                                                     canClone: { _, _ in true }, guard: Self.copyGuard)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
