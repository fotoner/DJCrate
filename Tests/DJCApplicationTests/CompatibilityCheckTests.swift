import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 라이브 쓰기 전 확인(`djc compat`)의 순서: 앱 버전 → 사본 구조 → 변경 카운터. 확인한 줄은 하나씩 알리고, 막히면 그 자리에서 멈춘다(알린 줄은 남는다).
@Suite("rekordbox 쓰기 전 확인")
struct CompatibilityCheckTests {
    struct Failure: Error, Equatable { let step: String }

    /// 가짜 rekordbox·사본. 막을 단계와 부른 차례를 적는다
    final class World: Sendable {
        struct State {
            var failAt: String?
            var counters: (local: Int?, cloud: Int?) = (5, 3)
            var calls: [String] = []
        }
        let state = Mutex(State())

        func fail(_ step: String) throws {
            try state.withLock { state in
                state.calls.append(step)
                if state.failAt == step { throw Failure(step: step) }
            }
        }

        var ports: CompatibilityPorts {
            CompatibilityPorts(
                installedAppVersion: { "7.2.18" }, verifiedAppVersions: ["7.2"],
                checkApp: { _ in try self.fail("app") }, databaseVersion: "6000",
                openSnapshot: { database in
                    try self.fail("open \(database?.lastPathComponent ?? "-")")
                    return CompatibilitySnapshot(fileName: "snapshot.db", checkSchema: { try self.fail("schema") },
                                                 updateCounters: {
                                                     try self.fail("counters")
                                                     return self.state.withLock { $0.counters }
                                                 },
                                                 close: { self.state.withLock { $0.calls.append("close") } })
                },
                checkCounters: { local, cloud in try self.fail("check \(local) \(cloud.map(String.init) ?? "-")") })
        }
    }

    func run(_ world: World, database: URL? = URL(filePath: "/tmp/djc-compat/copy.db")) -> ([CompatibilityCheck.Finding], Failure?) {
        var findings: [CompatibilityCheck.Finding] = []
        do {
            try CompatibilityCheck(ports: world.ports).run(database: database) { findings.append($0) }
            return (findings, nil)
        } catch {
            return (findings, error as? Failure)
        }
    }

    @Test func 확인한_것을_차례로_알리고_카운터까지_본다() {
        let world = World()
        let (findings, failure) = run(world)
        #expect(failure == nil)
        #expect(findings == [.app(installed: "7.2.18", verified: ["7.2"]), .schema(databaseVersion: "6000", file: "snapshot.db"),
                             .counters(local: 5, cloud: 3)])
        #expect(world.state.withLock { $0.calls } == ["app", "open copy.db", "schema", "counters", "check 5 3", "close"])
    }

    @Test func 앱_버전이_막히면_버전_줄만_알리고_사본을_열지_않는다() {
        let world = World()
        world.state.withLock { $0.failAt = "app" }
        let (findings, failure) = run(world)
        #expect(failure == Failure(step: "app"))
        #expect(findings == [.app(installed: "7.2.18", verified: ["7.2"])])
        #expect(world.state.withLock { $0.calls } == ["app"])
    }

    @Test func 구조가_다르면_사본을_닫고_구조_줄을_알리지_않는다() {
        let world = World()
        world.state.withLock { $0.failAt = "schema" }
        let (findings, failure) = run(world, database: nil)
        #expect(failure == Failure(step: "schema"))
        #expect(findings.count == 1)
        #expect(world.state.withLock { $0.calls } == ["app", "open -", "schema", "close"])
    }

    @Test func 로컬_카운터가_없으면_카운터_판정을_하지_않는다() {
        let world = World()
        world.state.withLock { $0.counters = (nil, 3) }
        let (findings, failure) = run(world)
        #expect(failure == nil && findings.last == .counters(local: nil, cloud: 3))
        #expect(!world.state.withLock { $0.calls }.contains { $0.hasPrefix("check") })
    }
}

/// 앱이 라이브러리를 읽은 뒤 보는 확인 결과(#327): `djc compat`(`run`)와 같은 차례·같은 판정 함수로 보고, 막힌 단계만 한 값으로 남긴다.
@Suite("rekordbox 쓰기 전 확인 — 앱 판정")
struct CompatibilityVerdictTests {
    typealias World = CompatibilityCheckTests.World

    @Test func 모두_통과하면_통과이고_run과_같은_차례로_본다() {
        let world = World(), compat = World()
        #expect(CompatibilityCheck(ports: world.ports).verdict(database: URL(filePath: "/tmp/djc-compat/copy.db")) == .passed)
        _ = CompatibilityCheckTests().run(compat)
        #expect(world.state.withLock { $0.calls } == compat.state.withLock { $0.calls })
    }

    @Test(arguments: [("app", CompatibilityCheck.Stage.app), ("open copy.db", .snapshot), ("schema", .schema),
                      ("counters", .counters), ("check 5 3", .counters)])
    func 막히면_그_단계와_설치된_버전을_남기고_run과_같은_자리에서_멈춘다(step: String, stage: CompatibilityCheck.Stage) {
        let world = World(), compat = World()
        world.state.withLock { $0.failAt = step }
        compat.state.withLock { $0.failAt = step }

        let verdict = CompatibilityCheck(ports: world.ports).verdict(database: URL(filePath: "/tmp/djc-compat/copy.db"))
        let (_, failure) = CompatibilityCheckTests().run(compat)

        #expect(verdict == .blocked(stage, installed: "7.2.18"))
        #expect(failure == CompatibilityCheckTests.Failure(step: step))
        #expect(world.state.withLock { $0.calls } == compat.state.withLock { $0.calls })
    }
}

/// 쓸 수 없는 이유 고르기(#327): 실제 쓰기가 막히는 차례(버전 → DB 구조·카운터 → 백업 폴더)에서 앞의 것 하나. 사본을 열지 못했으면 구조를 모른다.
@Suite("쓰기 막힘 이유")
struct LibraryWriteBlockTests {
    @Test func 버전이_DB_구조와_백업보다_앞선다() {
        #expect(LibraryWriteBlock.first(.blocked(.app, installed: "7.3.1"), canBackUp: false) == .unsupportedVersion("7.3.1"))
        #expect(LibraryWriteBlock.first(.blocked(.schema, installed: "7.2.18"), canBackUp: false) == .schema)
        #expect(LibraryWriteBlock.first(.blocked(.counters, installed: nil), canBackUp: false) == .counters)
    }

    @Test func 확인을_통과하면_백업_폴더만_본다() {
        #expect(LibraryWriteBlock.first(.passed, canBackUp: true) == nil)
        #expect(LibraryWriteBlock.first(.passed, canBackUp: false) == .backupFolder)
    }

    @Test func 사본을_열지_못하면_구조를_이유로_삼지_않는다() {
        #expect(LibraryWriteBlock.first(.blocked(.snapshot, installed: "7.2.18"), canBackUp: true) == nil)
        #expect(LibraryWriteBlock.first(.blocked(.snapshot, installed: "7.2.18"), canBackUp: false) == .backupFolder)
    }

    @Test func 이유는_원인과_할_일을_한_문장으로_말한다() {
        #expect(LibraryWriteBlock.unsupportedVersion("7.3.1").reason == "이 rekordbox 버전(7.3)은 아직 지원하지 않으니 DJCrate 업데이트를 확인하세요")
        #expect(LibraryWriteBlock.schema.reason == "rekordbox DB 구조가 DJCrate가 확인한 모양과 다르니 DJCrate 업데이트를 확인하세요")
        #expect(LibraryWriteBlock.counters.reason == "rekordbox 변경 카운터가 클라우드 동기화 카운터보다 작으니 rekordbox를 켜서 동기화를 끝낸 뒤 종료하세요")
        // 칩이 「쓸 수 없음」이라 단정하므로 쓰기 확인 창 문장(「쓰기가 막힐 수 있으니」)과 달리 단정한다
        #expect(LibraryWriteBlock.backupFolder.reason == "쓰기 전 백업을 만들 폴더에 쓸 수 없으니 DJCrate 데이터 폴더의 쓰기 권한을 확인하세요")
        #expect(LibraryWriteBlock.backupFolder.reason != ReflectionPrompts.noBackupText)
        for block in [LibraryWriteBlock.unsupportedVersion("7.3.1"), .schema, .counters, .backupFolder] {
            #expect(!block.reason.contains("\n") && block.reason.count <= 75)
            // 네 이유가 같은 모양으로 끝난다
            #expect(!block.reason.hasSuffix("."), "\(block)")
        }
    }
}
