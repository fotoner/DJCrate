import CryptoKit
import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 시점 스냅샷 만들기·목록·고정·보존 정리(#224). 합성 사본(`RekordboxFixture`·`AnlzBuilder`)으로만 한다.
@Suite("시점 스냅샷")
struct RekordboxPointSnapshotTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    /// 사본을 라이브로 보지 않는 관문(꺼짐)
    static let copyGuard = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" })

    func analysedTrack(_ fixture: RekordboxFixture, title: String = "시점 곡") throws -> TrackSpec {
        let uuid = UUID().uuidString.lowercased()
        var track = TrackSpec(uuid: uuid)
        track.title = title
        track.analysisDataPath = "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 128, first: 500.3, count: 64)
        let dat = AnlzBuilder.dat(beats: beats)
        try fixture.putAnalysis(for: track, dat: dat, ext: AnlzBuilder.ext(beats: beats))
        try fixture.addContentFile(for: track, hash: Insecure.MD5.hash(data: dat).map { String(format: "%02x", $0) }.joined(), size: dat.count)
        return track
    }

    func artwork(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> URL {
        let folder = fixture.shareRoot.appending(path: "PIONEER/Artwork/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "artwork.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
        return file
    }

    func create(_ fixture: RekordboxFixture, name: String = "정리 전", kind: RekordboxPointSnapshot.Kind = .manual, at time: Date? = nil,
                guard writeGuard: RekordboxWriteGuard = copyGuard) throws -> RekordboxPointSnapshot.Entry {
        try RekordboxPointSnapshot.create(name: name, kind: kind, database: fixture.database, shareRoot: nil,
                                          in: fixture.root.appending(path: "point-snapshots"), autoDays: 7, now: time ?? now, guard: writeGuard)
    }

    /// 정리 없이 뜬다(보존 정리 시험의 준비)
    func take(_ fixture: RekordboxFixture, name: String = "", kind: RekordboxPointSnapshot.Kind, at time: Date) throws -> RekordboxPointSnapshot.Entry {
        try RekordboxPointSnapshot.take(name: name, kind: kind, database: fixture.database, shareRoot: nil,
                                        in: fixture.root.appending(path: "point-snapshots"), now: time, guard: Self.copyGuard)
    }

    func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func DB·재생_목록_파일·분석·앨범아트_폴더를_한_시점으로_담고_정보를_적는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1234)
        let track = try analysedTrack(fixture)
        let art = try artwork(fixture, track)
        try Data("<xml/>".utf8).write(to: fixture.root.appending(path: "masterPlaylists6.xml"))
        try Data("<sync/>".utf8).write(to: fixture.root.appending(path: "playlists3.sync"))
        // 담지 않는 rekordbox 폴더 파일
        try Data("x".utf8).write(to: fixture.root.appending(path: "networkAnalyze6.db"))

        let entry = try create(fixture, name: "  큰 정리 전  ")
        #expect(entry.metadata.name == "큰 정리 전")
        #expect(entry.metadata.kind == .manual && !entry.metadata.pinned)
        #expect(entry.metadata.libraryID == "1")
        #expect(entry.metadata.localUpdateCount == 1234)
        #expect(entry.metadata.trackCount == 1)
        #expect(entry.metadata.createdAt == now)
        #expect(entry.metadata.items == ["master.db", "masterPlaylists6.xml", "playlists3.sync", "share/PIONEER/USBANLZ", "share/PIONEER/Artwork"])
        #expect(entry.id == "2026-09-25T120000Z-manual")

        let dat = fixture.analysisURL(for: track)
        let relative = String(dat.path.dropFirst(fixture.shareRoot.path.count))
        #expect(try Data(contentsOf: entry.url.appending(path: "share" + relative)) == Data(contentsOf: dat))
        #expect(try Data(contentsOf: entry.url.appending(path: "share/PIONEER/Artwork/\(track.uuid.prefix(3))/\(track.uuid.dropFirst(3))/artwork.jpg"))
            == Data(contentsOf: art))
        #expect(try Data(contentsOf: entry.url.appending(path: "playlists3.sync")) == Data("<sync/>".utf8))
        #expect(!FileManager.default.fileExists(atPath: entry.url.appending(path: "networkAnalyze6.db").path))
        // 읽느라 생긴 곁 파일은 남기지 않는다
        #expect(!FileManager.default.fileExists(atPath: entry.url.appending(path: "master.db-shm").path))
        // 토큰이 든 DB: 폴더 0700, 파일 0600
        #expect(try permissions(entry.url) == 0o700)
        #expect(try permissions(fixture.root.appending(path: "point-snapshots")) == 0o700)
        #expect(try permissions(entry.url.appending(path: "master.db")) == 0o600)
        #expect(try permissions(entry.url.appending(path: "snapshot.json")) == 0o600)

        // 뜬 뒤 라이브러리를 고쳐도 스냅샷은 그대로(클론은 쓰기 시 복사)
        let before = try Data(contentsOf: entry.url.appending(path: "share" + relative))
        try Data("changed".utf8).write(to: dat)
        #expect(try Data(contentsOf: entry.url.appending(path: "share" + relative)) == before)
    }

    @Test func 없는_폴더·파일은_빼고_뜬다() throws {
        let fixture = try RekordboxFixture()
        let entry = try create(fixture)
        #expect(entry.metadata.items == ["master.db"])
        #expect(entry.metadata.trackCount == 0)
    }

    @Test func rekordbox가_켜져_있으면_뜨지_않고_아무것도_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) { try create(fixture, guard: running) }
        #expect(RekordboxPointSnapshot.list(in: fixture.root.appending(path: "point-snapshots")).isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "point-snapshots").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func 뜨는_동안_rekordbox가_켜지면_버린다() throws {
        let fixture = try RekordboxFixture()
        // 처음 물을 때는 꺼짐, 뜬 뒤 다시 물으면 켜짐
        let calls = PointSnapshotCallCounter()
        let flipping = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { calls.next() > 0 }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) { try create(fixture, guard: flipping) }
        let folder = fixture.root.appending(path: "point-snapshots")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    }

    @Test func WAL이_남아_있으면_뜨지_않는다() throws {
        let fixture = try RekordboxFixture()
        try Data(repeating: 1, count: 32).write(to: URL(filePath: fixture.database.path + "-wal"))
        #expect(throws: DJCError.self) { try create(fixture) }
    }

    @Test func 분석_폴더_안에_심볼릭_링크가_있으면_뜨지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try analysedTrack(fixture)
        let link = fixture.analysisURL(for: track).deletingLastPathComponent().appending(path: "ANLZ0000.2EX")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(throws: DJCError.self) { try create(fixture) }
        #expect(RekordboxPointSnapshot.list(in: fixture.root.appending(path: "point-snapshots")).isEmpty)
    }

    @Test func 시험_프로세스는_실제_rekordbox_라이브러리에서_뜨지_않는다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-point-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = LibrarySnapshot.realRekordboxDirectory.appending(path: "master.db")
        #expect(throws: DJCError.self) {
            try RekordboxPointSnapshot.create(name: "실제", database: real, shareRoot: nil, in: folder, autoDays: 7, now: now,
                                              guard: RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { nil }))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func 목록은_최근_것부터이고_같은_초에_떠도_겹치지_않는다() throws {
        let fixture = try RekordboxFixture()
        let a = try create(fixture, name: "A")
        let b = try create(fixture, name: "B")
        let c = try create(fixture, name: "C", at: now.addingTimeInterval(60))
        #expect(a.id != b.id && b.id.hasSuffix("-manual-2"))
        let list = RekordboxPointSnapshot.list(in: fixture.root.appending(path: "point-snapshots"))
        #expect(list.map(\.metadata.name) == ["C", "B", "A"])
        #expect(RekordboxPointSnapshot.find(c.id, in: fixture.root.appending(path: "point-snapshots"))?.metadata.name == "C")
        #expect(RekordboxPointSnapshot.find("B", in: fixture.root.appending(path: "point-snapshots"))?.id == b.id)
        #expect(RekordboxPointSnapshot.size(of: a.url) > 0)
    }

    @Test func 고정하면_정보에_남고_고정한_스냅샷은_고정을_풀기_전에는_지우지_않는다() throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        let entry = try create(fixture)
        try RekordboxPointSnapshot.setPinned(true, entry.url, in: folder)
        #expect(RekordboxPointSnapshot.list(in: folder).first?.metadata.pinned == true)
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.delete(entry.url, in: folder) }
        try RekordboxPointSnapshot.setPinned(false, entry.url, in: folder)
        try RekordboxPointSnapshot.delete(entry.url, in: folder)
        #expect(RekordboxPointSnapshot.list(in: folder).isEmpty)
    }

    @Test func 스냅샷_폴더_밖의_항목은_고정하거나_지우지_않는다() throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        _ = try create(fixture)
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.delete(fixture.backups, in: folder) }
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.setPinned(true, fixture.root, in: folder) }
        #expect(FileManager.default.fileExists(atPath: fixture.backups.path))
    }

    @Test func 보존_정리는_수동·고정을_두고_자동은_일수로_복원_직전은_세_개만_남긴다() throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        let day = 86_400.0
        let oldManual = try take(fixture, name: "아주 옛 수동", kind: .manual, at: now.addingTimeInterval(-60 * day))
        let oldAuto = try take(fixture, kind: .auto, at: now.addingTimeInterval(-8 * day))
        let olderAuto = try take(fixture, kind: .auto, at: now.addingTimeInterval(-20 * day))
        let pinnedAuto = try take(fixture, kind: .auto, at: now.addingTimeInterval(-9 * day))
        try RekordboxPointSnapshot.setPinned(true, pinnedAuto.url, in: folder)
        let recentAuto = try take(fixture, kind: .auto, at: now.addingTimeInterval(-6 * day))
        var restores: [RekordboxPointSnapshot.Entry] = []
        for index in 0..<5 { restores.append(try take(fixture, kind: .beforeRestore, at: now.addingTimeInterval(Double(index - 10) * 60))) }
        try RekordboxPointSnapshot.setPinned(true, restores[0].url, in: folder)

        let removed = RekordboxPointSnapshot.prune(in: folder, autoDays: 7, now: now)
        let kept = Set(RekordboxPointSnapshot.list(in: folder).map(\.id))
        #expect(kept.contains(oldManual.id) && kept.contains(pinnedAuto.id) && kept.contains(recentAuto.id))
        // 7일 넘은 자동 중 가장 최근 하나는 남기고(#236), 더 옛 것은 지운다
        #expect(kept.contains(oldAuto.id) && !kept.contains(olderAuto.id))
        // 복원 직전: 고정한 하나 + 최근 셋
        #expect(kept.contains(restores[0].id))
        #expect(Set(restores[2...4].map(\.id)).isSubset(of: kept))
        #expect(!kept.contains(restores[1].id))
        #expect(removed.count == 2)

        // 일수를 줄이면 7일 안이던 자동도 옛 것이 된다: 그중 가장 최근 하나만 남는다(고정은 그대로)
        RekordboxPointSnapshot.prune(in: folder, autoDays: 3, now: now)
        let after = Set(RekordboxPointSnapshot.list(in: folder).map(\.id))
        #expect(after.contains(recentAuto.id) && !after.contains(oldAuto.id) && after.contains(pinnedAuto.id))
    }

    /// 자동 스냅샷을 주어진 며칠 전 시각들로 뜨고 정리한 뒤 남은 것의 며칠 전 값(옛 → 새 순서 아님, 큰 값 먼저)을 돌려준다
    func keptAutoAges(_ ages: [Double], pinned pinnedAges: Set<Double> = []) throws -> [Double] {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        for age in ages {
            let entry = try take(fixture, kind: .auto, at: now.addingTimeInterval(-age * 86_400))
            if pinnedAges.contains(age) { try RekordboxPointSnapshot.setPinned(true, entry.url, in: folder) }
        }
        RekordboxPointSnapshot.prune(in: folder, autoDays: 7, now: now)
        return RekordboxPointSnapshot.list(in: folder).map { (now.timeIntervalSince($0.metadata.createdAt) / 86_400).rounded() }.sorted(by: >)
    }

    @Test func 보존_정리는_7일_안의_자동만_있으면_그대로_둔다() throws {
        #expect(try keptAutoAges([1, 3, 6]) == [6, 3, 1])
    }

    @Test func 보존_정리는_7일_넘은_자동_중_가장_최근_하나를_남긴다() throws {
        #expect(try keptAutoAges([2, 8, 10, 30]) == [8, 2])
    }

    @Test func 보존_정리는_7일_넘은_자동이_하나뿐이어도_남긴다() throws {
        #expect(try keptAutoAges([40]) == [40])
        #expect(try keptAutoAges([1, 40]) == [40, 1])
    }

    @Test func 보존_정리는_고정한_옛_자동이_가장_최근이면_다른_옛_자동은_지운다() throws {
        // 가장 최근 옛 자동(8일)이 고정이라 이미 남는다. 더 옛 것(20일)은 지운다
        #expect(try keptAutoAges([8, 20], pinned: [8]) == [8])
        // 가장 최근 옛 자동이 아닌 것만 고정이면 둘 다 남는다
        #expect(try keptAutoAges([8, 20], pinned: [20]) == [20, 8])
    }

    @Test func 보존_정리는_수동과_복원_직전을_옛_자동으로_세지_않는다() throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        let manual = try take(fixture, name: "수동", kind: .manual, at: now.addingTimeInterval(-9 * 86_400))
        let auto = try take(fixture, kind: .auto, at: now.addingTimeInterval(-30 * 86_400))
        RekordboxPointSnapshot.prune(in: folder, autoDays: 7, now: now)
        let kept = Set(RekordboxPointSnapshot.list(in: folder).map(\.id))
        #expect(kept.contains(manual.id) && kept.contains(auto.id))
    }

    @Test func 만들면_보존_정리도_한다() throws {
        let fixture = try RekordboxFixture()
        let latestOld = try take(fixture, kind: .auto, at: now.addingTimeInterval(-40 * 86_400))
        let older = try take(fixture, kind: .auto, at: now.addingTimeInterval(-50 * 86_400))
        _ = try create(fixture, name: "새 수동")
        #expect(FileManager.default.fileExists(atPath: latestOld.url.path), "7일 넘은 자동 중 가장 최근 하나는 남긴다(#236)")
        #expect(!FileManager.default.fileExists(atPath: older.url.path))
    }

    @Test func 반쯤_뜬_폴더는_목록에_없고_오래되면_치운다() throws {
        let fixture = try RekordboxFixture()
        let folder = fixture.root.appending(path: "point-snapshots")
        _ = try create(fixture)
        let partial = folder.appending(path: ".partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data().write(to: partial.appending(path: "master.db"))
        #expect(RekordboxPointSnapshot.list(in: folder).count == 1)
        RekordboxPointSnapshot.prune(in: folder, autoDays: 7, now: Date())
        #expect(FileManager.default.fileExists(atPath: partial.path), "뜨는 중일 수 있는 새 폴더는 두고")
        RekordboxPointSnapshot.prune(in: folder, autoDays: 7, now: Date().addingTimeInterval(3_600))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func 같은_볼륨이면_클론으로_뜬다고_적는다() throws {
        let fixture = try RekordboxFixture()
        let entry = try create(fixture)
        #expect(entry.metadata.cloned == RekordboxPointSnapshot.canClone(from: fixture.root, to: fixture.root))
    }
}

/// 부를 때마다 하나씩 늘어나는 수(관문 흉내)
final class PointSnapshotCallCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
